#!/bin/sh
# Builds the KPM package and adds it to the publishable repo in ../repo.
#
#   ./kpm/build.sh            # uses TS_VERSION below
#   TS_VERSION=1.105.0 ./kpm/build.sh
#
# Needs python3 and kpm-helper.py from https://github.com/KindleModding/KPM
# (downloaded into vendor/ on first run).

set -e

TS_VERSION="${TS_VERSION:-1.104.2}"
TS_ARCH=arm

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="${ROOT}/vendor"
STAGE="${ROOT}/build/package"
DIST="${ROOT}/dist"
REPO="${ROOT}/repo"
HELPER="${VENDOR}/kpm-helper.py"
TARBALL="${VENDOR}/tailscale_${TS_VERSION}_${TS_ARCH}.tgz"

mkdir -p "${VENDOR}" "${DIST}" "${REPO}"

if [ ! -f "${HELPER}" ]; then
    echo "Fetching kpm-helper.py..."
    curl -fsSL -o "${HELPER}" \
        https://raw.githubusercontent.com/KindleModding/KPM/main/kpm-helper.py
fi

if [ ! -f "${TARBALL}" ]; then
    echo "Fetching Tailscale ${TS_VERSION} (${TS_ARCH})..."
    curl -fsSL -o "${TARBALL}" \
        "https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_${TS_ARCH}.tgz"
fi

if [ ! -f "${VENDOR}/LICENSE.tailscale" ]; then
    echo "Fetching Tailscale's license..."
    curl -fsSL -o "${VENDOR}/LICENSE.tailscale" \
        https://raw.githubusercontent.com/tailscale/tailscale/main/LICENSE
fi

echo "Staging package..."
rm -rf "${STAGE}"
mkdir -p "${STAGE}/tailscale"

cp "${ROOT}/kpm/manifest.json" "${STAGE}/manifest.json"
cp "${ROOT}/kpm/install.sh" "${STAGE}/install.sh"
cp "${ROOT}/kpm/uninstall.sh" "${STAGE}/uninstall.sh"
cp "${ROOT}/kpm/launch.sh" "${STAGE}/launch.sh"
cp -r "${ROOT}/kpm/scriptlets" "${STAGE}/scriptlets"
cp -r "${ROOT}/Tailscale.koplugin" "${STAGE}/Tailscale.koplugin"

# The upstream tarball unpacks to tailscale_<ver>_<arch>/{tailscale,tailscaled}.
tar xzf "${TARBALL}" -C "${STAGE}/tailscale" --strip-components=1 \
    "tailscale_${TS_VERSION}_${TS_ARCH}/tailscale" \
    "tailscale_${TS_VERSION}_${TS_ARCH}/tailscaled"
cp "${VENDOR}/LICENSE.tailscale" "${STAGE}/tailscale/LICENSE.tailscale"

# Sanity check: these must be ARM binaries, not whatever the build host runs.
file "${STAGE}/tailscale/tailscaled" | grep -q "ARM" || {
    echo "tailscaled is not an ARM binary - wrong tarball?"
    exit 1
}

echo "Packing .kpkg..."
rm -f "${DIST}"/*.kpkg
python3 "${HELPER}" package pack "${STAGE}" "${DIST}"

KPKG="$(ls "${DIST}"/*.kpkg | head -1)"
echo "Built ${KPKG}"

if [ ! -f "${REPO}/manifest.json" ]; then
    echo "No repo manifest at ${REPO}/manifest.json - skipping repo update."
    echo "Create one, then re-run to add this artifact."
    exit 0
fi

echo "Adding to repo..."
VERSION="$(python3 -c "import json;print('.'.join(str(n) for n in json.load(open('${ROOT}/kpm/manifest.json'))['version']))")"
python3 "${HELPER}" repo remove "${REPO}" tailscale-koplugin --version "${VERSION}" 2>/dev/null || true
python3 "${HELPER}" repo add "${REPO}" "${KPKG}"

echo "Done. Repo is ready to publish:"
find "${REPO}" -type f | sed "s|${ROOT}/||"
