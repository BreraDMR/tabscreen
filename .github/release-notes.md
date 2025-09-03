Two files, nothing to build.

**On the Mac** — download `TabScreen-mac.zip`, unpack, drag `TabScreen.app` into
Applications. The app is not signed with a paid Apple certificate, so the first launch
needs a right-click → **Open** instead of a double-click, and macOS will ask once for
screen recording permission.

You also need [BetterDisplay](https://github.com/waydabber/BetterDisplay) (free) — it
creates the virtual screen, which macOS has no public API for. TabScreen can set it up
for you: press **Create virtual screen**.

**On the tablet** — download `tabscreen-android.apk` straight to the tablet and open it.
Android will ask to allow installing from this source. No developer mode, no adb.

Then press **Turn on** on the Mac, and the tablet finds it by itself.
