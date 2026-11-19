import Foundation
import os

private let log = Logger(subsystem: "local.mybudget.MyBudget", category: "server")

/// Runs the `mybudget-server` binary bundled in `Contents/MacOS`.
///
/// The server listens on a free port (SPEC 1.2) and announces it as its first
/// line on stdout (SPEC 1.3), so several copies of the app, or a server you
/// started yourself, never fight over a port.
///
/// The server keeps each plan in a SQLite file in its data directory (SPEC
/// section 15), and saves every change before it answers the request.
@MainActor
final class ServerProcess {
    enum LaunchError: LocalizedError {
        case missingBinary
        /// The status, and what the server wrote to stderr, such as why it
        /// couldn't use its data directory (SPEC 15.1).
        case exitedBeforeListening(Int32, String)
        case unexpectedOutput(String)

        var errorDescription: String? {
            switch self {
            case .missingBinary:
                "The app bundle has no mybudget-server binary."
            case .exitedBeforeListening(let status, let message):
                "The server exited with status \(status) before it started listening."
                    + (message.isEmpty ? "" : "\n\n\(message)")
            case .unexpectedOutput(let line):
                "The server's first line wasn't its address: \(line)"
            }
        }
    }

    /// `Application Support/MyBudget` in the app's container. Plan files are
    /// named after their plans, such as `Household.sqlite` (SPEC 15.2).
    nonisolated static let defaultDataDirectory = URL.applicationSupportDirectory
        .appending(path: "MyBudget", directoryHint: .isDirectory)

    /// How long `stop()` waits for the server to exit after closing its stdin.
    /// The server finishes a save in progress first, which takes it at most
    /// half a second, inside SPEC 1.4's one.
    private static let exitPatience: Duration = .seconds(1)

    /// Where the server keeps its plans, or `nil` to keep them only in memory.
    let dataDirectory: URL?
    private var process: Process?
    /// The server's stdin. Keeping it open keeps the server running (SPEC 1.4).
    private var stdin: Pipe?

    init(dataDirectory: URL?) {
        self.dataDirectory = dataDirectory
    }

    /// Starts the server and returns its base URL once it's listening.
    func start() async throws -> URL {
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "mybudget-server") else {
            throw LaunchError.missingBinary
        }
        let process = Process()
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["MYBUDGET_ADDR"] = "127.0.0.1:0"
        // SPEC 15.1: the server creates the directory if it's missing. An
        // unset or empty MYBUDGET_DATA keeps everything in memory.
        environment["MYBUDGET_DATA"] = dataDirectory?.path(percentEncoded: false)
        // SPEC 1.4: the server exits when its stdin reaches end of file. Only
        // this process holds the pipe's write end, and the kernel closes it
        // when this process dies, so the server never outlives the app, even
        // after a crash.
        environment["MYBUDGET_EXIT_ON_STDIN_EOF"] = "1"
        process.environment = environment
        let stdin = Pipe()
        process.standardInput = stdin
        let stdout = Pipe()
        process.standardOutput = stdout
        let stderr = Pipe()
        process.standardError = stderr
        let errors = ErrorOutput(reading: stderr.fileHandleForReading)
        try process.run()
        self.process = process
        self.stdin = stdin

        do {
            let line = await Self.firstLine(of: stdout.fileHandleForReading)
            guard let line else {
                process.waitUntilExit()
                throw LaunchError.exitedBeforeListening(
                    process.terminationStatus, await errors.untilClosed()
                )
            }
            return try Self.baseURL(fromListeningLine: line)
        } catch {
            stop()
            throw error
        }
    }

    /// Closes the server's stdin, so it exits once any save in progress is
    /// done (SPEC 1.4), and sends it `SIGTERM` if it's still running after
    /// `exitPatience`. A save the signal cuts short is rolled back, as after a
    /// crash (SPEC 15.5), so this only spares the last change.
    func stop() {
        try? stdin?.fileHandleForWriting.close()
        stdin = nil
        if let process {
            let deadline = ContinuousClock.now + Self.exitPatience
            while process.isRunning, ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if process.isRunning {
                log.error("The server didn't exit after its stdin closed; terminating it")
                process.terminate()
            }
        }
        process = nil
    }

    /// Returns the first line of `handle`, or `nil` if it ends first. Reading
    /// continues in the background, discarding everything, so the server never
    /// blocks on a full pipe. The reads run off a dispatch source, so no thread
    /// waits on the pipe.
    nonisolated private static func firstLine(of handle: FileHandle) async -> String? {
        let state = OSAllocatedUnfairLock(
            initialState: (buffer: Data(), continuation: CheckedContinuation<String?, Never>?.none)
        )
        return await withCheckedContinuation { continuation in
            state.withLock { $0.continuation = continuation }
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                }
                let (waiting, line): (CheckedContinuation<String?, Never>?, String?) = state.withLock {
                    guard let waiting = $0.continuation else { return (nil, nil) }
                    $0.buffer.append(chunk)
                    if let newline = $0.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        $0.continuation = nil
                        return (waiting, String(decoding: $0.buffer[..<newline], as: UTF8.self))
                    }
                    if chunk.isEmpty {
                        $0.continuation = nil
                        return (waiting, nil)
                    }
                    return (nil, nil)
                }
                waiting?.resume(returning: line)
            }
        }
    }

    /// Turns `listening on 127.0.0.1:54321` into `http://127.0.0.1:54321`.
    nonisolated static func baseURL(fromListeningLine line: String) throws -> URL {
        let prefix = "listening on "
        guard line.hasPrefix(prefix),
              let url = URL(string: "http://" + line.dropFirst(prefix.count)),
              url.host() != nil, url.port != nil
        else {
            throw LaunchError.unexpectedOutput(line)
        }
        return url
    }
}

/// Reads the server's stderr until it closes, so the server never blocks on
/// a full pipe. Each line goes to the log: the server reports there the plan
/// files it skips at startup (SPEC 15.7) and the changes it can't save
/// (15.10). The lines are also kept for `untilClosed()`.
nonisolated private final class ErrorOutput: Sendable {
    private struct State {
        var partial = Data()
        var lines: [String] = []
        var closed = false
        var waiting: [CheckedContinuation<String, Never>] = []
    }

    /// Lines beyond this many are logged but not kept.
    private static let keptLines = 20
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(reading handle: FileHandle) {
        handle.readabilityHandler = { [state] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            }
            let (lines, waiting, text) = state.withLock {
                (state: inout State) -> ([String], [CheckedContinuation<String, Never>], String) in
                state.partial.append(chunk)
                var lines: [String] = []
                while let newline = state.partial.firstIndex(of: UInt8(ascii: "\n")) {
                    lines.append(String(decoding: state.partial[..<newline], as: UTF8.self))
                    state.partial.removeSubrange(...newline)
                }
                if chunk.isEmpty, !state.partial.isEmpty {
                    lines.append(String(decoding: state.partial, as: UTF8.self))
                    state.partial.removeAll()
                }
                state.lines.append(contentsOf: lines)
                state.lines = Array(state.lines.suffix(ErrorOutput.keptLines))
                guard chunk.isEmpty else { return (lines, [], "") }
                state.closed = true
                defer { state.waiting.removeAll() }
                return (lines, state.waiting, state.lines.joined(separator: "\n"))
            }
            for line in lines {
                log.error("Server: \(line, privacy: .public)")
            }
            for continuation in waiting {
                continuation.resume(returning: text)
            }
        }
    }

    /// Everything the server wrote, once it has closed stderr: the last
    /// `keptLines` lines, trimmed of surrounding white space.
    func untilClosed() async -> String {
        let text = await withCheckedContinuation { continuation in
            let text: String? = state.withLock { state in
                guard state.closed else {
                    state.waiting.append(continuation)
                    return nil
                }
                return state.lines.joined(separator: "\n")
            }
            if let text { continuation.resume(returning: text) }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
