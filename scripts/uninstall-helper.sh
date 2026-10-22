#!/bin/zsh
# Remove chargebar-helper and make sure the charger is reconnected. Run with sudo:
#   sudo scripts/uninstall-helper.sh
set -uo pipefail

label=net.digital-shokunin.chargebar.helper
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

# bootout sends SIGTERM; the helper reconnects the charger (CHIE=0x00) before exiting.
launchctl bootout system/$label 2>/dev/null || true
rm -f /Library/LaunchDaemons/$label.plist /Library/PrivilegedHelperTools/$label

# Belt and braces: if the chie-test tool is built, use it to confirm CHIE is 0x00.
root=${0:A:h:h}
if [[ -x $root/build/smc-probe ]]; then
    $root/build/smc-probe | grep '^CHIE' || true
fi
echo "Removed $label (CHIE should read 00 above)"
