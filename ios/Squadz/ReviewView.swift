import AVKit
import CoreGeo
import SwiftUI

// Looking back at a mission: its log in time order, with the clips and stills kept from streams.

/// Every mission log on this device.
struct MissionListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var missions: [MissionInfo] = []

    var body: some View {
        NavigationStack {
            List {
                if missions.isEmpty {
                    Text("No mission logs yet. A log is kept on this device for every squad it leads.")
                        .foregroundStyle(.secondary)
                }
                ForEach(missions) { mission in
                    NavigationLink {
                        MissionLogView(mission: mission, live: mission.id == model.missionID)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mission.name).fontWeight(.semibold)
                            Text(Self.when(mission)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for mission in offsets.map({ missions[$0] }) where mission.id != model.missionID { model.logs.delete(mission.id) }
                    missions = model.logs.missions()
                }
            }
            .navigationTitle("Mission logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { missions = model.logs.missions() }
        }
    }

    static func when(_ mission: MissionInfo) -> String {
        let start = mission.started.formatted(date: .abbreviated, time: .shortened)
        guard let ended = mission.ended else { return "\(start), still running" }
        return "\(start) to \(ended.formatted(date: .omitted, time: .shortened))"
    }
}

/// One mission's log.
struct MissionLogView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", media = "Media", orders = "Orders", notes = "Notes", track = "Positions"
        var id: String { rawValue }

        func takes(_ entry: LogEntry) -> Bool {
            switch self {
            case .all: entry.kind != .position
            case .media: entry.isMedia
            case .orders: [.order, .orderAnswer, .orderCancelled].contains(entry.kind)
            case .notes: entry.kind == .note
            case .track: entry.kind == .position
            }
        }
    }

    @Environment(AppModel.self) private var model
    let mission: MissionInfo
    /// The squad is running now: read the log again as it grows.
    let live: Bool
    @State private var entries: [LogEntry] = []
    @State private var filter = Filter.all
    @State private var exported: ExportedFile?

    struct ExportedFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

    var body: some View {
        let shown = entries.filter(filter.takes)
        VStack(spacing: 0) {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            List {
                if shown.isEmpty {
                    Text(filter == .all ? "Nothing logged yet." : "Nothing of this kind in the log.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown) { entry in
                    if entry.isMedia, let file = entry.file {
                        NavigationLink {
                            MediaView(entry: entry, url: model.logs.media(mission.id, file))
                        } label: {
                            LogRow(entry: entry)
                        }
                    } else {
                        LogRow(entry: entry)
                    }
                }
            }
            .listStyle(.plain)
            Text(Self.summary(entries))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .navigationTitle(mission.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Export", systemImage: "square.and.arrow.up") {
                    if let url = model.logs.export(mission.id) { exported = ExportedFile(url: url) }
                }
            }
        }
        .sheet(item: $exported) { file in ShareSheet(items: [file.url]) }
        .onAppear { entries = model.logs.entries(of: mission.id).sorted { $0.time < $1.time } }
        .onChange(of: model.logChanges) { _, _ in if live { entries = model.logs.entries(of: mission.id).sorted { $0.time < $1.time } } }
    }

    /// "214 positions · 3 orders · 5 notes · 1 clip · 2 stills"
    static func summary(_ entries: [LogEntry]) -> String {
        func count(_ kinds: LogEntry.Kind..., one: String, many: String) -> String? {
            let n = entries.filter { kinds.contains($0.kind) }.count
            return n == 0 ? nil : "\(n) \(n == 1 ? one : many)"
        }
        let parts = [count(.position, one: "position", many: "positions"), count(.order, one: "order", many: "orders"),
                     count(.note, one: "note", many: "notes"), count(.clip, one: "clip", many: "clips"),
                     count(.still, one: "still", many: "stills")].compactMap { $0 }
        return parts.isEmpty ? "The log is empty." : parts.joined(separator: " · ")
    }
}

/// One line of a log.
struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: Self.icon(entry.kind))
                .foregroundStyle(entry.isMedia ? Color.red : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(entry))
                if let detail = Self.detail(entry) {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(entry.time.formatted(date: .omitted, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    static func icon(_ kind: LogEntry.Kind) -> String {
        switch kind {
        case .squadStarted: "play.circle"
        case .squadEnded: "stop.circle"
        case .joined: "person.badge.plus"
        case .left, .removed: "person.badge.minus"
        case .position: "location"
        case .order: "flag"
        case .orderAnswer: "checkmark.bubble"
        case .orderCancelled: "flag.slash"
        case .note: "bubble.left"
        case .streamStarted: "video"
        case .streamStopped: "video.slash"
        case .clip: "film"
        case .still: "photo"
        }
    }

    static func title(_ entry: LogEntry) -> String {
        let who = entry.name ?? "Someone"
        switch entry.kind {
        case .squadStarted: return "\(who) started \(entry.text ?? "the squad")"
        case .squadEnded: return "The squad ended"
        case .joined: return "\(who) joined"
        case .left, .removed: return entry.text ?? "\(who) left"
        case .position: return who
        case .order: return entry.text ?? "Order"
        case .orderAnswer: return "\(who): \(entry.text ?? "answered")"
        case .orderCancelled: return "Order cancelled"
        case .note: return "\(who): \(entry.text ?? "")"
        case .streamStarted: return "\(who) started streaming"
        case .streamStopped: return "\(who) stopped streaming"
        case .clip: return "Clip from \(who)" + (entry.seconds.map { ", \(Int($0.rounded())) s" } ?? "")
        case .still: return "Still from \(who)"
        }
    }

    static func detail(_ entry: LogEntry) -> String? {
        guard let at = entry.at else { return nil }
        var text = String(format: "%.5f, %.5f", at.latitude, at.longitude)
        if let accuracy = entry.accuracy { text += " · ±\(MemberList.length(accuracy))" }
        if let heading = entry.heading { text += " · facing \(MemberList.compass(heading))" }
        return text
    }
}

/// A clip or a still, with where and when it was taken, and a way to send it somewhere.
struct MediaView: View {
    let entry: LogEntry
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 12) {
            if entry.kind == .clip {
                VideoPlayer(player: player)
                    .onAppear { player = AVPlayer(url: url) }
                    .onDisappear { player?.pause() }
            } else if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Text("The file for this entry is missing.").foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                Text(LogRow.title(entry)).fontWeight(.semibold)
                Text(entry.time.formatted(date: .abbreviated, time: .standard)).font(.footnote).foregroundStyle(.secondary)
                if let detail = LogRow.detail(entry) { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            .padding(.bottom, 12)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ShareLink(item: url) } }
    }
}

/// The system's share sheet, for a file that was just made.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
