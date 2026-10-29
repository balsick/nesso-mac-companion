#!/bin/sh
# Builds Nesso Hub.app and starts it. The log is ~/Library/Logs/Nesso Hub.log.
#
# It has to run as an app launched through LaunchServices: macOS charges the
# Bluetooth and Automation permissions to whichever app started a process, so a
# bare binary started from a terminal borrows the terminal's permissions, and
# is killed when the terminal has no Bluetooth usage string.
#
#   ./run.sh            build, install to /Applications, (re)start, tail the log
#   ./run.sh stop       stop it
set -e
cd "$(dirname "$0")"

# Installed outside .build: macOS is shy about permission prompts for apps that
# live in hidden folders.
APP="/Applications/Nesso Hub.app"
LOG="$HOME/Library/Logs/Nesso Hub.log"

pkill -x nesso-hub 2>/dev/null || true
[ "$1" = "stop" ] && exit 0

swift build -c release
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/nesso-hub "$APP/Contents/MacOS/nesso-hub"
cp Info.plist "$APP/Contents/Info.plist"
# Regenerate with: swift Icon/make-icon.swift Icon/AppIcon.icns
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/emoji-metadata/emoji_17_0_ordering.json "$APP/Contents/Resources/emoji-ordering.json"

# macOS ties the Bluetooth and Automation permissions to the signature. An
# ad-hoc one changes on every build, so each rebuild would lose them; a real
# certificate keeps them. NESSO_SIGN_IDENTITY picks one, otherwise the first
# Apple Development identity in the keychain, otherwise ad-hoc.
IDENTITY="${NESSO_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP" >/dev/null
# Make the Finder and the Dock pick up a changed icon.
touch "$APP"

# The app writes the log itself, so it is there however it was started.
open "$APP"
echo "started; log: $LOG"
[ "$1" = "--no-tail" ] || exec tail -n 20 -f "$LOG"
