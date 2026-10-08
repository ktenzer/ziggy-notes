import SwiftUI
import AppKit

/// In-app worker log viewer. Shows the Python worker's live combined stdout/stderr
/// (captured by `WorkerManager`), its current status, and a restart control. This
/// replaces having to run the worker in a terminal to see its output.
struct WorkerLogsView: View {
    @Environment(AppModel.self) private var app
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            logScroll
        }
        .background(Theme.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.plaintext").foregroundStyle(Theme.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Worker Logs")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(app.config.summary)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            statusBadge
            Spacer()
            Button { copyLog() } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .disabled(app.worker.recentLog.isEmpty)

            Button { onRetry() } label: {
                Label("Restart Worker", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.purple)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusBadge: some View {
        let (label, color) = statusLabelColor
        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    private var statusLabelColor: (String, Color) {
        switch app.worker.status {
        case .idle: return ("Idle", Theme.textSecondary)
        case .starting: return ("Starting", Theme.mediumPriority)
        case .running: return ("Running", Theme.lowPriority)
        case .failed: return ("Failed", Theme.highPriority)
        case .stopped: return ("Stopped", Theme.textSecondary)
        }
    }

    // MARK: - Log

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(app.worker.recentLog.isEmpty ? "No worker output yet." : app.worker.recentLog)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(app.worker.recentLog.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                // Anchor so new output scrolls into view.
                Color.clear.frame(height: 1).id("logBottom")
            }
            .onChange(of: app.worker.recentLog) { _, _ in
                withAnimation { proxy.scrollTo("logBottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("logBottom", anchor: .bottom) }
        }
    }

    private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(app.worker.recentLog, forType: .string)
    }
}
