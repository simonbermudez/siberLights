#!/usr/bin/env python3
"""siberLights menu bar app — native macOS status-bar controller for the strip.

Reuses the serial streamer, effects, and audio analyzer from lights_app.py.
Run with:  .venv/bin/python menubar_app.py
"""

import glob
import json
import os
import subprocess

import rumps
import sounddevice as sd

# rumps 0.4.0 sets the status-item title via the legacy pre-10.14 API
# (NSStatusItem.setTitle_), which is a silent no-op on macOS 26 — the item
# ends up zero-width and invisible. Route the title through the item's
# button (the modern API) instead.
from rumps.rumps import NSApp as _RumpsNSApp


def _set_status_bar_title(self):
    title = self._app['_title']
    if title is None:
        title = self._app['_name']
    button = self.nsstatusitem.button()
    if button is not None:
        button.setTitle_(title)
    else:  # pre-10.10 fallback, keeps old behavior
        self.nsstatusitem.setTitle_(title)


_RumpsNSApp.setStatusBarTitle = _set_status_bar_title

# Menu bar managers (Bartender etc.) leave persistent per-item hide flags in
# Control Center's prefs keyed by the item's autosave name. rumps items get the
# generic name "Item-N", and this machine has 165 of those flagged hidden — so
# any rumps app is born invisible. Give our item a unique autosave name with a
# clean history and force it visible.
_orig_initializeStatusBar = _RumpsNSApp.initializeStatusBar


def _initialize_status_bar(self):
    _orig_initializeStatusBar(self)
    self.nsstatusitem.setAutosaveName_("SiberLights")
    self.nsstatusitem.setVisible_(True)


_RumpsNSApp.initializeStatusBar = _initialize_status_bar

# NOTE on slider looks: macOS 26's rewritten menu pipeline renders a custom
# menu item view itself but NOT its subviews — wrapping the NSSlider in a
# padded container (frame-based or Auto Layout, layer-backed or not) yields a
# blank row. So the slider must stay as the item's direct view, which means
# no native-style margins until rumps supports the new pipeline.

from lights_core import (
    AudioAnalyzer,
    LedStreamer,
    MUSIC_EFFECTS,
    PRESETS,
    STATIC_EFFECTS,
)

CONFIG_DIR = os.path.expanduser("~/Library/Application Support/SiberLights")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")


def load_config():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def save_config(cfg):
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(CONFIG_PATH, "w") as f:
            json.dump(cfg, f, indent=2)
    except Exception:
        pass


def usb_ports():
    return sorted(glob.glob("/dev/cu.usbserial*") + glob.glob("/dev/cu.wchusbserial*"))


class SiberLights(rumps.App):
    def __init__(self):
        super().__init__("siberLights", title="💡", quit_button=None)
        self.streamer = LedStreamer()
        self.audio = AudioAnalyzer()
        self.streamer.audio = self.audio
        self.streamer.start()
        self.audio_device = None
        self._audio_names = {}
        self.user_disconnected = False  # manual disconnect suppresses auto-reconnect
        self._no_device_ticks = 0
        self._cfg = load_config()
        self._dirty = False

        # -- build menu ------------------------------------------------
        self.conn_item = rumps.MenuItem("Connect", callback=self._toggle_conn)

        self.effect_items = {}
        static_items = [self._effect_item(n) for n in STATIC_EFFECTS]
        music_items = [self._effect_item(n) for n in MUSIC_EFFECTS]

        color_items = [rumps.MenuItem(name, callback=self._pick_preset)
                       for name in PRESETS]
        color_items += [None, rumps.MenuItem("Custom…", callback=self._pick_custom)]

        self.bri_slider = rumps.SliderMenuItem(
            value=self._cfg.get("brightness", 100), min_value=1, max_value=100,
            callback=self._on_slider, dimensions=(180, 20))
        self.speed_slider = rumps.SliderMenuItem(
            value=self._cfg.get("speed", 50), min_value=1, max_value=100,
            callback=self._on_slider, dimensions=(180, 20))
        self.sens_slider = rumps.SliderMenuItem(
            value=self._cfg.get("sensitivity", 50), min_value=1, max_value=100,
            callback=self._on_slider, dimensions=(180, 20))

        self.menu = [
            self.conn_item,
            None,
            {"Static effects": static_items},
            {"Music effects": music_items},
            {"Color": color_items},
            None,
            rumps.MenuItem("Brightness"),
            self.bri_slider,
            rumps.MenuItem("Speed"),
            self.speed_slider,
            rumps.MenuItem("Music sensitivity"),
            self.sens_slider,
            None,
            {"Audio input": [rumps.MenuItem("Refresh devices",
                                            callback=self._refresh_audio), None]},
            None,
            rumps.MenuItem("Quit siberLights", callback=self._quit),
        ]

        # restore saved state (default mode)
        effect = self._cfg.get("effect", "Solid")
        if effect not in self.effect_items:
            effect = "Solid"
        self.effect_items[effect].state = 1
        color = self._cfg.get("color")
        if isinstance(color, list) and len(color) == 3:
            self.streamer.color = tuple(int(c) for c in color)
        self.streamer.configure(
            effect=effect,
            brightness=self.bri_slider.value / 100.0,
            speed=self.speed_slider.value / 12.5,
        )
        self.audio.gain = self.sens_slider.value / 50.0

        self._refresh_audio(None)  # resolves the saved device name if present
        self._connect()
        self._sync_audio_state()
        rumps.Timer(self._tick, 2).start()

    # -- persistence -----------------------------------------------------
    def _save(self):
        self._cfg.update(
            effect=self._current_effect(),
            color=list(self.streamer.color),
            brightness=self.bri_slider.value,
            speed=self.speed_slider.value,
            sensitivity=self.sens_slider.value,
            audio_device=self._audio_names.get(self.audio_device),
        )
        save_config(self._cfg)
        self._dirty = False

    def _tick(self, _):
        if self._dirty:
            self._save()
        ports = usb_ports()
        if not ports:
            # lights unplugged: quit after ~6s grace (survives replug blips);
            # the LaunchAgent relaunches us on the next USB attach
            self._no_device_ticks += 1
            if self._no_device_ticks >= 3:
                self._quit(None)
                return
        else:
            self._no_device_ticks = 0
        if not self.streamer.serial:
            # port vanished (unplug) or never connected; reflect it and retry
            if self.conn_item.title.startswith("Disconnect"):
                self.conn_item.title = "Connect"
            if ports and not self.user_disconnected:
                self._connect()
        if self._current_effect() in MUSIC_EFFECTS and self.audio.is_silent():
            self.title = "💡🔇"  # input open but delivering pure silence
        else:
            self.title = "💡"

    # -- menu construction helpers -------------------------------------
    def _effect_item(self, name):
        item = rumps.MenuItem(name, callback=self._set_effect)
        self.effect_items[name] = item
        return item

    # -- connection ------------------------------------------------------
    def _connect(self):
        ports = usb_ports()
        if not ports:
            self.conn_item.title = "Connect (no device found)"
            self.title = "💡"
            return
        err = self.streamer.connect(ports[0])
        if err:
            self.conn_item.title = f"Connect (error: {err[:40]})"
        else:
            self.conn_item.title = f"Disconnect ({ports[0].rsplit('/', 1)[-1]})"
        self.title = "💡"

    def _toggle_conn(self, _):
        if self.streamer.serial:
            self.user_disconnected = True
            self.streamer.disconnect()
            self.audio.stop()
            self.conn_item.title = "Connect"
            self.title = "💡"
        else:
            self.user_disconnected = False
            self._connect()
            self._sync_audio_state()

    # -- effects -----------------------------------------------------------
    def _set_effect(self, sender):
        for item in self.effect_items.values():
            item.state = 0
        sender.state = 1
        self.streamer.configure(effect=sender.title)
        self._sync_audio_state()
        self._dirty = True

    def _current_effect(self):
        for name, item in self.effect_items.items():
            if item.state:
                return name
        return "Solid"

    def _sync_audio_state(self):
        if self._current_effect() in MUSIC_EFFECTS:
            err = self.audio.start(self.audio_device)
            if err:
                rumps.notification("siberLights", "Audio input error", err)
        else:
            self.audio.stop()

    # -- color ---------------------------------------------------------------
    def _pick_preset(self, sender):
        self.streamer.configure(color=PRESETS[sender.title])
        self._dirty = True

    def _pick_custom(self, _):
        cur = self.streamer.color
        default = f"{{{cur[0] * 257}, {cur[1] * 257}, {cur[2] * 257}}}"
        res = subprocess.run(
            ["osascript", "-e", f"choose color default color {default}"],
            capture_output=True, text=True)
        if res.returncode == 0 and res.stdout.strip():
            parts = [int(p) for p in res.stdout.strip().split(", ")]
            if len(parts) == 3:
                self.streamer.configure(color=tuple(p // 257 for p in parts))
                self._dirty = True

    # -- sliders ----------------------------------------------------------
    def _on_slider(self, _):
        self.streamer.configure(
            brightness=self.bri_slider.value / 100.0,
            speed=self.speed_slider.value / 12.5,
        )
        self.audio.gain = self.sens_slider.value / 50.0
        self._dirty = True

    # -- audio input -----------------------------------------------------
    def _refresh_audio(self, _):
        menu = self.menu["Audio input"]
        menu.clear()
        menu.add(rumps.MenuItem("Refresh devices", callback=self._refresh_audio))
        menu.add(None)
        try:
            devices = sd.query_devices()
        except Exception:
            devices = []
        self._audio_names = {i: d["name"] for i, d in enumerate(devices)
                             if d["max_input_channels"] > 0}
        for i, name in self._audio_names.items():
            menu.add(rumps.MenuItem(f"[{i}] {name}",
                                    callback=self._pick_audio_device))
        # default: saved device name, else BlackHole loopback, else system default
        if self.audio_device is None:
            saved = self._cfg.get("audio_device")
            names_lower = {i: nm.lower() for i, nm in self._audio_names.items()}
            self.audio_device = next(
                (i for i, nm in self._audio_names.items() if nm == saved), None)
            if self.audio_device is None:
                self.audio_device = next(
                    (i for i, nm in names_lower.items() if "blackhole" in nm), None)
            if self.audio_device is None:
                try:
                    self.audio_device = sd.default.device[0]
                except Exception:
                    self.audio_device = next(iter(self._audio_names), None)
        self._mark_audio_device()

    def _mark_audio_device(self):
        for key, item in self.menu["Audio input"].items():
            if key.startswith("["):
                item.state = 1 if key.startswith(f"[{self.audio_device}]") else 0

    def _pick_audio_device(self, sender):
        self.audio_device = int(sender.title[1:sender.title.index("]")])
        self._mark_audio_device()
        if self._current_effect() in MUSIC_EFFECTS:
            self.audio.start(self.audio_device)
        self._dirty = True

    # -- quit -----------------------------------------------------------------
    def _quit(self, _):
        self._save()
        self.audio.stop()
        self.streamer.stop()  # blanks the strip and closes the port
        rumps.quit_application()


if __name__ == "__main__":
    SiberLights().run()
