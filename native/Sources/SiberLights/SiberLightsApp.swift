import SwiftUI

@main
struct SiberLightsApp: App {
    @StateObject private var controller = SerialController()

    var body: some Scene {
        // The label MUST NOT read any @Published property of the controller:
        // doing so re-evaluates this Scene on every state change, and a
        // re-registering .window-style MenuBarExtra steals key focus on
        // macOS 26. Connection / mic status lives inside the panel instead.
        MenuBarExtra {
            ContentView().environmentObject(controller)
        } label: {
            Image(systemName: "lightbulb.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
