# Canvas suite - test deployment guide

CLI-focused instructions for standing up the whole family on one box:

| Project | What it does | Ports |
|---|---|---|
| [CrossCanvas](https://github.com/RootSwitch/CrossCanvas) | draws the network diagram (served by PingCanvas's web container) | - |
| [PingCanvas](https://github.com/RootSwitch/PingCanvas) | turns the diagram into a live reachability wall | 8080/tcp web, 8443/tcp HTTPS |
| [SNMPCanvas](https://github.com/RootSwitch/SNMPCanvas) | SNMP polling, history, graphs; feeds live values onto the wall | 9161/tcp web |
| [SyslogCanvas](https://github.com/RootSwitch/SyslogCanvas) | syslog + SNMP trap receiver | 9514/tcp web, 514/udp, 162/udp |
| [AlertCanvas](https://github.com/RootSwitch/AlertCanvas) | threshold alerting on SNMPCanvas's export (email/ntfy/syslog) | 9162/tcp web |
| [LaunchCanvas](https://github.com/RootSwitch/LaunchCanvas) | the suite's front door: one login (opt-in SSO), tile launcher, board upload, quickstart docs | 9160/tcp web |

Everything below assumes a **bridged** virtual NIC, so the VM gets its own
address on your LAN. That matters twice: the ping poller needs to reach your
devices directly, and your devices need a stable address to send syslog to.

This is a test/homelab guide. The suite is designed for a trusted LAN - do not
expose any of these ports to the internet (syslog and SNMP are unauthenticated
UDP, and the suite's own docs say the same thing louder).

---

## Part 1 - Ubuntu VM

### VM sizing

| Resource | Minimum | Comfortable |
|---|---|---|
| vCPU | 1 | 2 |
| RAM | 2 GB | 4 GB |
| Disk | 20 GB | 32 GB |
| NIC | bridged | bridged |

The suite itself is small (six containers, one SQLite file each for the four
backends). The disk number is mostly OS + Docker images + headroom; message
history is bounded by design (SyslogCanvas prunes at 90 days and hard-caps at
500k rows).

### ISO and install choices

Use **Ubuntu Server 24.04 LTS** (Desktop works identically - you'll just run
the same commands in its terminal - but Server is the right shape for an
always-on box).

During the installer:

- **Type of install:** Ubuntu Server (the default, not "minimized")
- **Network:** DHCP is fine for a test. Note the IP it gets, and ideally give
  it a DHCP reservation in your router - syslog senders and your bookmarks
  both want a stable address
- **Storage:** Use entire disk, defaults are fine
- **Profile:** your user/hostname of choice
- **SSH:** **install OpenSSH server = yes** (you will do everything else over
  ssh)
- **Featured server snaps: select NOTHING.** In particular do NOT tick the
  Docker snap - the snap-packaged Docker has confined filesystem access and
  breaks bind mounts in confusing ways. We install Docker properly below.

Reboot, log in (or ssh in), and continue.

### Update and install packages

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y git docker.io docker-compose-v2
sudo usermod -aG docker $USER
# log out and back in (or: newgrp docker) so the group takes effect
```

That's the whole dependency list. Verify:

```bash
docker --version && docker compose version
```

Two harmless things you may hit later, noted here so they don't stop you:

- During `docker compose up --build`: `WARN ... configured to build using Bake,
  but buildx isn't installed`. Cosmetic - Compose falls back to the classic
  builder and the build completes. Silence it with `sudo apt install -y
  docker-buildx`, and confirm containers came up with `docker compose ps`.
- `./some-script.sh: Permission denied` - the script lost its executable bit
  (an older clone, or a box that strips it). `chmod +x <script>`, or run it as
  `sh <script>`.

### Directory layout and clones

One parent directory, five sibling clones. The sibling layout is load-bearing:
PingCanvas's build script finds CrossCanvas automatically at `../crosscanvas`.

```bash
mkdir -p ~/canvas && cd ~/canvas
git clone https://github.com/RootSwitch/CrossCanvas.git crosscanvas
git clone https://github.com/RootSwitch/PingCanvas.git pingcanvas
git clone https://github.com/RootSwitch/SNMPCanvas.git snmpcanvas
git clone https://github.com/RootSwitch/SyslogCanvas.git syslogcanvas
git clone https://github.com/RootSwitch/AlertCanvas.git  alertcanvas
git clone https://github.com/RootSwitch/LaunchCanvas.git launchcanvas
```

### PingCanvas (+ CrossCanvas editor)

```bash
cd ~/canvas/pingcanvas
./docker/build-web.sh          # assembles the web root from ../crosscanvas
mkdir -p data
docker compose up -d --build
```

The web container serves both the CrossCanvas editor and the kiosk. The poller
runs with host networking and `NET_RAW` so it can actually ping your LAN.

**Optional - HTTPS.** PingCanvas serves HTTPS on a *separate* port (8443); 8080
stays HTTP. Generate a self-signed cert (or drop your own
`fullchain.pem` + `privkey.pem` into `./certs`), then restart the web container:

```bash
cd ~/canvas/pingcanvas
./docker/gen-selfsigned-cert.sh <vm-ip-or-hostname>   # -> ./certs/{fullchain,privkey}.pem
docker compose restart web                            # NOT `up -d` - see note
```

Use `docker compose restart web`, not `up -d`: nothing compose *tracks* changed,
so `up -d` won't recreate the container and the entrypoint won't re-scan for the
cert. It's then reachable at `https://<vm-ip>:8443/`. A self-signed cert makes
browsers warn once - trust it on the kiosk machine, or front PingCanvas with a
reverse proxy (Caddy) for real PKI.

### SNMPCanvas

```bash
cd ~/canvas/snmpcanvas
mkdir -p data && sudo chown 1000:1000 data     # container runs as uid 1000
docker compose up -d --build
```

**Recommended before first start: `SNMPCANVAS_SECRET`.** It AES-encrypts the SNMP
credentials at rest, and setting it *before you add any devices* means every
credential is encrypted from its first write - no re-entry later. Uncomment it in
`docker-compose.yml` (or add it to a `docker-compose.override.yml`), and while
you're there `ADMIN_PASSWORD`:

```yaml
    environment:
      - SNMPCANVAS_SECRET=<a-long-random-string>   # generate with: openssl rand -base64 32
      - ADMIN_PASSWORD=<your-admin-password>
```

Keep the secret safe and back it up: it's the *only* thing that decrypts those
credentials, so losing it means re-entering every device's community/keys, and
moving the database to another box requires carrying the same secret. (Setting it
on an *existing* database doesn't retroactively encrypt what's already stored -
you'd re-save each device's credentials to encrypt them - which is why setting it
before you add devices is the tidy path.)

**Optional - HTTPS.** Unlike PingCanvas, SNMPCanvas serves HTTPS on the *same*
port (9161) the moment a cert exists - no extra port or firewall rule. Generate
a self-signed one into `./data/certs` (or drop your own `server.crt` +
`server.key` there), then restart:

```bash
cd ~/canvas/snmpcanvas
./tools/gen-cert.sh <vm-ip-or-hostname>
docker compose restart
```

`https://<vm-ip>:9161/` then; browsers warn once on the self-signed cert.

### SyslogCanvas

```bash
cd ~/canvas/syslogcanvas
mkdir -p data && sudo chown 1000:1000 data && sudo chmod 750 data
docker compose up -d --build
```

The `chmod 750` matters here: this directory holds your full message history.

**Optional - HTTPS.** Same model as SNMPCanvas: HTTPS on the *same* web port
(9514) once a cert exists in `./data/certs`. (This only secures the web UI - the
syslog/trap *listeners* on 514/162 are plain UDP regardless; keep them on a
trusted LAN.)

```bash
cd ~/canvas/syslogcanvas
./tools/gen-cert.sh <vm-ip-or-hostname>
docker compose restart
```

`https://<vm-ip>:9514/` then; browsers warn once on the self-signed cert.

### AlertCanvas

```bash
cd ~/canvas/alertcanvas
mkdir -p data && sudo chown 1000:1000 data
docker compose up -d --build
```

Its stock compose reads the feed from the sibling checkout's data dir
(`../snmpcanvas/data`, mounted read-only at `/status`), which is exactly the
layout this guide builds - so it works with no override. Open
`http://<vm-ip>:9162`, set a password, and the Watching page should already
list everything SNMPCanvas exports. Remember the rule that governs all of
its alerting: only exported values can alarm (see its README's "Exporting
is what arms alerting"). HTTPS follows the same model as the others:
`./tools/gen-cert.sh <vm-ip>` then `docker compose restart`.

### LaunchCanvas

```bash
cd ~/canvas/launchcanvas
mkdir -p data && sudo chown 1000:1000 data
docker compose up -d --build
```

Open `http://<vm-ip>:9160`, create the first account, and you have the
suite's front door: a tile per app, the in-app Quickstart, and board upload
(its stock compose mounts `../pingcanvas/data` at `/boards`, which is
exactly this guide's layout - uploads land where the kiosk reads). To turn
on single sign-on, generate one secret (`openssl rand -base64 32`) and set
`SUITE_SECRET=<value>` in the `environment:` of LaunchCanvas, SNMPCanvas,
SyslogCanvas, and AlertCanvas (override files keep it out of git), then
restart the four - the tiles now open the siblings already logged in. HTTPS:
`./tools/gen-cert.sh <vm-ip>` then `docker compose restart`, and keep the
suite all-HTTP or all-HTTPS so the SSO cookie travels.

### Wire SNMPCanvas into the wall (optional, the fun part)

SNMPCanvas writes an `snmp-status.json` export; if PingCanvas's kiosk can read
it, your diagram gains live link bandwidth and host metrics. Give SNMPCanvas a
second volume pointing at PingCanvas's data directory - as an override file, so
`git pull` never conflicts with it:

```bash
cat > ~/canvas/snmpcanvas/docker-compose.override.yml <<'EOF'
services:
  snmpcanvas:
    volumes:
      - ../pingcanvas/data:/export:z
EOF
cd ~/canvas/snmpcanvas && docker compose up -d
```

Then in the SNMPCanvas UI: **Settings -> export path** ->
`/export/snmp-status.json`. Every exported interface and sensor shows a
`{CODE}` chip in the UI - copy it, paste it onto a connection annotation or a
device label line in the editor, and the kiosk swaps in the live value.

### Firewall

Ubuntu Server ships with `ufw` installed but **inactive**, so everything above
already works. If you want it on, one honest caveat first: **Docker publishes
container ports via its own iptables rules, which bypass ufw** - so ufw rules
for the container ports are largely cosmetic on a default Docker install. The
real access control for this suite is "keep the box on a trusted LAN."

That said, for tidiness:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 8080/tcp   # PingCanvas web (editor + kiosk)
sudo ufw allow 8443/tcp   # PingCanvas HTTPS (only live once a cert exists)
sudo ufw allow 9160/tcp   # LaunchCanvas portal
sudo ufw allow 9161/tcp   # SNMPCanvas
sudo ufw allow 9162/tcp   # AlertCanvas
sudo ufw allow 9514/tcp   # SyslogCanvas web
sudo ufw allow 514/udp    # syslog in
sudo ufw allow 162/udp    # SNMP traps in
sudo ufw enable
```

SNMP *polling* is outbound (UDP/161 toward your devices) and needs no rule.

### URLs

Replace `<vm-ip>` with the VM's address:

| What | URL |
|---|---|
| CrossCanvas editor | `http://<vm-ip>:8080/index.html` |
| PingCanvas kiosk | `http://<vm-ip>:8080/kiosk.html` |
| Kiosk + all feeds | `http://<vm-ip>:8080/kiosk.html?board=data/board.xcanvas&status=data/status.json&snmp=data/snmp-status.json` |
| SNMPCanvas | `http://<vm-ip>:9161` |
| SyslogCanvas | `http://<vm-ip>:9514` |

If you enabled HTTPS (the optional steps above), swap `http` -> `https`; the
ports are unchanged except PingCanvas, which moves to **8443** (8080 stays HTTP).

### First-run checklist

1. **Visit SNMPCanvas and SyslogCanvas immediately** and set their admin
   passwords. Both offer a first-run setup page, and whoever reaches it first
   owns the instance - claim it before something else on your LAN does (or
   pre-set `ADMIN_PASSWORD` in the compose files and skip the race).
2. **Draw a board.** Open the editor, draw a few devices (or File -> Load
   Sample), and give each one an `IP-Address` in Device Details - that field
   is the monitoring opt-in. Title the diagram "board", Save, then copy the
   downloaded file to the server:
   ```bash
   scp ~/Downloads/board.xcanvas <user>@<vm-ip>:~/canvas/pingcanvas/data/
   ```
   The kiosk picks it up on refresh; the poller discovers it within a cycle.
3. **Point a device's syslog at the box** (`<vm-ip>:514`, UDP) and watch it
   appear in SyslogCanvas. `tools/seed-demo.js` can fake a fleet if you just
   want to see the UI populated.
4. **Add a device in SNMPCanvas** (v2c community or v3), tick **Export** on
   the interfaces you care about, and paste the `{CODE}` chips onto the board.

### Updating later

```bash
cd ~/canvas/crosscanvas && git pull
cd ~/canvas/pingcanvas && git pull && ./docker/build-web.sh && docker compose up -d --build
cd ~/canvas/snmpcanvas && git pull && docker compose up -d --build
cd ~/canvas/syslogcanvas && git pull && docker compose up -d --build
```

(All repos publish ordinary incremental history on `main` as of 2026-07-22, so
plain `git pull` is the whole story. A clone made before that date may refuse
to pull for PingCanvas/CrossCanvas - re-clone once. Your `data/` directories
and any `docker-compose.override.yml` are untracked and survive all of this.)

---

## Part 2 - Raspberry Pi / ARM64

The suite runs on a Raspberry Pi (or any ARM64 box). Follow Part 1 as written -
the compose files are identical and all four images build on arm64 - with two
Raspberry Pi OS caveats:

- **Use a 64-bit OS** (recommended; tested on a Pi 3B). The PowerShell poller
  base image publishes no arm64 build - Docker transparently pulls its 32-bit
  arm/v7 build, which a 64-bit kernel runs natively (verified: the built image
  reports arm v7 and runs healthy). A 32-bit Pi OS also works: every image in
  the pair has a native arm/v7 variant. Raspberry Pi Imager -> Raspberry Pi OS
  **Lite (64-bit)**; enable SSH and set your user in the gear-icon
  customization, then ssh in.
- **Install Docker via the convenience script**, because Debian/Raspberry Pi
  OS's packaged compose is the old v1 and chokes on these compose files:

  ```bash
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker $USER    # log out / back in
  ```

Then pick up Part 1 from "Directory layout" onward. On a Pi 4/5 with 2 GB+ it
behaves like the Ubuntu VM. Storage: any decent A1/A2 SD card works (the suite's
write load is bounded), but a USB SSD improves it. Firewall: Raspberry Pi OS
ships none enabled, so the Part 1 firewall note applies unchanged.

Same URLs as Part 1, with the Pi's address.

---

## Part 3 - Windows

The short version: **PingCanvas is Windows-native; the other two are not, and
that's your cue to try virtualization.**

**Option A - the recommended one: a VM, using Part 1.** Hyper-V is built into
Windows 10/11 Pro (`Turn Windows features on or off` -> Hyper-V); VirtualBox
covers Home. Create the VM with an **External** virtual switch (Hyper-V's name
for bridged), boot the Ubuntu Server ISO, and follow Part 1 exactly. This is
the same shape you'd use for any self-hosted service, and it is the config
these two backends were built for.

**Option B - PingCanvas natively, the rest elsewhere.** PingCanvas genuinely
supports Windows as a first-class host: a PowerShell poller running as a
scheduled task plus a static site under IIS. See `QUICKSTART-WINDOWS.md` in
the PingCanvas repo - it's the documented path, not a workaround. You can then
point its kiosk at an SNMPCanvas running on any Linux box (or the VM from
Option A) for the `?snmp=` overlay.

**Option C - the whole suite under Docker Desktop: fine for an afternoon,
wrong for always-on.** It works, with caveats worth knowing up front:

- Edit `pingcanvas/docker-compose.yml` and **remove the `network_mode: host`
  line** from the poller (the file's own comment says so - host networking is
  Linux-only). ICMP behavior through the Docker Desktop VM is also less
  faithful; expect the reachability wall to be more approximate than on Linux.
- UDP 514/162 port mappings pass through Docker Desktop's proxy - functional,
  but another layer of indirection for exactly the traffic you're debugging.
- Docker Desktop wants a logged-in user session and periodic restarts, which
  is the opposite of what a monitoring box should want.

If Option C is the step that makes someone go "actually, an old thin client
running Ubuntu would do this better" - that's the intended outcome.

---

## Quick reference - all URLs

| Service | URL | First visit |
|---|---|---|
| LaunchCanvas portal | `http://<ip>:9160` | **start here** - create the first account; the tiles and Quickstart do the rest |
| CrossCanvas editor | `http://<ip>:8080/index.html` | draw a board, add IP-Address fields |
| PingCanvas kiosk | `http://<ip>:8080/kiosk.html` | shows a getting-started page until a board exists |
| Kiosk, fully wired | `http://<ip>:8080/kiosk.html?board=data/board.xcanvas&status=data/status.json&snmp=data/snmp-status.json` | the wall |
| SNMPCanvas | `http://<ip>:9161` | **set the admin password immediately** |
| SyslogCanvas | `http://<ip>:9514` | **set the admin password immediately** |
| AlertCanvas | `http://<ip>:9162` | **set the admin password immediately** |

Syslog target for your devices: `<ip>:514` UDP. Trap target: `<ip>:162` UDP.

HTTPS is optional and per-project (see each section's "Optional - HTTPS" step).
Once enabled: PingCanvas moves to `https://<ip>:8443/`, while the Node apps
serve HTTPS on their same ports (`https://<ip>:9160/`, `:9161/`, `:9162/`,
`:9514/`). All self-signed certs warn once per browser - expected on a lab
box. If you use SSO, go all-HTTP or all-HTTPS so the cookie travels.
