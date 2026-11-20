import CoreGeo
import SquadKit
import ZoneKit
import SwiftUI

struct ZoneDraft {
    enum Shape: String, CaseIterable { case circle = "Circle", polygon = "Polygon" }
    var id = UUID()
    var name = ""
    var shape = Shape.circle
    var rule = SquadZone.Rule.goal
    var points: [GeoPoint] = []
    var radius = 100.0
    var members: Set<MemberID> = []

    init() {}
    init(_ zone: SquadZone) {
        id = zone.id; name = zone.name; rule = zone.rule; members = Set(zone.members ?? [])
        switch zone.shape {
        case let .circle(center, r): shape = .circle; points = [center]; radius = r
        case let .polygon(vertices): shape = .polygon; points = vertices
        }
    }
    var zone: SquadZone? {
        let geometry: ZoneShape
        switch shape {
        case .circle:
            guard let center = points.first else { return nil }
            geometry = .circle(center: center, radius: radius)
        case .polygon: geometry = .polygon(vertices: points)
        }
        return SquadZone(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), shape: geometry,
                         rule: rule, members: members.isEmpty ? nil : members.sorted { $0.raw.uuidString < $1.raw.uuidString })
    }
    mutating func pick(_ point: GeoPoint) {
        if shape == .circle { points = [point] } else if points.count < 64 { points.append(point) }
    }
}

extension SquadZone.Rule {
    var title: String { self == .goal ? "Goal arrival" : "Leave allowed area" }
    var symbol: String { self == .goal ? "flag.checkered" : "rectangle.dashed" }
}

struct ZonesPanel: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: ZoneDraft?
    @Binding var drawing: Bool
    @State private var deleting: SquadZone?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if draft != nil {
                    editor
                } else {
                    HStack {
                        Text("Zones").font(.title2.bold())
                        Spacer()
                        if model.role == .leader {
                            Button("Add zone", systemImage: "plus") { draft = ZoneDraft(); drawing = true }
                                .disabled(model.zones.count >= 32)
                        }
                    }
                    if model.zones.isEmpty {
                        ContentUnavailableView("No zones yet", systemImage: "map",
                                               description: Text(model.role == .leader ? "Add a labeled circle or polygon on the map." : "The commander can add goal and allowed-area zones."))
                    }
                    ForEach(model.zones) { zone in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(zone.name, systemImage: zone.rule.symbol).font(.headline)
                            Text(description(zone)).font(.footnote).foregroundStyle(.secondary)
                            Text(zone.members == nil ? "Whole squad" : "\(zone.members?.count ?? 0) selected members")
                                .font(.caption).foregroundStyle(.secondary)
                            if model.role == .leader {
                                HStack {
                                    Button("Edit") { draft = ZoneDraft(zone); drawing = false }
                                    Spacer()
                                    Button("Delete", role: .destructive) { deleting = zone }
                                }
                                .font(.footnote)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                    }
                    Text("Alerts need two fresh, accurate reports across a boundary. Initial positions and reconnects establish a baseline. Near-edge or missing positions do not trigger alerts.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Enable notification banners", systemImage: "bell.badge") {
                        Task { await model.enableZoneNotifications() }
                    }
                    Text("Keep squad apps open for live zone monitoring. Arrival does not mark an order Done.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("Zone activity").font(.headline)
                    if model.zoneEvents.isEmpty {
                        Text("No confirmed crossings yet.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(model.zoneEvents.reversed()) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(event.text, systemImage: event.kind == .arrived ? "flag.checkered" : "rectangle.portrait.and.arrow.right")
                                .font(.subheadline)
                            Text(event.time.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(14)
        }
        .confirmationDialog("Delete \(deleting?.name ?? "zone")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete zone", role: .destructive) {
                if let deleting { model.deleteZone(deleting) }
                deleting = nil
            }
        }
    }

    private var editor: some View {
        let binding = Binding<ZoneDraft>(get: { draft ?? ZoneDraft() }, set: { draft = $0 })
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.zones.contains(where: { $0.id == draft?.id }) ? "Edit zone" : "New zone").font(.title2.bold())
                Spacer()
                Button("Cancel") { draft = nil; drawing = false }
            }
            TextField("Map label", text: binding.name).textFieldStyle(.roundedBorder)
            Picker("Alert", selection: binding.rule) {
                ForEach(SquadZone.Rule.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Shape", selection: binding.shape) {
                ForEach(ZoneDraft.Shape.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: draft?.shape) { _, _ in draft?.points = []; drawing = true }
            if draft?.shape == .circle {
                HStack {
                    Text("Radius")
                    Spacer()
                    TextField("Metres", value: binding.radius, format: .number)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 100)
                    Text("m").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(drawing ? "Finish drawing" : (draft?.shape == .circle ? "Place centre on map" : "Add corners on map"), systemImage: "hand.tap") { drawing.toggle() }
                Spacer()
                if draft?.points.isEmpty == false { Button("Undo", systemImage: "arrow.uturn.backward") { _ = draft?.points.popLast() } }
            }
            .font(.footnote)
            if draft?.shape == .polygon { Text("\(draft?.points.count ?? 0) / 64 corners · edges close automatically") .font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("Members").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Whole squad") { draft?.members = [] }.font(.caption)
            }
            Text("No selection means the whole squad.").font(.caption).foregroundStyle(.secondary)
            ForEach(model.squad?.members ?? []) { member in
                Toggle(member.name, isOn: Binding(get: { draft?.members.contains(member.id) == true }, set: { on in
                    if on { draft?.members.insert(member.id) } else { draft?.members.remove(member.id) }
                }))
            }
            if let error = draft?.zone?.validationError { Text(error).font(.caption).foregroundStyle(.secondary) }
            if draft?.zone == nil { Text("Tap the map to place the circle centre.").font(.caption).foregroundStyle(.secondary) }
            Button("Save zone", systemImage: "checkmark") {
                if let zone = draft?.zone, model.saveZone(zone) { draft = nil; drawing = false }
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft?.zone == nil || draft?.zone?.validationError != nil)
        }
    }

    private func description(_ zone: SquadZone) -> String {
        switch zone.shape {
        case let .circle(_, radius): return "\(zone.rule.title) · circle, \(Int(radius)) m radius"
        case let .polygon(vertices): return "\(zone.rule.title) · polygon, \(vertices.count) corners"
        }
    }
}
