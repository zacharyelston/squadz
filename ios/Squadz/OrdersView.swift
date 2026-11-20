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

/// The leader's orders, all on show at once: who, what, where, a note, Send. Only the list of
/// what was sent scrolls.
struct OrdersPanel: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: OrderDraft
    /// The next tap on the map sets the place.
    @Binding var placing: Bool

    private var others: [Member] { (model.squad?.members ?? []).filter { $0.id != model.leaderID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if others.isEmpty {
                Text("Nobody else is in the squad yet. Invite someone, then send them an order.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                composer
            }
            Divider()
            Text("Sent").font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
            if model.orders.isEmpty {
                Text("Nothing sent yet.").font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.orders) { order in
                            sent(order)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: draft.kind) { _, _ in placing = draft.needsPlace && draft.place == nil }
        .onAppear { placing = draft.needsPlace && draft.place == nil }
    }

    @ViewBuilder private var composer: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("Whole squad", on: draft.to.isEmpty) { draft.to = [] }
                ForEach(others) { member in
                    chip(member.name, on: draft.to.contains(member.id)) {
                        if draft.to.contains(member.id) { draft.to.remove(member.id) } else { draft.to.insert(member.id) }
                    }
                }
            }
        }
        Picker("Kind", selection: $draft.kind) {
            ForEach(OrderDraft.kinds, id: \.self) { Text($0.coreTitle ?? $0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        if draft.needsPlace {
            HStack {
                if let place = draft.place, !placing {
                    Label(String(format: "%.5f, %.5f", place.latitude, place.longitude), systemImage: "mappin.circle.fill")
                        .font(.subheadline)
                    Spacer()
                    Button("Move it") { placing = true }.font(.subheadline)
                } else {
                    Label("Tap the map where you want them", systemImage: "hand.tap.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Spacer()
                    if draft.place != nil { Button("Keep it") { placing = false }.font(.subheadline) }
                }
            }
        }
        HStack(spacing: 8) {
            TextField(draft.kind == .note ? "Note" : "Note (optional)", text: $draft.text)
                .textFieldStyle(.roundedBorder)
                .onChange(of: draft.text) { _, new in
                    if new.count > Order.maxText { draft.text = String(new.prefix(Order.maxText)) }
                }
            Button {
                if model.sendOrder(draft.kind, text: draft.text, at: draft.needsPlace ? draft.place : nil, to: draft.to) {
                    // The same people and kind are ready for the next one; the place and note are not.
                    draft.place = nil
                    draft.text = ""
                    placing = draft.needsPlace
                }
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!draft.canSend)
        }
        Text("To \(names(draft.to)).").font(.caption).foregroundStyle(.secondary)
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: .capsule)
                .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
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
                if !model.isSettled(order) {
                    Button("Cancel", role: .destructive) { model.cancelOrder(order) }
                        .font(.footnote)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if !order.text.isEmpty, order.kind.coreTitle != nil { Text(order.text).font(.subheadline) }
            Text(model.cancelledOrders.contains(order.id) ? "Cancelled"
                 : Self.answers(to: order, from: model.recipients(of: order), given: model.answers[order.id] ?? [:]))
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

/// On a member's phone, over the map: the order to do next, in one line. Tapping it opens the
/// orders tab.
struct NextOrderLine: View {
    @Environment(AppModel.self) private var model
    let order: Order
    /// How many orders are waiting, this one included.
    let waiting: Int

    var body: some View {
        HStack {
            Label(order.title, systemImage: "flag.fill").font(.subheadline.weight(.semibold))
            if let place = order.at, let mine = model.located.first(where: { $0.isMe })?.position?.at {
                Text("\(MemberList.length(Geo.distance(mine, place))) \(MemberList.compass(Geo.bearing(from: mine, to: place)))")
                    .font(.subheadline)
            } else if !order.text.isEmpty {
                Text(order.text).font(.subheadline).lineLimit(1)
            }
            Spacer()
            if waiting > 1 { Text("+\(waiting - 1) more").font(.caption).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.orange.opacity(0.22))
        .contentShape(.rect)
    }
}

/// A member's orders, on their own tab: the ones still to do in the order they came, then the
/// ones already answered.
struct MemberOrdersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settled = model.orders.filter { model.isSettled($0) }
        List {
            if model.orders.isEmpty {
                Text("No orders yet. When your squad's leader sends one, it shows here.")
                    .foregroundStyle(.secondary)
            }
            if !model.queue.isEmpty {
                Section("To do, oldest first") {
                    ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, order in
                        OrderCard(order: order, isNext: index == 0)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
            if !settled.isEmpty {
                Section("Answered or cancelled") {
                    ForEach(settled) { order in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(order.title).fontWeight(.semibold)
                                Spacer()
                                Text(model.cancelledOrders.contains(order.id) ? "Cancelled" : model.myAnswers[order.id]?.title ?? "")
                                    .foregroundStyle(.secondary)
                            }
                            if !order.text.isEmpty, order.kind.coreTitle != nil { Text(order.text).font(.subheadline) }
                            Text(order.time.formatted(date: .omitted, time: .shortened)).font(.footnote).foregroundStyle(.secondary)
                        }
                        .opacity(0.6)
                    }
                }
            }
        }
    }
}

/// One order still to do, with the three answers.
struct OrderCard: View {
    @Environment(AppModel.self) private var model
    let order: Order
    var isNext = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(order.title, systemImage: "flag.fill").font(.headline)
                if isNext {
                    Text("Next").font(.caption.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.orange, in: .capsule).foregroundStyle(.white)
                }
                Spacer()
                Text("\(order.to == nil ? "Whole squad" : "You") · \(order.time.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
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
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isNext ? Color.orange.opacity(0.18) : Color.clear)
    }
}
