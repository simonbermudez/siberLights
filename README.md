# siberLights

An open-source macOS driver and controller for **Skydimo-protocol USB LED strips** —
including white-label variants like the **Fiotura G100** monitor backlight — built to
replace the vendor software entirely.

The strip presents as a WCH **CH340** USB-to-serial device (`1a86:7523`). This project
talks to it directly over serial, so no vendor app, no cloud, no telemetry.

## Two implementations

- **`native/`** — a native **Swift / SwiftUI** menu bar app (recommended). Tiny, fast,
  renders proper native controls, and integrates cleanly with macOS. This is the app to
  install.
- **Python** (repo root) — the original reference implementation (rumps menu bar app +
  tkinter window app). Useful for reading the protocol and effects logic in a
  higher-level language; kept for reference.

Both speak the identical serial protocol and implement the same 24 effects.

## Features

- **Menu bar app** (`menubar_app.py`) — the primary UI, a native macOS status-bar menu.
- **Window app** (`lights_app.py`) — an alternative tkinter window UI.
- **24 effects**: 16 static (Solid, Rainbow, Breathe, Comet, Scanner, Fire, Aurora,
  Police, Candle, …) and 8 music-reactive (Spectrum, Pulse, VU Meter, Center Burst,
  Rainbow Beat, Beat Flash, Ripples, Bass & Treble).
- **Music sync** via any audio input (microphone, or a loopback device like
  [BlackHole](https://github.com/ExistentialAudio/BlackHole) for perfect sync). A 24-band
  FFT with automatic gain control and beat detection. The input is opened *only* while a
  music effect is active.
- **Adjustable** brightness, effect speed, and music sensitivity.
- **Persistent settings** — the last mode, color, and slider positions are restored on
  launch (`~/Library/Application Support/SiberLights/config.json`).
- **Auto-launch on plug-in** and auto-quit on unplug, via a LaunchAgent that watches for
  the CH340 USB device.

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

A minimal sender is about three lines:

```python
import serial
s = serial.Serial("/dev/cu.usbserial-14220", 115200)
s.write(b"Ada\x00\x00" + bytes([65]) + bytes([255, 0, 0]) * 65)  # all red
```

The CH340 serial driver is built into macOS 11+ — no extra kernel driver needed.

## Native app (recommended)

Requires the Swift toolchain (Xcode or Command Line Tools — no full Xcode needed).

```bash
cd native
./build.sh install     # build, bundle, sign, copy to /Applications, load LaunchAgent, launch
# or just: ./build.sh  -> build/SiberLights.app without installing
```

`install` also registers a LaunchAgent that auto-launches the app when the strip is
plugged in; the app auto-quits ~6s after it's unplugged.

### Native layout

| File | Purpose |
|------|---------|
| `native/Sources/SiberLights/SerialController.swift` | Serial port + 30fps render loop + persistence + lifecycle |
| `native/Sources/SiberLights/Effects.swift`          | All 24 effects |
| `native/Sources/SiberLights/AudioAnalyzer.swift`    | AVAudioEngine + vDSP FFT (music effects) |
| `native/Sources/SiberLights/ContentView.swift`      | SwiftUI menu panel |
| `native/Sources/SiberLights/SiberLightsApp.swift`   | MenuBarExtra entry point |
| `native/build.sh`                                   | Build / bundle / install script |

## Python reference implementation

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python menubar_app.py     # menu bar app (rumps)
.venv/bin/python lights_app.py      # window app (tkinter)
.venv/bin/python setup.py py2app    # -> dist/SiberLights.app
```

| File | Purpose |
|------|---------|
| `lights_core.py` | Serial streamer, effects engine, audio analyzer (no UI deps) |
| `menubar_app.py` | Menu bar app (rumps) |
| `lights_app.py`  | Window app (tkinter) |
| `setup.py`       | py2app build script |

## License

MIT
