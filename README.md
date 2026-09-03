# tabscreen

Turn an old Android tablet into a second display for a Mac — over the USB cable, with
**~37 ms of latency**.

No subscription, no Wi-Fi, no kernel extension. spacedesk only ships a Windows server,
Sidecar only talks to iPads, and Duet wants a yearly fee — this is the missing piece for
"MacBook + whatever Android tablet is in the drawer".

```
   Mac                                                    Tablet
┌─────────────────────────────┐                    ┌──────────────────┐
│ BetterDisplay               │                    │                  │
│   └── virtual display       │                    │  TabScreen app   │
│         │                   │                    │    │             │
│ TabCapture (Swift)          │   USB (adb reverse)│    ├─ MediaCodec │
│   ScreenCaptureKit ─────────┼───────────────────►│    └─ SurfaceView│
│   VideoToolbox H.264        │   ~5 Mbit/s        │                  │
│         │                   │                    └──────────────────┘
│ server.py (fan-out, metrics)│
└─────────────────────────────┘
```

## Why it is fast

The obvious build — ffmpeg grabbing the screen, a browser showing the stream — lands at
**200-500 ms** and feels awful. Getting to 37 ms came down to four things, and the last
one mattered more than the rest combined:

| Fix | Effect |
|---|---|
| Read the encoder's pipe with `os.read`, not a fixed-size read | a blocking read waits for the buffer to fill: 500 ms bursts became a 39 ms stream |
| Send each frame as `[length][seq][NAL]` instead of raw Annex-B | the tablet's Java loop couldn't scan for start codes at 60 fps |
| Keep every queue short (5 frames) and drop to the next keyframe on overflow | a 24-frame queue *is* 400 ms of latency |
| **`EnableLowLatencyRateControl` on the VideoToolbox encoder** | **the tablet's decoder stopped buffering: 9 frames in flight → 1, latency 150 ms → 37 ms** |

Measured end-to-end, by the Mac's own clock: the server stamps frames, the tablet reports
back when a frame is on screen. Do not trust a tablet's clock for this — they drift by
hundreds of milliseconds.

| | ffmpeg + AVFoundation | this |
|---|---|---|
| Latency to screen | 122-174 ms | **37-39 ms** |
| Under heavy screen activity | 218 ms | **37 ms** |
| Frames stuck in the decoder | 6-10 | **1** |
| Mac CPU | 29-34 % of a core | **2 %** |

Tested on a MacBook Air M1 (macOS 26) and a Samsung Galaxy Tab A 10.1 2019 (SM-T515,
Android 11) — a tablet with 2 GB of RAM and a hardware decoder from 2019. Newer hardware
should only do better.

## What you need

- macOS 12.3+ (ScreenCaptureKit) on Apple Silicon or Intel
- [BetterDisplay](https://github.com/waydabber/BetterDisplay) — the free version is enough;
  it creates the virtual display. macOS has no public API for that, so this part cannot be
  replaced by code here.
- An Android tablet with USB debugging on, and `adb` (`brew install android-platform-tools`)
- Xcode command line tools (`xcode-select --install`) for `swiftc`

## Setup

```bash
git clone https://github.com/BreraDMR/tabscreen
cd tabscreen
./setup.sh          # downloads a JDK + Android SDK into ./tools, builds both apps
```

`setup.sh` installs nothing system-wide and asks for no password — everything lands in
`./tools` (about 750 MB, delete it when you are done building).

Create the virtual display once, in BetterDisplay or from its CLI:

```bash
betterdisplaycli create -type=VirtualScreen
betterdisplaycli set -tagID=<id> -connected=on
betterdisplaycli set -tagID=<id> -virtualScreenHiDPI=off
betterdisplaycli set -tagID=<id> -useResolutionList=on -resolutionList=1280x800
betterdisplaycli set -tagID=<id> -resolution=1280x800
```

> `-resolution=` is silently ignored unless `-useResolutionList=on` is set first.

Then:

```bash
./start.sh
```

macOS will ask for screen recording permission the first time — grant it to **TabCapture**.

## Layout

| Path | What it is |
|---|---|
| `swift/capture.swift` | screen capture + H.264 encoding, writes `[length][NAL]` to stdout |
| `server.py` | runs the capture, fans frames out to clients, measures latency |
| `android/` | the tablet client: socket → MediaCodec → SurfaceView |
| `android/build.sh` | builds the APK with plain SDK tools — no Gradle, no Android Studio |
| `tools/debloat.sh` | optional: quiets down a Samsung tablet (see below) |

The whole Android client is ~300 lines of Java, the capture ~200 lines of Swift, and the
APK comes out at 17 KB.

## Tuning

Edit the constants at the top of `server.py`:

```python
FPS = 60          # 30 makes latency WORSE - see below
BITRATE = "5M"
USE_SWIFT_CAPTURE = True    # False falls back to ffmpeg
```

**Lower frame rate means higher latency.** A decoder's pipeline is measured in frames, not
milliseconds: at 30 fps each of those frames costs twice as long. Dropping to 30 fps took
latency from 131 ms to 440 ms. Keep it at 60.

## If the tablet itself is the bottleneck

An old Samsung spends most of its RAM on software you never asked for. On the test device
348 packages were installed and 570 MB sat in swap permanently. `tools/debloat.sh` disables
the usual suspects for the current user (`pm disable-user`) — nothing is deleted, everything
comes back with `tools/rebloat.sh`, and a factory reset undoes it all anyway.

On the test tablet this halved the swap in use and cut the worst frame gap from 52 ms to 28.

## Known limits

- **Touch input is not implemented.** There is a working `input.py` (touch → `CGEvent`) but
  it is off: at any latency above ~50 ms a finger-driven cursor feels wrong, and the effort
  is better spent elsewhere.
- **~45 fps, not 60.** `EnableLowLatencyRateControl` costs some throughput. Given it buys a
  4× latency cut, that is a good trade.
- **The virtual display needs BetterDisplay.** macOS exposes no public API for creating one;
  every tool in this space uses the same private interface.
- Capture stops when nobody is watching, so the Mac idles at 0 % when the tablet is asleep.

## License

MIT
