import SwiftUI

@main
struct RelayGUIApp: App {
    @StateObject private var relay = RelayService()

    var body: some Scene {
        WindowGroup("Relay") {
            ContentView()
                .environmentObject(relay)
                .preferredColorScheme(.dark)
                .frame(minWidth: 960, minHeight: 620)
                .task {
                    await relay.run()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
    }
}
