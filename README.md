# TabScreen

Use an Android tablet as a second display for your Mac — **~40 ms latency**, no
subscription, no cables required.

spacedesk only ships a Windows server. Sidecar only talks to iPads. Duet wants a yearly
fee. If you have a MacBook and an Android tablet sitting in a drawer, this is the missing
piece.

## Install

**Two downloads, no terminal.** Get them from the
[Releases](https://github.com/BreraDMR/tabscreen/releases) page.

1. **Install [BetterDisplay](https://github.com/waydabber/BetterDisplay)** (free) on the
   Mac. It creates the virtual screen — macOS has no public API for that, so no app can
   replace it.
2. **Unpack `TabScreen-mac.zip`**, drag `TabScreen.app` to Applications, then
   **right-click → Open** (the app isn't signed with a paid Apple certificate, so a plain
   double-click gets blocked the first time). Allow screen recording when asked.
3. In TabScreen press **Create virtual screen** — it sets one up through BetterDisplay,
   1280×800, ready to use.
4. **On the tablet:** open `tabscreen-android.apk` — download it straight to the tablet,
   Android will ask to allow installs from this source. No developer mode, no adb.
5. Press **Turn on** on the Mac. The tablet finds it on the network by itself; the app on
   the Mac also shows its address and a QR code if you'd rather type it in.

That's it. Drag a window onto the new screen and it shows up on the tablet.

## What you get

Measured on a MacBook Air M1 and a **Samsung Galaxy Tab A 10.1 from 2019** — 2 GB of RAM
and a decoder from that era:

| | |
|---|---|
| Latency to the tablet's screen | **37–41 ms** |
| Frame rate | 45–60 fps |
| Mac CPU | **2 %** of one core |
| Bandwidth | ~5 Mbit/s |

Over Wi-Fi it's 41 ms; over a USB cable 34 ms — close enough that the cable isn't worth
the bother unless you're chasing the last few milliseconds (see `dev/` for that route).

## Why it's fast

The obvious build — ffmpeg grabbing the screen, a browser showing the stream — lands at
**200–500 ms** and feels terrible. Getting to 40 ms came down to four things, and the last
one mattered more than the other three combined:

| Fix | Effect |
|---|---|
| Read the encoder's output as it arrives, not in fixed-size blocks | a blocking read waits for its buffer to fill: 500 ms bursts became a 39 ms stream |
| Frame each NAL as `[length][seq][data]` | the tablet's decode loop couldn't scan a byte stream for start codes at 60 fps |
| Keep every queue short — 5 frames — and skip to the next keyframe on overflow | a 24-frame queue *is* 400 ms of latency, sitting there quietly |
| **`EnableLowLatencyRateControl` on the VideoToolbox encoder** | **the tablet's decoder stopped hoarding frames: 9 in flight → 1, latency 150 ms → 37 ms** |

Two counter-intuitive findings worth knowing if you build something similar:

- **Lower frame rate means *higher* latency.** A decoder's pipeline is measured in frames,
  not milliseconds — at 30 fps each frame in it costs twice as long. Dropping 60 → 30 fps
  took latency from 131 ms to 440 ms.
- **Never trust the tablet's clock** to measure latency. They drift by hundreds of
  milliseconds; one measurement here came out negative. TabScreen stamps frames and has
  the tablet report back, so everything is timed on the Mac's own clock.

## How it works

```
   Mac                                              Tablet
┌──────────────────────────────┐             ┌────────────────────┐
│ BetterDisplay                │             │                    │
│   └── virtual display        │             │  TabScreen app     │
│         │                    │  Wi-Fi/USB  │    │               │
│ TabScreen.app                │────────────►│    ├─ MediaCodec   │
│   ScreenCaptureKit           │  ~5 Mbit/s  │    └─ SurfaceView  │
│   VideoToolbox H.264         │             │                    │
│   TCP server + discovery     │             └────────────────────┘
└──────────────────────────────┘
```

Capture stops when nobody is watching, so the Mac idles at 0 % with the tablet asleep.

## Building from source

Only needed if you want to change something.

```bash
git clone https://github.com/BreraDMR/tabscreen
cd tabscreen
./setup.sh     # builds the Mac app, downloads a JDK + Android SDK into ./tools, builds the APK
```

| Path | What it is |
|---|---|
| `mac/TabScreen/Capture.swift` | ScreenCaptureKit → VideoToolbox |
| `mac/TabScreen/Server.swift` | TCP fan-out, framing, latency measurement, discovery beacon |
| `mac/TabScreen/VirtualDisplay.swift` | drives BetterDisplay through its URL scheme |
| `mac/TabScreen/App.swift` | the window |
| `android/` | the tablet client — socket → MediaCodec → SurfaceView |
| `android/build.sh` | builds the APK with plain SDK tools: no Gradle, no Android Studio |
| `tools/debloat.sh` | optional, quiets down a Samsung tablet |
| `dev/` | earlier Python/ffmpeg iterations, kept for debugging and comparison |

The Android client is ~450 lines of Java and the APK is 17 KB.

## If the tablet itself is sluggish

An old Samsung spends its RAM on things you never asked for: on the test device 348
packages were installed and 570 MB sat in swap permanently. `tools/debloat.sh` disables
the usual suspects for the current user — nothing is deleted, `tools/rebloat.sh` puts it
all back, and a factory reset undoes it anyway. It needs adb, unlike the app itself.

On the test tablet this halved the swap in use and cut the worst frame gap from 52 ms to
28 ms.

## Known limits

- **Touch input isn't wired up.** There's a working implementation in `dev/input.py`
  (touch → `CGEvent`), but it's off: with any noticeable latency a finger-driven cursor
  feels wrong.
- **The virtual display needs BetterDisplay.** No public macOS API exists; every tool in
  this space uses the same private interface.
- **Unsigned app.** No paid Apple developer account, so the first launch needs
  right-click → Open.
- Requires macOS 13+ (ScreenCaptureKit) and Android 6+.

## License

MIT
