import SwiftUI

@main
struct SquadzApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in Task { await model.open(url) } }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { model.resume() } else if phase == .background { model.pause() }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.account == nil {
                WelcomeView()
            } else if model.squad != nil {
                SquadView()
            } else if model.me != nil {
                NoSquadView()
            } else {
                ConnectingView()
            }
        }
        .alert("Squadz", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
    }
}

/// Paired, but the server hasn't answered yet.
struct ConnectingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            if let problem = model.connectionProblem {
                ContentUnavailableView {
                    Label("Can't reach the server", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("\(problem) Squadz keeps trying while this screen is open.")
                } actions: {
                    Button("Forget this server", role: .destructive) { Task { await model.signOut() } }
                }
            } else {
                ProgressView("Connecting…")
            }
        }
        .padding()
    }
}
