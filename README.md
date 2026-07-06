# siberLights

An open-source **native macOS menu bar app** for **Skydimo-protocol USB LED strips** —
including white-label variants like the **Fiotura G100** monitor backlight — built to
replace the vendor software entirely.

The strip presents as a WCH **CH340** USB-to-serial device (`1a86:7523`). The app talks to
it directly over serial, so no vendor app, no cloud, no telemetry.

## Features

- **Native SwiftUI menu bar app** (`MenuBarExtra`) — tiny, fast, no runtime dependencies.
- **33 effects**:
  - **16 static**: Solid, Rainbow, Breathe, Color Wipe, Theater Chase, Comet, Scanner,
    Sparkle, Confetti, Fire, Aurora, Wave, Strobe, Police, Candle, Off.
  - **16 music-reactive**: Spectrum, Pulse, VU Meter, Center Burst, Rainbow Beat,
    Beat Flash, Ripples, Bass & Treble, Mirror Spectrum, Dual VU, Color Organ, Fireworks,
    Energy Comet, Bass Pump, Flow, Meter Peak.
  - **1 screen-reactive**: Screen Sync — ambient/bias lighting that mirrors the screen
    content just above the strip.
- **Music sync** from the default audio input via `AVAudioEngine` + Accelerate/`vDSP` — a
  24-band FFT with automatic gain control and beat detection. The mic is opened *only*
  while a music effect is active.
- **Screen sync** via `ScreenCaptureKit` — samples the bottom edge of the middle row of
  displays (where the strip physically sits, spanning multiple monitors), averages one
  color per LED at 30fps with temporal smoothing, and maps LEDs to screens proportionally
  by their arrangement. A "Reverse LED direction" toggle handles strips wired
  right-to-left. Capture runs *only* while Screen Sync is active; needs the Screen
  Recording permission (macOS prompts on first use).
- **Adjustable** brightness, effect speed, and music sensitivity, with native color presets
  and a color picker.
- **Persistent settings** — the last effect, color, and slider positions are restored on
  launch (stored in `UserDefaults`).
- **Auto-launch on plug-in** via a LaunchAgent that watches for the CH340 USB device, and
  **auto-quit ~6s after unplug** (with auto-reconnect on replug).
- **Automatic overrides** — while the screensaver is showing, the lights switch to Screen
  Sync (they follow the screensaver); while the displays are asleep, the lights turn off.
  The selected effect resumes when conditions return to normal.

## Install

Requires the Swift toolchain — Xcode **or** just the Command Line Tools
(`xcode-select --install`); a full Xcode install is not needed.

```bash
cd native
./build.sh install     # build, bundle, sign, copy to /Applications, load LaunchAgent, launch
```

Or build without installing:

```bash
cd native
./build.sh             # -> native/build/SiberLights.app
```

The CH340 serial driver is built into macOS 11+ — no extra kernel driver needed. On first
use of a music effect, macOS prompts for microphone access.

## The protocol

Reverse-engineered from the Hyperion project's `skydimo` driver and verified against the
hardware. It's a simplified Adalight variant:

- **Serial:** 115200 baud, 8N1
- **Frame:** `"Ada"` (`0x41 0x64 0x61`) + `0x00 0x00` + one byte LED count, followed by
  3 bytes per LED in **RGB** order.
- No checksum (unlike classic Adalight, which uses count-hi / count-lo / XOR in bytes 3–5).
- Fire-and-forget: stream a new frame whenever colors change.
- This strip wants the **real** LED count in the frame; padding to 255 LEDs misbehaves.
  The Fiotura G100 (27") has 65 LEDs.

The whole wire format, illustrated in any language (here Python):

```python
import serial
s = serial.Serial("/dev/cu.usbserial-XXXX", 115200)
s.write(b"Ada\x00\x00" + bytes([65]) + bytes([255, 0, 0]) * 65)  # all red
```

## Layout

| File | Purpose |
|------|---------|
| `native/Sources/SiberLights/SerialController.swift` | Serial port + 30fps render loop + persistence + lifecycle |
| `native/Sources/SiberLights/Effects.swift`          | All static + music effects |
| `native/Sources/SiberLights/AudioAnalyzer.swift`    | `AVAudioEngine` + `vDSP` FFT (music effects) |
| `native/Sources/SiberLights/ScreenSampler.swift`    | `ScreenCaptureKit` bottom-edge capture (Screen Sync) |
| `native/Sources/SiberLights/ContentView.swift`      | SwiftUI panel (hosted in an `NSPopover`) |
| `native/Sources/SiberLights/main.swift`             | Entry point — `NSStatusItem` menu bar item |
| `native/build.sh`                                   | Build / bundle / install script |

## License

MIT
