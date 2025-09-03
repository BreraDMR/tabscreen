package com.tabscreen;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;

/** Shows the Mac's virtual screen. The stream comes in over the USB cable
 *  (adb reverse puts it on 127.0.0.1), decoded straight by MediaCodec. */
public class MainActivity extends Activity implements SurfaceHolder.Callback {

    private StreamPlayer player;
    private TextView status;
    private boolean statusVisible = true;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);

        SurfaceView sv = new SurfaceView(this);
        root.addView(sv, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));

        status = new TextView(this);
        status.setTextColor(Color.GREEN);
        status.setBackgroundColor(0xA0000000);
        status.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        status.setText("подключаюсь…");
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT);
        lp.gravity = Gravity.BOTTOM | Gravity.START;
        root.addView(status, lp);

        // tap hides the counter, tap again brings it back
        root.setOnClickListener(v -> {
            statusVisible = !statusVisible;
            status.setVisibility(statusVisible ? View.VISIBLE : View.GONE);
        });

        setContentView(root);
        hideSystemBars();
        sv.getHolder().addCallback(this);

        // hide the status line after a few seconds: an overlay on top of the video
        // forces the compositor to mix layers instead of handing the frame straight
        // to the display
        new Handler(Looper.getMainLooper()).postDelayed(() -> {
            statusVisible = false;
            status.setVisibility(View.GONE);
        }, 25000);
    }

    private void hideSystemBars() {
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        | View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideSystemBars();
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        Handler ui = new Handler(Looper.getMainLooper());
        player = new StreamPlayer(holder.getSurface(),
                text -> ui.post(() -> status.setText(text)));
        player.start();
    }

    @Override public void surfaceChanged(SurfaceHolder h, int f, int w, int hh) {}

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        if (player != null) { player.stopPlayer(); player = null; }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (player != null) player.stopPlayer();
    }
}
