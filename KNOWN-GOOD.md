# Known-good configuration

The setup Damir signed off on: **32–41 ms to the tablet's screen, 44–60 fps, 2 % of one
Mac core**. If a change makes things worse, come back to exactly these numbers.

Tag: `git checkout known-good` · commit `bc4e449`

## Virtual display (BetterDisplay)

```
betterdisplaycli create -type=VirtualScreen
betterdisplaycli set -tagID=<tag> -virtualScreenHiDPI=off
betterdisplaycli set -tagID=<tag> -useResolutionList=on -resolutionList=1280x800
betterdisplaycli set -tagID=<tag> -connected=on
betterdisplaycli set -tagID=<tag> -resolution=1280x800
```

1280×800, HiDPI **off**, 60 Hz. `-resolution=` is ignored unless `useResolutionList=on`
is set first. If BetterDisplay isn't running, the CLI silently returns nothing and the
virtual screen shows up with `displayID 0` — meaning "not connected".

## Capture (swift/capture.swift)

| Setting | Value | Why |
|---|---|---|
| `EnableLowLatencyRateControl` | **true** | the single most important line: decoder holds 1 frame instead of 9 |
| `RealTime` | true | |
| `ProfileLevel` | Baseline AutoLevel | old decoders handle it best |
| `AllowFrameReordering` | false | no B-frames |
| `MaxKeyFrameInterval` | fps / 2 | keyframe twice a second |
| `MaxKeyFrameIntervalDuration` | 0.5 | |
| `queueDepth` (SCStream) | 3 | shallow on purpose |
| `minimumFrameInterval` | 1/60 | |
| Ticker | repeats the last frame when idle | a decoder pipeline measured in frames stalls otherwise |

**Do not add** `MaxFrameDelayCount` — it made latency worse (193–206 ms).

## Server (server.py)

```python
FPS = 60            # 30 makes latency WORSE - the decoder queue is counted in frames
BITRATE = "5M"
USE_SWIFT_CAPTURE = True
Client(maxsize=5)   # short queue; on overflow drop everything until the next keyframe
SO_SNDBUF = 65536   # a big socket buffer is just hidden latency
disable_nagle_algorithm = True
```

Reads the capture with `os.read` on an unbuffered pipe. A fixed-size read waits for its
buffer to fill and turns a smooth stream into 500 ms bursts.

## Android client

| Setting | Value |
|---|---|
| Decoder | `MediaCodec.createDecoderByType` → `OMX.Exynos.avc.dec` (hardware) |
| `KEY_LOW_LATENCY` | 1 |
| `KEY_PRIORITY` | 0 (realtime) |
| `KEY_OPERATING_RATE` | `Short.MAX_VALUE` |
| First `dequeueOutputBuffer` timeout | 6000 µs, then 0 |
| Skip-ahead threshold | `BufferedInputStream.available() > 120000` → drop to next keyframe |
| Wire format | `[4-byte length][4-byte seq][NAL]` |

**Do not** force the software decoder (`c2.android.avc.decoder`) — 162 ms instead of 149.
**Do not** throttle input to keep the decoder queue short — frame gaps jump 36 → 217 ms.
**Do not** drop P-frames selectively — they are reference frames, the picture collapses to
1–2 fps.

## Transport

`adb reverse tcp:8090 tcp:8090`, tablet connects to `127.0.0.1:8090`. Over Wi-Fi the same
setup measures 41 ms — near enough that the cable is optional.

## Measured

| | |
|---|---|
| Latency to screen | 32–41 ms |
| Frames inside the decoder | 1 |
| Worst frame gap | 28–35 ms |
| Frame rate | 44–60 fps |
| Mac CPU | 2 % of one core |
| Bandwidth | ~5 Mbit/s |
