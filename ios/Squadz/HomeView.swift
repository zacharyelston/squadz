import SquadKit
import SwiftUI

/// In no squad: say who you are, then start a squad or join one.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("displayName") private var name = ""
    @AppStorage("relayURL") private var relayURL = ""
    @AppStorage("relayPin") private var relayPin = ""
    @State private var squadName = ""
    @State private var scanning = false
    @State private var reviewing = false

    private var me: String { name.trimmingCharacters(in: .whitespaces) }
    private var newSquad: String { squadName.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.tint)
                        Text("Squadz").font(.largeTitle.weight(.bold))
                        Text("See where your squad is. No internet and no server needed: your phones talk to each other.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("Your name", text: $name)
                        .textContentType(.nickname)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                } header: {
                    Text("Shown to your squad")
                } footer: {
                    if me.isEmpty { Text("Enter your name to start or join a squad.") }
                }

                Section {
                    Button("Scan an invite", systemImage: "qrcode.viewfinder") { scanning = true }
                } header: {
                    Text("Join a squad")
                } footer: {
                    Text("Scan the code on the leader's phone. You'll be asked before you join.")
                }
                .disabled(me.isEmpty || model.joining)

                Section {
                    TextField("Squad name", text: $squadName)
                        .submitLabel(.go)
                        .onSubmit(start)
                    Button("Start squad", systemImage: "plus.circle.fill", action: start)
                        .disabled(me.isEmpty || newSquad.isEmpty || model.joining)
                } header: {
                    Text("Start a squad")
                } footer: {
                    Text("Your phone leads it: the others connect to it, and it has to stay on and in reach.")
                }

                Section {
                    Button("Mission logs", systemImage: "list.bullet.clipboard") { reviewing = true }
                } footer: {
                    Text("What happened in each squad this device led: positions, orders, notes, and any clips and stills kept. Kept on this device only.")
                }

                Section {
                    TextField("Relay address", text: $relayURL, prompt: Text("relay.example.org"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Certificate fingerprint", text: $relayPin, prompt: Text("Only for a relay with its own certificate"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                } header: {
                    Text("Relay (optional)")
                } footer: {
                    Text("With a relay, a squad you start can be reached over the internet as well as nearby. The relay passes messages along and can't read them. Leave this empty to stay on your own network.")
                }
            }
            .overlay {
                if model.joining { ProgressView("Joining…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) }
            }
            .fullScreenCover(isPresented: $scanning) { ScanView() }
            .sheet(isPresented: $reviewing) { MissionListView() }
        }
    }

    private func start() {
        guard !me.isEmpty, !newSquad.isEmpty else { return }
        model.startSquad(name: newSquad, as: me)
    }
}

/// "Join Red led by Ana?" Nothing joins until the button is tapped.
struct JoinConfirmView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("displayName") private var name = ""
    let invite: SquadInvite

    private var me: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text(invite.by.map { "Join \(invite.name), led by \($0)?" } ?? "Join \(invite.name)?")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("The squad will see your name and where you are while Squadz is open.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                TextField("Your name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.nickname)
                    .autocorrectionDisabled()
                Button("Join \(invite.name)") { model.join(invite, as: me) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(me.isEmpty)
                Spacer()
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

extension SquadInvite: @retroactive Identifiable {
    public var id: Data { enrol }
}
