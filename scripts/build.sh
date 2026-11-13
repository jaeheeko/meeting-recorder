#!/bin/bash
# 릴리스 빌드 후 build/MeetingRecorder.app 을 조립하고 ad-hoc 서명한다. 설치는 하지 않는다.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product MeetingRecorder
BIN=$(swift build -c release --product MeetingRecorder --show-bin-path)
APP=build/MeetingRecorder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MeetingRecorder" "$APP/Contents/MacOS/MeetingRecorder"
cp Sources/MeetingRecorder/Info.plist "$APP/Contents/Info.plist"
cp Resources/* "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - --identifier com.jerryko.MeetingRecorder "$APP"
echo "built: $APP"
