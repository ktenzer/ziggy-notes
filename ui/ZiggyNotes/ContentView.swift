import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \MeetingRecord.createdAt, order: .reverse) private var meetings: [MeetingRecord]

    @State private var selectedId: String?
    @State private var showNewNote = false

    private var liveExists: Bool { meetings.contains { $0.state.isLive } }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewNote = true
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .disabled(liveExists)
                .help(liveExists ? "Stop the running note before starting a new one" : "Start a new note and begin active listening")
            }
            ToolbarItem(placement: .automatic) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Configure AI provider, Temporal, capture, and output folder")
            }
        }
        .sheet(isPresented: $showNewNote) {
            NewNoteSheet { title, repName in
                Task {
                    if let record = await app.startNewMeeting(title: title, repName: repName) {
                        selectedId = record.meetingId
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { bannerView }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TemporalLogoMark()
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().overlay(Theme.hairline)

            List(selection: $selectedId) {
                ForEach(groupedMeetings, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { meeting in
                            MeetingRow(meeting: meeting)
                                .tag(meeting.meetingId)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        delete(meeting)
                                    } label: {
                                        Label("Delete Note", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        delete(meeting)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
                if meetings.isEmpty {
                    Text("No notes yet. Click New Note to start.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(Theme.background)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedId, let meeting = meetings.first(where: { $0.meetingId == id }) {
            if meeting.state.isLive {
                ActiveMeetingView(meeting: meeting)
                    .id(meeting.meetingId)
            } else {
                MeetingDetailView(meeting: meeting)
                    .id(meeting.meetingId)
            }
        } else {
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        ZStack {
            ZiggyBackground()
            VStack(spacing: 14) {
                Text("Select a note, or start a new one")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Button {
                    showNewNote = true
                } label: {
                    Label("New Note", systemImage: "square.and.pencil").fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.purple)
                .disabled(liveExists)
            }
        }
    }

    // MARK: - Banner

    @ViewBuilder
    private var bannerView: some View {
        if let banner = app.banner {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white)
                Text(banner).font(.caption).foregroundStyle(.white).lineLimit(2)
                Spacer(minLength: 0)
                Button {
                    app.banner = nil
                } label: { Image(systemName: "xmark").foregroundStyle(.white) }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Theme.purpleDark, in: RoundedRectangle(cornerRadius: 10))
            .padding(16)
            .frame(maxWidth: 560)
        }
    }

    private func delete(_ meeting: MeetingRecord) {
        if selectedId == meeting.meetingId { selectedId = nil }
        Task { await app.deleteMeeting(meeting) }
    }

    // MARK: - Grouping by date

    private var groupedMeetings: [(String, [MeetingRecord])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: meetings) { cal.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted(by: >).map { day in
            (Self.dateLabel(day), groups[day]!.sorted { $0.createdAt > $1.createdAt })
        }
    }

    private static func dateLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateFormat = cal.isDate(day, equalTo: .now, toGranularity: .year) ? "EEEE, MMM d" : "MMM d, yyyy"
        return fmt.string(from: day)
    }
}

private struct MeetingRow: View {
    @Bindable var meeting: MeetingRecord

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if meeting.state.isLive {
                Image(systemName: "waveform")
                    .foregroundStyle(Theme.highPriority)
                    .font(.system(size: 11))
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
        }
        .padding(.vertical, 3)
    }

    private var dotColor: Color {
        switch meeting.state {
        case .recording: return Theme.highPriority
        case .summarizing: return Theme.mediumPriority
        case .completed: return Theme.lowPriority
        default: return Theme.textSecondary
        }
    }

    private var subtitle: String {
        meeting.createdAt.formatted(date: .omitted, time: .shortened)
    }
}
