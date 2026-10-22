#!/bin/zsh
# Install (or update) chargebar-helper as a root LaunchDaemon. Run with sudo:
#   sudo scripts/install-helper.sh
# Build first with scripts/build.sh release.
set -euo pipefail

root=${0:A:h:h}
label=net.digital-shokunin.chargebar.helper
binary="$root/build/Release/chargebar-helper"
plist="$root/helper/$label.plist"
dest_bin=/Library/PrivilegedHelperTools/$label
dest_plist=/Library/LaunchDaemons/$label.plist

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
[[ -x $binary ]] || { echo "missing $binary; run scripts/build.sh release first" >&2; exit 1; }

# Stop any running copy; its SIGTERM handler reconnects the charger.
launchctl bootout system/$label 2>/dev/null || true

install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$binary" "$dest_bin"
install -o root -g wheel -m 644 "$plist" "$dest_plist"

launchctl bootstrap system "$dest_plist"
sleep 1
launchctl print system/$label | grep -E '^\s*(state|pid) ' || true
echo "Installed $label"
