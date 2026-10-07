import SwiftUI

/// Read-only view of a finished meeting: the summary up top, the color-coded
/// guidance that was surfaced during the call, and a collapsed transcript at the
/// bottom that can be expanded.
struct MeetingDetailView: View {
    @Bindable var meeting: MeetingRecord
    @State private var transcriptExpanded = false

    private var sortedSuggestions: [SuggestionRecord] {
        meeting.suggestions.sorted { $0.atChunk < $1.atChunk }
    }

    private var sortedLines: [TranscriptLineRecord] {
        meeting.lines.sorted { $0.index < $1.index }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleHeader

                if meeting.hasSummary {
                    summaryCard
                } else {
                    Text(meeting.state == .summarizing ? "Summary is being generated…" : "No summary available for this meeting.")
                        .foregroundStyle(Theme.textSecondary)
                        .ziggyCard()
                }

                if !sortedSuggestions.isEmpty {
                    guidanceSection
                }

                transcriptSection
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(ZiggyBackground())
    }

    private var titleHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
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
                        Text(line.speaker.isEmpty ? "Speaker" : line.speaker)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.purple)
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
