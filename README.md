# audiotap

Pipe your Mac's audio into anything, from the command line. No virtual audio driver, no BlackHole, no kernel extension.

`audiotap` is one small Swift file. It streams live audio to stdout as raw PCM:

- `audiotap system`: everything the Mac is playing (all apps), through Apple's ScreenCaptureKit
- `audiotap mic`: the default microphone, which other apps can keep using at the same time

Nothing is written to disk. Samples go to stdout, status lines go to stderr. What you do with the stream is up to you: save it, transcribe it, measure it, send it somewhere.

```bash
# 5 seconds of whatever the Mac is playing, as a WAV file
audiotap system | head -c 320000 | ffmpeg -f f32le -ar 16000 -ac 1 -i - clip.wav
```

## Build

Needs Xcode or the Xcode Command Line Tools (Swift 5.9 or newer).

```bash
git clone https://github.com/GianlucaBave/audiotap.git
cd audiotap
swift build -c release
```

The binary is `.build/release/audiotap` (about 100 KB). Copy it to any folder on your `PATH`.

Without SwiftPM, one command does it too:

```bash
swiftc -O Sources/audiotap/main.swift -o audiotap -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia
```

## Usage

```
audiotap system   # the Mac's audio output (default when no argument is given)
audiotap mic      # the default microphone
```

It runs until you stop it (Ctrl-C) or until whatever reads stdout goes away. When the reader closes the pipe, `audiotap` exits cleanly with status 0, so `head -c` works as a timer.

Save raw samples, then convert later:

```bash
audiotap system > call.raw          # Ctrl-C to stop
ffmpeg -f f32le -ar 16000 -ac 1 -i call.raw call.wav
```

Read it from Python (this is how Murmury uses it):

```python
import subprocess
import numpy as np

tap = subprocess.Popen(["audiotap", "system"], stdout=subprocess.PIPE)
while chunk := tap.stdout.read(16000 * 4):  # about 1 second
    samples = np.frombuffer(chunk, dtype=np.float32)
    print(f"level {np.sqrt(np.mean(samples ** 2)):.4f}")
```

## Output format

| | |
|---|---|
| Encoding | 32-bit float, little endian (`f32le` in ffmpeg terms) |
| Sample rate | 16,000 Hz |
| Channels | 1 (mono) |
| Header | none, raw samples only |
| Data rate | 64,000 bytes per second, about 230 MB per hour |

The format is fixed. 16 kHz mono is what speech recognition models such as Whisper expect, which is what `audiotap` was written for. If you need another rate or stereo, resample downstream (ffmpeg does it) or change the two settings at the top of `main.swift`.

### A measured run

On an Apple Silicon Mac (M5), macOS 26.6, while macOS's `say` command spoke a sentence:

```console
$ audiotap system | head -c 320000 > five.raw
audiotap: system audio started (16000 Hz mono)
```

- `five.raw` was exactly 320,000 bytes: 80,000 samples, 5.0 seconds.
- Peak level 0.66, so the speech was captured, not silence.
- The whole command took 5.2 seconds of wall time and about 1% CPU, then `audiotap` exited with status 0.
- `ffmpeg -f f32le -ar 16000 -ac 1 -i five.raw five.wav` gave a 5.000 second, 16 kHz mono WAV.

`audiotap mic` on the same Mac: `audiotap: microphone started (16000 Hz mono, from 48000 Hz)`, then a quiet room came through at a peak of about 0.01.

## How it works

ScreenCaptureKit can capture system audio, but only as part of a screen capture stream: there is no audio-only mode. `audiotap` asks for the smallest video it can, 2 by 2 pixels at one frame per second, and throws the frames away. The audio arrives already at 16 kHz mono from ScreenCaptureKit, and is written straight to stdout.

If the stream stops (the Mac sleeps, a monitor is unplugged, a full-screen app takes over), `audiotap` logs it to stderr and reattaches, retrying once a second.

The microphone side uses `AVAudioEngine` and converts from the device's own rate (often 48 kHz) to 16 kHz mono.

## Permissions

macOS asks the first time, and the permission belongs to the app that launched `audiotap` (Terminal, iTerm, your own app), not to `audiotap` itself.

- `audiotap system` needs **Screen & System Audio Recording** (System Settings > Privacy & Security). If it is refused, `audiotap` says so on stderr and exits with status 1. After allowing it, you may need to quit and reopen the terminal app.
- `audiotap mic` needs **Microphone** in the same place.

## Limits

- **macOS 13 or newer.** ScreenCaptureKit audio capture starts with macOS 13 Ventura. I have only tested it on macOS 26.6.
- **Apple Silicon tested, Intel not tested.** It should build for Intel Macs, but I have not run it on one.
- **All system audio, not one app.** `system` captures everything the Mac plays. There is no per-app selection.
- **Needs a display.** It attaches to the first display ScreenCaptureKit reports. A Mac with no display attached at all has not been tested.
- **Default microphone only.** There is no option to pick another input device.
- **Fixed format.** 16 kHz, mono, float32, as described above.
- Exit codes: `0` when the reader closes the pipe, `1` when permission is refused or the microphone cannot start, `64` for a wrong argument.

## Made for Murmury

`audiotap` is the audio part of [Murmury](https://github.com/GianlucaBave/murmury), an open-source Mac app that listens to the other side of a call and shows answers from your own documents while you talk. Murmury pipes `audiotap system` into a local Whisper model to know what the other person just said.

If `audiotap` is useful to you, have a look at Murmury, and a star there helps the project a lot.

## License

GPL-3.0, like Murmury. See [LICENSE](LICENSE).
