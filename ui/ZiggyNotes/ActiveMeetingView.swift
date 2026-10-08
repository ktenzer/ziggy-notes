import SwiftUI

/// Live "active listening" screen: streaming transcript on the left, color-coded
/// LLM suggestions on the right, and a bottom bar with Stop + a (disabled for now)
/// "ask anything" prompt.
struct ActiveMeetingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Bindable var meeting: MeetingRecord

    @State private var askText: String = ""
    @State private var isStopping = false

    private var sortedLines: [TranscriptLineRecord] {
        meeting.lines.sorted { $0.index < $1.index }
    }

    // The live board: highest priority first, then oldest first (stable order so
    // cards don't jump around as the set is re-ranked/replaced).
    private var sortedSuggestions: [SuggestionRecord] {
        meeting.suggestions.sorted {
            ($0.priorityRank, $0.createdAt) < ($1.priorityRank, $1.createdAt)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            HStack(alignment: .top, spacing: 0) {
                transcriptPane
                Divider().overlay(Theme.hairline)
                suggestionsPane
                    .frame(width: 320)
            }
            Divider().overlay(Theme.hairline)
            bottomBar
        }
        .background(Theme.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                WorkflowTitleLink(title: meeting.title, meetingId: meeting.meetingId, size: 17)
                Text(meeting.state == .summarizing ? "Summarizing…" : "Listening · \(app.config.summary)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if !meeting.roster.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill").foregroundStyle(Theme.purple)
                    Text(meeting.roster.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Transcript

    private var transcriptPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if sortedLines.isEmpty {
                        Text("Waiting for audio…")
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 20)
                    }
                    ForEach(sortedLines) { line in
                        transcriptRow(line).id(line.index)
                    }
                }
                .padding(20)
            }
            .onChange(of: sortedLines.count) { _, _ in
                if let last = sortedLines.last {
                    withAnimation { proxy.scrollTo(last.index, anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func transcriptRow(_ line: TranscriptLineRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line.speaker.isEmpty ? "Speaker" : line.speaker)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(speakerColor(line.speaker))
            Text(line.text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func speakerColor(_ speaker: String) -> Color {
        let s = speaker.lowercased()
        if s == "you" || s.contains("temporal") { return Theme.purple }
        if s == "other" || s.contains("customer") { return Theme.textSecondary }
        return Theme.purpleDark
    }

    // MARK: - Suggestions

    private var suggestionsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Theme.purple)
                Text("Active Guidance")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(sortedSuggestions.count)")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider().overlay(Theme.hairline)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if sortedSuggestions.isEmpty {
                        Text("Guidance will appear here as the conversation develops.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 24)
                    }
                    ForEach(sortedSuggestions) { s in
                        SuggestionCardView(title: s.title, detail: s.detail, priority: s.priority, kind: s.kind)
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.background.opacity(0.6))
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    isStopping = true
                    await app.stopMeeting(meeting)
                    isStopping = false
                }
            } label: {
                Label(isStopping ? "Stopping…" : "Stop", systemImage: "stop.fill")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.highPriority)
            .disabled(isStopping || meeting.state == .summarizing)

            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Theme.textSecondary)
                TextField("Ask anything about this meeting… (coming soon)", text: $askText)
                    .textFieldStyle(.plain)
                    .disabled(true)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))

            Button {
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .disabled(true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
