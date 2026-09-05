package com.tabscreen;

import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Build;
import android.util.Log;
import android.view.Surface;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.InputStream;
import java.util.Locale;
import java.io.OutputStream;
import java.net.Socket;
import java.nio.ByteBuffer;

/** Pulls Annex-B H.264 off the socket, feeds it to MediaCodec, draws on the Surface.
 *  Everything runs on its own thread; the UI only gets status text. */
class StreamPlayer extends Thread {

    interface Status {
        void say(String text);
        /** true while frames are arriving, false once the link is gone. */
        void streaming(boolean on);
        /** How to turn the picture. The Mac decides this - the tablet only obeys. */
        void rotate(int degrees);
    }

    // 127.0.0.1 means "over the cable" (adb reverse); anything else is a Mac on the network
    static String host = "127.0.0.1";
    private static final int PORT = 8090;
    private static final int MAX_NAL = 4 * 1024 * 1024;

    private final Surface surface;
    private final Status status;
    private volatile boolean running = true;

    private MediaCodec codec;
    private byte[] sps, pps;
    private long frames = 0, started = 0, fed = 0;
    private long total = 0, lastLog = 0, nalCount = 0, dropped = 0;
    private boolean skipping = false;
    private long lastFps = 0, lastFrameAt = 0, worstGap = 0, shownGap = 0, drawn = 0;
    private long lastRecvAt = 0, worstRecv = 0, shownRecv = 0;
    private int lastSeq = 0;
    private BufferedInputStream buffered;
    private volatile OutputStream out;
    private long retryDelay = 1000;
    /** Angle the Mac asked for. The decoder does the turning while it draws - rotating
     *  the SurfaceView instead just leaves a black screen on this hardware. */
    private volatile int rotation = 0;
    private final MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
    private static final byte[] START = {0, 0, 0, 1};
    /** Sequence number the Mac uses for commands instead of video. */
    private static final int COMMAND_SEQ = 0xFFFFFFFF;
    private InputStream stream;
    private long lastReport = 0;

    StreamPlayer(Surface surface, Status status) {
        this.surface = surface;
        this.status = status;
    }

    void stopPlayer() {
        running = false;
        interrupt();
    }

    @Override
    public void run() {
        while (running) {
            Socket sock = null;
            try {
                status.say(L.CONNECTING);
                sock = new Socket(host, PORT);
                sock.setTcpNoDelay(true);
                sock.setReceiveBufferSize(64 * 1024);   // a big buffer just hides lag in itself
                out = sock.getOutputStream();
                InputStream in = sock.getInputStream();
                stream = in;
                retryDelay = 1000;                     // connected, start over
                status.say(L.WAITING_KEY);
                readStream(in);
            } catch (Exception e) {
                status.say(L.NO_LINK + e.getMessage() + L.RETRY);
            } finally {
                out = null;
                status.streaming(false);
                closeCodec();
                try { if (sock != null) sock.close(); } catch (Exception ignored) {}
            }
            if (running) {
                // The Mac may be asleep for hours - back off instead of hammering it.
                try { Thread.sleep(retryDelay); } catch (InterruptedException e) { return; }
                retryDelay = Math.min(retryDelay * 2, 30000);
            }
        }
    }

    /** The server sends each NAL as [4-byte length][data], so there is nothing to parse. */
    private void readStream(InputStream in) throws Exception {
        BufferedInputStream bin = new BufferedInputStream(in, 1 << 16);
        DataInputStream din = new DataInputStream(bin);
        buffered = bin;
        byte[] nal = new byte[MAX_NAL];
        while (running) {
            int len = din.readInt();
            if (len <= 0 || len > MAX_NAL) throw new Exception(L.BAD_LENGTH + len);
            lastSeq = din.readInt();
            din.readFully(nal, 0, len);
            if (lastSeq == COMMAND_SEQ) { handleCommand(nal, len); continue; }
            total += len + 4;
            long recvNow = System.currentTimeMillis();
            if (lastRecvAt > 0) {
                long g = recvNow - lastRecvAt;
                if (g > worstRecv) worstRecv = g;
            }
            lastRecvAt = recvNow;
            
            handleNal(nal, len);
        }
    }

    /** The Mac sends short text commands in place of a frame. Right now there is one:
     *  "ROT 0|90|180|270". Nothing on this side ever sends one back. */
    private void handleCommand(byte[] data, int len) {
        String text = new String(data, 0, len, java.nio.charset.StandardCharsets.UTF_8).trim();
        if (!text.startsWith("ROT ")) return;
        try {
            int deg = Integer.parseInt(text.substring(4).trim());
            if (deg != 0 && deg != 90 && deg != 180 && deg != 270) return;
            if (deg == rotation) return;
            rotation = deg;
            status.rotate(deg);          // the UI only resizes to keep the proportions
            closeCodec();                // the angle is baked in at configure time
            pps = null;
            skipping = true;
            Log.i("tabscreen", "поворот: " + deg + " - пересобираю декодер");
        } catch (NumberFormatException ignored) {}
    }

    private void handleNal(byte[] nal, int len) throws Exception {
        int type = nal[0] & 0x1f;

        // If bytes are piling up in the socket we're behind: throw frames away
        // until the next keyframe instead of letting the delay grow forever.
        // measure the backlog where it actually accumulates - in our own buffer
        if (!skipping && buffered != null && buffered.available() > 120000) skipping = true;
        if (skipping) {
            if (type == 5) skipping = false;      // caught up, resume here
            else if (type == 1) { dropped++; return; }
        }
        nalCount++;
        if (type != 1) Log.i("tabscreen", "NAL тип " + type + " длина " + len);
        if (type == 7) {
            byte[] fresh = copy(nal, len);
            // A different SPS means the picture changed shape - rotated, or the screen
            // resolution changed. This decoder won't follow that on the fly, so build a
            // new one. Without this the picture turns to garbage.
            if (sps != null && !java.util.Arrays.equals(sps, fresh)) {
                Log.i("tabscreen", "новый SPS - пересобираю декодер");
                closeCodec();
                pps = null;
                skipping = true;      // wait for the next keyframe before feeding anything
            }
            sps = fresh;
            maybeConfigure();
            return;
        }
        if (type == 8) {
            pps = copy(nal, len);
            maybeConfigure();
            return;
        }
        if (codec == null || (type != 1 && type != 5)) return;   // skip SEI and friends

        int idx = codec.dequeueInputBuffer(10000);
        if (idx >= 0) {
            ByteBuffer bb = codec.getInputBuffer(idx);
            bb.clear();
            bb.put(START);
            bb.put(nal, 0, len);
            codec.queueInputBuffer(idx, 0, len + 4, lastSeq * 1000L, 0);
            fed++;
        }
        drain();
    }

    private void drain() {
        // Small wait on the first poll: it lets a just-decoded frame out immediately
        // instead of waiting for the next NAL to arrive.
        boolean first = true;
        for (;;) {
            int out = codec.dequeueOutputBuffer(info, first ? 6000 : 0);
            first = false;
            if (out < 0) break;
            long seq = info.presentationTimeUs / 1000;
            codec.releaseOutputBuffer(out, true);
            frames++;
            drawn++;
            if (seq > 0 && seq % 30 == 0) ack(Long.toString(seq));

            long now = System.currentTimeMillis();
            if (lastFrameAt > 0) {
                long gap = now - lastFrameAt;
                if (gap > worstGap) worstGap = gap;
            }
            lastFrameAt = now;
            if (now - lastReport > 1000) {
                lastFps = frames * 1000 / Math.max(1, now - lastReport);
                shownGap = worstGap;
                worstGap = 0;
                shownRecv = worstRecv;
                worstRecv = 0;
                frames = 0;
                lastReport = now;
                Log.i("tabscreen", "метрика: " + lastFps + " к/с, рывок " + shownGap
                        + " мс, пауза в приёме " + shownRecv
                        + " мс, в декодере " + (fed - drawn)
                        + ", часы " + String.format("%07.3f", (now % 100000) / 1000.0));
                status.say(L.RUNNING + " | " + lastFps + (Locale.getDefault().getLanguage().equals("ru") ? " к/с | рывок " : " fps | worst gap ") + shownGap + (Locale.getDefault().getLanguage().equals("ru") ? " мс | в декодере " : " ms | in decoder ")
                        + (fed - drawn) + " | clock " + String.format("%07.3f", (now % 100000) / 1000.0));
            }
        }
    }

    private void maybeConfigure() throws Exception {
        if (codec != null || sps == null || pps == null) return;

        // Size here is a placeholder - the decoder reads the real one out of the SPS.
        MediaFormat fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 1280, 800);
        fmt.setByteBuffer("csd-0", withStartCode(sps));
        fmt.setByteBuffer("csd-1", withStartCode(pps));
        if (Build.VERSION.SDK_INT >= 30) {
            fmt.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);   // this is the whole point
        }
        if (rotation != 0) fmt.setInteger(MediaFormat.KEY_ROTATION, rotation);
        fmt.setInteger(MediaFormat.KEY_PRIORITY, 0);          // realtime, not best-effort
        fmt.setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE);
        fmt.setInteger("vendor.sec-dec-param.low-latency.value", 1);   // Exynos, если поймёт
        codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
        codec.configure(fmt, surface, null, 0);
        codec.start();
        status.streaming(true);
        Log.i("tabscreen", "декодер: " + codec.getName());
        try {
            android.os.Bundle p = new android.os.Bundle();
            p.putInt("low-latency", 1);
            p.putInt("vendor.sec-dec-param.low-latency.value", 1);   // Exynos-specific
            codec.setParameters(p);
        } catch (Exception e) {
            Log.i("tabscreen", "low-latency не принят: " + e);
        }
        started = 0;
        lastReport = 0;
        status.say(L.DECODER_UP);
    }

    /** Tell the Mac this frame just hit the screen - it times the round trip itself,
     *  which is the only clock we can trust here. */
    private void ack(String body) {
        // one line back down the same socket - the Mac times the round trip itself
        final OutputStream o = out;
        if (o == null) return;
        try {
            o.write(("ACK " + body + "\n").getBytes("US-ASCII"));
            o.flush();
        } catch (Exception ignored) {}
    }

    private void closeCodec() {
        if (codec != null) {
            try { codec.stop(); } catch (Exception ignored) {}
            try { codec.release(); } catch (Exception ignored) {}
            codec = null;
        }
        sps = pps = null;
    }

    private static byte[] copy(byte[] src, int len) {
        byte[] out = new byte[len];
        System.arraycopy(src, 0, out, 0, len);
        return out;
    }

    private static ByteBuffer withStartCode(byte[] nal) {
        ByteBuffer bb = ByteBuffer.allocate(nal.length + 4);
        bb.put(START).put(nal);
        bb.flip();
        return bb;
    }
}
