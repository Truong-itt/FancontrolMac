#!/bin/bash
# Removes the Fan Control root helper: sudo scripts/uninstall-helper.sh
set -euo pipefail

LABEL=local.fancontrol.helper

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root: sudo $0" >&2
    exit 1
fi

# The helper returns the fans to auto by itself when it receives SIGTERM.
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL" /var/run/fancontrol.sock
echo "Removed helper $LABEL"
