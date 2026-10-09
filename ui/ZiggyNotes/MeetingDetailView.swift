import SwiftUI
import AppKit

/// Read-only view of a finished meeting: the summary up top, the color-coded
/// guidance that was surfaced during the call, and a collapsed transcript at the
/// bottom that can be expanded.
struct MeetingDetailView: View {
    @Environment(AppModel.self) private var app
    @Bindable var meeting: MeetingRecord
    @State private var transcriptExpanded = false
    @State private var copied = false
    @State private var askText = ""
    @State private var sending = false

    // Final board: highest priority first, then oldest first.
    private var sortedSuggestions: [SuggestionRecord] {
        meeting.suggestions.sorted {
            ($0.priorityRank, $0.createdAt) < ($1.priorityRank, $1.createdAt)
        }
    }

    private var sortedLines: [TranscriptLineRecord] {
        meeting.lines.sorted { $0.index < $1.index }
    }

    var body: some View {
        GeometryReader { geo in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleHeader

                if meeting.hasSummary {
                    summaryCard
                    if !meeting.feedbackText.isEmpty || meeting.score > 0 {
                        feedbackCard
                    }
                } else {
                    Text(meeting.state == .summarizing ? "Summary is being generated…" : "No summary available for this meeting.")
                        .foregroundStyle(Theme.textSecondary)
                        .ziggyCard()
                }

                askCard

                if !sortedSuggestions.isEmpty {
                    guidanceSection
                }

                transcriptSection
            }
            .padding(24)
            .frame(maxWidth: contentWidth(for: geo.size.width), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.background)
        }
    }

    /// A readable content column that uses much more of the pane than the old fixed
    /// 820pt: ~90% of the pane on normal windows, growing toward ~50% on very wide
    /// displays but capped at 1400pt so long lines stay readable.
    private func contentWidth(for total: CGFloat) -> CGFloat {
        guard total > 0 else { return 820 }
        return min(max(total * 0.9, 820), min(total, 1400))
    }

    private var titleHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            WorkflowTitleLink(title: meeting.title, meetingId: meeting.meetingId, size: 24)
            HStack(spacing: 10) {
                Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                statusChip
                if !meeting.roster.isEmpty {
                    Text("· " + meeting.roster.joined(separator: ", "))
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
        }
    }

    private var statusChip: some View {
        let (label, color): (String, Color) = {
            switch meeting.state {
            case .completed: return ("Completed", Theme.lowPriority)
            case .summarizing: return ("Summarizing", Theme.mediumPriority)
            case .recording: return ("Recording", Theme.highPriority)
            case .stopped: return ("Stopped", Theme.textSecondary)
            case .error: return ("Error", Theme.highPriority)
            case .unknown: return ("Unknown", Theme.textSecondary)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Summary")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(action: copySummary) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.purple)
                .help("Copy the formatted summary — paste into Google Docs to keep headings, bullets, and bold")
            }
            if !meeting.attendees.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill").foregroundStyle(Theme.purple)
                        Text("Attendees").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Text(meeting.attendees.joined(separator: ", "))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !meeting.summaryText.isEmpty {
                Text(meeting.summaryText)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            bulletBlock("Key Points", items: meeting.keyPoints, icon: "key.fill", color: Theme.purple)
            bulletBlock("Action Items", items: meeting.actionItems, icon: "checkmark.circle.fill", color: Theme.lowPriority)
            bulletBlock("Next Steps", items: meeting.nextSteps, icon: "arrow.right.circle.fill", color: Theme.mediumPriority)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ziggyCard(padding: 20)
    }

    // MARK: - Copy summary

    /// Puts a rich (HTML) + plain-text representation of the summary on the
    /// pasteboard. Pasting into Google Docs (or Word/Gmail) keeps the headings,
    /// bullets, and bold; apps that only read plain text get the fallback.
    private func copySummary() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.html, .string], owner: nil)
        pb.setString(summaryHTML(), forType: .html)
        pb.setString(summaryPlainText(), forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }

    private func summaryHTML() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        func list(_ items: [String]) -> String {
            items.isEmpty ? "" : "<ul>" + items.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
        }
        // Bold section titles (as paragraphs, not <h2>) so Google Docs keeps them
        // bold on paste rather than applying its non-bold Heading style.
        func heading(_ t: String) -> String {
            "<p><span style=\"font-size:13pt\"><strong>\(esc(t))</strong></span></p>"
        }
        var body = "<p><span style=\"font-size:18pt\"><strong>\(esc(meeting.title))</strong></span></p>"
        if !meeting.attendees.isEmpty {
            body += "<p><strong>Attendees:</strong> \(esc(meeting.attendees.joined(separator: ", ")))</p>"
        }
        if !meeting.summaryText.isEmpty { body += heading("Summary") + "<p>\(esc(meeting.summaryText))</p>" }
        if !meeting.keyPoints.isEmpty { body += heading("Key Points") + list(meeting.keyPoints) }
        if !meeting.actionItems.isEmpty { body += heading("Action Items") + list(meeting.actionItems) }
        if !meeting.nextSteps.isEmpty { body += heading("Next Steps") + list(meeting.nextSteps) }
        if !meeting.feedbackText.isEmpty {
            let score = meeting.score > 0 ? " (\(meeting.score)/10)" : ""
            body += heading("Coaching Feedback\(score)") + "<p>\(esc(meeting.feedbackText))</p>"
        }
        return "<!DOCTYPE html><html><body>\(body)</body></html>"
    }

    private func summaryPlainText() -> String {
        var lines: [String] = [meeting.title, ""]
        if !meeting.attendees.isEmpty {
            lines.append("Attendees: \(meeting.attendees.joined(separator: ", "))")
            lines.append("")
        }
        if !meeting.summaryText.isEmpty {
            lines.append("Summary"); lines.append(meeting.summaryText); lines.append("")
        }
        func section(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append(title)
            lines.append(contentsOf: items.map { "• \($0)" })
            lines.append("")
        }
        section("Key Points", meeting.keyPoints)
        section("Action Items", meeting.actionItems)
        section("Next Steps", meeting.nextSteps)
        if !meeting.feedbackText.isEmpty {
            let score = meeting.score > 0 ? " (\(meeting.score)/10)" : ""
            lines.append("Coaching Feedback\(score)")
            lines.append(meeting.feedbackText)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Ask anything

    private var askThread: [AppModel.AskExchange] { app.askThreads[meeting.meetingId] ?? [] }
    private var askPending: Bool { app.askPending[meeting.meetingId] == true }

    private var askCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Theme.purple)
                Text("Ask Ziggy about this meeting")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            ForEach(askThread) { ex in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.fill").foregroundStyle(Theme.purple)
                        Text(ex.question)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                    if ex.pending {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Ziggy is thinking…")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "sparkles").foregroundStyle(Theme.purple)
                            MarkdownText(text: ex.answer)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Theme.textSecondary)
                    TextField("Ask anything about this meeting…", text: $askText)
                        .textFieldStyle(.plain)
                        .disabled(askPending || sending)
                        .onSubmit { submitAsk() }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))

                Button(action: submitAsk) {
                    if askPending || sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(askText.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.textSecondary : Theme.purple)
                .disabled(askPending || sending || askText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ziggyCard(padding: 20)
    }

    private func submitAsk() {
        let q = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !askPending, !sending else { return }
        askText = ""
        sending = true   // lock the input immediately, before the workflow registers
        Task {
            await app.ask(meeting, question: q)
            sending = false
        }
    }

    private var scoreColor: Color {
        switch meeting.score {
        case 8...10: return Theme.lowPriority
        case 5...7:  return Theme.mediumPriority
        default:     return Theme.highPriority
        }
    }

    private var feedbackCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "person.fill.checkmark").foregroundStyle(Theme.purple)
                Text("Coaching Feedback")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if meeting.score > 0 {
                    Text("\(meeting.score)/10")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(scoreColor, in: Capsule())
                }
            }
            if !meeting.feedbackText.isEmpty {
                Text(meeting.feedbackText)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ziggyCard(padding: 20)
    }

    @ViewBuilder
    private func bulletBlock(_ title: String, items: [String], icon: String, color: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(color)
                    Text(title).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(color).frame(width: 5, height: 5).padding(.top, 6)
                        Text(item).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var guidanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Theme.purple)
                Text("Guidance during the call")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            ForEach(sortedSuggestions) { s in
                SuggestionCardView(title: s.title, detail: s.detail, priority: s.priority, kind: s.kind)
            }
        }
    }

    private var transcriptSection: some View {
        DisclosureGroup(isExpanded: $transcriptExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(sortedLines) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(line.speaker.isEmpty ? "Speaker" : line.speaker)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.purple)
                            Text(line.timestamp)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Text(line.text)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if sortedLines.isEmpty {
                    Text("No transcript recorded.").foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft").foregroundStyle(Theme.textSecondary)
                Text("Transcript (\(sortedLines.count) lines)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .tint(Theme.purple)
        .ziggyCard(padding: 18)
    }
}
