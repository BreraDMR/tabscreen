#!/bin/bash
# Second screen on the tablet, over the USB cable. Run this, that's it.
set -e
cd "$(dirname "$0")"

if ! adb devices | grep -q "device$"; then
  echo "планшет не виден по USB — проверь кабель и отладку"; exit 1
fi

pkill -f "$(pwd)/server.py" 2>/dev/null || true
sleep 1

# the virtual screen has to exist before the server measures it
if ! betterdisplaycli get -identifiers 2>/dev/null | grep -q VirtualScreen; then
  echo "нет виртуального экрана — создай его в BetterDisplay"; exit 1
fi

nohup ./.venv/bin/python server.py > /tmp/tabscreen.log 2>&1 &
sleep 3

adb reverse tcp:8090 tcp:8090
adb shell svc power stayon usb
adb shell settings put system user_rotation 1 >/dev/null 2>&1 || true
adb shell am force-stop com.tabscreen
adb shell am start -n com.tabscreen/.MainActivity >/dev/null

echo "готово — картинка на планшете. Остановить: pkill -f server.py"
