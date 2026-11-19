import SwiftUI

@main
struct SquadzApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { model.resume() }
                // An invite link. It only offers to join; see AppModel.offer.
                .onOpenURL { model.offer($0.absoluteString) }
                .onChange(of: phase) { _, new in if new == .active { model.foreground() } }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("displayName") private var name = ""

    var body: some View {
        @Bindable var model = model
        Group {
            if model.role == .none { HomeView() } else { SquadView() }
        }
        .alert("Squadz", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .sheet(item: $model.offered) { invite in
            JoinConfirmView(invite: invite)
        }
    }
}
