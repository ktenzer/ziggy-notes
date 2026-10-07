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

        SwiftUI.Settings {
            SettingsView()
                .environment(app)
        }
    }
}

/// Gates the main UI behind the bootstrap sequence (mic → worker → Temporal client).
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.isReady {
                ContentView()
            } else {
                BootstrapOverlay(onRetry: { Task { await app.bootstrap() } })
            }
        }
        .tint(Theme.purple)
    }
}
