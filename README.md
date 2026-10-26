# LUFSBar

**Every sound on your Mac, measured.**

LUFSBar is a free, open-source loudness meter that lives in your macOS menu bar. It measures everything your Mac plays through its sound output — Apple Music, Spotify, YouTube, your DAW — in real time, with no BlackHole, no Loopback, no virtual audio device setup.

[日本語のREADMEはこちら / Japanese README](README.ja.md)

## Features

- **Live LUFS in the menu bar** — Momentary, Short-term, or Integrated (right-click to switch)
- **Full readout in one click** — M / S / I LUFS and True Peak (dBTP)
- **Reference snapshot** — capture the loudness of whatever is playing (e.g. a reference track on a streaming service), then see the delta against your own mix in real time
- **Streaming normalization forecast** — see exactly how much Apple Music (-16), Spotify (-14), and YouTube (-14) will turn your track down
- **Auto-reset** — Integrated measurement resets automatically after ~2 seconds of silence

## What gets measured

LUFSBar measures the audio going to your Mac's **current sound output** (System Settings › Sound › Output).

- **An app playing to a different device is not measured.** If your DAW plays to an audio interface while the Mac's output is the built-in speakers, set the Mac's output to the interface too.
- **It follows the output.** When you switch the sound output, LUFSBar starts measuring the new device (Integrated starts over).
- **The device's stereo pair.** On a multichannel interface, the outputs set for stereo in Audio MIDI Setup › Configure Speakers are measured (1–2 unless you changed it).

Up to 1.1, LUFSBar measured every device at once and corrected the level by guessing from the current output, which could read about 14 dB off when apps played to different devices. 1.1.1 measures one device at its true level instead.

## Requirements

- macOS 14.4 (Sonoma) or later
- Apple silicon & Intel (Universal Binary)

## Install

1. Download the latest `LUFSBar_x.x.pkg` from [Releases](../../releases/latest)
2. Run the installer (signed & notarized by Apple)
3. Launch LUFSBar from Applications
4. Grant **System Audio Recording** permission when prompted

> **Note:** LUFSBar registers itself as a login item on first launch so your meter is always available (macOS will show a "Background Items Added" notification). You can turn this off anytime in Settings — LUFSBar will never re-enable it behind your back.

## How it works & privacy

LUFSBar uses the Core Audio process tap API (macOS 14.4+) to observe the audio going to the current output device, and [libebur128](https://github.com/jiixyj/libebur128) for ITU-R BS.1770-4 / EBU R128 compliant measurement (K-weighting, gating, 4× oversampled True Peak).

- No network requests
- No telemetry
- No accounts
- Audio is analyzed in memory and never recorded to disk

## Build from source

```
git clone https://github.com/tokyomeltdown/LUFSBar.git
cd LUFSBar
bash build.sh
```

Requires Xcode 16+. Without the author's signing certificate, `build.sh` signs the app ad hoc, so macOS asks for System Audio Recording permission again after each rebuild.

## License

MIT — see [LICENSE](LICENSE). Bundled [libebur128](https://github.com/jiixyj/libebur128) is also MIT licensed.

---

Made by [tokyomeltdown](https://x.com/tokyomeltdownJP)
