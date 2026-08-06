# Canvas suite - one-command setup

`canvas-suite-setup.sh` stands the whole suite up on a fresh Linux box (built for
a newly spun-up Ubuntu Server VM; also handles RHEL/Rocky/Fedora). It is the
"run this" path; if you want to see each step by hand, use
`canvas-suite-shared-data-deploy.md` instead - the script produces the same
shared-data layout (the script additionally wires SUITE_SECRET single sign-on
into every override, adds the host FQDN to the certs, and auto-detects TZ -
the manual doc treats those as optional steps).

## What it does

- Installs git, curl, openssl, and Docker (via the official convenience script,
  so you get modern compose v2).
- Auto-detects the box's LAN IP and timezone.
- Creates `/srv/canvas-suite` (all history, owned by the container uid 1000) and
  `/opt/canvas-suite` (the six git checkouts, owned by you).
- Clones CrossCanvas, PingCanvas, SNMPCanvas, SyslogCanvas, AlertCanvas, and
  LaunchCanvas.
- Writes the `docker-compose.override.yml` files that point every container at
  the shared data folder, and mints one `SUITE_SECRET` shared by LaunchCanvas
  and the three Node siblings so single sign-on works out of the box.
- Generates self-signed TLS certs (unless `--no-tls`) so HTTPS is live from the
  first boot. Plain HTTP stays available too - no forced redirect.
- Builds and starts all five stacks - five containers cover the six apps (CrossCanvas has no container of its own;
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
| `--board FILE` | none | seed this `.xcanvas` as the kiosk board (never overwrites an existing board) |
| `--scan CIDR[,CIDR...]` | none | ping-scan these subnets (`nmap -sn`) and seed a board from every host that answered, so the wall is live from minute one |
| `--no-tls` | off | skip cert generation, HTTP only |
| `--data DIR` | `/srv/canvas-suite` | shared data root |
| `--projects DIR` | `/opt/canvas-suite` | where the repos are cloned |
| `--update` | off | `git pull` existing clones instead of leaving them as-is |

Any of `BOX_IP`, `DATA_ROOT`, `PROJ_ROOT`, `TZ` can be set as env vars instead.

## Safe to re-run

One caveat: re-runs rewrite the `docker-compose.override.yml` files (the
minted secrets are preserved, in their `- NAME=value` form). If you add your
own env vars, put them in the stock `docker-compose.yml` or re-add them after
a re-run.

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
  LaunchCanvas Launch page (or save it as
  `/srv/canvas-suite/.private/board.xcanvas` by hand). The kiosk shows a
  getting-started page until then.
- Boards live under `.private` on purpose: the web tier never serves that
  path, the poller writes a sanitized `.wall` copy (hidden device fields
  stripped) into the served root, and the printed kiosk URL points at the
  `.wall` pair - so the URL carries no more than the picture shows. The SNMP
  feed gets the same split: SNMPCanvas writes its full export (device names,
  addresses, interface names) into `.private` for AlertCanvas, and the served
  root only carries `snmp-status.wall.json` - codes and values, nothing that
  names anything. Details in PingCanvas's DEPLOY.md.
- Pairs well with Uptime Kuma (service-level checks and status pages) as its
  own compose stack (port 3001) with no conflict.

## Updating later

```bash
./canvas-suite-setup.sh --update      # pulls each repo, rebuilds, restarts
```

Your `/srv/canvas-suite` and the override files are untracked, so updates never
touch them.
