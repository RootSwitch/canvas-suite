# Canvas Suite

> Draw your network, then watch it live. Six small self-hosted apps that
> turn a network diagram into a monitoring wall - reachability, SNMP
> health, syslog, alerting, and a single front door - each one useful
> alone, better together, and all public domain.

This repo is the suite's front door: what the apps are, and two one-shot
scripts that stand them up on a fresh Linux box in minutes.

## The apps

| App | What it does | Port |
|---|---|---|
| [**CrossCanvas**](https://github.com/RootSwitch/CrossCanvas) | The diagram editor - one folder of static files, no build, no server, no accounts. Draws the boards everything else displays. | (static) |
| [**PingCanvas**](https://github.com/RootSwitch/PingCanvas) | Turns a diagram into a live reachability wall - devices glow with ping status on a kiosk display. | 8080 / 8443 |
| [**SNMPCanvas**](https://github.com/RootSwitch/SNMPCanvas) | Polls device health over SNMP - interfaces, CPU, temperature, UPS state - graphs the history, and feeds live readings onto the wall. | 9161 |
| [**SyslogCanvas**](https://github.com/RootSwitch/SyslogCanvas) | Catches what your devices say - syslog and SNMP traps, searchable. | 9514 (web); ingest 514 + 162 udp |
| [**AlertCanvas**](https://github.com/RootSwitch/AlertCanvas) | Turns readings into notifications - thresholds, device-down, ping-down - via email, ntfy, or syslog. | 9162 |
| [**LaunchCanvas**](https://github.com/RootSwitch/LaunchCanvas) | The front door - one login, a tile for each app, single sign-on across the suite, board upload/download. | 9160 |

Everything is deliberately small: plain files, SQLite, no runtime
dependencies beyond Docker, and diagrams that never leave your network.

## Three scripts

- **`canvas-suite-setup.sh`** - the whole suite, six apps, shared data
  layout, single sign-on wired up. For the box that will be your
  monitoring hub.
- **`canvas-wall-setup.sh`** - the lightweight pair: PingCanvas +
  AlertCanvas only. A ping wall that pages you; light enough for a
  Raspberry Pi.
- **`docker-ready.sh`** - installs no application. It prepares a bare box
  for containers of this shape and then gets out of the way: Docker with
  compose v2, the daemon *enabled* (the RHEL family does not start it on
  install), your user in the docker group, host directories owned by the
  uid the containers run as, and the host firewall opened if you ask.
  Run it with `--check` first and it changes nothing, just reports.

All three are safe to re-run: they never regenerate existing secrets, never
touch existing history or certs, and a re-run after a failure resumes
where it left off.

`docker-ready.sh` is deliberately app-agnostic - the other two call the
same ground it covers, but it is equally the right first step for any
container that expects a bind mount owned by uid 1000 and a published
port. Use it, then deploy whatever you like:

```bash
bash docker-ready.sh --check
bash docker-ready.sh --ports 7777 --data /srv/appdata
```

## Quickstart

Download the script, read it, then run it - it wants sudo, so it deserves
the look-over (piping curl to bash is not the family posture):

```bash
curl -fsSLO https://raw.githubusercontent.com/RootSwitch/canvas-suite/main/canvas-suite-setup.sh
less canvas-suite-setup.sh
bash canvas-suite-setup.sh
```

Useful flags (both scripts take `--help`):

- `--scan 192.168.1.0/24[,10.50.1.0/24...]` - ping-scan your subnets and
  seed the wall with every device that answered, so the kiosk is live
  from minute one. From there the whole loop is in-app: LaunchCanvas's
  *Edit in CrossCanvas* opens the seeded board, *Upload board* publishes
  your arrangement, and SNMPCanvas's *Bulk add > From file* turns the same
  board into a polling fleet.
- `--ip ADDR` if the box has more than one NIC, `--no-tls` to skip the
  self-signed cert, `--update` to pull newer app versions on a re-run.

What the suite script sets up, in brief: installs Docker if needed, clones
the six repos into `/projects`, creates `/srv/noc-data` for all persistent
data, writes compose overrides pointing everything at it, mints secrets
(single sign-on + at-rest credential encryption - **on by default**, which
manual installs do not get), generates TLS certs, and builds and starts
the stacks. `docs/canvas-suite-setup.md` walks through it step by step,
and `docs/canvas-suite-shared-data-deploy.md` is the same layout done by
hand if you would rather see every move.
`docs/canvas-suite-test-deploy.md` is the from-scratch tutorial - firewall
guidance, VM sizing, Raspberry Pi notes, Windows options, and the
first-run password checklist live there.

**Back up your secrets:** they live in the `docker-compose.override.yml`
files under `/projects`. A database restored onto a redeploy only decrypts
with the same secrets it was written under - keep those files with your
data backups.

## Tested on

The six apps are developed and tested together; the suite as described
here is known-good as of **2026-07-23** (each repo's `main`).

- **Ubuntu Server** (Noble, fresh minimal install, 1 GB RAM / 1 vCPU)
- **Rocky Linux 9** (fresh minimal install - SELinux and firewalld in
  their default postures)
- **Raspberry Pi OS 64-bit on a Pi 3B** (1 GB RAM) - the full suite
  installs in a few minutes; the ping poller transparently runs its
  32-bit build (its base image publishes no arm64 variant)
- Debian should behave like Ubuntu (untested at time of writing); note
  the netinst installer does not add your user to `sudo` if you set a
  root password - fix that first.

Anything with `apt` or `dnf` in the Debian/Ubuntu or RHEL families should
work; anything else fails fast with a clear message rather than half-installing.

Minimums that proved out: the full suite runs comfortably in 1 GB, but
the *builds* are the hungry part - on a 1 GB box add swap first
(`CONF_SWAPSIZE=2048` on a Pi) and expect the first build to take a
while. If you are installing Ubuntu Server itself, its installer wants
1.5-2 GB during setup; install big, then shrink the VM.

## Troubleshooting

- **`Unable to find a match: docker-ce ...` on Rocky/Alma** - seen
  2026-07: Docker's `linux/rocky/*` repos were published incomplete
  upstream while `linux/centos/9` remained intact (same `.el9` binaries).
  Check whether it has been fixed before working around it; if not:
  `sudo sed -i 's|/linux/rocky/|/linux/centos/|g' /etc/yum.repos.d/docker-ce.repo`,
  `sudo dnf clean all`, install `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`,
  `sudo systemctl enable --now docker`, then re-run the script.
- **`Docker is installed but the daemon is not answering`** - the RHEL
  family does not auto-start services on install. The message says the
  fix: `sudo systemctl enable --now docker`.
- **dnf says packages are missing right after a flaky connection** - a
  partial metadata download can poison the cache: `sudo dnf clean all`
  and re-run.
- **Kernel warnings at Docker start on Rocky 9** (`nft_compat`,
  `ip_set`, `br_netfilter`) - expected deprecation notices, harmless.
- **Updating later**: re-run the script with `--update`, or per app:
  `cd /projects/<app> && git pull && docker compose up -d --build`
  (PingCanvas also wants `bash docker/build-web.sh` first; CrossCanvas
  is a build input with no container - just pull it).

## License

Everything here, like every app in the suite, is released into the public
domain under [the Unlicense](LICENSE). Use it, fork it, sell it, no
attribution needed.

That covers **our code**. A container image is a compilation: it also holds an
OS userland, a JavaScript runtime and npm packages under their own licences
(mostly MIT, plus GPL-2.0 for BusyBox from the Alpine base). A public-domain
dedication cannot relicense any of that. If you redistribute the images, ship
them inside a product, or need to answer a compliance question,
[THIRD-PARTY.md](THIRD-PARTY.md) lists what is inside, where the notices live,
and how to get source for the GPL components. Building from source with
`build: .` sidesteps the question entirely.
