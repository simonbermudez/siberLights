import SwiftUI

@main
struct SiberLightsApp: App {
    @StateObject private var controller = SerialController()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(controller)
        } label: {
            // mirrors the Python icon: lightbulb normally, muted glyph when a
            // music effect is active but the mic is delivering silence
            Image(systemName: controller.micSilent ? "lightbulb.slash"
                            : (controller.isConnected ? "lightbulb.fill" : "lightbulb"))
        }
        .menuBarExtraStyle(.window)
    }
}
