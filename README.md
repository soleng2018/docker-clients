# docker-clients

Generates a `docker-compose.yml` per lab VM (Windows or macOS, via
[dockurr/windows](https://github.com/dockur/windows) /
[dockurr/macos](https://github.com/dockur/macos)) with USB devices passed
through by MAC address, and keeps them working across a host reboot (which
reassigns every USB device's bus address).

## One clone, many testbeds

Unlike the old layout, there is **one clone** of this repo (e.g.
`/home/nova/docker-clients`), with a single `parameters.txt` describing
every testbed. Running `reconcile.sh` creates one folder per testbed as a
**sibling** of the clone -- one directory up -- each holding one subfolder
per VM:

```
/home/nova/docker-clients/     <- this clone: reconcile.sh, parameters.txt (real data, gitignored)
/home/nova/nw3/win1/           <- generated: docker-compose.yml + VM storage
/home/nova/nw3/win2/
/home/nova/nw3/mac1/
/home/nova/nw4/win1/
/home/nova/nw4/win2/
/home/nova/nw4/mac1/
```

A testbed is just a name prefix on the VM's key in `parameters.txt` --
`nw3/win1` becomes container `nw3-win1` / folder `../nw3/win1`. There's no
separate place to declare a testbed; adding one is just adding its first VM
line.

## `parameters.txt`

```
<testbed>/<vm> = "os","version","ram","cpu","username","password","web_port","remote_port","url","mac1"[,"mac2"][,"ip=<address>"]
```

See [parameters.txt.example](parameters.txt.example) for the full field
reference and a worked example. Notes:

- `parameters.txt` itself is git-ignored (see `.gitignore`) -- it holds real
  MACs, hostnames, and credentials for this specific deployment. Only
  `parameters.txt.example` is committed. **Keep your real `parameters.txt`
  backed up somewhere outside this repo** -- cloning this repo fresh does
  not recover it.
- `url` is the VM's complete Traefik hostname (e.g. `nw3-win1.example.com`)
  and must be unique across every testbed in the file.
- All host ports (`web_port`/`remote_port`, across every testbed) must be
  unique.
- `reconcile.sh` validates the whole file up front -- bad os value, missing
  testbed prefix, duplicate key, non-numeric/duplicate port, invalid/
  duplicate url, malformed MAC, invalid/duplicate `ip=` -- and refuses to
  generate or change anything until every error is fixed.
- A VM whose MAC(s) aren't currently resolvable locally is skipped (warning
  printed, its existing folder left as-is) rather than generating a broken
  compose file -- this is what makes it safe to add a line speculatively,
  e.g. before a dongle has been plugged in yet.

## Usage

```bash
bash reconcile.sh              # generate + start every VM, prune anything removed, report
bash reconcile.sh --dry-run    # same, but change nothing on disk or in docker
```

`reconcile.sh` is the only script you run day to day. It:

1. Validates `parameters.txt` (see above) -- aborts with no changes if it
   finds an error.
2. Generates/updates `../<testbed>/<vm>/docker-compose.yml` for every VM,
   resolving each MAC to whatever bus/address it currently has.
3. Runs `docker compose up -d` per VM -- compose only recreates a container
   whose config actually changed, so re-running after a reboot only touches
   the VMs whose USB mapping actually moved.
4. Tears down and **moves** (not deletes) any VM's folder that this tool
   previously generated but that no longer has a line in `parameters.txt`,
   into `.trash/<testbed>-<vm>-<timestamp>/` inside this clone. Restore by
   moving it back to `../<testbed>/<vm>` and re-adding its line.

## Keeping USB bus addresses fixed across a reboot

Linux reassigns every USB device's bus address (`hostaddr`) on every reboot
-- the bus number alone is not enough to find a device again. `install.sh`
sets up a systemd service that runs `reconcile.sh` once at boot (after
Docker and the network are up), so every VM's stale `-device
usb-host,hostbus=...,hostaddr=...` gets corrected and recreated
automatically instead of leaving the container stuck in a restart loop:

```bash
sudo bash install.sh      # install + enable the boot service
sudo bash cleanup.sh      # uninstall it (see --wipe-pods / --wipe-data for teardown options)
```

Check it: `systemctl status docker-clients-reconcile.service`,
`journalctl -u docker-clients-reconcile.service`, or run it on demand with
`sudo systemctl start docker-clients-reconcile.service`.

## Rebuilding this box from scratch

1. Install Docker.
2. Plug every USB dongle into this host directly.
3. `soleng2018/hol`'s `setup.sh` (FRR/DHCP/RADIUS containers).
4. `soleng2018/labs`'s `labs.sh` (Traefik/Authentik/Cloudflared).
5. Clone this repo once, e.g. `git clone git@github.com:soleng2018/docker-clients.git /home/nova/docker-clients`.
6. Restore your real `parameters.txt` into that clone (kept outside git --
   see above), then `bash reconcile.sh`.
7. `sudo bash install.sh` so a future reboot self-heals.

Fresh installs: Windows VMs install unattended (a ~6 GB ISO download each);
macOS VMs need their first-boot setup done by hand in the GUI.
