import PairKitUI
import SwiftUI

/// The squad on a map, with the member list underneath.
struct SquadView: View {
    @Environment(AppModel.self) private var model
    @State private var inviting = false
    @State private var confirmingLeave = false
    @State private var recenter = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let problem = model.connectionProblem {
                    Label(problem, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(.yellow.opacity(0.3))
                }
                SquadMap(locations: model.locations, me: model.me?.deviceID, tiles: model.me?.tiles,
                         client: model.client, recenter: recenter)
                    .overlay(alignment: .bottomTrailing) {
                        Button("Show everyone", systemImage: "scope") { recenter += 1 }
                            .labelStyle(.iconOnly)
                            .padding(10)
                            .background(.regularMaterial, in: .circle)
                            .padding()
                    }
                MemberList()
                    .frame(maxHeight: 220)
            }
            .navigationTitle(model.squad?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Leave", role: .destructive) { confirmingLeave = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Invite", systemImage: "qrcode") { inviting = true }
                }
            }
            .confirmationDialog("Leave \(model.squad?.name ?? "this squad")?", isPresented: $confirmingLeave, titleVisibility: .visible) {
                Button("Leave squad", role: .destructive) { Task { await model.leaveSquad() } }
            } message: {
                Text("The others will stop seeing your position.")
            }
            .sheet(isPresented: $inviting) { InviteView() }
        }
    }
}

struct MemberList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.squad?.members ?? []) { member in
            let located = model.locations.first { $0.memberID == member.id }
            HStack {
                Text(member.name)
                if member.id == model.me?.deviceID { Text("you").foregroundStyle(.secondary) }
                if member.id == model.squad?.leaderID {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Leader")
                }
                Spacer()
                Text(Self.status(located)).foregroundStyle(.secondary)
            }
            .opacity(located.map { $0.isStale ? 0.5 : 1 } ?? 0.5)
        }
        .listStyle(.plain)
    }

    static func status(_ located: Located?) -> String {
        guard let located else { return "No position yet" }
        if located.age < 60 { return located.isStale ? "Stale" : "Now" }
        let minutes = located.age / 60
        return minutes < 60 ? "\(minutes) min ago" : "\(minutes / 60) h ago"
    }
}

/// A fresh single-use code for one new member.
struct InviteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var invite: InviteReply?
    @State private var expires = Date.now
    @State private var memberCount = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let invite {
                    QRCodeView(invite.payload)
                        .clipShape(.rect(cornerRadius: 12))
                        .frame(maxWidth: 320)
                        .accessibilityLabel("Pairing code")
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if context.date < expires {
                            Text("Works for one phone, for \(Text(expires, style: .timer)) more.")
                        } else {
                            Text("This code has expired.")
                        }
                    }
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    Button("New code", systemImage: "arrow.clockwise") { Task { await load() } }
                        .buttonStyle(.bordered)
                    if let link = AppModel.link(for: invite.payload) {
                        ShareLink("Send as a link", item: link)
                            .font(.footnote)
                    }
                } else {
                    ProgressView()
                }
            }
            .padding()
            .navigationTitle("Invite to \(model.squad?.name ?? "squad")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            // Someone joined: the code is spent, so make the next one.
            .onChange(of: model.squad?.members.count ?? 0) { old, new in
                if new > old { Task { await load() } }
            }
        }
    }

    private func load() async {
        invite = nil
        if let reply = await model.invite() {
            invite = reply
            expires = .now.addingTimeInterval(TimeInterval(reply.expiresIn))
        } else {
            dismiss()
        }
    }
}
