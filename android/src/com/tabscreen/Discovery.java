package com.tabscreen;

import android.content.Context;
import android.net.wifi.WifiManager;
import android.util.Log;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;

/** Listens for the "I'm here" shout the Mac app sends once a second, so nobody has
 *  to type an IP address. */
class Discovery extends Thread {

    interface Found {
        void mac(String address, String name);
    }

    private static final int PORT = 8089;
    private final Found callback;
    private final Context context;
    private volatile boolean running = true;
    private DatagramSocket socket;
    private WifiManager.MulticastLock lock;

    Discovery(Context context, Found callback) {
        this.context = context;
        this.callback = callback;
    }

    void stopLooking() {
        running = false;
        if (socket != null) socket.close();
        interrupt();
    }

    @Override
    public void run() {
        try {
            // Wi-Fi silently drops broadcast packets unless we hold this lock
            WifiManager wifi = (WifiManager) context.getApplicationContext()
                    .getSystemService(Context.WIFI_SERVICE);
            if (wifi != null) {
                lock = wifi.createMulticastLock("tabscreen");
                lock.setReferenceCounted(true);
                lock.acquire();
            }
            socket = new DatagramSocket(null);
            socket.setReuseAddress(true);
            socket.setBroadcast(true);
            socket.bind(new java.net.InetSocketAddress(PORT));
            byte[] buf = new byte[256];
            while (running) {
                DatagramPacket packet = new DatagramPacket(buf, buf.length);
                socket.receive(packet);
                String text = new String(packet.getData(), 0, packet.getLength(), "UTF-8");
                if (!text.startsWith("TABSCREEN")) continue;
                InetAddress from = packet.getAddress();
                String name = text.length() > 10 ? text.substring(10).trim() : "Mac";
                Log.i("tabscreen", "нашёл мак: " + from.getHostAddress());
                callback.mac(from.getHostAddress(), name);
            }
        } catch (Exception e) {
            if (running) Log.i("tabscreen", "поиск прекращён: " + e);
        } finally {
            if (lock != null && lock.isHeld()) lock.release();
        }
    }
}
