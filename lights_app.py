#!/usr/bin/env python3
"""siberLights — tkinter window UI (secondary; the menu bar app is the main UI).

The protocol, effects engine, and audio analyzer live in lights_core.py.
Run with:  .venv/bin/python lights_app.py
"""

import glob
import tkinter as tk
from tkinter import colorchooser, ttk

import sounddevice as sd

from lights_core import (
    AudioAnalyzer,
    LedStreamer,
    MUSIC_EFFECTS,
    PRESETS,
    STATIC_EFFECTS,
)


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("siberLights")
        self.resizable(False, False)
        self.streamer = LedStreamer()
        self.audio = AudioAnalyzer()
        self.streamer.audio = self.audio
        self.streamer.start()
        self._build()
        self._refresh_ports()
        self._refresh_audio_devices()
        self.protocol("WM_DELETE_WINDOW", self._quit)
        self.after(500, self._poll_status)

    # -- UI -------------------------------------------------------------
    def _build(self):
        pad = {"padx": 10, "pady": 5}
        frm = ttk.Frame(self)
        frm.grid(sticky="nsew", padx=10, pady=10)

        # connection row
        row = ttk.Frame(frm)
        row.grid(row=0, column=0, sticky="ew", **pad)
        ttk.Label(row, text="Port:").pack(side="left")
        self.port_var = tk.StringVar()
        self.port_menu = ttk.Combobox(row, textvariable=self.port_var, width=28, state="readonly")
        self.port_menu.pack(side="left", padx=5)
        ttk.Button(row, text="⟳", width=2, command=self._refresh_ports).pack(side="left")
        self.conn_btn = ttk.Button(row, text="Connect", command=self._toggle_conn)
        self.conn_btn.pack(side="left", padx=5)

        # effect selectors, grouped by category
        self.effect_var = tk.StringVar(value="Solid")

        row3 = ttk.LabelFrame(frm, text="Static effects")
        row3.grid(row=2, column=0, sticky="ew", **pad)
        for i, name in enumerate(STATIC_EFFECTS):
            ttk.Radiobutton(row3, text=name, value=name, variable=self.effect_var,
                            command=self._apply_settings).grid(row=i // 4, column=i % 4,
                                                               sticky="w", padx=8, pady=3)

        row3b = ttk.LabelFrame(frm, text="Music effects (uses audio input)")
        row3b.grid(row=3, column=0, sticky="ew", **pad)
        for i, name in enumerate(MUSIC_EFFECTS):
            ttk.Radiobutton(row3b, text=name, value=name, variable=self.effect_var,
                            command=self._apply_settings).grid(row=i // 4, column=i % 4,
                                                               sticky="w", padx=8, pady=3)

        # color presets + picker
        row4 = ttk.LabelFrame(frm, text="Color")
        row4.grid(row=4, column=0, sticky="ew", **pad)
        swatches = ttk.Frame(row4)
        swatches.pack(fill="x", padx=5, pady=5)
        for i, (name, rgb) in enumerate(PRESETS.items()):
            hexcol = "#%02x%02x%02x" % rgb
            b = tk.Button(swatches, bg=hexcol, width=2, relief="raised",
                          command=lambda c=rgb: self._set_color(c))
            b.grid(row=0, column=i, padx=2)
        pick = ttk.Frame(row4)
        pick.pack(fill="x", padx=5, pady=(0, 6))
        ttk.Button(pick, text="Custom color…", command=self._pick_color).pack(side="left")
        self.color_preview = tk.Label(pick, text="   ", bg="#ff6000", relief="sunken")
        self.color_preview.pack(side="left", padx=8, ipadx=10)

        # sliders
        row5 = ttk.Frame(frm)
        row5.grid(row=5, column=0, sticky="ew", **pad)
        ttk.Label(row5, text="Brightness").grid(row=0, column=0, sticky="w")
        self.bri_var = tk.DoubleVar(value=100)
        ttk.Scale(row5, from_=1, to=100, variable=self.bri_var, length=260,
                  command=lambda v: self._apply_settings()).grid(row=0, column=1, padx=8)
        ttk.Label(row5, text="Speed").grid(row=1, column=0, sticky="w")
        self.speed_var = tk.DoubleVar(value=50)
        ttk.Scale(row5, from_=1, to=100, variable=self.speed_var, length=260,
                  command=lambda v: self._apply_settings()).grid(row=1, column=1, padx=8)
        ttk.Label(row5, text="Music sensitivity").grid(row=2, column=0, sticky="w")
        self.sens_var = tk.DoubleVar(value=50)
        ttk.Scale(row5, from_=1, to=100, variable=self.sens_var, length=260,
                  command=lambda v: self._apply_settings()).grid(row=2, column=1, padx=8)

        # audio input (used by Music effects; input opens only while one is active)
        rowa = ttk.Frame(frm)
        rowa.grid(row=6, column=0, sticky="ew", **pad)
        ttk.Label(rowa, text="Audio input:").pack(side="left")
        self.audio_var = tk.StringVar()
        self.audio_menu = ttk.Combobox(rowa, textvariable=self.audio_var, width=30,
                                       state="readonly")
        self.audio_menu.pack(side="left", padx=5)
        self.audio_menu.bind("<<ComboboxSelected>>", lambda e: self._apply_settings())
        ttk.Button(rowa, text="⟳", width=2,
                   command=self._refresh_audio_devices).pack(side="left")

        # status bar
        self.status = tk.StringVar(value="Not connected")
        ttk.Label(frm, textvariable=self.status, foreground="gray").grid(
            row=7, column=0, sticky="w", **pad)

    # -- callbacks --------------------------------------------------------
    def _refresh_ports(self):
        ports = sorted(glob.glob("/dev/cu.usbserial*") + glob.glob("/dev/cu.wchusbserial*"))
        self.port_menu["values"] = ports
        if ports and not self.port_var.get():
            self.port_var.set(ports[0])

    def _refresh_audio_devices(self):
        items = []
        try:
            for i, d in enumerate(sd.query_devices()):
                if d["max_input_channels"] > 0:
                    items.append(f"[{i}] {d['name']}")
        except Exception:
            pass
        self.audio_menu["values"] = items
        if items and not self.audio_var.get():
            # prefer a loopback device (BlackHole etc.) if present, else default input
            loop = next((s for s in items if "blackhole" in s.lower()), None)
            if loop:
                self.audio_var.set(loop)
            else:
                try:
                    default = sd.default.device[0]
                    self.audio_var.set(next(s for s in items
                                            if s.startswith(f"[{default}]")))
                except Exception:
                    self.audio_var.set(items[0])

    def _audio_device_index(self):
        v = self.audio_var.get()
        if v.startswith("["):
            try:
                return int(v[1:v.index("]")])
            except ValueError:
                pass
        return None

    def _toggle_conn(self):
        if self.streamer.serial:
            self.streamer.disconnect()
            self.conn_btn.config(text="Connect")
            self.status.set("Not connected")
        else:
            port = self.port_var.get()
            if not port:
                self.status.set("No port selected — plug in the lights and hit ⟳")
                return
            err = self.streamer.connect(port)
            if err:
                self.status.set(f"Error: {err}")
            else:
                self._apply_settings()
                self.conn_btn.config(text="Disconnect")
                self.status.set(f"Connected to {port}")

    def _set_color(self, rgb):
        self.color_preview.config(bg="#%02x%02x%02x" % rgb)
        self.streamer.configure(color=rgb)
        # picking a color while "Off" is selected implies the user wants light
        if self.effect_var.get() == "Off":
            self.effect_var.set("Solid")
        self._apply_settings()

    def _pick_color(self):
        rgb, _ = colorchooser.askcolor(parent=self)
        if rgb:
            self._set_color(tuple(int(c) for c in rgb))

    def _apply_settings(self):
        effect = self.effect_var.get()
        self.streamer.configure(
            effect=effect,
            brightness=self.bri_var.get() / 100.0,
            speed=self.speed_var.get() / 12.5,  # 1..100 -> 0.08..8
        )
        # 1..100 -> gain 0.02..2.0 (50 = neutral); also affects beat trigger ease
        self.audio.gain = self.sens_var.get() / 50.0
        # open the audio input only while a music effect is selected
        if effect in MUSIC_EFFECTS:
            err = self.audio.start(self._audio_device_index())
            if err:
                self.status.set(f"Audio error: {err}")
        else:
            self.audio.stop()

    def _poll_status(self):
        err = self.streamer.error
        if err and self.streamer.serial is None and self.conn_btn["text"] == "Disconnect":
            self.conn_btn.config(text="Connect")
            self.status.set(f"Disconnected: {err}")
        self.after(500, self._poll_status)

    def _quit(self):
        self.audio.stop()
        self.streamer.stop()
        self.destroy()


if __name__ == "__main__":
    App().mainloop()
