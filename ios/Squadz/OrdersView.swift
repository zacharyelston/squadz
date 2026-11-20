import CoreGeo
import SquadKit
import SwiftUI

// Orders: the leader tasks one member, several, or the whole squad, and each answers Seen, Done
// or Can't. The squad core carries them (docs/WIRE.md); this is the app's side.

extension Order {
    /// What to call it: the kind, for the kinds this app knows, or its text.
    var title: String { kind.coreTitle ?? (text.isEmpty ? "Order" : text) }
}

extension OrderAck.Response {
    var title: String {
        switch self {
        case .seen: "Seen"
        case .done: "Done"
        case .cannot: "Can't"
        }
    }
}

/// An order the leader is writing. Kept by the squad screen, so it survives the sheet being put
/// away to tap the map.
struct OrderDraft: Equatable {
    /// The kinds this app offers. Capture waits for the app to take photos.
    static let kinds: [Order.Kind] = [.moveTo, .holdPosition, .note]
    static let pinID = UUID()

    /// Empty means the whole squad.
    var to: Set<MemberID> = []
    var kind: Order.Kind = .moveTo
    var place: GeoPoint?
    var text = ""

    var needsPlace: Bool { kind == .moveTo }

    var canSend: Bool {
        if needsPlace, place == nil { return false }
        if kind == .note, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return true
    }
}

/// The leader's orders: who, what, where, send. Then what was sent and how each person answered.
struct OrdersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: OrderDraft
    /// Put the sheet away and let the leader tap the map.
    let pickPlace: () -> Void

    private var others: [Member] { (model.squad?.members ?? []).filter { $0.id != model.leaderID } }

    var body: some View {
        NavigationStack {
            List {
                if others.isEmpty {
                    Section {
                        Text("Nobody else is in the squad yet. Invite someone, then send them an order.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Who") {
                        row("Whole squad", on: draft.to.isEmpty) { draft.to = [] }
                        ForEach(others) { member in
                            row(member.name, on: draft.to.contains(member.id)) {
                                if draft.to.contains(member.id) { draft.to.remove(member.id) } else { draft.to.insert(member.id) }
                            }
                        }
                    }
                    Section("What") {
                        Picker("Kind", selection: $draft.kind) {
                            ForEach(OrderDraft.kinds, id: \.self) { Text($0.coreTitle ?? $0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if draft.needsPlace {
                            Button(action: pickPlace) {
                                if let place = draft.place {
                                    Label(String(format: "%.5f, %.5f. Tap to move it", place.latitude, place.longitude), systemImage: "mappin.circle.fill")
                                } else {
                                    Label("Tap the map to say where", systemImage: "hand.tap.fill")
                                }
                            }
                        }
                        TextField(draft.kind == .note ? "Note" : "Note (optional)", text: $draft.text, axis: .vertical)
                            .lineLimit(1...3)
                            .onChange(of: draft.text) { _, new in
                                if new.count > Order.maxText { draft.text = String(new.prefix(Order.maxText)) }
                            }
                    }
                    Section {
                        Button {
                            if model.sendOrder(draft.kind, text: draft.text, at: draft.needsPlace ? draft.place : nil, to: draft.to) {
                                draft = OrderDraft()
                            }
                        } label: {
                            Label("Send to \(names(draft.to))", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!draft.canSend)
                    }
                }
                if !model.orders.isEmpty {
                    Section("Sent") {
                        ForEach(model.orders) { order in sent(order) }
                    }
                }
            }
            .navigationTitle("Orders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(Color.primary)
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func names(_ ids: Set<MemberID>) -> String {
        ids.isEmpty ? "the whole squad" : others.filter { ids.contains($0.id) }.map(\.name).joined(separator: ", ")
    }

    private func sent(_ order: Order) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(order.title).fontWeight(.semibold)
                Spacer()
                Text(order.time.formatted(date: .omitted, time: .shortened)).font(.footnote).foregroundStyle(.secondary)
            }
            if !order.text.isEmpty, order.kind.coreTitle != nil { Text(order.text).font(.subheadline) }
            Text(Self.answers(to: order, from: model.recipients(of: order), given: model.answers[order.id] ?? [:]))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .opacity(model.isSettled(order) ? 0.55 : 1)
    }

    /// "Ana: Done · Ben: no answer yet", or that nobody it was for is still in the squad.
    static func answers(to order: Order, from recipients: [Member], given: [MemberID: OrderAck.Response]) -> String {
        guard !recipients.isEmpty else { return "Nobody it was for is still in the squad." }
        return recipients.map { "\($0.name): \(given[$0.id]?.title ?? "no answer yet")" }.joined(separator: " · ")
    }
}

/// On a member's phone: the newest order still to be carried out, and the three answers.
struct OrderCard: View {
    @Environment(AppModel.self) private var model
    let order: Order

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(order.title, systemImage: "flag.fill").font(.headline)
                Spacer()
                Text(order.to == nil ? "Whole squad" : "You").font(.caption).foregroundStyle(.secondary)
            }
            if !order.text.isEmpty, order.kind.coreTitle != nil { Text(order.text) }
            if let place = order.at {
                if let mine = model.located.first(where: { $0.isMe })?.position?.at {
                    Text("\(MemberList.length(Geo.distance(mine, place))) \(MemberList.compass(Geo.bearing(from: mine, to: place))) of you. The flag on the map.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The flag on the map.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            HStack {
                ForEach(OrderAck.Response.allCases, id: \.self) { response in
                    let chosen = model.myAnswers[order.id] == response
                    Button(response.title) { model.answer(order, response) }
                        .buttonStyle(.bordered)
                        .tint(chosen ? .accentColor : .gray)
                        .fontWeight(chosen ? .bold : .regular)
                }
                Spacer()
                let more = model.openOrders.count - 1
                if more > 0 { Text("\(more) more after this").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.18))
    }
}
