import SquadKit
import SwiftUI

/// The squad on a map, with the member list underneath.
struct SquadView: View {
    @Environment(AppModel.self) private var model
    @State private var inviting = false
    @State private var confirmingLeave = false
    @State private var recenter = 0

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
                            .frame(maxHeight: 220)
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
        List(model.located) { located in
            HStack {
                Text(located.member.name)
                if located.isMe { Text("you").foregroundStyle(.secondary) }
                if located.isLeader {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Leader")
                }
                Spacer()
                Text(Self.status(located, now: now)).foregroundStyle(.secondary)
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

    static func status(_ located: Located, now: Date) -> String {
        guard let age = located.age(now: now) else { return "No position yet" }
        if age < 60 { return "Now" }
        let minutes = Int(age) / 60
        return minutes < 60 ? "\(minutes) min ago" : "\(minutes / 60) h ago"
    }
}
