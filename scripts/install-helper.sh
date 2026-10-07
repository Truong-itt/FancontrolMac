#!/bin/bash
# Installs the Fan Control root helper. Must run as root:
#   sudo scripts/install-helper.sh [path-to-fancontrold] [uid]
# The app runs this script itself (with a password prompt) when you click "Install Helper…".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="${1:-$SCRIPT_DIR/../.build/release/fancontrold}"
# The user allowed to control the fans: defaults to whoever ran sudo.
ALLOWED_UID="${2:-${SUDO_UID:-}}"

LABEL=local.fancontrol.helper
BINARY=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root: sudo $0" >&2
    exit 1
fi
if [[ ! -x "$SOURCE" ]]; then
    echo "Helper not found at $SOURCE (run scripts/build.sh first)" >&2
    exit 1
fi
if [[ ! "$ALLOWED_UID" =~ ^[0-9]+$ ]]; then
    echo "Missing the uid of the user allowed to control the fans" >&2
    exit 1
fi

# Remove the running copy (if any) and wait for launchd to finish cleaning up.
launchctl bootout "system/$LABEL" 2>/dev/null || true
for _ in $(seq 1 50); do
    launchctl print "system/$LABEL" >/dev/null 2>&1 || break
    sleep 0.1
done

mkdir -p /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$SOURCE" "$BINARY"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BINARY</string>
		<string>--uid</string>
		<string>$ALLOWED_UID</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/var/log/fancontrold.log</string>
	<key>StandardErrorPath</key>
	<string>/var/log/fancontrold.log</string>
</dict>
</plist>
EOF
# launchd refuses to load a plist that group or others can write.
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootstrap system "$PLIST"
echo "Installed helper $LABEL for uid $ALLOWED_UID"
