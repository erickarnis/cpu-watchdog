#!/bin/zsh
# Install / uninstall the cpu-watchdog launchd agent.
#   ./install.sh            install (or reinstall) and start
#   ./install.sh uninstall  stop and remove
set -e
LABEL=local.cpu-watchdog
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
HERE=${0:A:h}

launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true

if [[ $1 == uninstall ]]; then
  rm -f "$DEST"
  echo "Removed $LABEL. (Log/state kept in ~/Library/Application Support/cpu-watchdog)"
  exit 0
fi

mkdir -p "$HOME/Library/Application Support/cpu-watchdog" "$HOME/Library/LaunchAgents"
chmod +x "$HERE/cpu-watchdog.sh"
sed -e "s|__SCRIPT__|$HERE/cpu-watchdog.sh|" -e "s|__HOME__|$HOME|" "$HERE/$LABEL.plist" > "$DEST"
launchctl bootstrap gui/$(id -u) "$DEST"
echo "Installed $LABEL — checks every 5 minutes."
echo "Log: ~/Library/Application Support/cpu-watchdog/watchdog.log"
