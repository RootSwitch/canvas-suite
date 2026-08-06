# Canvas suite - shared-data deployment (compose overrides)

A variation of the main test-deploy guide for when you want **all persistent
data in one place, outside the git checkouts**, wired up with
`docker-compose.override.yml` files. This is the layout for a box like a Rocky
Linux host with the repos under `/opt/canvas-suite` and history under `/srv/canvas-suite`.

Why do it this way:

- **Outputs co-located.** PingCanvas's status files and SNMPCanvas's export
  land in the same folder, so the kiosk reads both (via their sanitized
  `.wall` copies - the full files stay in the unserved `.private/`).
- **History lives outside the repos.** Databases and status files sit in
  `/srv/canvas-suite`, not inside `/opt/canvas-suite/*`, so a `git pull` or a rebuild can
  never clobber them and you can't wipe them by cleaning a checkout.
- **Overrides, not edits.** `docker-compose.override.yml` is untracked, so it
  survives every update and never conflicts with a pull.

It assumes you've read the main guide (VM sizing, package install, firewall,
first-run) - this only changes *where the volumes point*. Rocky/RHEL/Fedora is
SELinux-enforcing, so every bind mount below carries `:z` (relabel for container
access); harmless elsewhere.

---

## Safe co-location (requires PingCanvas >= 2026-07-19)

PingCanvas's web tier serves its bind-mounted data dir as static files (the
kiosk fetches the board + status JSON from it). That used to make a *shared*
data dir dangerous: a co-located `snmpcanvas.db` or a TLS `server.key` would be
downloadable at `http://<box>:8080/data/<name>`.

As of the 2026-07-19 build, the web tier **returns 404 for databases, keys,
certs, and secrets** (`.db`/`.db-wal`/`.db-shm`/`.key`/`.pem`/`.crt`/... and
hidden files), so a shared folder is safe by default - only the board and status
JSON, which the kiosk fetches anyway, are served. **Make sure you're on that
build or newer** (rebuild with `./docker/build-web.sh && docker compose up -d
--build`); the verify step at the end confirms it. On an older build, keep
sensitive files out of the shared dir.

---

## Layout

Everything under one folder. `.private/` holds the SOURCES - the full board
and the full feeds, which name every device - and the web tier never serves
dot-paths; the served root carries only the sanitized `.wall` copies the
kiosk reads, so a kiosk URL exposes no more than the picture shows:

```
/srv/canvas-suite/
├── .private/
│   ├── board.xcanvas          you place this; the poller + portal read it
│   ├── status.json            PingCanvas poller writes (+ status-all.json)
│   └── snmp-status.json       SNMPCanvas's FULL export (AlertCanvas reads it)
├── board.wall.xcanvas         poller writes: hidden device fields stripped
├── status.wall.json           poller writes: label-named, opaque-keyed
├── snmp-status.wall.json      SNMPCanvas writes: codes + values only
├── snmpcanvas.db (+ -wal/-shm)   SNMPCanvas history (served? no - 404'd)
└── certs/
    ├── server.crt  server.key         SNMPCanvas HTTPS
    └── fullchain.pem  privkey.pem      PingCanvas HTTPS (different names, no clash)

/srv/canvas-suite/syslogcanvas/    SyslogCanvas gets its OWN subdir - see note
├── syslogcanvas.db
└── certs/  server.crt  server.key

/srv/canvas-suite/alertcanvas/     AlertCanvas likewise (same cert filenames)
├── alertcanvas.db
└── certs/  server.crt  server.key

/srv/canvas-suite/launchcanvas/    LaunchCanvas likewise (same cert filenames)
├── launchcanvas.db
└── certs/  server.crt  server.key
```

**Why SyslogCanvas is separate:** it uses the same cert filenames as SNMPCanvas
(`server.crt`/`server.key`). Two services writing those into one `certs/` would
share (clobber) a single cert. Its own subdir gives it its own cert. PingCanvas
doesn't collide - its cert is `fullchain.pem`/`privkey.pem` - so it can share
`/srv/canvas-suite/certs` with SNMPCanvas. (You *could* let SNMPCanvas and
SyslogCanvas share one host cert since it's the same box, but a subdir is
tidier and lets each present its own.)

---

## One-time setup

The four Node apps run as **uid 1000** inside their containers; the PingCanvas poller
runs as root. So the dirs those apps write to must be owned by uid 1000 (root
writes regardless). Your first login user is usually uid 1000 - check `id -u`.

```bash
# the shared data root, owned by the container apps' uid (1000)
sudo mkdir -p /srv/canvas-suite/certs /srv/canvas-suite/.private /srv/canvas-suite/syslogcanvas/certs /srv/canvas-suite/alertcanvas/certs /srv/canvas-suite/launchcanvas/certs
sudo chown -R 1000:1000 /srv/canvas-suite

# the repo root - make it yours so you can clone without sudo
sudo mkdir -p /opt/canvas-suite && sudo chown "$USER:$USER" /opt/canvas-suite

cd /opt/canvas-suite
git clone https://github.com/RootSwitch/CrossCanvas.git crosscanvas
git clone https://github.com/RootSwitch/PingCanvas.git  pingcanvas
git clone https://github.com/RootSwitch/SNMPCanvas.git  snmpcanvas
git clone https://github.com/RootSwitch/SyslogCanvas.git syslogcanvas
git clone https://github.com/RootSwitch/AlertCanvas.git  alertcanvas
git clone https://github.com/RootSwitch/LaunchCanvas.git launchcanvas

cp your-board.xcanvas /srv/canvas-suite/.private/board.xcanvas
```

(A board at the served root still works - it is simply served in full. The
`.private` location is what makes the poller publish the sanitized `.wall`
pair instead; see PingCanvas's DEPLOY.md.)

---

## The override files

Each goes next to that project's `docker-compose.yml`. They're untracked, so a
`git pull` never touches them.

### PingCanvas - `/opt/canvas-suite/pingcanvas/docker-compose.override.yml`

```yaml
services:
  web:
    volumes:
      - /srv/canvas-suite:/usr/share/nginx/html/data:ro,z
      - /srv/canvas-suite/certs:/etc/nginx/certs:ro,z
  poller:
    volumes:
      - /srv/canvas-suite:/data:z
```

List **both** web mounts. Compose merges volume lists by container target, so a
data-only override leaves the base `./certs` mount in the repo dir; naming both
moves the certs into the shared folder too. (Omit the certs line if you'd rather
keep PingCanvas's certs under `/opt/canvas-suite/pingcanvas/certs` - that works fine.)

### SNMPCanvas - `/opt/canvas-suite/snmpcanvas/docker-compose.override.yml`

```yaml
services:
  snmpcanvas:
    volumes:
      - /srv/canvas-suite:/data:z
    environment:
      - TZ=America/New_York
      - SNMPCANVAS_SECRET=<a-long-random-string>   # generate with: openssl rand -base64 32
      - SNMPCANVAS_EXPORT=/data/.private/snmp-status.json   # full feed: unserved
```

`SNMPCANVAS_SECRET` AES-encrypts the SNMP credentials at rest. **Set it before
you add any devices** so every credential is encrypted from its first write.
Guard it: it's the only thing that decrypts those credentials, so back it up -
losing it means re-entering every device's community/keys, and moving the
database elsewhere requires carrying the same secret. (Setting it on an existing
database doesn't retroactively encrypt what's already stored; you'd re-save each
device's credentials to encrypt them.)

`SNMPCANVAS_EXPORT` sends the full export - which names every monitored
device - into `.private`, where AlertCanvas reads it and the web tier never
serves it. The anonymized wall copy (`snmp-status.wall.json`, codes + values
only) lands at the served root by default; that is the file the kiosk reads.
(SNMPCanvas serves its UI on 9161 from its own `public/` dir, never from
`/data`, so its database isn't web-exposed by SNMPCanvas itself; the
PingCanvas 404 rules cover the one path that could have served it.)

### SyslogCanvas - `/opt/canvas-suite/syslogcanvas/docker-compose.override.yml`

```yaml
services:
  syslogcanvas:
    volumes:
      - /srv/canvas-suite/syslogcanvas:/data:z
    environment:
      - TZ=America/New_York
```

### AlertCanvas - `/opt/canvas-suite/alertcanvas/docker-compose.override.yml`

```yaml
services:
  alertcanvas:
    volumes:
      - /srv/canvas-suite/alertcanvas:/data:z
      - /srv/canvas-suite:/status:ro,z
    environment:
      - TZ=America/New_York
      - ALERTCANVAS_SECRET=<a-long-random-string>   # generate with: openssl rand -base64 32
      - STATUS_FILE=/status/.private/snmp-status.json        # the FULL SNMP feed
      - PING_STATUS_FILE=/status/.private/status-all.json    # the full ping feed
```

The second mount is the feed: a read-only view of the shared root. Alert
text needs device names, so both feed paths point at the full files in
`.private` (the wall copies at the served root are anonymized - useless for
alerting). `ALERTCANVAS_SECRET` encrypts the stored SMTP password and ntfy
token at rest - same care-and-feeding as SNMPCanvas's secret (set before
configuring, back it up).

### LaunchCanvas - `/opt/canvas-suite/launchcanvas/docker-compose.override.yml`

```yaml
services:
  launchcanvas:
    volumes:
      - /srv/canvas-suite/launchcanvas:/data:z
      - /srv/canvas-suite/.private:/boards:z
    environment:
      - TZ=America/New_York
      - SUITE_SECRET=<a-long-random-string>   # generate with: openssl rand -base64 32
```

The second mount is read-write on purpose: board uploads from the portal
land as `/srv/canvas-suite/.private/board.xcanvas` - private, where the
poller reads them - and the authenticated download still serves the full
file. `SUITE_SECRET` enables single sign-on - add the **same value** to the
`environment:` of the SNMPCanvas, SyslogCanvas, and AlertCanvas overrides
above and logging into the portal logs you into all three (leave it unset
anywhere to keep that app's own login). Rotating it signs everyone out.

---

## Bring it up

```bash
cd /opt/canvas-suite/pingcanvas && ./docker/build-web.sh && docker compose up -d --build
cd /opt/canvas-suite/snmpcanvas && docker compose up -d --build
cd /opt/canvas-suite/syslogcanvas && docker compose up -d --build
cd /opt/canvas-suite/alertcanvas && docker compose up -d --build
cd /opt/canvas-suite/launchcanvas && docker compose up -d --build
```

Confirm a mount took: `docker compose -f docker-compose.yml -f
docker-compose.override.yml config | grep -A3 volumes`.

**Harmless warnings you may see:**

- `WARN ... Docker Compose is configured to build using Bake, but buildx isn't
  installed` - cosmetic. Compose prefers the Bake builder but falls back to the
  classic one, and the build still completes. Silence it with
  `sudo apt install -y docker-buildx`. Check the containers came up either way:
  `docker compose ps`.
- `./tools/gen-cert.sh: Permission denied` on an older clone - the script lost
  its executable bit. Fresh clones are fixed, but for an existing one:
  `chmod +x tools/gen-cert.sh` (or just run it as `sh tools/gen-cert.sh`).

---

## Optional - HTTPS

Generate each cert into the folder its override points at.

```bash
# SNMPCanvas + SyslogCanvas: gen-cert.sh honors CERT_DIR, so write in place:
cd /opt/canvas-suite/snmpcanvas
CERT_DIR=/srv/canvas-suite/certs ./tools/gen-cert.sh <box-ip>
docker compose restart

cd /opt/canvas-suite/syslogcanvas
CERT_DIR=/srv/canvas-suite/syslogcanvas/certs ./tools/gen-cert.sh <box-ip>
docker compose restart

cd /opt/canvas-suite/alertcanvas
CERT_DIR=/srv/canvas-suite/alertcanvas/certs ./tools/gen-cert.sh <box-ip>
docker compose restart

cd /opt/canvas-suite/launchcanvas
CERT_DIR=/srv/canvas-suite/launchcanvas/certs ./tools/gen-cert.sh <box-ip>
docker compose restart

# PingCanvas: its script honors CERT_DIR too, so write in place (different cert
# names - fullchain.pem/privkey.pem - so they share the folder without clashing):
cd /opt/canvas-suite/pingcanvas
CERT_DIR=/srv/canvas-suite/certs ./docker/gen-selfsigned-cert.sh <box-ip>
docker compose restart web        # NOT up -d - the entrypoint only re-scans on recreate
```

HTTPS then: PingCanvas on **8443** (8080 stays HTTP), SNMPCanvas, SyslogCanvas,
AlertCanvas, and LaunchCanvas on their same ports (9161 / 9514 / 9162 / 9160).
Run the suite all-HTTP or all-HTTPS: a `Secure` SSO cookie set by an HTTPS
portal is not sent to plain-HTTP siblings.

---

## Verify the 404 rules are working

The whole reason co-location is safe - prove it on your box:

```bash
# these must FAIL (404) - sources and secrets live in the shared dir but must not serve:
curl -sf http://<box>:8080/data/snmpcanvas.db              && echo "EXPOSED - update PingCanvas" || echo "ok: db 404s"
curl -sf http://<box>:8080/data/certs/server.key           && echo "EXPOSED - update PingCanvas" || echo "ok: key 404s"
curl -sf http://<box>:8080/data/.private/board.xcanvas     && echo "EXPOSED - update PingCanvas" || echo "ok: private board 404s"

# these should SUCCEED - the sanitized wall files, meant to be fetched:
curl -sf http://<box>:8080/data/board.wall.xcanvas      >/dev/null && echo "ok: wall board served"
curl -sf http://<box>:8080/data/snmp-status.wall.json   >/dev/null && echo "ok: snmp wall export served"
```

If either of the first two returns content, you're on an older PingCanvas build -
rebuild it, or move the sensitive files out of the shared dir. And with
`SNMPCANVAS_SECRET` set (above), even a stray exposure would only leak an
encrypted database.

---

## Migrating an existing flat setup

If you already have `snmpcanvas.db` and certs sitting flat in `/srv/canvas-suite`
(the common starting point), you only need to: pull the newer PingCanvas and
rebuild it (`git ... && ./docker/build-web.sh && docker compose up -d --build`),
then move SyslogCanvas to its own subdir so its cert stops clobbering
SNMPCanvas's:

```bash
cd /opt/canvas-suite/syslogcanvas && docker compose down
sudo mkdir -p /srv/canvas-suite/syslogcanvas
sudo mv /srv/canvas-suite/syslogcanvas.db* /srv/canvas-suite/syslogcanvas/ 2>/dev/null || true
# (then add the override above and `docker compose up -d`)
```

Move the `.db*` files BEFORE first start with the new override, or SyslogCanvas
opens a fresh empty database and your history sits orphaned one level up.

---

## URLs and updating

Same as the main guide, and now genuinely safe against data loss - nothing you
pull touches `/srv/canvas-suite`:

```bash
cd /opt/canvas-suite/crosscanvas && git pull
cd /opt/canvas-suite/pingcanvas  && git pull && ./docker/build-web.sh && docker compose up -d --build
cd /opt/canvas-suite/snmpcanvas  && git pull && docker compose up -d --build
cd /opt/canvas-suite/syslogcanvas && git pull && docker compose up -d --build
cd /opt/canvas-suite/alertcanvas && git pull && docker compose up -d --build
cd /opt/canvas-suite/launchcanvas && git pull && docker compose up -d --build
```

(Every repo is ordinary incremental history on `main` as of 2026-07-22, so
plain `git pull` is the whole update story. A CrossCanvas or PingCanvas clone
from before that date carries the retired snapshot history - re-clone those
once and you're back on plain pulls. Overrides and `/srv/canvas-suite` are never
touched either way.)
