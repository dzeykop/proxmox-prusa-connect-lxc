# proxmox-prusa-connect-lxc

One-command installer for **Prusa Connect Local** on Proxmox VE.
It creates an **unprivileged Debian LXC container** and runs Prusa Connect Local as a systemd service – no cloud, no Prusa Account.

## Quick start

Run on the Proxmox host as root (via SSH):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dzeykop/proxmox-prusa-connect-lxc/main/prusa-connect-lxc.sh)"
```

> Always review a script before running it as root.

## What the script does

1. Checks: root, Proxmox host, amd64, internet connection
2. Asks for container ID, hostname, CPU, RAM, storage, disk, bridge, DHCP/static IP
3. Downloads the newest `prusa_connect_amd64` from [prusa3d/prusa-connect](https://github.com/prusa3d/prusa-connect) and verifies its SHA256 checksum
4. Downloads the newest Debian template (if needed) and creates the container
5. Installs the binary to `/opt/prusa-connect`, runs it as user `prusa-connect` via systemd
6. Shows the web address (port 8080) and the one-time setup code
7. Asks whether the container should start automatically at host boot (can be changed later under *Options → Start at boot*)
8. Removes the unfinished container automatically if anything fails

## Default settings

| Setting   | Recommended | Minimum |
|-----------|-------------|---------|
| CPU cores | 1           | 1       |
| RAM       | 512 MB      | 256 MB  |
| Disk      | 8 GB        | 4 GB    |

Print files are stored on the container disk – choose more space if you keep many G-codes.

## After the installation

1. Open `http://<container-ip>:8080` and enter the setup code
2. Create the admin account in the wizard
3. Add a printer: download the settings file, copy it to a USB drive, load it on the printer (Settings → Network → Prusa Connect). Firmware 6.4.0 or newer is required.

Setup code lost? Show it on the Proxmox host with:

```bash
pct exec <CTID> -- journalctl -u prusa-connect --no-pager
```

Open a shell in the container:

```bash
pct enter <CTID>
```

## Updates

Prusa Connect Local is still beta (0.x) – configuration and API may change. **Take a snapshot before every update:**

```bash
pct snapshot <CTID> before-update
```

## Troubleshooting

| Message | Meaning |
|---------|---------|
| `No internet connection` | The Proxmox host cannot reach GitHub – check DNS/gateway |
| `Checksum mismatch` | The download is damaged – run the command again; nothing was installed |
| `Container has no network/DNS` | Check bridge, DHCP or static IP settings |
| `[ROLLBACK] ... removing unfinished container` | Installation failed; the half-created container was removed |
| `Setup code: not found` | Run the `journalctl` command above |

## Changelog

| Version | Changes |
|---------|---------|
| 1.2.0   | Asks at the end whether the container should start at boot |
| 1.1.0   | Visible progress: numbered steps [1/8]…[8/8], spinner with elapsed time, download progress bar, waiting timers, total install time |
| 1.0.1   | Own repository (proxmox-prusa-connect-lxc) |
| 1.0.0   | First release |

---
from JFFK
