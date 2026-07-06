import SwiftUI

private let PRESETS: [(String, RGB)] = [
    ("Red", RGB(r: 255, g: 0, b: 0)),
    ("Orange", RGB(r: 255, g: 96, b: 0)),
    ("Yellow", RGB(r: 255, g: 200, b: 0)),
    ("Green", RGB(r: 0, g: 255, b: 0)),
    ("Cyan", RGB(r: 0, g: 220, b: 255)),
    ("Blue", RGB(r: 0, g: 0, b: 255)),
    ("Purple", RGB(r: 160, g: 0, b: 255)),
    ("Pink", RGB(r: 255, g: 0, b: 128)),
    ("White", RGB(r: 255, g: 255, b: 255)),
]

struct ContentView: View {
    @EnvironmentObject var controller: SerialController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // header + status
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(controller.isConnected ? .yellow : .secondary)
                Text("siberLights").font(.headline)
                Spacer()
                if controller.micSilent {
                    Image(systemName: "mic.slash")
                        .font(.caption).foregroundStyle(.orange)
                        .help("Music effect active but no audio detected")
                }
                if controller.screenNoPermission {
                    Image(systemName: "rectangle.on.rectangle.slash")
                        .font(.caption).foregroundStyle(.orange)
                        .help("Screen Sync needs Screen Recording permission — System Settings > Privacy & Security > Screen & System Audio Recording")
                }
                Circle()
                    .fill(controller.isConnected ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(controller.isConnected ? controller.portName : "not connected")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            // effect — static and music grouped in one native menu
            Picker("Effect", selection: $controller.effect) {
                Section("Static") {
                    ForEach(STATIC_EFFECTS, id: \.self) { Text($0).tag($0) }
                }
                Section("Music") {
                    ForEach(MUSIC_EFFECTS, id: \.self) { Text($0).tag($0) }
                }
                Section("Screen") {
                    ForEach(SCREEN_EFFECTS, id: \.self) { Text($0).tag($0) }
                }
            }
            .pickerStyle(.menu)

            if SCREEN_EFFECTS.contains(controller.effect) {
                Toggle("Reverse LED direction", isOn: $controller.screenReversed)
                    .font(.caption)
            }

            // color: presets + native color well
            HStack(spacing: 6) {
                ForEach(PRESETS, id: \.0) { name, rgb in
                    Button {
                        controller.color = rgb
                    } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(red: Double(rgb.r) / 255,
                                        green: Double(rgb.g) / 255,
                                        blue: Double(rgb.b) / 255))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
                ColorPicker("", selection: Binding(
                    get: { controller.swiftUIColor },
                    set: { controller.swiftUIColor = $0 }))
                    .labelsHidden()
            }

            // sliders — the whole reason for going native
            VStack(alignment: .leading, spacing: 2) {
                Text("Brightness").font(.caption).foregroundStyle(.secondary)
                Slider(value: $controller.brightness, in: 1...100)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Speed").font(.caption).foregroundStyle(.secondary)
                Slider(value: $controller.speed, in: 1...100)
            }
            VStack(alignment: .leading, spacing: 2) {
                let isMusic = MUSIC_EFFECTS.contains(controller.effect)
                Text("Music sensitivity").font(.caption)
                    .foregroundStyle(isMusic ? .secondary : Color.secondary.opacity(0.4))
                Slider(value: $controller.sensitivity, in: 1...100)
                    .disabled(!isMusic)
            }

            Toggle(isOn: $controller.followScreen) {
                Text("Turn off with display")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Blank the strip while the display sleeps, restore it on wake")

            Divider()

            HStack {
                Button(controller.isConnected ? "Disconnect" : "Connect") {
                    if controller.isConnected {
                        controller.userDisconnected = true
                        controller.disconnect()
                    } else {
                        controller.userDisconnected = false
                        controller.connect()
                    }
                }
                Spacer()
                Button("Quit") {
                    controller.shutdown()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
