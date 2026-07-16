# LUFSBar

**Every sound on your Mac, measured.**

LUFSBar is a free, open-source loudness meter that lives in your macOS menu bar. It measures everything playing on your Mac — Apple Music, Spotify, YouTube, your DAW — in real time, with no BlackHole, no Loopback, no virtual audio device setup.

[日本語のREADMEはこちら / Japanese README](README.ja.md)

## Features

- **Live LUFS in the menu bar** — Momentary, Short-term, or Integrated (right-click to switch)
- **Full readout in one click** — M / S / I LUFS and True Peak (dBTP)
- **Reference snapshot** — capture the loudness of whatever is playing (e.g. a reference track on a streaming service), then see the delta against your own mix in real time
- **Streaming normalization forecast** — see exactly how much Apple Music (-16), Spotify (-14), and YouTube (-14) will turn your track down
- **Auto-reset** — Integrated measurement resets automatically after ~2 seconds of silence

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

LUFSBar uses the Core Audio process tap API (macOS 14.4+) to observe the system audio mix, and [libebur128](https://github.com/jiixyj/libebur128) for ITU-R BS.1770-4 / EBU R128 compliant measurement (K-weighting, gating, 4× oversampled True Peak).

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

Requires Xcode 16+.

## License

MIT — see [LICENSE](LICENSE). Bundled [libebur128](https://github.com/jiixyj/libebur128) is also MIT licensed.

---

Made by [tokyomeltdown](https://x.com/tokyomeltdownJP)
