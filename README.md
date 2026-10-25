# Tailscale for KOReader on Kindle

A KOReader plugin that runs [Tailscale](https://tailscale.com) on a jailbroken
Kindle. It manages `tailscaled`, walks you through authorizing the device, and
reports the address you were given — all from **Network → Tailscale** inside
KOReader, with no terminal.

Once connected, anything listening on the Kindle is reachable from the rest of
your tailnet. Pair it with KOReader's own SSH server and you have a shell on
your Kindle from anywhere, without port forwarding.

## Requirements

- A jailbroken Kindle with [KPM](https://github.com/KindleModding/KPM)
- KOReader 2026.07 or newer, installed at `/mnt/us/koreader`
- A Tailscale account
- Roughly 70 MB free on the user partition

Built and tested on a Kindle Paperwhite (12th gen) running firmware 5.17.1.0.4,
`kindlehf`, KOReader v2026.07.1, Tailscale 1.104.2. The bundled Tailscale build
is the unmodified upstream `linux/arm` binary, statically linked, so the
device's libc is irrelevant. `kindlepw2` devices are untested but likely work;
reports welcome.

## Install

### With KPM

`;kpm add-repo` cannot be run from the Kindle search bar — the Kindle's
`scriptExecutor` rejects arguments containing `:` and `.`, so the command never
reaches KPM. Add the repo from kterm or a scriptlet instead:

```sh
/var/local/kmc/bin/kpm add-repo https://raw.githubusercontent.com/kon3gor/tailscale-koplugin/main/repo/manifest.json
/var/local/kmc/bin/kpm update
```

After that the search bar works normally:

```
;kpm install tailscale-koplugin
```

Restart KOReader when it finishes.

### By hand

Copy `Tailscale.koplugin/` into `/mnt/us/koreader/plugins/`, then put the
`tailscale` and `tailscaled` binaries for `linux/arm` from
[pkgs.tailscale.com](https://pkgs.tailscale.com/stable/) into
`/mnt/us/tailscale/` and `chmod +x` them. The plugin disables itself if
`/mnt/us/tailscale/tailscaled` is missing.

## Use

**Network → Tailscale**:

| Entry | What it does |
| --- | --- |
| Tailscale daemon | Starts or stops `tailscaled` |
| Connect | Runs `tailscale up` and shows the authorization URL to open elsewhere |
| Disconnect | `tailscale down`, leaving the daemon running |
| Status | Your tailnet address, the mode in use, and peer summary |
| View daemon log | Last lines of `/mnt/us/tailscale/tailscaled.log` |
| Hostname | Name this device registers under (default `kindle`) |
| Auth key | A pre-auth key from the admin console, to skip the URL entirely |
| Userspace networking | See below |
| Start daemon with KOReader | Brings the daemon up when KOReader launches |

The KPM package also installs a **Tailscale** scriptlet in your library. Tapping
it toggles the daemon without opening KOReader — useful after a reboot when you
want to SSH in over the tailnet and nothing is running yet. It shares its
pidfile and socket with the plugin, so both always agree on the state, and it
reads a reusable auth key from `/mnt/us/tailscale/auth.key` if you put one
there.

The login is stored in `/mnt/us/tailscale/state`, so you authorize once. A
"Toggle Tailscale" action is registered with KOReader's dispatcher, so you can
bind it to a gesture or key.

### TUN vs userspace networking

With a TUN device the plugin runs Tailscale normally: a `tailscale0` interface,
real routing, inbound and outbound both working.

Without one it falls back to `--tun=userspace-networking`, which still gives
outbound connections and inbound connections to local ports (so SSH over the
tailnet works), but cannot route traffic on behalf of other machines — no exit
node, no subnet router. A SOCKS5 and HTTP proxy are exposed on `localhost:1055`
in that mode.

The plugin picks the mode automatically by checking for `/dev/net/tun`, and the
menu lets you override it. To check your own device:

```sh
grep tun /proc/misc        # "200 tun" means the driver is loaded
cat /dev/net/tun           # "File descriptor in bad state" is the healthy answer
```

### Notes

- The plugin passes `--accept-dns=false`, so Tailscale never rewrites
  `/etc/resolv.conf` — which matters on a read-only Kindle rootfs.
- It opens UDP 41641 in the Kindle's firewall while the daemon runs (the INPUT
  policy is `DROP`) and closes it again on stop, so peers can connect directly
  instead of relaying everything through DERP.
- Kindles ship no `ip6tables`; Tailscale logs a complaint about IPv6 netfilter
  and carries on over IPv4.
- The Kindle's resolver is an IPv6 link-local address that Go cannot use, so the
  first DNS lookup in the log fails and Tailscale falls back to bootstrap DNS.
  Harmless.
- The pidfile and socket live in `/tmp`, so a device reboot leaves the daemon
  stopped. Start it from the menu, or enable autostart. Your login survives.
- `;kpm uninstall koreader` removes `/mnt/us/koreader` wholesale, this plugin
  included.

## Troubleshooting

| Symptom | Where to look |
| --- | --- |
| No Tailscale entry in the menu | `koreader/crash.log`, and Tools → Plugin management |
| Daemon won't start | `/mnt/us/tailscale/tailscaled.log` |
| Connect times out | `/tmp/tailscale_up.log` |

## Building a release

```sh
./kpm/build.sh                      # or: TS_VERSION=1.105.0 ./kpm/build.sh
```

That fetches `kpm-helper.py` and the Tailscale tarball into `vendor/`, stages
the package, packs `dist/tailscale-koplugin_<version>_kindlehf.kpkg`, and adds
it to `repo/`.

`repo/manifest.json` references artifacts by relative path, so publishing
`repo/` anywhere static (GitHub Pages, for instance) gives you a working KPM
repo, at the cost of a ~36 MB binary per release in git history. To keep the
repository lean instead, upload the `.kpkg` as a GitHub release asset and
replace that relative `url` with the absolute release URL.

Bump `version` in `kpm/manifest.json` for each release. `uninstall.sh` keeps
`/mnt/us/tailscale` when KPM passes `upgrade`, so upgrades don't cost users
their login.

## License

AGPL-3.0, matching KOReader, whose plugin API this builds on and whose
`SSH.koplugin` served as the model. See [LICENSE](LICENSE).

The bundled Tailscale binaries are unmodified upstream builds, BSD-3-Clause;
their license ships alongside them as `LICENSE.tailscale` and is installed to
`/mnt/us/tailscale/`.
