#!/bin/bash
# tools/android/make_apk.sh <libmain.so> <saida.apk>
# Monta o APK de teste do LAS Recomp para Android (arm64-v8a): o projeto Gradle do SDL3 (classes Java SDLActivity),
# a libmain.so do jogo e as bibliotecas de que ela depende (SDL3, FFmpeg, shaderc, libc++_shared).
# Variaveis exigidas (o workflow define): P (pasta das dependencias, com lib/), NDK, TOOLBIN (bin do NDK).
# Opcional: ANDROID_HOME (SDK do Android), GRADLE_CMD (padrao: "sh ./gradlew").
set -euo pipefail

LIBMAIN="$(realpath "${1:?uso: make_apk.sh <libmain.so> <saida.apk>}")"
OUT="$(realpath -m "${2:?uso: make_apk.sh <libmain.so> <saida.apk>}")"
: "${P:?variavel P (dependencias) nao definida}" "${NDK:?variavel NDK nao definida}" "${TOOLBIN:?variavel TOOLBIN nao definida}"
SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
GRADLE_CMD="${GRADLE_CMD:-sh ./gradlew}"
PKG=com.lasrecomp.android

test -f "$LIBMAIN" || { echo "ERRO: $LIBMAIN nao existe"; exit 1; }
OUTDIR="$(dirname "$OUT")"
mkdir -p "$OUTDIR"

WORK="$(mktemp -d)"
echo ">>> baixando o projeto Android do SDL3"
curl -fsSL -o "$WORK/sdl.tgz" https://github.com/libsdl-org/SDL/releases/download/release-3.4.16/SDL3-3.4.16.tar.gz
echo "7322236cd12090c3eb40b9728be4d49c76f66ad17d04369584d4ecad5cf77c68  $WORK/sdl.tgz" | sha256sum -c --quiet
mkdir -p "$WORK/sdl"
tar -xzf "$WORK/sdl.tgz" -C "$WORK/sdl" --strip-components 1 SDL3-3.4.16/android-project
SDLP="$WORK/sdl/android-project"
test -f "$SDLP/gradlew" || { echo "ERRO: gradlew nao encontrado no projeto do SDL"; exit 1; }

PROJ="$WORK/proj"
APP="$PROJ/app"
mkdir -p "$APP/src/main/java/org/libsdl/app" "$APP/src/main/java/com/lasrecomp/android" "$APP/src/main/res" \
         "$APP/src/main/jniLibs/arm64-v8a"
cp -r "$SDLP/gradle" "$SDLP/gradlew" "$PROJ/"
cp "$SDLP/app/src/main/java/org/libsdl/app/"*.java "$APP/src/main/java/org/libsdl/app/"
cp -r "$SDLP/app/src/main/res/." "$APP/src/main/res/"

# versao da plataforma Android usada para compilar: 35 se o SDK a tem, senao a mais nova instalada
CSDK=35
if [ -n "$SDK_ROOT" ] && [ ! -d "$SDK_ROOT/platforms/android-35" ]; then
  FOUND="$(ls "$SDK_ROOT/platforms" 2>/dev/null | sed -n 's/^android-\([0-9][0-9]*\)$/\1/p' | sort -n | tail -n 1 || true)"
  if [ -n "$FOUND" ]; then CSDK="$FOUND"; fi
fi
echo ">>> compileSdk = $CSDK"

cat > "$PROJ/settings.gradle" <<'EOT'
include ':app'
EOT

cat > "$PROJ/gradle.properties" <<EOT
org.gradle.jvmargs=-Xmx2048m
android.useAndroidX=false
android.suppressUnsupportedCompileSdk=$CSDK
EOT

cat > "$PROJ/build.gradle" <<'EOT'
buildscript {
    repositories {
        mavenCentral()
        google()
    }
    dependencies {
        classpath 'com.android.tools.build:gradle:8.7.3'
    }
}

allprojects {
    repositories {
        mavenCentral()
        google()
    }
}
EOT

cat > "$APP/build.gradle" <<EOT
plugins {
    id 'com.android.application'
}

android {
    namespace = "$PKG"
    compileSdk $CSDK
    defaultConfig {
        applicationId "$PKG"
        minSdk 33
        targetSdk 35
        versionCode 1
        versionName "0.1"
        ndk {
            abiFilters 'arm64-v8a'
        }
    }
    lint {
        abortOnError = false
    }
}
EOT

cat > "$APP/src/main/AndroidManifest.xml" <<'EOT'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-feature android:name="android.hardware.touchscreen" android:required="false" />
    <uses-feature android:name="android.hardware.bluetooth" android:required="false" />
    <uses-feature android:name="android.hardware.gamepad" android:required="false" />
    <uses-feature android:name="android.hardware.usb.host" android:required="false" />

    <uses-permission android:name="android.permission.VIBRATE" />

    <application
        android:label="@string/app_name"
        android:icon="@mipmap/ic_launcher"
        android:allowBackup="false"
        android:theme="@style/AppTheme"
        android:enableOnBackInvokedCallback="false"
        android:hardwareAccelerated="true">

        <activity
            android:name=".MainActivity"
            android:label="@string/app_name"
            android:alwaysRetainTaskState="true"
            android:launchMode="singleInstance"
            android:screenOrientation="sensorLandscape"
            android:configChanges="layoutDirection|locale|grammaticalGender|fontScale|fontWeightAdjustment|orientation|uiMode|screenLayout|screenSize|smallestScreenSize|keyboard|keyboardHidden|navigation"
            android:preferMinimalPostProcessing="true"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
            <intent-filter>
                <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED" />
            </intent-filter>
        </activity>
    </application>

</manifest>
EOT

cat > "$APP/src/main/java/com/lasrecomp/android/MainActivity.java" <<'EOT'
package com.lasrecomp.android;

import org.libsdl.app.SDLActivity;

// SDLActivity loads libSDL3.so and libmain.so and calls SDL_main (runtime/main.c).
public class MainActivity extends SDLActivity {
}
EOT

cat > "$APP/src/main/res/values/strings.xml" <<'EOT'
<resources>
    <string name="app_name">LAS Recomp</string>
</resources>
EOT

echo ">>> reunindo as bibliotecas nativas"
JNI="$APP/src/main/jniLibs/arm64-v8a"
cp "$LIBMAIN" "$JNI/libmain.so"
for f in "$P"/lib/*.so; do cp -L "$f" "$JNI/$(basename "$f")"; done
CXXSO="$(find "$NDK" -name libc++_shared.so -path '*aarch64*' -print -quit)"
test -n "$CXXSO" || { echo "ERRO: libc++_shared.so nao encontrada no NDK"; exit 1; }
cp "$CXXSO" "$JNI/libc++_shared.so"
for f in "$JNI"/*.so; do "$TOOLBIN/llvm-strip" --strip-unneeded "$f"; done
echo "Bibliotecas no APK:"
ls -l "$JNI"

echo ">>> conferindo dependencias das bibliotecas"
MISSING=""
for f in "$JNI"/*.so; do
  for n in $("$TOOLBIN/llvm-readelf" -d "$f" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'); do
    if [ ! -f "$JNI/$n" ]; then MISSING="$MISSING $n"; fi
  done
done
echo "Dependencias fora do APK (devem ser bibliotecas do proprio Android):"
echo "$MISSING" | tr ' ' '\n' | sort -u | grep -v '^$' || echo "(nenhuma)"

echo ">>> compilando o APK com o Gradle"
cd "$PROJ"
set +e
$GRADLE_CMD --no-daemon --console=plain assembleDebug > "$OUTDIR/gradle.log" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "ERRO: o Gradle falhou (codigo $rc). Ultimas linhas:"
  tail -n 60 "$OUTDIR/gradle.log"
  exit "$rc"
fi

APK="$APP/build/outputs/apk/debug/app-debug.apk"
test -f "$APK" || { echo "ERRO: APK nao foi gerado"; tail -n 40 "$OUTDIR/gradle.log"; exit 1; }
cp "$APK" "$OUT"
echo "APK pronto: $OUT"
ls -l "$OUT"
