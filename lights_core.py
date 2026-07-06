#!/usr/bin/env python3
"""siberLights core — serial streamer, effects engine, audio analyzer.

Speaks the Skydimo serial protocol directly:
  frame = b"Ada" + 0x00 0x00 + <led count byte> + RGB*count  @ 115200 baud
"""

import colorsys
import glob
import math
import random
import threading
import time
import numpy as np
import serial
import sounddevice as sd

BAUD = 115200
FPS = 30
LED_COUNT = 65

STATIC_EFFECTS = [
    "Solid", "Rainbow", "Breathe", "Color Wipe",
    "Theater Chase", "Comet", "Scanner", "Sparkle",
    "Confetti", "Fire", "Aurora", "Wave",
    "Strobe", "Police", "Candle", "Off",
]

MUSIC_EFFECTS = [
    "Spectrum", "Pulse", "VU Meter", "Center Burst",
    "Rainbow Beat", "Beat Flash", "Ripples", "Bass & Treble",
]

EFFECTS = STATIC_EFFECTS + MUSIC_EFFECTS

PRESETS = {
    "Red": (255, 0, 0),
    "Orange": (255, 96, 0),
    "Yellow": (255, 200, 0),
    "Green": (0, 255, 0),
    "Cyan": (0, 220, 255),
    "Blue": (0, 0, 255),
    "Purple": (160, 0, 255),
    "Pink": (255, 0, 128),
    "White": (255, 255, 255),
}


class AudioAnalyzer:
    """Captures an audio input and exposes smoothed band energies + beat flag.

    The input stream is only open while a music effect is active.
    """

    NBANDS = 24
    RATE = 44100
    BLOCK = 2048

    def __init__(self):
        self.lock = threading.Lock()
        self.stream = None
        self.device = None
        self.bands = [0.0] * self.NBANDS
        self.level = 0.0
        self.beat = False
        self.error = None
        self.gain = 1.0  # music sensitivity multiplier (applied post-AGC)
        self._last_signal = 0.0
        self._started_at = 0.0
        self._peak = 1e-6
        self._bass_hist = []
        edges = np.geomspace(50, 8000, self.NBANDS + 1)
        freqs = np.fft.rfftfreq(self.BLOCK, 1 / self.RATE)
        self._bins = [np.where((freqs >= lo) & (freqs < hi))[0]
                      for lo, hi in zip(edges[:-1], edges[1:])]
        self._window = np.hanning(self.BLOCK)

    def start(self, device=None):
        with self.lock:
            if self.stream and device == self.device:
                return None  # already running on this device
            self._stop_locked()
            try:
                self.stream = sd.InputStream(
                    device=device, channels=1, samplerate=self.RATE,
                    blocksize=self.BLOCK, callback=self._cb)
                self.stream.start()
                self.device = device
                self.error = None
                self._started_at = time.time()
                self._last_signal = time.time()
            except Exception as e:
                self.stream = None
                self.error = str(e)
            return self.error

    def stop(self):
        with self.lock:
            self._stop_locked()

    def _stop_locked(self):
        if self.stream:
            try:
                self.stream.stop()
                self.stream.close()
            except Exception:
                pass
        self.stream = None
        self.device = None

    def _cb(self, indata, frames, t, status):
        mono = indata[:, 0]
        if len(mono) != self.BLOCK:
            return
        if float(np.max(np.abs(mono))) > 1e-4:
            self._last_signal = time.time()
        spec = np.abs(np.fft.rfft(mono * self._window))
        raw = np.array([spec[idx].mean() if len(idx) else 0.0 for idx in self._bins])
        # auto gain: normalize against a slowly-decaying peak
        self._peak = max(raw.max(), self._peak * 0.995, 1e-6)
        norm = np.clip(raw / self._peak * self.gain, 0, 1)
        bass = float(norm[:4].mean())
        self._bass_hist.append(bass)
        if len(self._bass_hist) > 22:  # ~1s of history
            self._bass_hist.pop(0)
        avg = sum(self._bass_hist) / len(self._bass_hist)
        with self.lock:
            # fast attack, slow decay per band
            self.bands = [max(float(v), b * 0.72) for v, b in zip(norm, self.bands)]
            self.level = max(float(norm.mean()) * 1.8, self.level * 0.85)
            self.beat = bass > max(0.12, avg * 1.45)

    def snapshot(self):
        with self.lock:
            return list(self.bands), min(1.0, self.level), self.beat

    def is_silent(self):
        """True if the input has been running >3s without any signal at all.

        Usually means macOS denied microphone access (TCC hands the app
        pure silence rather than an error)."""
        with self.lock:
            return (self.stream is not None
                    and time.time() - self._started_at > 3
                    and time.time() - self._last_signal > 3)


class LedStreamer(threading.Thread):
    """Background thread that renders the current effect and streams frames."""

    def __init__(self):
        super().__init__(daemon=True)
        self.lock = threading.Lock()
        self.serial = None
        self.port = None
        self.led_count = LED_COUNT
        self.effect = "Solid"
        self.color = (255, 96, 0)
        self.brightness = 1.0
        self.speed = 1.0
        self.error = None
        self._stop = threading.Event()
        self._fx = {}  # per-effect scratch state (sparkle levels, fire heat, ...)
        self.audio = None  # AudioAnalyzer, attached by the app

    # -- control (called from GUI thread) ------------------------------
    def configure(self, **kw):
        with self.lock:
            for k, v in kw.items():
                setattr(self, k, v)

    def connect(self, port):
        with self.lock:
            self._close()
            try:
                self.serial = serial.Serial(port, BAUD, timeout=1)
                self.port = port
                self.error = None
            except Exception as e:
                self.serial = None
                self.port = None
                self.error = str(e)
        return self.error

    def disconnect(self):
        with self.lock:
            # best effort: blank the strip before releasing the port
            if self.serial:
                try:
                    n = self.led_count
                    self.serial.write(b"Ada\x00\x00" + bytes([n]) + b"\x00" * (3 * n))
                    self.serial.flush()
                except Exception:
                    pass
            self._close()

    def _close(self):
        if self.serial:
            try:
                self.serial.close()
            except Exception:
                pass
        self.serial = None
        self.port = None

    def stop(self):
        self.disconnect()
        self._stop.set()

    # -- rendering ------------------------------------------------------
    def _pixels(self, t, n):
        e, (r, g, b), spd = self.effect, self.color, self.speed
        if e == "Off":
            return [(0, 0, 0)] * n
        if e == "Solid":
            return [(r, g, b)] * n
        if e == "Rainbow":
            out = []
            for i in range(n):
                h = (t * 0.1 * spd + i / n) % 1.0
                out.append(tuple(int(c * 255) for c in colorsys.hsv_to_rgb(h, 1, 1)))
            return out
        if e == "Breathe":
            k = 0.5 - 0.5 * math.cos(t * 2 * math.pi * 0.25 * spd)
            k = 0.05 + 0.95 * k
            return [(int(r * k), int(g * k), int(b * k))] * n
        if e == "Color Wipe":
            pos = (t * n * 0.5 * spd) % (2 * n)
            filled = int(pos) if pos < n else n - int(pos - n) - 1
            return [(r, g, b) if i < filled else (0, 0, 0) for i in range(n)]
        if e == "Theater Chase":
            off = int(t * 10 * spd) % 3
            return [(r, g, b) if (i + off) % 3 == 0 else (0, 0, 0) for i in range(n)]
        if e == "Comet":
            head = (t * n * 0.6 * spd) % n
            out = []
            for i in range(n):
                d = (head - i) % n  # distance behind the head, wrapping
                k = max(0.0, 1.0 - d / (n * 0.35))
                k = k * k
                out.append((int(r * k), int(g * k), int(b * k)))
            return out
        if e == "Scanner":
            # triangle wave bounce, glowing tail on both sides
            phase = (t * 0.6 * spd) % 2.0
            pos = phase * (n - 1) if phase < 1 else (2 - phase) * (n - 1)
            out = []
            for i in range(n):
                k = max(0.0, 1.0 - abs(i - pos) / (n * 0.12 + 1))
                k = k * k
                out.append((int(r * k), int(g * k), int(b * k)))
            return out
        if e == "Sparkle":
            lv = self._fx_list("sparkle", n)
            for i in range(n):
                lv[i] *= 0.85
            if random.random() < 0.3 + 0.6 * min(spd, 1.5):
                lv[random.randrange(n)] = 1.0
            base = (r * 0.25, g * 0.25, b * 0.25)
            return [tuple(int(min(255, c + (255 - c) * lv[i])) for c in base)
                    for i in range(n)]
        if e == "Confetti":
            st = self._fx.setdefault("confetti", {})
            px = st.setdefault("px", [[0, 0, 0] for _ in range(n)])
            if len(px) != n:
                px = st["px"] = [[0, 0, 0] for _ in range(n)]
            for p in px:
                p[0] = int(p[0] * 0.92)
                p[1] = int(p[1] * 0.92)
                p[2] = int(p[2] * 0.92)
            for _ in range(max(1, int(spd))):
                if random.random() < 0.7:
                    c = colorsys.hsv_to_rgb(random.random(), 1, 1)
                    px[random.randrange(n)] = [int(v * 255) for v in c]
            return [tuple(p) for p in px]
        if e == "Fire":
            heat = self._fx_list("fire", n)
            for i in range(n):
                heat[i] = max(0.0, heat[i] - random.uniform(0, 0.15))
                if random.random() < 0.35:
                    heat[i] = min(1.0, heat[i] + random.uniform(0, 0.45))
            out = []
            for h in heat:
                # black -> red -> orange -> yellow-white palette
                out.append((int(255 * min(1, h * 1.8)),
                            int(255 * min(1, max(0, h * 1.4 - 0.35))),
                            int(255 * min(1, max(0, h * 2.2 - 1.5)))))
            return out
        if e == "Aurora":
            out = []
            for i in range(n):
                x = i / n
                v = (math.sin(x * 5 + t * 0.7 * spd)
                     + math.sin(x * 11 - t * 0.4 * spd)) / 4 + 0.5
                h = 0.33 + v * 0.45  # green -> blue -> purple
                k = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(x * 7 + t * spd))
                rr, gg, bb = colorsys.hsv_to_rgb(h % 1.0, 0.9, k)
                out.append((int(rr * 255), int(gg * 255), int(bb * 255)))
            return out
        if e == "Wave":
            out = []
            for i in range(n):
                k = 0.15 + 0.85 * (0.5 + 0.5 * math.sin(i / n * 4 * math.pi - t * 3 * spd))
                out.append((int(r * k), int(g * k), int(b * k)))
            return out
        if e == "Strobe":
            on = (t * 8 * spd) % 1.0 < 0.25
            return [(r, g, b) if on else (0, 0, 0)] * n
        if e == "Police":
            half = n // 2
            swap = int(t * 4 * spd) % 2
            red, blue = (255, 0, 0), (0, 0, 255)
            a, bcol = (red, blue) if swap else (blue, red)
            return [a] * half + [bcol] * (n - half)
        if e in MUSIC_EFFECTS:
            return self._music_pixels(e, n, (r, g, b), spd)
        if e == "Candle":
            st = self._fx.setdefault("candle", {"k": 0.8})
            st["k"] += random.uniform(-0.12, 0.12) * min(spd, 2)
            st["k"] = max(0.35, min(1.0, st["k"]))
            k = st["k"]
            return [(int(r * k), int(g * k), int(b * k))] * n
        return [(0, 0, 0)] * n

    def _music_pixels(self, e, n, color, spd):
        r, g, b = color
        bands, level, beat = self.audio.snapshot() if self.audio else ([0.0] * 24, 0.0, False)
        nb = len(bands)

        if e == "Spectrum":
            out = []
            for i in range(n):
                v = bands[min(nb - 1, int(i / n * nb))] ** 1.5
                h = 0.66 * (1 - i / n)  # red (bass) ... blue (treble)
                rr, gg, bb = colorsys.hsv_to_rgb(h, 1, v)
                out.append((int(rr * 255), int(gg * 255), int(bb * 255)))
            return out

        if e == "Pulse":
            k = 0.04 + 0.96 * level ** 1.3
            if beat:  # blend toward white on beats
                return [(int(r * k + (255 - r * k) * 0.5),
                         int(g * k + (255 - g * k) * 0.5),
                         int(b * k + (255 - b * k) * 0.5))] * n
            return [(int(r * k), int(g * k), int(b * k))] * n

        if e == "VU Meter":
            lit = int(level * n)
            out = []
            for i in range(n):
                if i < lit:
                    frac = i / max(1, n - 1)
                    h = 0.33 * max(0.0, 1 - frac * 1.3)  # green -> yellow -> red
                    rr, gg, bb = colorsys.hsv_to_rgb(h, 1, 1)
                    out.append((int(rr * 255), int(gg * 255), int(bb * 255)))
                else:
                    out.append((0, 0, 0))
            return out

        if e == "Center Burst":
            half = max(1.0, (n - 1) / 2)
            c = (n - 1) / 2
            ext = (level ** 1.2) * (half + 1)
            out = []
            for i in range(n):
                d = abs(i - c)
                k = max(0.0, min(1.0, ext - d))
                if beat and d < half * 0.15:  # white core on beats
                    out.append((255, 255, 255))
                else:
                    out.append((int(r * k), int(g * k), int(b * k)))
            return out

        if e == "Rainbow Beat":
            st = self._fx.setdefault("rbeat", {"phase": 0.0, "prev": False})
            if beat and not st["prev"]:
                st["phase"] += 0.13  # hue jumps on each beat
            st["prev"] = beat
            bri = 0.1 + 0.9 * level
            out = []
            for i in range(n):
                h = (st["phase"] + i / n * 0.5) % 1.0
                rr, gg, bb = colorsys.hsv_to_rgb(h, 1, bri)
                out.append((int(rr * 255), int(gg * 255), int(bb * 255)))
            return out

        if e == "Beat Flash":
            st = self._fx.setdefault("bflash", {"v": 0.0})
            st["v"] = 1.0 if beat else st["v"] * 0.80
            k = st["v"]
            return [(int(r * k), int(g * k), int(b * k))] * n

        if e == "Ripples":
            st = self._fx.setdefault("ripples", {"list": [], "prev": False})
            if beat and not st["prev"]:
                st["list"].append(0.0)
            st["prev"] = beat
            step = n * 0.02 * max(0.3, spd)
            st["list"] = [rad + step for rad in st["list"] if rad < n]
            c = (n - 1) / 2
            half = max(1.0, (n - 1) / 2)
            out = []
            for i in range(n):
                d = abs(i - c)
                k = 0.0
                for rad in st["list"]:
                    ring = max(0.0, 1.0 - abs(d - rad) / (n * 0.06 + 1))
                    fade = max(0.0, 1.0 - rad / (half * 1.1))
                    k = max(k, ring * fade)
                out.append((int(r * k), int(g * k), int(b * k)))
            return out

        if e == "Bass & Treble":
            bass = sum(bands[:5]) / 5
            treb = sum(bands[nb * 2 // 3:]) / max(1, nb - nb * 2 // 3)
            lv = self._fx_list("bt_sparkle", n)
            for i in range(n):
                lv[i] *= 0.80
            if random.random() < min(0.9, treb * 1.5):
                lv[random.randrange(n)] = 1.0
            k = bass ** 1.2
            return [tuple(int(min(255, c * k + (255 - c * k) * lv[i]))
                          for c in (r, g, b)) for i in range(n)]

        return [(0, 0, 0)] * n

    def _fx_list(self, key, n):
        lst = self._fx.get(key)
        if not isinstance(lst, list) or len(lst) != n:
            lst = self._fx[key] = [0.0] * n
        return lst

    def run(self):
        t0 = time.time()
        while not self._stop.is_set():
            with self.lock:
                ser, n, bri = self.serial, self.led_count, self.brightness
                if ser:
                    px = self._pixels(time.time() - t0, n)
                    data = bytearray(b"Ada\x00\x00")
                    data.append(n)
                    for r, g, b in px:
                        data += bytes((int(r * bri), int(g * bri), int(b * bri)))
                    try:
                        ser.write(data)
                        ser.flush()
                    except Exception as e:
                        self.error = str(e)
                        self._close()
            time.sleep(1 / FPS)


