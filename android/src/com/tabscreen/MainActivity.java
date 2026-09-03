package com.tabscreen;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Two screens in one: a small setup page until we know which Mac to talk to,
 *  then nothing but the picture. */
public class MainActivity extends Activity implements SurfaceHolder.Callback {

    private static final String PREFS = "tabscreen";
    private static final String KEY_HOST = "host";

    private StreamPlayer player;
    private TextView status;
    private SurfaceView video;
    private LinearLayout setup;
    private TextView setupHint;
    private EditText hostField;
    private Discovery discovery;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private boolean statusVisible = true;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);

        video = new SurfaceView(this);
        root.addView(video, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        status = new TextView(this);
        status.setTextColor(Color.GREEN);
        status.setBackgroundColor(0xA0000000);
        status.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        FrameLayout.LayoutParams sp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT);
        sp.gravity = Gravity.BOTTOM | Gravity.START;
        root.addView(status, sp);

        root.addView(buildSetup());
        setContentView(root);
        hideSystemBars();

        String saved = prefs().getString(KEY_HOST, null);
        String fromIntent = getIntent() != null ? getIntent().getStringExtra("host") : null;
        if (fromIntent != null && !fromIntent.isEmpty()) saved = fromIntent;

        if (saved != null && !saved.isEmpty()) {
            connectTo(saved);
        } else {
            showSetup(true);
            lookForMac();
        }

        root.setOnClickListener(v -> {
            if (setup.getVisibility() == View.VISIBLE) return;
            statusVisible = !statusVisible;
            status.setVisibility(statusVisible ? View.VISIBLE : View.GONE);
        });
        ui.postDelayed(() -> {
            statusVisible = false;
            status.setVisibility(View.GONE);
        }, 25000);
    }

    private SharedPreferences prefs() {
        return getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private View buildSetup() {
        setup = new LinearLayout(this);
        setup.setOrientation(LinearLayout.VERTICAL);
        setup.setGravity(Gravity.CENTER);
        setup.setBackgroundColor(0xFF101014);
        setup.setPadding(60, 60, 60, 60);

        TextView title = new TextView(this);
        title.setText("TabScreen");
        title.setTextColor(Color.WHITE);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 26);
        title.setGravity(Gravity.CENTER);
        setup.addView(title);

        setupHint = new TextView(this);
        setupHint.setText("Ищу Mac в сети…\nЗапусти на нём TabScreen и нажми «Включить».");
        setupHint.setTextColor(0xFFAAAAAA);
        setupHint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        setupHint.setGravity(Gravity.CENTER);
        setupHint.setPadding(0, 24, 0, 24);
        setup.addView(setupHint);

        hostField = new EditText(this);
        hostField.setHint("или введи адрес вручную: 192.168.0.30");
        hostField.setTextColor(Color.WHITE);
        hostField.setHintTextColor(0xFF666666);
        hostField.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        hostField.setGravity(Gravity.CENTER);
        setup.addView(hostField);

        Button connect = new Button(this);
        connect.setText("Подключиться");
        connect.setOnClickListener(v -> {
            String h = hostField.getText().toString().trim();
            if (!h.isEmpty()) connectTo(h);
        });
        setup.addView(connect);

        return setup;
    }

    private void showSetup(boolean show) {
        setup.setVisibility(show ? View.VISIBLE : View.GONE);
        video.setVisibility(show ? View.GONE : View.VISIBLE);
    }

    private void lookForMac() {
        discovery = new Discovery((address, name) -> ui.post(() -> {
            setupHint.setText("Нашёл: " + name + " (" + address + ")\nПодключаюсь…");
            connectTo(address);
        }));
        discovery.start();
    }

    private void connectTo(String address) {
        if (discovery != null) {
            discovery.stopLooking();
            discovery = null;
        }
        prefs().edit().putString(KEY_HOST, address).apply();
        StreamPlayer.host = address;
        showSetup(false);
        status.setText("подключаюсь к " + address + "…");
        video.getHolder().addCallback(this);
        if (video.getHolder().getSurface() != null && video.getHolder().getSurface().isValid()) {
            surfaceCreated(video.getHolder());
        }
    }

    /** Long-press anywhere on the setup screen forgets the saved Mac. */
    @Override
    public void onBackPressed() {
        if (setup.getVisibility() != View.VISIBLE) {
            prefs().edit().remove(KEY_HOST).apply();
            if (player != null) { player.stopPlayer(); player = null; }
            showSetup(true);
            lookForMac();
            return;
        }
        super.onBackPressed();
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
        if (player != null) return;
        player = new StreamPlayer(holder.getSurface(), text -> ui.post(() -> status.setText(text)));
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
        if (discovery != null) discovery.stopLooking();
    }
}
