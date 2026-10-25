#!/bin/sh
# KPM passes "upgrade" as $1 when this runs as part of an upgrade. In that case
# keep /mnt/us/tailscale, so the node's saved login survives and the user is not
# sent back through the authorization URL.
#
# Per KPM's guidelines this must not delete the package's own files in ./ --
# KPM handles that itself.

KOREADER_PLUGINS=/mnt/us/koreader/plugins
TAILSCALE_DIR=/mnt/us/tailscale
SCRIPTLET=/mnt/us/documents/Tailscale.sh

echo "Stopping tailscaled if it is running..."
if [ -f /tmp/tailscaled_koreader.pid ]; then
    PID=$(cat /tmp/tailscaled_koreader.pid)
    if [ -d "/proc/${PID}" ]; then
        "${TAILSCALE_DIR}/tailscale" --socket=/tmp/tailscaled.sock down 2>/dev/null
        kill -TERM "${PID}" 2>/dev/null
    fi
    rm -f /tmp/tailscaled_koreader.pid /tmp/tailscaled.sock
fi
iptables -D INPUT -p udp --dport 41641 -j ACCEPT 2>/dev/null

echo "Removing KOReader plugin..."
rm -rf "${KOREADER_PLUGINS}/Tailscale.koplugin"

# Only remove the scriptlet if it is still ours, byte for byte.
if [ -f "${SCRIPTLET}" ] && [ -f ./scriptlets/Tailscale.sh ]; then
    if [ "$(md5sum < "${SCRIPTLET}")" = "$(md5sum < ./scriptlets/Tailscale.sh)" ]; then
        echo "Removing library scriptlet..."
        rm -f "${SCRIPTLET}"
    else
        echo "Leaving ${SCRIPTLET} alone - it has been modified"
    fi
fi

if [ ! "$1" = "upgrade" ]; then
    echo "Removing Tailscale binaries and state..."
    rm -rf "${TAILSCALE_DIR}"
fi
