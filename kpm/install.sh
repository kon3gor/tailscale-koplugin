#!/bin/sh
# Installs the Tailscale KOReader plugin, the Tailscale binaries it drives, and
# a library scriptlet that toggles the daemon without opening KOReader.
#
# KPM passes "upgrade" as $1 when this runs as part of an upgrade, and exports
# $KPM_PLATFORM and $KPM_VERSION_* (KPM 0.3.0+). stdout lands in the KPM log.

KOREADER_PLUGINS=/mnt/us/koreader/plugins
TAILSCALE_DIR=/mnt/us/tailscale
SCRIPTLET=/mnt/us/documents/Tailscale.sh

if [ "$1" = "upgrade" ]; then
    echo "Upgrading (state in ${TAILSCALE_DIR}/state is kept)"
fi
[ -n "${KPM_PLATFORM}" ] && echo "Platform: ${KPM_PLATFORM}"

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

# ./scriptlets is deliberately left in place: uninstall.sh compares against it
# so it never deletes a scriptlet that isn't ours.
echo "Installing library scriptlet..."
cp -f ./scriptlets/Tailscale.sh "${SCRIPTLET}"

echo "Done. Restart KOReader for Network -> Tailscale, or tap Tailscale in your library."
