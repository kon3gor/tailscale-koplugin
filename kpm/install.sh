#!/bin/sh
# Installs the Tailscale KOReader plugin and the Tailscale binaries it drives.

KOREADER_PLUGINS=/mnt/us/koreader/plugins
TAILSCALE_DIR=/mnt/us/tailscale

if [ ! -d /mnt/us/koreader ]; then
    echo "KOReader is not installed at /mnt/us/koreader - aborting"
    exit 1
fi

# A running daemon holds its binary open; replacing it in place would fail with
# "Text file busy". Stop it, and unlink before copying so the inode is released.
if [ -f /tmp/tailscaled_koreader.pid ]; then
    PID=$(cat /tmp/tailscaled_koreader.pid)
    if [ -d "/proc/${PID}" ]; then
        echo "Stopping the running tailscaled..."
        "${TAILSCALE_DIR}/tailscale" --socket=/tmp/tailscaled.sock down 2>/dev/null
        kill -TERM "${PID}" 2>/dev/null
        i=0
        while [ -d "/proc/${PID}" ] && [ $i -lt 20 ]; do
            sleep 1
            i=$((i + 1))
        done
        [ -d "/proc/${PID}" ] && kill -KILL "${PID}" 2>/dev/null
    fi
    rm -f /tmp/tailscaled_koreader.pid /tmp/tailscaled.sock
fi

echo "Installing Tailscale binaries to ${TAILSCALE_DIR}..."
mkdir -p "${TAILSCALE_DIR}"
rm -f "${TAILSCALE_DIR}/tailscale" "${TAILSCALE_DIR}/tailscaled"
cp ./tailscale/tailscale ./tailscale/tailscaled "${TAILSCALE_DIR}/"
cp -f ./tailscale/LICENSE.tailscale "${TAILSCALE_DIR}/"
chmod +x "${TAILSCALE_DIR}/tailscale" "${TAILSCALE_DIR}/tailscaled"
rm -rf ./tailscale

echo "Installing KOReader plugin..."
mkdir -p "${KOREADER_PLUGINS}"
rm -rf "${KOREADER_PLUGINS}/Tailscale.koplugin"
cp -rf ./Tailscale.koplugin "${KOREADER_PLUGINS}/"
rm -rf ./Tailscale.koplugin

echo "Done. Restart KOReader, then open Network -> Tailscale."
