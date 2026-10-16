"""Synthesizes Squish's finish sound from layers, the way a sound designer would stack samples.

Usage: python3 Tools/render_sound.py Squish/Resources/squish.wav

The sound tells a tiny story in ~0.5 s: something soft gets pressed (squish), air escapes,
it pops, and a small chime says "done". Each layer covers one part of the spectrum or one
moment in time, so together they read as one rich sound rather than a beep:

  layer      when (s)   range         job
  ---------  ---------  ------------  -------------------------------------------------
  thump      0.00–0.09  70–120 Hz     weight; felt more than heard
  squish     0.00–0.13  170–430 Hz    the main squash tone, two slightly detuned voices
  squelch    0.00–0.11  3.2→0.9 kHz   filtered noise sweeping down: the "wet" texture
  click      0.105      4–10 kHz      2 ms transient so the pop has a crisp edge
  pop        0.105–0.17 620→1520 Hz   the bubble: an upward chirp
  chime      0.12–0.50  1.76/2.64 kHz soft bell fifth, panned apart, so it lands as "done"
  room       whole      —             short early reflections so it doesn't sound dry

Pure standard library; the noise is seeded, so the output is identical on every run.
"""
import math
import random
import struct
import sys
import wave

RATE = 44100
LENGTH = 0.52  # seconds
N = int(RATE * LENGTH)
TAU = 2 * math.pi


def env(t, attack, decay):
    """Linear attack, exponential decay. Zero before t = 0."""
    if t < 0:
        return 0.0
    if t < attack:
        return t / attack
    return math.exp(-(t - attack) / decay)


def glide(start, end, t, duration):
    """Exponential pitch glide from start to end Hz over duration seconds."""
    p = min(max(t / duration, 0.0), 1.0)
    return start * (end / start) ** p


class Bandpass:
    """RBJ-cookbook biquad band-pass whose center can move every sample."""

    def __init__(self, q):
        self.q = q
        self.x1 = self.x2 = self.y1 = self.y2 = 0.0

    def __call__(self, x, center):
        w = TAU * center / RATE
        alpha = math.sin(w) / (2 * self.q)
        cos_w = math.cos(w)
        a0 = 1 + alpha
        b0, b2 = alpha / a0, -alpha / a0
        a1, a2 = -2 * cos_w / a0, (1 - alpha) / a0
        y = b0 * x + b2 * self.x2 - a1 * self.y1 - a2 * self.y2
        self.x2, self.x1 = self.x1, x
        self.y2, self.y1 = self.y1, y
        return y


class Highpass:
    """One-pole high-pass, enough to take the body out of the click."""

    def __init__(self, cutoff):
        rc = 1 / (TAU * cutoff)
        self.a = rc / (rc + 1 / RATE)
        self.prev_x = self.prev_y = 0.0

    def __call__(self, x):
        y = self.a * (self.prev_y + x - self.prev_x)
        self.prev_x, self.prev_y = x, y
        return y


def oscillator():
    """Phase-accumulating sine so pitch glides stay smooth."""
    phase = [0.0]

    def step(freq):
        phase[0] += TAU * freq / RATE
        return math.sin(phase[0])

    return step


# ---------------------------------------------------------------------------
# Layers. Each returns a list of (left, right) samples.
# ---------------------------------------------------------------------------

def thump():
    osc = oscillator()
    out = []
    for i in range(N):
        t = i / RATE
        s = osc(glide(120, 70, t, 0.08)) * env(t, 0.004, 0.03)
        out.append((s, s))
    return out


def squish():
    # Two voices 9 cents apart give a soft chorus; a touch of 2nd harmonic adds roundness.
    a, b = oscillator(), oscillator()
    detune = 2 ** (9 / 1200)
    out = []
    for i in range(N):
        t = i / RATE
        f = glide(430, 170, t, 0.12)
        va = a(f)
        vb = b(f * detune)
        tone = 0.5 * (va + vb) + 0.15 * math.sin(2 * math.asin(max(-1, min(1, va))))
        s = tone * env(t, 0.006, 0.045)
        out.append((s * 1.0, s * 0.9))  # a hair left of center
    return out


def squelch():
    rng = random.Random(7)
    bp = Bandpass(q=3.5)
    out = []
    for i in range(N):
        t = i / RATE
        center = glide(3200, 900, t, 0.1)
        s = bp(rng.uniform(-1, 1), center) * env(t, 0.003, 0.032)
        out.append((s * 0.85, s))  # a hair right, opposite the squish
    return out


def click(at=0.105):
    rng = random.Random(11)
    hp = Highpass(4000)
    out = []
    for i in range(N):
        t = i / RATE - at
        s = hp(rng.uniform(-1, 1)) * env(t, 0.0003, 0.0018) if t >= 0 else 0.0
        out.append((s, s))
    return out


def pop(at=0.105):
    osc = oscillator()
    out = []
    for i in range(N):
        t = i / RATE - at
        if t < 0:
            out.append((0.0, 0.0))
            continue
        s = osc(620 + 900 * min(t / 0.03, 1.0)) * env(t, 0.002, 0.026)
        out.append((s, s))
    return out


def chime(at=0.12):
    # A6 and E7: a perfect fifth reads as resolved and friendly. Slight inharmonic partial
    # on each gives a soft bell rather than a pure test tone. Panned apart for width.
    voices = [
        (1760.0, 0.75, 0.20),   # freq, pan (0 = left, 1 = right), decay
        (2637.0, 0.25, 0.15),
    ]
    oscs = [(oscillator(), oscillator()) for _ in voices]
    out = []
    for i in range(N):
        t = i / RATE - at
        left = right = 0.0
        if t >= 0:
            for (freq, pan, decay), (fundamental, partial) in zip(voices, oscs):
                s = (fundamental(freq) + 0.25 * partial(freq * 2.76)) * env(t, 0.004, decay)
                left += s * math.cos(pan * math.pi / 2)
                right += s * math.sin(pan * math.pi / 2)
        out.append((left, right))
    return out


# ---------------------------------------------------------------------------
# Mix
# ---------------------------------------------------------------------------

def add(mix, layer, gain):
    for i, (l, r) in enumerate(layer):
        mix[i][0] += l * gain
        mix[i][1] += r * gain


def room(mix, wet=0.14):
    """A few early reflections, offset per channel so the tail feels wide."""
    taps = [(0.011, 0.013, 0.55), (0.019, 0.023, 0.38), (0.031, 0.029, 0.25), (0.043, 0.047, 0.15)]
    dry = [list(s) for s in mix]
    for dl, dr, gain in taps:
        nl, nr = int(dl * RATE), int(dr * RATE)
        for i in range(N):
            if i >= nl:
                mix[i][0] += dry[i - nl][1] * gain * wet  # cross-feed adds width
            if i >= nr:
                mix[i][1] += dry[i - nr][0] * gain * wet


def render():
    mix = [[0.0, 0.0] for _ in range(N)]
    add(mix, thump(), 0.30)
    add(mix, squish(), 0.30)
    add(mix, squelch(), 0.55)   # band-passed noise is quiet, so it needs more gain
    add(mix, click(), 0.10)
    add(mix, pop(), 0.20)
    add(mix, chime(), 0.07)     # felt as a glint, not a melody
    room(mix)

    # Gentle tanh limiter, normalize to a polite peak, then a short fade so nothing clicks.
    for s in mix:
        s[0], s[1] = math.tanh(s[0] * 1.4), math.tanh(s[1] * 1.4)
    peak = max(max(abs(l), abs(r)) for l, r in mix) or 1.0
    target = 10 ** (-9 / 20)  # −9 dBFS
    for i, s in enumerate(mix):
        fade = min(1.0, (LENGTH - i / RATE) / 0.03)
        s[0] = s[0] / peak * target * fade
        s[1] = s[1] / peak * target * fade
    return mix


def main(path):
    with wave.open(path, "wb") as out:
        out.setnchannels(2)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(b"".join(struct.pack("<hh", int(l * 32767), int(r * 32767)) for l, r in render()))


if __name__ == "__main__":
    main(sys.argv[1])
