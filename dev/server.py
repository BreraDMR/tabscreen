#!/usr/bin/env python3
"""Shows a macOS virtual display on an Android tablet over the USB cable.

One ffmpeg hardware-encodes the virtual screen into fragmented mp4 and every
browser that connects gets the init segment plus the live fragments, so
reconnecting doesn't spawn a second capture. The tablet reaches this through
adb reverse - no wifi in the path.

    python3 server.py [screen_index]
"""
import http.server
import queue
import select
import re
import socket
import socketserver
import time
import subprocess
import json
import os
import sys
import threading

import input as pointer_input

PORT = 8090
FPS = 60
BITRATE = "5M"
# Own capture (ScreenCaptureKit + VideoToolbox, no ffmpeg) - set to False to fall back
USE_SWIFT_CAPTURE = True
SWIFT_CAPTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "swift/TabCapture.app/Contents/MacOS/TabCapture")


def virtual_display_id():
    """macOS id of the virtual display - the last one in the list."""
    import Quartz
    import time
    for _ in range(20):
        err, ids, cnt = Quartz.CGGetActiveDisplayList(16, None, None)
        if ids:
            return list(ids)[-1]
        time.sleep(0.25)
    sys.exit("no displays found")


def virtual_screen_size():
    """Native size of the virtual display, so we can capture it 1:1.

    The display list comes back empty for a moment while macOS is reshuffling
    screens, so give it a few tries before giving up.
    """
    import Quartz
    import time
    for _ in range(20):
        err, ids, cnt = Quartz.CGGetActiveDisplayList(16, None, None)
        if ids:
            mode = Quartz.CGDisplayCopyDisplayMode(list(ids)[-1])
            return (Quartz.CGDisplayModeGetPixelWidth(mode),
                    Quartz.CGDisplayModeGetPixelHeight(mode))
        time.sleep(0.25)
    sys.exit("no displays found - is the virtual screen connected?")


WIDTH, HEIGHT = virtual_screen_size()


def find_screen_index():
    """Last 'Capture screen' avfoundation reports is the newest one = virtual."""
    out = subprocess.run(
        ["ffmpeg", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
        capture_output=True, text=True).stderr
    screens = re.findall(r"\[(\d+)\] Capture screen \d+", out)
    if not screens:
        sys.exit("no screen capture devices found")
    return screens[-1]


SCREEN = sys.argv[1] if len(sys.argv) > 1 else find_screen_index()


class Client:
    """One viewer. Keeps a short queue; if it overflows we drop everything until
    the next keyframe instead of letting a backlog build up."""

    def __init__(self, maxsize=5):
        self.q = queue.Queue(maxsize=maxsize)
        self.waiting_key = False
        self.dropped = 0

    def push(self, data, is_key):
        if self.waiting_key:
            if not is_key:
                self.dropped += 1
                return
            self.waiting_key = False
        try:
            self.q.put_nowait(data)
        except queue.Full:
            while not self.q.empty():          # throw the backlog away wholesale
                try:
                    self.q.get_nowait()
                except queue.Empty:
                    break
            self.waiting_key = True
            self.dropped += 1

    def get(self, timeout=None):
        return self.q.get(timeout=timeout)


class Broadcaster:
    """Runs ffmpeg only while somebody is watching, and fans the output out.

    raw=True gives Annex-B H.264 for the native client; raw=False wraps it in
    fragmented mp4 for browsers.
    """

    def __init__(self, screen, raw):
        self.screen = screen
        self.raw = raw
        self.init_segment = b""
        self.sps = self.pps = b""
        self.seq = 0
        self.sent_at = {}
        self.clients = set()
        self.lock = threading.Lock()
        self.frames = 0
        self.proc = None
        self.wanted = threading.Event()
        threading.Thread(target=self.run, daemon=True).start()

    def ffmpeg_cmd(self):
        if self.raw and USE_SWIFT_CAPTURE and os.path.exists(SWIFT_CAPTURE):
            return [SWIFT_CAPTURE, str(virtual_display_id()), str(WIDTH), str(HEIGHT),
                    str(FPS), str(int(BITRATE.rstrip("M")) * 1_000_000)]
        cmd = [
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-fflags", "+nobuffer", "-flags", "low_delay",
            "-f", "avfoundation", "-capture_cursor", "1",
            "-framerate", str(FPS), "-i", self.screen,
            "-vf", "format=nv12",
            "-c:v", "h264_videotoolbox", "-realtime", "1",
            "-profile:v", "baseline", "-b:v", BITRATE, "-g", "30",
            # keyframe twice a second: a client that fell behind recovers fast
            "-force_key_frames", "expr:gte(t,n_forced*0.5)",
        ]
        if self.raw:
            # keyframes often enough that a fresh client picks up quickly
            cmd += ["-f", "h264", "-"]
        else:
            cmd += ["-movflags",
                    "+frag_keyframe+empty_moov+default_base_moof+frag_every_frame",
                    "-f", "mp4", "-"]
        return cmd

    def run(self):
        while True:
            self.wanted.wait()          # idle until a client shows up
            proc = subprocess.Popen(self.ffmpeg_cmd(), stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, bufsize=0)
            self.proc = proc
            try:
                self.pump(proc.stdout)
            except Exception as e:
                print("capture stopped:", e, flush=True)
            proc.kill()
            proc.wait()
            self.proc = None
            self.init_segment = b""
            self.sps = self.pps = b""

    def read_exactly(self, stream, n):
        buf = b""
        while len(buf) < n:
            chunk = stream.read(n - len(buf))
            if not chunk:
                raise EOFError("ffmpeg closed")
            buf += chunk
        return buf

    def pump(self, stream):
        if self.raw:
            if USE_SWIFT_CAPTURE and os.path.exists(SWIFT_CAPTURE):
                return self.pump_lengths(stream)
            return self.pump_annexb(stream)
        return self.pump_mp4(stream)

    def pump_lengths(self, stream):
        """Our own capture already hands us [4-byte length][NAL] - just pass it along."""
        fd = stream.fileno()
        buf = b""
        while self.wanted.is_set():
            chunk = os.read(fd, 65536)
            if not chunk:
                raise EOFError("capture closed")
            buf += chunk
            while len(buf) >= 4:
                size = int.from_bytes(buf[:4], "big")
                if size <= 0 or size > 8 << 20:
                    raise EOFError("битая длина от захвата")
                if len(buf) < 4 + size:
                    break
                self.emit(buf[4:4 + size])
                buf = buf[4 + size:]
        raise EOFError("nobody watching")

    def pump_annexb(self, stream):
        """Cut the stream into NAL units and send each one length-prefixed.

        The tablet used to hunt for start codes byte by byte in Java, and on that
        CPU it simply couldn't keep up at 60 fps. Doing it here costs nothing.
        """
        fd = stream.fileno()
        buf = b""
        while self.wanted.is_set():
            ready, _, _ = select.select([fd], [], [], 0.004)
            if not ready:
                if len(buf) > 3 and buf.startswith(b"\x00\x00\x01"):
                    self.emit(buf[3:])          # ffmpeg paused - the frame is complete
                    buf = b""
                continue
            chunk = os.read(fd, 65536)
            if not chunk:
                raise EOFError("ffmpeg closed")
            buf += chunk
            start = buf.find(b"\x00\x00\x01")
            while start >= 0:
                nxt = buf.find(b"\x00\x00\x01", start + 3)
                if nxt < 0:
                    break
                end = nxt - 1 if nxt > 0 and buf[nxt - 1] == 0 else nxt
                self.emit(buf[start + 3:end])
                buf = buf[nxt:]
                start = 0 if buf.startswith(b"\x00\x00\x01") else buf.find(b"\x00\x00\x01")
        raise EOFError("nobody watching")
        return self.pump_mp4(stream)

    def pump_mp4(self, stream):
        """Walk the mp4 box by box: ftyp+moov is the init, moof+mdat are frames."""
        pending = b""
        while True:
            header = self.read_exactly(stream, 8)
            size = int.from_bytes(header[:4], "big")
            kind = header[4:8]
            body = self.read_exactly(stream, size - 8) if size > 8 else b""
            box = header + body

            if kind in (b"ftyp", b"moov"):
                self.init_segment += box
            elif kind == b"moof":
                pending = box
            elif kind == b"mdat":
                self.publish(pending + box)
                pending = b""
            # styp/sidx/anything else: not needed for MSE, drop it

    def emit(self, nal):
        """Send one NAL out, remembering headers and stamping a sequence number."""
        if not nal:
            return
        kind = nal[0] & 0x1f
        if kind == 7:
            self.sps = nal
        elif kind == 8:
            self.pps = nal
        if self.sps and self.pps:
            self.init_segment = (len(self.sps).to_bytes(4, "big") + b"\x00\x00\x00\x00" + self.sps
                                 + len(self.pps).to_bytes(4, "big") + b"\x00\x00\x00\x00" + self.pps)
        self.seq = (self.seq + 1) & 0x7fffffff
        if self.seq % 30 == 0:
            self.sent_at[self.seq] = time.time()
            if len(self.sent_at) > 200:
                self.sent_at.pop(next(iter(self.sent_at)))
        self.publish(len(nal).to_bytes(4, "big") + self.seq.to_bytes(4, "big") + nal, kind == 5)

    def remember_headers(self, data):
        """Keep the newest SPS/PPS around so a late client can configure its decoder."""
        i = 0
        last_start = 0
        while True:
            i = data.find(b"\x00\x00\x01", i)
            if i < 0:
                break
            last_start = i
            kind = data[i + 3] & 0x1f if i + 3 < len(data) else 0
            end = data.find(b"\x00\x00\x01", i + 3)
            if end < 0:
                break
            if kind in (7, 8):
                nal = data[i:end]
                if kind == 7:
                    self.sps = nal
                else:
                    self.pps = nal
                if self.sps and self.pps:
                    self.init_segment = self.sps + self.pps
            i = end
        return data[last_start:][-64:]        # carry a little over the chunk boundary

    def publish(self, fragment, is_key=False):
        self.frames += 1
        if self.frames % 600 == 0:
            info = [(c.q.qsize(), c.dropped) for c in self.clients]
            if info:
                print("клиенты (в очереди, выброшено):", info, flush=True)
        with self.lock:
            for c in self.clients:
                c.push(fragment, is_key)

    def subscribe(self):
        c = Client()
        with self.lock:
            self.clients.add(c)
            self.wanted.set()
        return c

    def unsubscribe(self, c):
        with self.lock:
            self.clients.discard(c)
            if not self.clients:
                self.wanted.clear()
                if self.proc:
                    self.proc.kill()   # nobody left, stop burning cpu


HTML = """<!doctype html><meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Mac screen</title>
<style>
  html,body{margin:0;height:100%;background:#000;overflow:hidden}
  video{width:100%;height:100%;object-fit:contain;display:block;background:#000}
  #st{position:fixed;left:0;bottom:0;padding:4px 8px;color:#6f6;font:11px monospace;
      background:#000a;pointer-events:none}
</style>
<video id=v autoplay muted playsinline></video>
<div id=st>подключаюсь…</div>
<script>
const v = document.getElementById('v'), st = document.getElementById('st');
const MIME = 'video/mp4; codecs="avc1.42E01E"';
let bytes = 0, frags = 0;

let shown = 0, lastTick = performance.now(), fps = 0, lagMs = 0;
function log(s) {
  st.textContent = s + ' | ' + fps.toFixed(0) + ' к/с | лаг ' + lagMs.toFixed(0) + ' мс | '
                 + frags + ' фр ' + (bytes/1048576).toFixed(1) + ' МБ';
}
// count what the tablet actually paints, not what we sent it
if (v.requestVideoFrameCallback) {
  const tick = () => {
    shown++;
    const now = performance.now();
    if (now - lastTick > 1000) { fps = shown * 1000 / (now - lastTick); shown = 0; lastTick = now; }
    v.requestVideoFrameCallback(tick);
  };
  v.requestVideoFrameCallback(tick);
}
setInterval(() => log(v.paused ? 'пауза' : 'идёт'), 1000);

async function start() {
  if (!('MediaSource' in window) || !MediaSource.isTypeSupported(MIME)) {
    log('MSE не поддерживается'); return;
  }
  const ms = new MediaSource();
  v.src = URL.createObjectURL(ms);
  ms.addEventListener('sourceopen', async () => {
    let sb;
    try { sb = ms.addSourceBuffer(MIME); } catch (e) { log('addSourceBuffer: ' + e); return; }
    sb.mode = 'sequence';
    const q = [];
    const pump = () => {
      if (sb.updating || !q.length) return;
      try { sb.appendBuffer(q.shift()); } catch (e) { log('append: ' + e.name); }
    };
    sb.addEventListener('updateend', () => {
      if (sb.buffered.length) {
        const end = sb.buffered.end(sb.buffered.length - 1);
        const start = sb.buffered.start(0);
        if (end - start > 6 && !sb.updating) {
          try { sb.remove(start, end - 3); } catch (e) {}
        }
        const lag = end - v.currentTime;
        lagMs = lag * 1000;
        if (lag > 0.6) v.currentTime = end - 0.02;        // too far behind, jump
        else if (lag > 0.08) v.playbackRate = 1.3;        // shave the buffer down
        else if (v.playbackRate !== 1) v.playbackRate = 1;
      }
      pump();
    });
    sb.addEventListener('error', () => log('ошибка буфера'));

    try {
      const res = await fetch('/stream?' + Date.now());
      const reader = res.body.getReader();
      log('поток открыт');
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        bytes += value.byteLength; frags++;
        q.push(value);
        if (q.length > 8) q.splice(0, q.length - 4);   // stale frames are useless, drop them
        pump();
        if (frags % 30 === 0) log(v.paused ? 'пауза' : 'идёт');
      }
      log('поток закрылся');
    } catch (e) { log('fetch: ' + e.message); }
    setTimeout(start, 1000);
  });
}
start();

v.addEventListener('error', () => log('video error ' + (v.error && v.error.code)));

// touch input is off for now - too laggy to be useful on this tablet
document.body.onclick = () => {
  const el = document.documentElement;
  if (!document.fullscreenElement && el.requestFullscreen) el.requestFullscreen().catch(() => {});
  v.play().catch(() => {});
};
</script>"""


recv_samples = []
draw_samples = []


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        if self.path.startswith("/ack"):
            length = int(self.headers.get("Content-Length", 0))
            try:
                body = self.rfile.read(length).decode().strip()
                kind, _, num = body.partition(":")
                seq = int(num)
                sent = raw_caster.sent_at.get(seq)
                if sent:
                    ms = (time.time() - sent) * 1000
                    (recv_samples if kind == "r" else draw_samples).append(ms)
                    if kind == "d":
                        raw_caster.sent_at.pop(seq, None)
                    if len(draw_samples) % 10 == 0 and recv_samples and draw_samples:
                        r = sorted(recv_samples[-30:]); d = sorted(draw_samples[-30:])
                        print("по проводу: %.0f мс | всего до экрана: %.0f мс | планшет тратит: %.0f мс"
                              % (r[len(r)//2], d[len(d)//2], d[len(d)//2] - r[len(r)//2]), flush=True)
            except Exception:
                pass
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if not self.path.startswith("/input"):
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            for msg in json.loads(raw):
                pointer.handle(msg)
        except Exception as e:
            print("input:", e, flush=True)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self.path.startswith("/h264"):
            self.stream(raw_caster, need_init=False)
        elif self.path.startswith("/stream"):
            self.stream(caster, need_init=True)
        else:
            body = (HTML.replace("__AR__", str(WIDTH / HEIGHT))
                        .replace("__W__", str(WIDTH))
                        .replace("__H__", str(HEIGHT))).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def stream(self, source, need_init):
        client = source.subscribe()
        if need_init:
            for _ in range(100):       # wait for the moov, else the client chokes
                if source.init_segment:
                    break
                threading.Event().wait(0.1)
            if not source.init_segment:
                source.unsubscribe(client)
                self.send_error(503, "capture not ready")
                return
        # raw clients get the stream from the first byte - it starts with a keyframe.
        # Waiting here would let the queue drop exactly that keyframe.
        try:
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 65536)
        except Exception:
            pass
        self.send_response(200)
        self.send_header("Content-Type", "video/mp4" if need_init else "video/h264")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            if source.init_segment:
                self.wfile.write(source.init_segment)
                self.wfile.flush()
            while True:
                self.wfile.write(client.get())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            source.unsubscribe(client)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    disable_nagle_algorithm = True   # Nagle would sit on small writes and add lag


if __name__ == "__main__":
    pointer = pointer_input.Pointer()
    caster = Broadcaster(SCREEN, raw=False)
    raw_caster = Broadcaster(SCREEN, raw=True)
    print(f"capturing screen {SCREEN} -> http://127.0.0.1:{PORT}", flush=True)
    Server(("0.0.0.0", PORT), Handler).serve_forever()
