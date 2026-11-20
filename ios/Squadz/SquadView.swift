import CoreGeo
import SquadKit
import SwiftUI

/// The squad on a map, with the member list underneath.
struct SquadView: View {
    @Environment(AppModel.self) private var model
    @State private var inviting = false
    @State private var confirmingLeave = false
    @State private var recenter = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var leading: Bool { model.role == .leader }
    private var squadName: String { model.squad?.name ?? "this squad" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(spacing: 0) {
                        SquadMap(located: model.located, now: context.date, recenter: recenter)
                            .overlay(alignment: .bottomTrailing) {
                                Button("Show everyone", systemImage: "scope") { recenter += 1 }
                                    .labelStyle(.iconOnly)
                                    .padding(10)
                                    .background(.regularMaterial, in: .circle)
                                    .padding()
                            }
                        MemberList(now: context.date)
                            .frame(maxHeight: sizeClass == .regular ? 360 : 240)
                    }
                }
            }
            .navigationTitle(model.squad?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(leading ? "End" : "Leave", role: .destructive) { confirmingLeave = true }
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
        }
    }
}

struct MemberList: View {
    @Environment(AppModel.self) private var model
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
                let details = Self.details(located, from: mine)
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
    static func details(_ located: Located, from mine: GeoPoint?) -> [String] {
        var out: [String] = []
        switch located.link {
        case .direct: out.append("Connected")
        case .relay: out.append("Connected through the relay")
        case .away: out.append("Not connected")
        case nil: break
        }
        if let p = located.position {
            if !located.isMe, let mine {
                out.append("\(length(Geo.distance(mine, p.at))) \(compass(Geo.bearing(from: mine, to: p.at))) of you")
            }
            out.append("±\(length(p.accuracy))")
            out.append(String(format: "%.5f, %.5f", p.at.latitude, p.at.longitude))
        }
        if let joined = located.joined {
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
