#!/bin/sh
# KPM passes "upgrade" as $1 when this runs as part of an upgrade. In that case
# keep /mnt/us/tailscale, so the node's saved login survives and the user is not
# sent back through the authorization URL.

KOREADER_PLUGINS=/mnt/us/koreader/plugins
TAILSCALE_DIR=/mnt/us/tailscale

echo "Stopping tailscaled if it is running..."
if [ -f /tmp/tailscaled_koreader.pid ]; then
    PID=$(cat /tmp/tailscaled_koreader.pid)
    [ -d "/proc/${PID}" ] && kill -TERM "${PID}"
    rm -f /tmp/tailscaled_koreader.pid
fi
iptables -D INPUT -p udp --dport 41641 -j ACCEPT 2>/dev/null

echo "Removing KOReader plugin..."
rm -rf "${KOREADER_PLUGINS}/Tailscale.koplugin"

if [ ! "$1" = "upgrade" ]; then
    echo "Removing Tailscale binaries and state..."
    rm -rf "${TAILSCALE_DIR}"
fi
