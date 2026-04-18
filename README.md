# proxmox-vm-profiles

A simple per-VM profile switcher for Proxmox VE. Keep multiple `.conf` snapshots per VM (`minimal`, `full`, `testing`, whatever) in a normal directory, then start a VM with whichever profile you want in one command:

```bash
./start.sh 110 minimal
./start.sh 110 full
./start.sh 110 auto        # load 110_auto.conf + detect connected USB devices
```

Every run backs up `/etc/pve/qemu-server/${VMID}.conf` before overwriting it, so switching profiles is always reversible.

## Why

Proxmox stores exactly one config per VM at `/etc/pve/qemu-server/{VMID}.conf`. If the same VM needs different configurations depending on what you're doing — GPU passthrough for desktop use, minimal config for headless tasks, a testing config with experimental flags — you end up editing that file by hand every time. This script keeps the variants in version-controllable files and swaps the active one before `qm start`.

## How it works

1. You keep per-VM profile configs under `vmconfigs/{VMID}/{VMID}_{profile}.conf` (e.g. `vmconfigs/110/110_minimal.conf`).
2. `./start.sh VMID PROFILE` backs up the current `/etc/pve/qemu-server/{VMID}.conf` to `vmconfigs/backups/`, copies the chosen profile into place, then runs `qm start`.
3. Profile files are plain Proxmox VM configs — the same format `qm config` emits.

## Profiles

| Profile | What it loads |
|---|---|
| `full` | `{VMID}_full.conf` — all passthrough devices, max resources |
| `minimal` | `{VMID}_minimal.conf` — lightweight, no passthrough |
| `testing` | `{VMID}_testing.conf` — experimental flags, separate from your stable config |
| `auto` | `{VMID}_auto.conf` plus currently-connected USB devices attached via resource mappings — requires [proxmox-usb-hotplug](https://github.com/codemonkeying/proxmox-usb-hotplug) |
| `default` | leaves `/etc/pve/qemu-server/{VMID}.conf` alone — just backs up and starts |

You can rename or add profiles freely. The script accepts any of the five listed above; extend the `VALID_PROFILES` array in `start.sh` to add more.

## Requirements

- Proxmox VE with `qm` available
- Root (it writes to `/etc/pve/qemu-server/`)
- Bash
- Optional: [proxmox-usb-hotplug](https://github.com/codemonkeying/proxmox-usb-hotplug) for the `auto` profile

## Install

```bash
git clone https://github.com/codemonkeying/proxmox-vm-profiles.git /opt/proxmox-vm-profiles
cd /opt/proxmox-vm-profiles/vmconfigs
cp settings.example settings
$EDITOR settings                     # set DEFAULT and DEFAULT_PROFILE
```

Put your per-VM configs under `vmconfigs/{VMID}/`. The repo ships with a few `*.example.conf` files you can copy and adapt:

```bash
cp vmconfigs/110/110_minimal.example.conf vmconfigs/110/110_minimal.conf
$EDITOR vmconfigs/110/110_minimal.conf
```

You can put this directory anywhere — `/opt/`, `/root/`, your home — and the script will work. No install step, no symlink required. If you want `start.sh` on your `$PATH`:

```bash
ln -s /opt/proxmox-vm-profiles/start.sh /usr/local/bin/pve-start
```

`VMCONFIGS_DIR` can also be overridden via environment variable if you want the scripts and configs in separate locations:

```bash
VMCONFIGS_DIR=/etc/proxmox-vm-profiles ./start.sh 110 minimal
```

## Usage

```bash
./start.sh                         # default VM + default profile
./start.sh 110                     # VM 110 + default profile
./start.sh 110 minimal             # VM 110 + minimal profile
./start.sh 110 auto                # requires proxmox-usb-hotplug
./start.sh --help                  # full help, lists available VMs/profiles

./start.sh --set-default-vm 110    # persist default VMID
./start.sh --set-default-profile minimal
```

## Creating a new profile

The quickest way to get a starting point is `qm config VMID > vmconfigs/VMID/VMID_newprofile.conf`, then trim or add lines. Proxmox expects keys in alphabetical order in the main section (`[PENDING]` / `[snapshot]` sections come after and do **not** need to be sorted). See the `*.example.conf` files for a minimal template.

## Backups

Every `start.sh` run writes a timestamped copy of the current `/etc/pve/qemu-server/{VMID}.conf` to `vmconfigs/backups/` before overwriting it. Nothing auto-prunes them — clean up manually when they pile up:

```bash
find vmconfigs/backups -name "*.conf" -mtime +30 -delete
```

## Integration with proxmox-usb-hotplug

The `auto` profile is the integration point with [proxmox-usb-hotplug](https://github.com/codemonkeying/proxmox-usb-hotplug). When you run `./start.sh VMID auto`:

1. `start.sh` loads `{VMID}_auto.conf`
2. It calls `add_available_mappings_to_config` from `usb-mapping-helper.sh` (installed to `/usr/local/bin/` by the hotplug project) to append currently-connected USB mappings to the config before start
3. It writes the VMID to `/var/run/usb-hotplug-auto-vm.state` so the hotplug daemon knows which VM to actively manage

Without `proxmox-usb-hotplug` installed, the `auto` profile errors out with a pointer. The other four profiles work standalone.

## License

MIT — see [LICENSE](LICENSE).
