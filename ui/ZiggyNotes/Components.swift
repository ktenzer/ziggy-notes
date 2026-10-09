import SwiftUI

/// Off-white canvas with the Ziggy tardigrade mascot as a faint watermark.
struct ZiggyBackground: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            GeometryReader { geo in
                Image("ZiggyMascot")
                    .resizable()
                    .scaledToFit()
                    .frame(width: min(geo.size.width, geo.size.height) * 0.55)
                    .opacity(0.07)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
        }
    }
}

/// The Temporal symbol shown in the top-left of the sidebar (logo only).
struct TemporalLogoMark: View {
    var tint: Color = Theme.textPrimary   // brand symbol shown in black on off-white
    var body: some View {
        Image("TemporalLogo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: 28)
            .foregroundStyle(tint)
    }
}

/// A meeting title that is also a link to the meeting's workflow in the Temporal
/// Web UI (local dev server UI or Temporal Cloud). Clicking opens the browser.
struct WorkflowTitleLink: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    let title: String
    let meetingId: String
    var size: CGFloat = 17

    var body: some View {
        Button {
            if let url = app.config.workflowWebURL(meetingId: meetingId) {
                openURL(url)
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: size * 0.62))
                    .foregroundStyle(Theme.purple)
            }
        }
        .buttonStyle(.plain)
        .help("Open this workflow in Temporal")
    }
}

/// A single color-coded active-listening suggestion from the LLM.
struct SuggestionCardView: View {
    let title: String
    let detail: String
    let priority: String
    let kind: String
    /// When provided, shows an "×" to dismiss this suggestion for the meeting.
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        let color = Theme.priorityColor(priority)
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: Theme.priorityIcon(priority))
                        .foregroundStyle(color)
                        .font(.system(size: 12, weight: .bold))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    Text(priority.uppercased())
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color, in: Capsule())
                    if let onDismiss {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss — don't suggest this again this meeting")
                    }
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(color.opacity(0.25), lineWidth: 1))
    }
}

/// Renders a lightweight subset of Markdown for LLM answers: inline **bold** /
/// *italic* / `code`, "-"/"*" bullet lists, and "1."/"1)" numbered lists with
/// indentation. Avoids pulling in a full Markdown engine while still showing
/// formatting instead of raw asterisks.
struct MarkdownText: View {
    let text: String
    var font: Font = .system(size: 13)
    var color: Color = Theme.textPrimary

    private enum Block: Hashable {
        case paragraph(String)
        case bullet(String)
        case numbered(String, String)
        case spacer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                row(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [Block] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return .spacer }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                return .bullet(String(line.dropFirst(2)))
            }
            if let num = numbered(line) { return .numbered(num.0, num.1) }
            return .paragraph(line)
        }
    }

    private func numbered(_ line: String) -> (String, String)? {
        guard let r = line.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) else { return nil }
        return (String(line[r]).trimmingCharacters(in: .whitespaces), String(line[r.upperBound...]))
    }

    @ViewBuilder
    private func row(for block: Block) -> some View {
        switch block {
        case .spacer:
            Spacer().frame(height: 2)
        case .paragraph(let s):
            Text(inline(s)).font(font).foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let s):
            HStack(alignment: .top, spacing: 6) {
                Text("•").font(font).foregroundStyle(color)
                Text(inline(s)).font(font).foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 8)
        case .numbered(let marker, let s):
            HStack(alignment: .top, spacing: 6) {
                Text(marker).font(font.weight(.semibold)).foregroundStyle(color)
                Text(inline(s)).font(font).foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 8)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}

/// Launch / boot overlay shown while the worker starts and the client connects.
struct BootstrapOverlay: View {
    @Environment(AppModel.self) private var app
    var onRetry: () -> Void

    var body: some View {
        ZStack {
            ZiggyBackground()
            VStack(spacing: 18) {
                Text("Ziggy Listens")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)

                switch app.phase {
                case .failed(let message):
                    VStack(spacing: 12) {
                        Label("Startup failed", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.highPriority)
                            .font(.headline)
                        ScrollView {
                            Text(message)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: 520, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
                        Button(action: onRetry) {
                            Text("Retry").fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.purple)
                    }
                    .ziggyCard()
                    .frame(maxWidth: 560)
                default:
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(statusText)
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(40)
        }
    }

    private var statusText: String {
        switch app.phase {
        case .launching: return "Starting up…"
        case .requestingMic: return "Requesting microphone access…"
        case .startingWorker: return "Starting the Temporal worker…"
        case .connecting: return "Connecting to \(app.config.summary)…"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }
}

/// Sheet for starting a new note.
struct NewNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onStart: (_ title: String, _ repName: String?) -> Void

    @State private var title: String = "Temporal Sales Call"
    @State private var repName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image("TemporalLogo").renderingMode(.template).resizable().scaledToFit()
                    .frame(height: 24).foregroundStyle(Theme.textPrimary)
                Text("New Note").font(.title2.weight(.bold))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Title").font(.caption).foregroundStyle(Theme.textSecondary)
                TextField("Meeting title", text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Your name (optional)").font(.caption).foregroundStyle(Theme.textSecondary)
                TextField("e.g. Keith (mic will be attributed to this name)", text: $repName)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    onStart(title, repName.isEmpty ? nil : repName)
                    dismiss()
                } label: {
                    Label("Start Listening", systemImage: "record.circle")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.purple)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.background)
    }
}
