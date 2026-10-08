import SwiftUI
import SwiftData
import AppKit

/// Ensures the Python worker is stopped when the app quits, and that closing the
/// window actually quits the app (so the worker lifecycle matches the app's).
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var onTerminate: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppDelegate.onTerminate?()
        }
    }
}

@main
struct ZiggyNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(
                for: MeetingRecord.self, TranscriptLineRecord.self, SuggestionRecord.self
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .modelContainer(container)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    app.attach(context: container.mainContext)
                    AppDelegate.onTerminate = { app.shutdown() }
                    Task { await app.bootstrap() }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            // Keep the standard ⌘, shortcut, but open our in-app Settings page
            // instead of a separate popup window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { app.pendingRoute = .settings }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Worker Logs") { app.pendingRoute = .workerLogs }
            }
        }
    }
}

/// Gates the main UI behind the bootstrap sequence (mic → worker → Temporal client).
/// Once bootstrap finishes — successfully *or* with a failure — we show the main
/// window so the in-app Settings and Worker Logs pages are always reachable (the
/// failure surfaces as an inline banner there). The full-screen overlay is only
/// used for the brief transient startup phases.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .ready, .failed:
                ContentView()
            default:
                BootstrapOverlay(onRetry: { Task { await app.bootstrap() } })
            }
        }
        .tint(Theme.purple)
    }
}
