import SwiftUI

@main
struct SiberLightsApp: App {
    @StateObject private var controller = SerialController()

    var body: some Scene {
        MenuBarExtra("siberLights", systemImage: "lightbulb.fill") {
            ContentView().environmentObject(controller)
        }
        .menuBarExtraStyle(.window)
    }
}
