# Canvas suite - one-command setup

`canvas-suite-setup.sh` stands the whole suite up on a fresh Linux box (built for
a newly spun-up Ubuntu Server VM; also handles RHEL/Rocky/Fedora). It is the
"run this" path; if you want to see each step by hand, use
`canvas-suite-shared-data-deploy.md` instead - the script produces the exact same
shared-data layout.

## What it does

- Installs git, curl, openssl, and Docker (via the official convenience script,
  so you get modern compose v2).
- Auto-detects the box's LAN IP and timezone.
- Creates `/srv/noc-data` (all history, owned by the container uid 1000) and
  `/projects` (the six git checkouts, owned by you).
- Clones CrossCanvas, PingCanvas, SNMPCanvas, SyslogCanvas, AlertCanvas, and
  LaunchCanvas.
- Writes the `docker-compose.override.yml` files that point every container at
  the shared data folder, and mints one `SUITE_SECRET` shared by LaunchCanvas
  and the three Node siblings so single sign-on works out of the box.
- Generates self-signed TLS certs (unless `--no-tls`) so HTTPS is live from the
  first boot. Plain HTTP stays available too - no forced redirect.
- Builds and starts all five stacks (CrossCanvas has no container of its own;
  PingCanvas's web tier serves the editor).
- Verifies the sensitive-file 404 guard and that the editor is serving.

## Run it

```bash
# copy the script to the box, then:
chmod +x canvas-suite-setup.sh
./canvas-suite-setup.sh
```

You need a user with `sudo`. If Docker was just installed, the script uses
`sudo docker` for this run so you do not have to log out and back in first; your
next login picks up docker-group membership for plain `docker`.

## Options

| Flag | Default | Purpose |
|---|---|---|
| `--ip ADDR` | auto-detected | address the box is reached at (set it if auto-detect grabs the wrong NIC) |
| `--board FILE` | none | seed this `.xcanvas` as the kiosk board |
| `--no-tls` | off | skip cert generation, HTTP only |
| `--data DIR` | `/srv/noc-data` | shared data root |
| `--projects DIR` | `/projects` | where the repos are cloned |
| `--update` | off | `git pull` existing clones instead of leaving them as-is |

Any of `BOX_IP`, `DATA_ROOT`, `PROJ_ROOT`, `TZ` can be set as env vars instead.

## Safe to re-run

Re-running reconciles the box to this layout. It does **not** regenerate the
`SNMPCANVAS_SECRET`, `ALERTCANVAS_SECRET`, or `SUITE_SECRET` (it reuses the
ones already in the overrides - regenerating would orphan your encrypted
credentials and sign everyone out) and does **not** touch existing history
or certs. Use `--update` when you want it to also pull the latest code.

## After it finishes

- The final output prints every URL, with LaunchCanvas (port 9160) as the
  "start here" line: log in once there and the tiles open the whole suite,
  already authenticated. Its in-app Quickstart walks the rest.
- If it minted a new `SNMPCANVAS_SECRET`, it prints it once - copy that into a
  password manager. It is the only thing that decrypts your SNMP credentials.
- No board yet? Draw one in the editor, export it, and upload it from the
  LaunchCanvas Launch page (or save it as `/srv/noc-data/board.xcanvas` by
  hand). The kiosk shows a getting-started page until then.
- Pairs well with Uptime Kuma (service-level checks and status pages) as its
  own compose stack (port 3001) with no conflict.

## Updating later

```bash
./canvas-suite-setup.sh --update      # pulls each repo, rebuilds, restarts
```

Your `/srv/noc-data` and the override files are untracked, so updates never
touch them.
