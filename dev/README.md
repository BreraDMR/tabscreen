# Development leftovers

These are the earlier iterations, kept because they are useful for debugging and they
document how the project got to its current shape. **Nothing here is needed to use
TabScreen** — the Mac app in `../mac/` does all of this by itself now.

- `server.py` — the original Python server: ran the capture, fanned frames out to
  clients, measured latency. Also contains an ffmpeg fallback path (`USE_SWIFT_CAPTURE
  = False`) which is handy when you want to compare against AVFoundation.
- `input.py` — touch events from the tablet turned into mouse events via `CGEvent`.
  Works, but is off by default: at any noticeable latency a finger-driven cursor feels
  wrong.
- `start.sh` — launcher for the Python path, including `adb reverse` for the USB route.
- `standalone-capture/` — the capture as a plain command-line tool that writes H.264 to
  stdout. Good for measuring the capture on its own.

The USB route (`adb reverse`) lives on here too. It needs USB debugging on the tablet
and gives ~34 ms instead of ~41 ms over Wi-Fi — worth it only if you are chasing the
last few milliseconds.
