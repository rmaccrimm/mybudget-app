import Foundation
import os

/// Runs the `mybudget-server` binary bundled in `Contents/MacOS`.
///
/// The server listens on a free port (SPEC 1.2) and announces it as its first
/// line on stdout (SPEC 1.3), so several copies of the app, or a server you
/// started yourself, never fight over a port.
@MainActor
final class ServerProcess {
    enum LaunchError: LocalizedError {
        case missingBinary
        case exitedBeforeListening(Int32)
        case unexpectedOutput(String)

        var errorDescription: String? {
            switch self {
            case .missingBinary:
                "The app bundle has no mybudget-server binary."
            case .exitedBeforeListening(let status):
                "The server exited with status \(status) before it started listening."
            case .unexpectedOutput(let line):
                "The server's first line wasn't its address: \(line)"
            }
        }
    }

    private var process: Process?
    /// The server's stdin. Keeping it open keeps the server running (SPEC 1.4).
    private var stdin: Pipe?

    /// Starts the server and returns its base URL once it's listening.
    func start() async throws -> URL {
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "mybudget-server") else {
            throw LaunchError.missingBinary
        }
        let process = Process()
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["MYBUDGET_ADDR"] = "127.0.0.1:0"
        // The server keeps its data here once SPEC section 15 (persistence) is
        // built; until then it ignores this and keeps everything in memory.
        environment["MYBUDGET_DATA"] = URL.applicationSupportDirectory
            .appending(path: "MyBudget", directoryHint: .isDirectory)
            .path(percentEncoded: false)
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
        try process.run()
        self.process = process
        self.stdin = stdin

        do {
            let line = await Self.firstLine(of: stdout.fileHandleForReading)
            guard let line else {
                process.waitUntilExit()
                throw LaunchError.exitedBeforeListening(process.terminationStatus)
            }
            return try Self.baseURL(fromListeningLine: line)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        try? stdin?.fileHandleForWriting.close()
        stdin = nil
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
