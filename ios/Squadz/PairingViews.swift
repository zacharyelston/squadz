import PairKitUI
import SwiftUI

/// First run: say who you are, then scan (or paste) a pairing code.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("displayName") private var name = ""
    @State private var scanning = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.tint)
                        Text("Squadz").font(.largeTitle.weight(.bold))
                        Text("See where your squad is, with no internet needed.")
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
                }

                if let code = model.pendingCode {
                    Section {
                        Button("Join with the invite you opened", systemImage: "person.badge.plus") {
                            Task { await model.pair(code: code, name: trimmed) }
                        }
                        .disabled(trimmed.isEmpty || model.busy)
                    } footer: {
                        Text(trimmed.isEmpty ? "Enter your name first." : "")
                    }
                }

                Section {
                    Button("Scan a code", systemImage: "qrcode.viewfinder") { scanning = true }
                    PairCodePasteButton(name: trimmed)
                } footer: {
                    Text("To join a squad, scan the code a member shows you under Invite. To start one, scan the code on the server's page.")
                }
                .disabled(trimmed.isEmpty || model.busy)
            }
            .overlay { if model.busy { ProgressView("Pairing…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
            .fullScreenCover(isPresented: $scanning) { ScanView(name: trimmed) }
        }
    }
}

/// Pairs from a code on the clipboard, for phones with no working camera.
/// iOS asks the user to allow the paste.
struct PairCodePasteButton: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        Button("Paste a code", systemImage: "doc.on.clipboard") {
            guard let code = UIPasteboard.general.string, !code.isEmpty else {
                model.alert = "There's no text to paste, or pasting wasn't allowed. Copy the pairing code and try again."
                return
            }
            Task { await model.pair(code: code, name: name) }
        }
    }
}

/// The camera scanner. Closes itself once a code has been read.
struct ScanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let name: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if QRScanner.isAvailable {
                    QRScanner { code in
                        dismiss()
                        Task { await model.pair(code: code, name: name) }
                    }
                    .clipShape(.rect(cornerRadius: 16))
                    .accessibilityLabel("Camera viewfinder for the pairing code")
                    Text("Point the camera at the pairing code.")
                        .foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("Camera scanning isn't available", systemImage: "camera",
                                           description: Text("Allow camera access in Settings, or go back and paste the code instead."))
                }
            }
            .padding()
            .navigationTitle("Scan a code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// Paired with a server but in no squad: start one, or join another.
struct NoSquadView: View {
    @Environment(AppModel.self) private var model
    @State private var squadName = ""
    @State private var scanning = false

    private var trimmed: String { squadName.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Squad name", text: $squadName)
                        .submitLabel(.go)
                        .onSubmit(create)
                    Button("Start squad", systemImage: "plus.circle.fill", action: create)
                        .disabled(trimmed.isEmpty || model.busy)
                } header: {
                    Text("Start a squad")
                } footer: {
                    Text("You'll get a code to show the others.")
                }

                Section {
                    Button("Scan a code", systemImage: "qrcode.viewfinder") { scanning = true }
                    PairCodePasteButton(name: model.me?.name ?? "")
                } header: {
                    Text("Join a squad instead")
                }
                .disabled(model.busy)

                Section {
                    Button("Forget this server", role: .destructive) { Task { await model.signOut() } }
                }
            }
            .navigationTitle("Hello, \(model.me?.name ?? "")")
            .fullScreenCover(isPresented: $scanning) { ScanView(name: model.me?.name ?? "") }
        }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        Task { await model.createSquad(name: trimmed) }
    }
}
