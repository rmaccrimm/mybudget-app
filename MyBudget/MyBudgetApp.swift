import AppKit
import SwiftUI

@main
struct MyBudgetApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("MyBudget", id: "main") {
            ContentView(model: appDelegate.model)
        }
        .defaultSize(width: 1160, height: 680)
        .commands { PlanCommands(app: appDelegate.model) }
    }
}

/// Owns the server's lifetime: it starts before the window appears and stops
/// when the app quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // When the app only hosts the unit tests, the tests start their own
        // servers, and XCTest ends the app without applicationWillTerminate.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task { await model.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
