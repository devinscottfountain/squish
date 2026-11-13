"""Synthesizes Squish's sounds. Same recipe as ClientOS's UI sounds, baked to WAV files.

Usage: python3 Tools/render_sound.py Squish/Resources

Each sound is a few short "voices": a sine or triangle note with a fast attack and a short
exponential decay, so it sounds like something struck rather than a beep. Everything sits in
C major around C5-C6, so the sounds never clash; success rises and failure falls. One gentle
lowpass over the mix takes the click edge off the attacks.

  file         when                         what
  -----------  ---------------------------  --------------------------------------------------
  finish.wav   a batch finished             triangle arpeggio E5 G5 C6, 60 ms apart, plus a
                                            faint octave shimmer on the last note
  drop.wav     files landed in the queue    one soft triangle pluck gliding 520 -> 300 Hz
  drop2.wav    (alternate, a tone higher)   so quick repeated drops don't sound robotic
  fail.wav     a file failed                triangle F4 then C4: low, soft, a falling fourth

NSSound plays at system volume, so the quietness is baked in: peaks sit well under a macOS
system sound. Pure standard library and no randomness, so the output is identical every run.
"""
import math
import struct
import sys
import wave
from pathlib import Path

RATE = 48000
TAU = 2 * math.pi
LOWPASS_HZ = 6500
TAIL = 0.03  # trailing silence, so the last decay is never clipped by the player


def voice(wave_shape, freq, at, dur, peak, tau, attack=0.001, to=None, glide=0.05):
    """One note: `freq` Hz starting `at` seconds, optionally gliding to `to` over `glide` s."""
    return dict(shape=wave_shape, freq=freq, at=at, dur=dur, peak=peak, tau=tau,
                attack=attack, to=to, glide=glide)


def transpose(voices, ratio):
    return [dict(v, freq=v["freq"] * ratio, to=v["to"] * ratio if v["to"] else None) for v in voices]


E5, G5, C6, C7 = 659.25, 783.99, 1046.50, 2093.00
F4, C4 = 349.23, 261.63
WHOLE_TONE = 2 ** (2 / 12)

FINISH = [
    voice("triangle", E5, 0.00, 0.12, 0.30, 0.040),
    voice("triangle", G5, 0.06, 0.12, 0.30, 0.040),
    voice("triangle", C6, 0.12, 0.26, 0.30, 0.075),
    voice("sine", C7, 0.12, 0.26, 0.07, 0.085),  # shimmer: an octave above the last note
]
DROP = [voice("triangle", 520, 0.0, 0.11, 0.50, 0.025, to=300, glide=0.05)]
FAIL = [
    voice("triangle", F4, 0.00, 0.16, 0.35, 0.050),
    voice("triangle", C4, 0.09, 0.22, 0.35, 0.070),
]

# name -> (voices, peak level of the finished file in dBFS)
SOUNDS = {
    "finish": (FINISH, -15.0),
    "drop": (DROP, -20.0),
    "drop2": (transpose(DROP, WHOLE_TONE), -20.0),
    "fail": (FAIL, -17.0),
}


def render(voices):
    length = max(v["at"] + v["dur"] for v in voices) + TAIL
    out = [0.0] * int(RATE * length)
    for v in voices:
        start = int(v["at"] * RATE)
        count = int(v["dur"] * RATE)
        release = int(0.006 * RATE)  # short fade at the note's end, so stopping it never clicks
        phase = 0.0
        for i in range(count):
            t = i / RATE
            if v["to"] and t < v["glide"]:
                freq = v["freq"] * (v["to"] / v["freq"]) ** (t / v["glide"])
            else:
                freq = v["to"] or v["freq"]
            # Integrating the phase keeps a glide smooth; sin(2*pi*f(t)*t) would chirp wrong.
            phase += TAU * freq / RATE
            if v["shape"] == "sine":
                sample = math.sin(phase)
            else:
                sample = 2 / math.pi * math.asin(math.sin(phase))
            if t < v["attack"]:
                env = v["peak"] * t / v["attack"]
            else:
                env = v["peak"] * math.exp(-(t - v["attack"]) / v["tau"])
            if count - i < release:
                env *= (count - i) / release
            out[start + i] += sample * env
    return lowpass(out)


def lowpass(samples):
    """Gentle biquad lowpass (Q 0.5): most of the 'warm, not cheap' character."""
    w = TAU * LOWPASS_HZ / RATE
    alpha = math.sin(w) / (2 * 0.5)
    cos = math.cos(w)
    a0 = 1 + alpha
    b0, b1, b2 = (1 - cos) / 2 / a0, (1 - cos) / a0, (1 - cos) / 2 / a0
    a1, a2 = -2 * cos / a0, (1 - alpha) / a0
    x1 = x2 = y1 = y2 = 0.0
    out = []
    for x in samples:
        y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, x, y1, y
        out.append(y)
    return out


def write(path, samples, peak_db):
    peak = max(abs(s) for s in samples)
    gain = 10 ** (peak_db / 20) / peak
    frames = b"".join(struct.pack("<h", round(s * gain * 32767)) for s in samples)
    with wave.open(str(path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(frames)
    print(f"  {path.name}: {len(samples) / RATE * 1000:.0f} ms, peak {peak_db:.0f} dBFS, {len(frames) // 1024} KB")


def main():
    folder = Path(sys.argv[1] if len(sys.argv) > 1 else "Squish/Resources")
    folder.mkdir(parents=True, exist_ok=True)
    for name, (voices, peak_db) in SOUNDS.items():
        write(folder / f"{name}.wav", render(voices), peak_db)


if __name__ == "__main__":
    main()
