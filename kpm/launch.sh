#!/bin/sh
# Toggles the Tailscale daemon. Run via `kpm launch tailscale-koplugin`, which
# is what the library scriptlet calls — so the tailnet can be brought up
# without opening KOReader at all.
#
# Shares its pidfile and socket with the KOReader plugin, so whichever one you
# use, the other reports the same state.

DEST=/mnt/us/tailscale
STATE="${DEST}/state"
LOG="${DEST}/tailscaled.log"
AUTH_KEY="${DEST}/auth.key"
PID_FILE=/tmp/tailscaled_koreader.pid
SOCKET=/tmp/tailscaled.sock
UP_LOG=/tmp/tailscale_up.log
TS_PORT=41641
HOSTNAME_ARG=kindle

TS="${DEST}/tailscale"
TSD="${DEST}/tailscaled"

is_running() {
    [ -f "${PID_FILE}" ] || return 1
    pid=$(cat "${PID_FILE}")
    [ -n "${pid}" ] && [ -d "/proc/${pid}" ]
}

if [ ! -x "${TSD}" ]; then
    echo "tailscaled is missing from ${DEST}"
    exit 1
fi

###
# Running -> stop
###
if is_running; then
    echo "Stopping Tailscale..."
    "${TS}" --socket="${SOCKET}" down 2>/dev/null

    pid=$(cat "${PID_FILE}")
    kill -TERM "${pid}" 2>/dev/null
    i=0
    while [ -d "/proc/${pid}" ] && [ ${i} -lt 20 ]; do
        sleep 1
        i=$((i + 1))
    done
    [ -d "/proc/${pid}" ] && kill -KILL "${pid}" 2>/dev/null

    iptables -D INPUT -p udp --dport ${TS_PORT} -j ACCEPT 2>/dev/null
    rm -f "${PID_FILE}" "${SOCKET}"
    echo "Tailscale stopped."
    exit 0
fi

###
# Stopped -> start
###
echo "Starting Tailscale..."
mkdir -p "${STATE}"

# No TUN device means userspace networking: outbound and inbound-to-local-ports
# still work, routing for other machines does not.
TUN=tailscale0
PROXIES=""
if [ ! -c /dev/net/tun ]; then
    TUN=userspace-networking
    PROXIES="--socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1055"
    echo "No TUN device; using userspace networking."
fi

# The INPUT policy is DROP, so let peers reach us directly instead of relaying
# everything through DERP.
iptables -A INPUT -p udp --dport ${TS_PORT} -j ACCEPT 2>/dev/null

cd "${DEST}" || exit 1
# shellcheck disable=SC2086
(./tailscaled --state="${STATE}/tailscaled.state" --statedir="${STATE}" \
    --socket="${SOCKET}" --tun="${TUN}" ${PROXIES} >>"${LOG}" 2>&1 & echo $! >"${PID_FILE}")

i=0
while [ ! -S "${SOCKET}" ] && [ ${i} -lt 20 ]; do
    sleep 1
    i=$((i + 1))
done

if ! is_running; then
    echo "tailscaled failed to start. See ${LOG}"
    exit 1
fi

UP_ARGS="up --accept-dns=false --hostname=${HOSTNAME_ARG}"
if [ -f "${AUTH_KEY}" ]; then
    UP_ARGS="${UP_ARGS} --authkey=$(cat "${AUTH_KEY}")"
fi

# `up` blocks until the node is authorized, so background it and watch for the
# login URL. An already-registered node comes up in a second or two.
rm -f "${UP_LOG}"
# shellcheck disable=SC2086
("${TS}" --socket="${SOCKET}" ${UP_ARGS} >"${UP_LOG}" 2>&1 &)

i=0
while [ ${i} -lt 15 ]; do
    sleep 2
    IP=$("${TS}" --socket="${SOCKET}" ip -4 2>/dev/null | head -1)
    case "${IP}" in
        [0-9]*)
            echo "Tailscale connected: ${IP}"
            exit 0
            ;;
    esac
    if grep -q "login.tailscale.com" "${UP_LOG}" 2>/dev/null; then
        echo "Authorize this Kindle at:"
        grep -o "https://login.tailscale.com/[^ ]*" "${UP_LOG}" | head -1
        echo "(or put a reusable auth key in ${AUTH_KEY})"
        exit 0
    fi
    i=$((i + 1))
done

echo "Daemon is up but not connected yet. See ${UP_LOG}"
exit 0
