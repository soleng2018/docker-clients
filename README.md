# docker-clients

Generates a `docker-compose.yml` per lab VM (Windows or macOS, via
[dockurr/windows](https://github.com/dockur/windows) /
[dockurr/macos](https://github.com/dockur/macos)) with USB devices passed
through by MAC address, and keeps them working when those devices arrive
over [usbip-net-toolkit](https://github.com/soleng2018/usbip-net-toolkit)
instead of a physical cable.

## One clone per workshop

Each hands-on-lab pod (RF chamber + Pi + wired dongle) gets its **own
clone** of this repo, one directory per workshop, e.g.:

```
/home/nova/nw1
/home/nova/nw2
/home/nova/nw3
/home/nova/nw4
```

Each clone has its own `parameters.txt` (its own VMs, MACs, ports) and its
own generated `<vm-name>/docker-compose.yml` subfolders (e.g.
`nw3/win1/docker-compose.yml`). The clone's folder name is also used to
automatically prefix every actual Docker container name and Traefik
hostname — a `win1` entry inside `/home/nova/nw3` becomes container
`nw3-win1` / hostname `nw3-win1.<domain>`, with no need to type the workshop
name into `parameters.txt` itself (so it can never drift out of sync with
the folder it's actually in). To add the next workshop:

```bash
git clone git@github.com:soleng2018/docker-clients.git /home/nova/nw4
cd /home/nova/nw4
cp parameters.txt.example parameters.txt   # then fill in nw4's real values
bash script
sudo bash install.sh
```

## How it works

`script` reads `parameters.txt`, and for each line resolves the listed
MAC address(es) to whatever's currently visible locally under
`/sys/class/net`/`/sys/bus/usb/devices`, then writes a `docker-compose.yml`
into a folder named after that line's container name, with QEMU
USB-passthrough args (`-device usb-host,hostbus=X,hostaddr=Y`).

**A MAC's origin is invisible to this script.** Whether a NIC is a
USB-Ethernet dongle plugged directly into this host, or a USB WiFi dongle
that physically lives on a Raspberry Pi across the network and arrives here
via `usbip-net-toolkit`'s `client/` (`vhci_hcd` makes an imported device
look exactly like a locally plugged-in one), `find_usb_device()` resolves
it the same way. A VM can list any number of MACs from any mix of sources.

## `parameters.txt`

```
container_name = "os","version","ram","cpu","username","password","web_port","remote_port","domain","mac1"[,"mac2"...]
```

See [parameters.txt.example](parameters.txt.example) for a worked example
of both `os` values. Notes:

- `os` is `windows` or `macos`. Everything else about the two images is
  identical (RAM_SIZE/CPU_CORES/VERSION, `/dev/kvm`, USB passthrough,
  Traefik routing) except: `macos` doesn't take `username`/`password`
  (pass `"",""`), its remote-access port is VNC/5900 instead of RDP/3389,
  and it doesn't get the `./data` volume mount.
- `parameters.txt` itself is git-ignored (see `.gitignore`) — it holds real
  MACs, domain, and credentials for this specific deployment. Only
  `parameters.txt.example` is committed. **Keep your real `parameters.txt`
  backed up somewhere outside this repo** — cloning this repo fresh does
  not recover it.
- All host ports (`web_port` and `remote_port`, across every line) must be
  unique; `script` validates this up front and refuses to generate anything
  if it finds a collision.
- A pod whose MAC(s) aren't currently resolvable locally is skipped
  (warning printed, nothing written) rather than generating a broken
  compose file — this is what makes it safe to run `script` speculatively,
  e.g. before a Pi/adapter has come online yet, or to comment a line out
  entirely (`#win1 = ...`) while a dongle is still being sorted out.
- `container_name` may also contain `/` if you ever want to group VMs
  within a single clone (e.g. `foo/win1`); not needed for the one-clone-
  per-workshop layout above, but supported since `mkdir -p` handles it.
- The actual Docker container name / Traefik hostname is
  `<workshop-folder-name>-<container_name>`, with any `/` in
  `container_name` also replaced by `-` (both can't hold a literal `/`).

## Usage

```bash
bash script                 # (re)generate docker-compose.yml for every resolvable VM in this clone
cd <vm-name> && docker compose up -d
```

## Keeping USB/IP-sourced devices in sync (`usbip-net-regen`)

If any of your MACs arrive via `usbip-net-toolkit`, a device's `hostaddr`
can change whenever it's re-attached (Pi reboot, network blip, this host
rebooting) — silently breaking a running container's passthrough until
`script` is rerun and the container recreated. `install.sh` sets up a
**shared** systemd path unit (one per machine, not one per clone) that
does that automatically for every registered workshop folder:

```bash
sudo bash install.sh
```

Since one USB/IP client on this machine can feed multiple workshop clones
(e.g. nw1–nw4, each with their own Pi), the watcher itself is shared:
running `install.sh` from any clone installs/refreshes it and adds that
clone's directory to `/etc/usbip-net-regen/repos.txt`. Whenever
`usbip-net-toolkit`'s `/var/lib/usbip-net-client/attached.csv` changes, it
reruns `script` then `docker compose up -d` for every registered clone —
compose only recreates a container whose config actually differs, so this
only touches whatever pod's device mapping actually moved, in whichever
clone it belongs to.

```bash
sudo bash cleanup.sh                            # unregister this clone only
sudo bash cleanup.sh --wipe-pods                # + docker compose down every generated pod here
sudo bash cleanup.sh --wipe-pods --wipe-data    # + delete VM storage/data too (destructive)
sudo bash cleanup.sh --purge-shared             # + remove the shared bridge (refuses if other clones still registered)
```

## Rebuilding this box from scratch

This repo is one piece of a larger lab; from a fresh Ubuntu install, the
full sequence is:

1. Install Docker.
2. On each Raspberry Pi holding USB adapters:
   `usbip-net-toolkit/host/install.sh`.
3. On this machine: `usbip-net-toolkit/client/install.sh`, then list each
   Pi in `/etc/usbip-net/servers.conf`.
4. `soleng2018/hol`'s `setup.sh` (FRR/DHCP/RADIUS containers).
5. `soleng2018/labs`'s `labs.sh` (Traefik/Authentik/Cloudflared).
6. For each workshop (nw1, nw2, ...): clone this repo into its own
   directory, restore that workshop's real `parameters.txt` (kept outside
   git — see above), then `bash script` and `sudo bash install.sh`.
