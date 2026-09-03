#!/bin/bash
# Undoes debloat.sh - re-enables everything it turned off.
cd "$(dirname "$0")"
[ -f disabled-packages.txt ] || { echo "нечего возвращать: нет disabled-packages.txt"; exit 1; }
while read -u 3 p; do
  [ -z "$p" ] && continue
  adb shell pm enable "$p" </dev/null >/dev/null 2>&1 && echo "возвращён $p"
done 3< disabled-packages.txt
echo "готово — перезагрузи планшет: adb reboot"
