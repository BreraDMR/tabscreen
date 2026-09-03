package com.tabscreen;

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
    private volatile boolean running = true;
    private DatagramSocket socket;

    Discovery(Found callback) {
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
                callback.mac(from.getHostAddress(), name);
            }
        } catch (Exception e) {
            if (running) Log.i("tabscreen", "поиск прекращён: " + e);
        }
    }
}
