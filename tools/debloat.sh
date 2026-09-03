#!/bin/bash
# Optional: quiets down a Samsung tablet so it stops swapping.
#
# Nothing is deleted - `pm disable-user` only stops packages from running for the
# current user. Everything comes back with rebloat.sh, and a factory reset undoes
# it all anyway. Read the list before running it; skip anything you actually use.
set -e
cd "$(dirname "$0")"
OUT=disabled-packages.txt
: > "$OUT"

PACKAGES="
com.google.android.googlequicksearchbox
com.google.android.apps.turbo
com.google.android.apps.tachyon
com.google.android.projection.gearhead
com.google.android.apps.restore
com.google.android.gms.location.history
com.google.android.printservice.recommendation
com.google.android.apps.photos
com.google.mainline.telemetry
com.google.android.feedback
com.google.android.partnersetup
com.samsung.android.rubin.app
com.sec.android.diagmonagent
com.sec.android.sdhms
com.samsung.android.dqagent
com.samsung.android.dsms
com.samsung.android.bbc.bbcagent
com.samsung.android.game.gos
com.samsung.android.game.gamehome
com.samsung.android.game.gametools
com.samsung.klmsagent
com.samsung.android.knox.analytics.uploader
com.samsung.android.knox.attestation
com.samsung.android.knox.containeragent
com.samsung.android.knox.containercore
com.samsung.android.knox.pushmanager
com.samsung.android.app.reminder
com.samsung.android.scloud
com.samsung.android.smartswitchassistant
com.samsung.android.kidsinstaller
com.samsung.android.app.sharelive
com.samsung.android.app.dressroom
com.samsung.android.mcfserver
com.samsung.android.mcfds
com.samsung.android.mobileservice
com.samsung.android.app.settings.bixby
com.samsung.android.bixby.agent
com.samsung.android.bixby.wakeup
com.samsung.android.visionintelligence
com.samsung.android.aremoji
com.samsung.android.ardrawing
com.samsung.android.arzone
com.samsung.android.themestore
com.samsung.android.wallpaper.res
com.samsung.android.fmm
com.samsung.android.forest
com.samsung.android.beaconmanager
com.samsung.android.svcagent
com.sec.android.app.samsungapps
com.samsung.android.mdx.kit
com.samsung.android.mdx.quickboard
com.samsung.android.app.appsedge
com.samsung.android.app.clipboardedge
com.samsung.android.app.cocktailbarservice
com.samsung.android.aircommandmanager
com.samsung.android.livestickers
com.samsung.android.dynamiclock
com.samsung.android.homemode
com.samsung.android.easysetup
com.samsung.android.app.watchmanagerstub
com.samsung.android.allshare.service.fileshare
com.samsung.android.allshare.service.mediashare
com.samsung.android.app.simplesharing
com.samsung.android.aware.service
com.samsung.android.icecone
com.samsung.android.mapsagent
com.samsung.android.hdmapp
com.samsung.android.app.updatecenter
com.samsung.android.container
com.samsung.android.appseparation
com.samsung.SMT
com.samsung.android.app.galaxyfinder
com.samsung.android.mdm
com.samsung.android.cidmanager
com.samsung.android.kgclient
"

# Add these if you want the tablet to be nothing but a screen. They take the Play
# Store and Google services with them, so anything depending on Google stops working.
if [ "$1" = "--everything" ]; then
  PACKAGES="$PACKAGES
com.android.vending
com.google.android.gms
com.google.android.gsf
com.google.android.gm
com.google.android.youtube
com.google.android.apps.maps
com.android.chrome
com.sec.android.app.sbrowser
com.samsung.android.app.notes
com.samsung.android.lool
"
fi

count=0
# adb eats stdin, so feed the loop through its own descriptor
while read -u 3 p; do
  [ -z "$p" ] && continue
  r=$(adb shell pm disable-user --user 0 "$p" </dev/null 2>&1 | tr -d '\r')
  if echo "$r" | grep -q disabled; then
    echo "$p" >> "$OUT"
    echo "  выключен $p"
    count=$((count + 1))
  fi
done 3< <(echo "$PACKAGES")

echo
echo "выключено пакетов: $count (список в tools/$OUT)"
echo "перезагрузи планшет, чтобы освободилась память: adb reboot"
