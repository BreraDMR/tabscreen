#!/bin/bash
# Builds the APK without Android Studio or Gradle - just the SDK tools.
set -e
cd "$(dirname "$0")"

# Point these at your own JDK 17 and Android SDK, or let the defaults find the ones
# that setup.sh downloaded into ../tools/
TOOLS="$(cd "$(dirname "$0")/.." && pwd)/tools"
export JAVA_HOME="${JAVA_HOME:-$(ls -d "$TOOLS"/jdk-*/Contents/Home 2>/dev/null | head -1)}"
SDK="${ANDROID_HOME:-$TOOLS/sdk}"
if [ ! -x "$JAVA_HOME/bin/javac" ]; then echo "JDK не найден — запусти ../setup.sh"; exit 1; fi
if [ ! -d "$SDK/platforms" ]; then echo "Android SDK не найден — запусти ../setup.sh"; exit 1; fi
BT="$SDK/build-tools/34.0.0"
PLATFORM="$SDK/platforms/android-30/android.jar"
OUT=build

rm -rf $OUT && mkdir -p $OUT/classes

# a debug key, made once and reused
KS="$(cd "$(dirname "$0")" && pwd)/debug.keystore"
if [ ! -f "$KS" ]; then
  "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$KS" -storepass android -keypass android \
    -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
fi

"$BT/aapt2" link -o $OUT/base.apk -I "$PLATFORM" --manifest AndroidManifest.xml \
  --min-sdk-version 29 --target-sdk-version 30

"$JAVA_HOME/bin/javac" --release 11 -cp "$PLATFORM" -d $OUT/classes $(find src -name '*.java')

"$BT/d8" --lib "$PLATFORM" --output $OUT $(find $OUT/classes -name '*.class')

cd $OUT && zip -q base.apk classes.dex && cd ..
"$BT/zipalign" -f 4 $OUT/base.apk $OUT/aligned.apk
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out $OUT/tabscreen.apk $OUT/aligned.apk

echo "готово: $(pwd)/$OUT/tabscreen.apk"
ls -la $OUT/tabscreen.apk
