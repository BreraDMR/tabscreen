#!/bin/bash
# Downloads the build tools needed for the Android client (a JDK and the Android
# SDK command-line tools) into ./tools. Nothing is installed system-wide and no
# password is asked for - everything lands in this folder.
set -e
cd "$(dirname "$0")"
mkdir -p tools && cd tools

if [ ! -d "$(ls -d jdk-*/Contents/Home 2>/dev/null | head -1)" ]; then
  echo "==> JDK 17"
  curl -sL -o jdk.tar.gz \
    "https://api.adoptium.net/v3/binary/latest/17/ga/mac/aarch64/jdk/hotspot/normal/eclipse"
  tar xzf jdk.tar.gz && rm jdk.tar.gz
fi

if [ ! -d sdk/cmdline-tools/latest ]; then
  echo "==> Android command-line tools"
  curl -sL -o cmdline.zip \
    "https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip"
  mkdir -p sdk/cmdline-tools
  unzip -q cmdline.zip -d sdk/cmdline-tools
  mv sdk/cmdline-tools/cmdline-tools sdk/cmdline-tools/latest
  rm cmdline.zip
fi

export JAVA_HOME="$(ls -d "$PWD"/jdk-*/Contents/Home | head -1)"
SDK="$PWD/sdk"
echo "==> platform 30 + build-tools 34"
yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" --licenses >/dev/null 2>&1 || true
"$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" \
  "platforms;android-30" "build-tools;34.0.0" >/dev/null

cd ..
echo "==> Swift capture"
(cd swift && ./build.sh)
echo "==> Android client"
(cd android && ./build.sh)

echo
echo "Готово. Дальше: ./start.sh"
