import CoreGeo
import SquadKit
import SwiftUI

/// The squad on a map. The leader's device has a panel beside the map (under it on a phone) for
/// the team and for orders. A member's phone has the map and the team on one tab and its orders
/// on another.
struct SquadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var inviting = false
    @State private var choosingDetails = false
    @State private var confirmingLeave = false
    @State private var recenter = 0
    @State private var panel = LeaderPanel.Tab.team
    @State private var draft = OrderDraft()
    /// The next tap on the map says where the order being written is for.
    @State private var placing = false
    @State private var memberTab = MemberTab.map
    /// The team list (on the leader's device, the whole panel) can be put away to give the map
    /// the screen. Kept across launches.
    @AppStorage("showsList") private var showsList = true

    enum MemberTab { case map, orders }

    private var leading: Bool { model.role == .leader }
    private var squadName: String { model.squad?.name ?? "this squad" }
    private var wide: Bool { sizeClass == .regular }
    /// A tap on the map sets the place only while the leader is writing a move-to order.
    private var picking: Bool { leading && showsList && panel == .orders && draft.needsPlace && placing }

    var body: some View {
        NavigationStack {
            Group {
                if leading { leaderScreen } else { memberScreen }
            }
            .navigationTitle(model.squad?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(leading ? "End" : "Leave", role: .destructive) { confirmingLeave = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Squad settings", systemImage: "gearshape") { choosingDetails = true }
                }
                if leading {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Invite", systemImage: "qrcode") { inviting = true }
                    }
                }
            }
            .confirmationDialog(leading ? "End \(squadName)?" : "Leave \(squadName)?", isPresented: $confirmingLeave, titleVisibility: .visible) {
                if leading {
                    Button("End squad for everyone", role: .destructive) { model.endSquad() }
                } else {
                    Button("Leave squad", role: .destructive) { model.leaveSquad() }
                }
            } message: {
                Text(leading ? "Everyone is disconnected and has to join a new squad." : "You'll need a new invite to come back.")
            }
            .sheet(isPresented: $inviting) { InviteView() }
            .sheet(isPresented: $choosingDetails) { SquadSettingsView(leading: leading) }
        }
    }

    // MARK: The leader's device

    private var leaderScreen: some View {
        VStack(spacing: 0) {
            banners
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    map(now: context.date)
                    if showsList {
                        if wide { Divider() }
                        LeaderPanel(tab: $panel, draft: $draft, placing: $placing, now: context.date)
                            .frame(width: wide ? 400 : nil)
                            .frame(maxHeight: wide ? .infinity : 390)
                    }
                }
            }
        }
    }

    // MARK: A member's phone

    private var memberScreen: some View {
        TabView(selection: $memberTab) {
            VStack(spacing: 0) {
                banners
                // A new order comes to the front here; once it's seen, the next one to do shows.
                if let shown = model.newOrder ?? model.queue.first {
                    NextOrderLine(order: shown, isNew: model.newOrder != nil, waiting: model.queue.count) { memberTab = .orders }
                }
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(spacing: 0) {
                        map(now: context.date)
                        if showsList {
                            MemberList(now: context.date)
                                .frame(maxHeight: wide ? 360 : 240)
                        }
                    }
                }
            }
            .onAppear {
                model.orderArrived = { _ in UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            }
            .tabItem { Label("Map", systemImage: "map") }
            .tag(MemberTab.map)

            MemberOrdersView()
                .tabItem { Label("Orders", systemImage: "flag") }
                .tag(MemberTab.orders)
                .badge(model.queue.count)
        }
    }

    // MARK: Shared

    @ViewBuilder private var banners: some View {
        if let problem = model.linkProblem {
            Label(problem, systemImage: "wifi.exclamationmark")
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(.yellow.opacity(0.3))
        }
        if let notice = model.notice {
            Label(notice.text, systemImage: "person.fill.xmark")
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(.blue.opacity(0.15))
        }
        if let note = model.relayNote {
            Label(note, systemImage: "antenna.radiowaves.left.and.right")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(6)
        }
    }

    private func map(now: Date) -> some View {
        SquadMap(located: model.located, now: now, recenter: recenter, places: places,
                 onPick: picking ? { place in
                     draft.place = place
                     placing = false
                 } : nil)
            .overlay(alignment: .top) {
                if picking {
                    Label("Tap the map where you want them", systemImage: "hand.tap.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.orange, in: .capsule)
                        .foregroundStyle(.white)
                        .padding(.top, 10)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(spacing: 10) {
                    Button(showsList ? "Hide the list" : "Show the list", systemImage: showsList ? "rectangle.expand.vertical" : "list.bullet") {
                        withAnimation { showsList.toggle() }
                    }
                    Button("Show everyone", systemImage: "scope") { recenter += 1 }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(MapButtonStyle())
                .padding()
            }
    }

    /// Open orders that have a place, and the place of the order being written.
    private var places: [SquadMap.Place] {
        var out = model.openOrders.compactMap { order in
            order.at.map { SquadMap.Place(id: order.id, title: order.title, at: $0, color: UIColor(model.tone(of: order).color)) }
        }
        if leading, showsList, panel == .orders, draft.needsPlace, let place = draft.place {
            out.append(SquadMap.Place(id: OrderDraft.pinID, title: "New order", at: place, isDraft: true))
        }
        return out
    }
}

/// A round button that sits on the map.
struct MapButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 22, height: 22)
            .padding(10)
            .background(.regularMaterial, in: .circle)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Beside the leader's map: the team, or orders.
struct LeaderPanel: View {
    enum Tab: Hashable { case team, orders }

    @Environment(AppModel.self) private var model
    @Binding var tab: Tab
    @Binding var draft: OrderDraft
    @Binding var placing: Bool
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $tab) {
                Text("Team").tag(Tab.team)
                Text(model.openOrders.isEmpty ? "Orders" : "Orders (\(model.openOrders.count) open)").tag(Tab.orders)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            switch tab {
            case .team: MemberList(now: now)
            case .orders: OrdersPanel(draft: $draft, placing: $placing)
            }
        }
        .background(Color(.systemBackground))
    }
}

/// One thing the list can say about a member, under their name.
enum MemberDetail: String, CaseIterable, Identifiable {
    case link, distance, accuracy, coordinates, joined

    var id: String { rawValue }

    var title: String {
        switch self {
        case .link: "Connection"
        case .distance: "Distance and direction from you"
        case .accuracy: "Accuracy of their position"
        case .coordinates: "Coordinates"
        case .joined: "When they joined"
        }
    }

    /// What the leader has chosen to show, kept as the names joined by commas. Everything, until
    /// they choose.
    /// Only the leader's device knows who is connected and when they joined.
    var leaderOnly: Bool { self == .link || self == .joined }

    static let storageKey = "memberDetails"
    static let everything = allCases.map(\.rawValue).joined(separator: ",")

    static func chosen(_ stored: String) -> Set<MemberDetail> {
        Set(stored.split(separator: ",").compactMap { MemberDetail(rawValue: String($0)) })
    }

    static func stored(_ chosen: Set<MemberDetail>) -> String {
        allCases.filter(chosen.contains).map(\.rawValue).joined(separator: ",")
    }
}

/// Settings for the squad screen, on any device: which details the member list shows. A
/// member's phone offers the ones it has.
struct SquadSettingsView: View {
    let leading: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MemberDetail.storageKey) private var stored = MemberDetail.everything

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(MemberDetail.allCases.filter { leading || !$0.leaderOnly }) { detail in
                        let on = MemberDetail.chosen(stored).contains(detail)
                        Button {
                            var chosen = MemberDetail.chosen(stored)
                            if on { chosen.remove(detail) } else { chosen.insert(detail) }
                            stored = MemberDetail.stored(chosen)
                        } label: {
                            HStack {
                                Text(detail.title).foregroundStyle(Color.primary)
                                Spacer()
                                if on { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                } header: {
                    Text("Show under each member")
                } footer: {
                    Text(leading
                         ? "This changes the list on this device only. Everyone in the squad chooses for their own."
                         : "This changes the list on this phone only. The squad's leader also sees who is connected and when each person joined.")
                }
            }
            .navigationTitle("Squad settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct MemberList: View {
    @Environment(AppModel.self) private var model
    @AppStorage(MemberDetail.storageKey) private var stored = MemberDetail.everything
    let now: Date

    var body: some View {
        let mine = model.located.first { $0.isMe }?.position?.at
        List(model.located) { located in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(located.member.name)
                    if located.isMe { Text("you").foregroundStyle(.secondary) }
                    if located.isLeader {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Leader")
                    }
                    Spacer()
                    Text(Self.status(located, now: now)).foregroundStyle(.secondary)
                }
                let details = Self.details(located, from: mine, showing: MemberDetail.chosen(stored))
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .opacity(located.isStale(now: now) ? 0.5 : 1)
            .swipeActions {
                if model.role == .leader, !located.isMe {
                    Button("Remove", role: .destructive) { model.remove(located.id) }
                }
            }
        }
        .listStyle(.plain)
    }

    /// What else is known about a member, most useful first: how they are linked (on the leader's
    /// device), how far and which way from this device, how good the fix is, where, and when
    /// they joined.
    static func details(_ located: Located, from mine: GeoPoint?, showing: Set<MemberDetail> = Set(MemberDetail.allCases)) -> [String] {
        var out: [String] = []
        if showing.contains(.link) {
            switch located.link {
            case .direct: out.append("Connected")
            case .relay: out.append("Connected through the relay")
            case .away: out.append("Not connected")
            case nil: break
            }
        }
        if let p = located.position {
            if showing.contains(.distance), !located.isMe, let mine {
                out.append("\(length(Geo.distance(mine, p.at))) \(compass(Geo.bearing(from: mine, to: p.at))) of you")
            }
            if showing.contains(.accuracy) { out.append("±\(length(p.accuracy))") }
            if showing.contains(.coordinates) { out.append(String(format: "%.5f, %.5f", p.at.latitude, p.at.longitude)) }
        }
        if showing.contains(.joined), let joined = located.joined {
            out.append("joined \(joined.formatted(date: .omitted, time: .shortened))")
        }
        return out
    }

    /// In the units this device's region uses.
    static func length(_ metres: Double) -> String {
        Measurement(value: max(0, metres), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    /// One of eight points, from degrees clockwise from north.
    static func compass(_ bearing: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let turned = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return points[Int((turned + 22.5) / 45) % 8]
    }

    static func status(_ located: Located, now: Date) -> String {
        guard let age = located.age(now: now) else { return "No position yet" }
        if age < 60 { return "Now" }
        let minutes = Int(age) / 60
        return minutes < 60 ? "\(minutes) min ago" : "\(minutes / 60) h ago"
    }
}
