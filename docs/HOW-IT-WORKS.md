# How it works, and why it's fast

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

The Mac captures a virtual display with ScreenCaptureKit, hardware-encodes it with
VideoToolbox, and hands each NAL unit to a small TCP server. The tablet reads them and
feeds MediaCodec, which draws straight onto a SurfaceView. Capture stops when nobody is
watching, so the Mac idles at 0 %.

## The four fixes that mattered

The first working version ran at 200–500 ms. Four changes took it to 33, and the last one
did more than the other three together.

| Fix | Effect |
|---|---|
| Read the encoder's output as it arrives, not in fixed-size blocks | a blocking read waits for its buffer to fill: 500 ms bursts became a 39 ms stream |
| Frame each NAL as `[length][seq][data]` | the tablet's decode loop couldn't scan a byte stream for start codes at 60 fps |
| Keep every queue short — 5 frames — and skip to the next keyframe on overflow | a 24-frame queue *is* 400 ms of latency, sitting there quietly |
| **`EnableLowLatencyRateControl` on the VideoToolbox encoder** | **the tablet's decoder stopped hoarding frames: 9 in flight → 1, latency 150 ms → 37 ms** |

## Things that turned out to be false

**Lower frame rate means lower latency.** It's the opposite. A decoder's pipeline is
measured in frames, not milliseconds, so at 30 fps every frame inside it costs twice as
long. Going 60 → 30 fps took latency from 131 ms to 440 ms.

**A cable is faster than Wi-Fi.** Not here. The stream is 5 Mbit/s and both links are
underused by an order of magnitude, so throughput never matters — only latency does. And
the "cable" route goes through the adb daemon, which multiplexes and copies packets;
measured, that overhead was 8–14 ms. Wi-Fi and USB come out the same.

**The tablet's clock can measure latency.** It can't — they drift by hundreds of
milliseconds; one measurement came out negative. TabScreen stamps each frame, the tablet
reports back when it hits the screen, and the Mac times the round trip on its own clock.

**A smaller picture will be faster.** Dropping 1280×800 → 1024×640 made latency worse
(283 ms), because the bottleneck was never the pixel count.

## Traps specific to these APIs

**ScreenCaptureKit refuses to run from a plain command-line binary** — it fails with
error -3805, "the attempt to connect to the app was interrupted". It needs a real `.app`
bundle with an `Info.plist` and at least an ad-hoc signature.

**An `SCStream` must be kept in a live variable.** Create it inside a completion block and
it's released immediately; the stream dies silently, with nothing in the log.

**ScreenCaptureKit only emits a frame when the picture changes.** Since the decoder's
pipeline is counted in frames, the last frame gets stuck in it on a still screen. The app
repeats the last frame at a steady beat to keep things moving.

**`NWListener` comes up IPv6-only by default.** The port looks open in `lsof`, and the
client gets "connection refused". Set `NWProtocolIP.Options.version = .v4`.

**Android silently drops broadcast packets** unless the app holds a
`WifiManager.MulticastLock`, which is why device discovery quietly does nothing.

**"The last non-builtin display" is not the virtual one** as soon as a real monitor is
plugged in. Ask BetterDisplay which display is virtual (`get -identifiers`,
`deviceType == VirtualScreen`).

**BetterDisplay's URL scheme can be switched off** in its settings — its command-line
binary always answers, so drive that instead.

**Windows on the virtual screen are invisible to the user.** Both the app's own window and
System Settings kept opening there, where only the tablet could see them. The app pulls
its window back to the Mac's display on launch.

## Measurements

| | ffmpeg + AVFoundation | this |
|---|---|---|
| Latency to screen | 122–174 ms | **31–39 ms** |
| Under heavy screen activity | 218 ms | **37 ms** |
| Frames inside the decoder | 6–10 | **1** |
| Mac CPU | 29–34 % of a core | **2 %** |

Every number here was measured on a MacBook Air M1 and a Samsung Galaxy Tab A 10.1 (2019,
SM-T515, Android 11).
