#!/usr/bin/env bash
# =============================================================================
#  Prusa Connect Local – Proxmox LXC installer
#  Version: 1.0.0
#  Author:  JFFK (github.com/dzeykop)
#  Repo:    https://github.com/dzeykop/proxmox-prusa-connect
#
#  Creates an unprivileged Debian LXC container on Proxmox VE and installs
#  Prusa Connect Local (binary + systemd service) inside it.
#
#  Run on the Proxmox host as root:
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/dzeykop/proxmox-prusa-connect/main/prusa-connect-lxc.sh)"
# =============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
APP_NAME="Prusa Connect Local"
GH_REPO="prusa3d/prusa-connect"
ASSET_NAME="prusa_connect_amd64"
APP_DIR="/opt/prusa-connect"
APP_USER="prusa-connect"
APP_PORT="8080"
TITLE="Prusa Connect Local LXC Installer v${SCRIPT_VERSION}"

# Recommended / minimum values
REC_CORES=1;   MIN_CORES=1
REC_RAM=512;   MIN_RAM=256      # MB
REC_DISK=8;    MIN_DISK=4       # GB (G-code files are stored here)

# State flags for rollback
CT_CREATED=0
INSTALL_DONE=0
CTID=""
TMP_DIR="$(mktemp -d)"

# ---------- output helpers ----------------------------------------------------
GN="\e[32m"; YW="\e[33m"; RD="\e[31m"; BL="\e[36m"; CL="\e[0m"; BD="\e[1m"
msg_info() { echo -e " ${BL}[INFO]${CL} $*"; }
msg_ok()   { echo -e " ${GN}[ OK ]${CL} $*"; }
msg_warn() { echo -e " ${YW}[WARN]${CL} $*"; }
msg_err()  { echo -e " ${RD}[FAIL]${CL} $*" >&2; }
die()      { msg_err "$*"; exit 1; }

cleanup() {
  local rc=$?
  rm -rf "$TMP_DIR"
  if [[ $rc -ne 0 && $CT_CREATED -eq 1 && $INSTALL_DONE -eq 0 && -n "$CTID" ]]; then
    msg_warn "[ROLLBACK] Installation failed – removing unfinished container ${CTID}"
    pct stop "$CTID" >/dev/null 2>&1 || true
    pct destroy "$CTID" --purge >/dev/null 2>&1 || true
    msg_ok "[ROLLBACK] Container ${CTID} removed"
  fi
}
trap cleanup EXIT
trap 'msg_err "Error in line $LINENO: $BASH_COMMAND"' ERR

cancelled() { echo; msg_warn "Cancelled by user – nothing was changed."; exit 0; }

# ---------- 1. pre-flight checks ------------------------------------------------
clear
echo -e "${BD}${TITLE}${CL}\n"

[[ $EUID -eq 0 ]] || die "Please run this script as root."
command -v pct >/dev/null && command -v pveversion >/dev/null \
  || die "This script must run on a Proxmox VE host."
command -v whiptail >/dev/null || die "whiptail not found."
msg_ok "Proxmox VE detected: $(pveversion | cut -d/ -f2)"

[[ "$(dpkg --print-architecture)" == "amd64" ]] \
  || die "Only amd64 (Intel/AMD) Proxmox hosts are supported."

msg_info "Checking internet connection..."
curl -fsS --max-time 10 -o /dev/null https://api.github.com \
  || die "No internet connection (api.github.com not reachable)."
msg_ok "Internet connection OK"

whiptail --title "$TITLE" --yesno \
"This will create a new unprivileged LXC container with ${APP_NAME}.\n\nProceed?" 10 64 \
  || cancelled

# ---------- 2. host resources -------------------------------------------------
HOST_CORES=$(nproc)
HOST_RAM_FREE=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)

# ---------- 3. settings ---------------------------------------------------------
NEXT_ID=$(pvesh get /cluster/nextid)
CTID=$(whiptail --title "$TITLE" --inputbox "Container ID:" 9 60 "$NEXT_ID" 3>&1 1>&2 2>&3) || cancelled
[[ "$CTID" =~ ^[0-9]+$ ]] || die "Invalid container ID."
if pct status "$CTID" >/dev/null 2>&1 || qm status "$CTID" >/dev/null 2>&1; then
  die "ID ${CTID} is already in use."
fi

CT_HOSTNAME=$(whiptail --title "$TITLE" --inputbox "Hostname:" 9 60 "prusa-connect" 3>&1 1>&2 2>&3) || cancelled
[[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9-]+$ ]] || die "Invalid hostname."

ask_number() { # $1 label $2 rec $3 min $4 max $5 unit
  local val
  val=$(whiptail --title "$TITLE" --inputbox \
"$1\n\nRecommended: $2 $5   Minimum: $3 $5   Host available: $4 $5" 11 66 "$2" 3>&1 1>&2 2>&3) || cancelled
  [[ "$val" =~ ^[0-9]+$ ]] || die "Invalid number for $1."
  if (( val < $3 )); then die "$1 below minimum ($3 $5)."; fi
  if (( val > $4 )); then
    whiptail --title "$TITLE" --defaultno --yesno "$1 ($val $5) exceeds available host resources ($4 $5).\nContinue anyway?" 10 64 || cancelled
  fi
  echo "$val"
}
CORES=$(ask_number "CPU cores" "$REC_CORES" "$MIN_CORES" "$HOST_CORES" "")
RAM=$(ask_number "RAM" "$REC_RAM" "$MIN_RAM" "$HOST_RAM_FREE" "MB")

# storage for the container disk
mapfile -t STORAGES < <(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {printf "%s %d\n", $1, $6/1024/1024}')
(( ${#STORAGES[@]} )) || die "No active storage for containers found."
MENU=(); for s in "${STORAGES[@]}"; do MENU+=("${s%% *}" "free: ${s##* } GB"); done
CT_STORAGE=$(whiptail --title "$TITLE" --menu "Storage for the container disk:" 15 60 6 "${MENU[@]}" 3>&1 1>&2 2>&3) || cancelled
STORAGE_FREE=$(printf '%s\n' "${STORAGES[@]}" | awk -v s="$CT_STORAGE" '$1==s {print $2}')
DISK=$(ask_number "Disk size" "$REC_DISK" "$MIN_DISK" "$STORAGE_FREE" "GB")

# network bridge
mapfile -t BRIDGES < <(ip -o link show type bridge | awk -F': ' '{print $2}' | grep '^vmbr' || true)
(( ${#BRIDGES[@]} )) || die "No vmbr bridge found."
MENU=(); for b in "${BRIDGES[@]}"; do MENU+=("$b" ""); done
BRIDGE=$(whiptail --title "$TITLE" --menu "Network bridge:" 14 60 5 "${MENU[@]}" 3>&1 1>&2 2>&3) || cancelled

# IP configuration
if whiptail --title "$TITLE" --yes-button "DHCP" --no-button "Static" --yesno \
"IP address configuration:\n\nTip: a static IP (or a DHCP reservation in your router) keeps the web address stable." 11 66; then
  NET_IP="dhcp"; NET_CFG="name=eth0,bridge=${BRIDGE},ip=dhcp"
else
  NET_IP=$(whiptail --title "$TITLE" --inputbox "Static IP with CIDR (e.g. 192.168.20.50/24):" 9 60 3>&1 1>&2 2>&3) || cancelled
  [[ "$NET_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "Invalid IP/CIDR."
  NET_GW=$(whiptail --title "$TITLE" --inputbox "Gateway (e.g. 192.168.20.1):" 9 60 3>&1 1>&2 2>&3) || cancelled
  [[ "$NET_GW" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Invalid gateway."
  NET_CFG="name=eth0,bridge=${BRIDGE},ip=${NET_IP},gw=${NET_GW}"
fi

# summary
whiptail --title "$TITLE" --yesno \
"Summary:\n
  Container ID:  ${CTID}
  Hostname:      ${CT_HOSTNAME}
  CPU cores:     ${CORES}
  RAM:           ${RAM} MB
  Disk:          ${DISK} GB on ${CT_STORAGE}
  Bridge:        ${BRIDGE}
  IP:            ${NET_IP}
  Type:          unprivileged LXC, start at boot\n
Create the container now?" 20 64 || cancelled

# ---------- 4. find the newest release (pre-releases included) ------------------
msg_info "Looking up the newest ${APP_NAME} release..."
curl -fsSL "https://api.github.com/repos/${GH_REPO}/releases?per_page=10" -o "$TMP_DIR/releases.json" \
  || die "Could not read releases from GitHub."
# Perl with JSON::PP is always present on Proxmox (no jq needed)
read -r REL_TAG ASSET_URL ASSET_DIGEST < <(perl -MJSON::PP -e '
  local $/; my $r = decode_json(<STDIN>);
  for my $rel (@$r) {
    next if $rel->{draft};
    for my $a (@{$rel->{assets}}) {
      if ($a->{name} eq $ARGV[0]) {
        print join(" ", $rel->{tag_name}, $a->{browser_download_url}, ($a->{digest} // "none")), "\n";
        exit 0;
      }
    }
  }' "$ASSET_NAME" < "$TMP_DIR/releases.json") || true
[[ -n "${ASSET_URL:-}" ]] || die "Release file ${ASSET_NAME} not found on GitHub."
msg_ok "Found release ${REL_TAG}"

msg_info "Downloading ${ASSET_NAME}..."
curl -fsSL "$ASSET_URL" -o "$TMP_DIR/$ASSET_NAME" || die "Download failed."
if [[ "$ASSET_DIGEST" == sha256:* ]]; then
  echo "${ASSET_DIGEST#sha256:}  $TMP_DIR/$ASSET_NAME" | sha256sum -c --status \
    || die "Checksum mismatch – download damaged. Nothing was installed."
  msg_ok "Checksum verified (SHA256)"
else
  msg_warn "No checksum published by GitHub – verification skipped"
fi

# ---------- 5. Debian template --------------------------------------------------
msg_info "Updating template list..."
pveam update >/dev/null || msg_warn "Template list update failed – using cached list"
TEMPLATE=$(pveam available --section system | awk '{print $2}' \
  | grep -E '^debian-[0-9]+-standard_.*_amd64\.tar\.(zst|gz|xz)$' | sort -V | tail -n1)
[[ -n "$TEMPLATE" ]] || die "No Debian template found."
TPL_STORAGE=$(pvesm status -content vztmpl | awk 'NR>1 && $3=="active" {print $1; exit}')
[[ -n "$TPL_STORAGE" ]] || die "No storage for templates found."
if ! pveam list "$TPL_STORAGE" | grep -q "$TEMPLATE"; then
  msg_info "Downloading template ${TEMPLATE}..."
  pveam download "$TPL_STORAGE" "$TEMPLATE" >/dev/null || die "Template download failed."
fi
msg_ok "Template ready: ${TEMPLATE}"

# ---------- 6. create container -------------------------------------------------
msg_info "Creating container ${CTID}..."
DESCRIPTION="<h3>${APP_NAME}</h3><p>Installed with proxmox-prusa-connect v${SCRIPT_VERSION}<br>Release: ${REL_TAG}<br>Web UI: port ${APP_PORT}</p><p>from JFFK</p>"
pct create "$CTID" "${TPL_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CORES" --memory "$RAM" --swap 256 \
  --rootfs "${CT_STORAGE}:${DISK}" \
  --net0 "$NET_CFG" \
  --unprivileged 1 --features nesting=1 \
  --onboot 1 --ostype debian \
  --tags "prusa;3d-printing" \
  --description "$DESCRIPTION" >/dev/null
CT_CREATED=1
msg_ok "Container ${CTID} created"

pct start "$CTID"
msg_info "Waiting for network in the container..."
for _ in $(seq 1 30); do
  pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
  sleep 2
done
pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 || die "Container has no network/DNS."
msg_ok "Container is online"

# ---------- 7. install inside the container -------------------------------------
msg_info "Updating the container system (this can take a minute)..."
pct exec "$CTID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get -y -qq upgrade && apt-get -y -qq install curl ca-certificates" >/dev/null
msg_ok "System updated"

msg_info "Installing ${APP_NAME} ${REL_TAG}..."
pct exec "$CTID" -- bash -c "id ${APP_USER} >/dev/null 2>&1 || useradd --system --home ${APP_DIR} --shell /usr/sbin/nologin ${APP_USER}; mkdir -p ${APP_DIR}"
pct push "$CTID" "$TMP_DIR/$ASSET_NAME" "${APP_DIR}/prusa_connect" --perms 0755
pct exec "$CTID" -- bash -c "echo '${REL_TAG}' > ${APP_DIR}/VERSION; chown -R ${APP_USER}:${APP_USER} ${APP_DIR}"

cat > "$TMP_DIR/prusa-connect.service" <<EOF
[Unit]
Description=Prusa Connect Local
After=network-online.target
Wants=network-online.target

[Service]
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/prusa_connect
Restart=on-failure
RestartSec=5
# allows the time server on UDP port 123 (below 1024)
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
pct push "$CTID" "$TMP_DIR/prusa-connect.service" /etc/systemd/system/prusa-connect.service
pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now prusa-connect >/dev/null 2>&1
msg_ok "Service prusa-connect installed and started"

# ---------- 8. reachability + setup code ---------------------------------------
msg_info "Waiting for the web interface on port ${APP_PORT}..."
UP=0
for _ in $(seq 1 60); do
  if pct exec "$CTID" -- curl -fs -o /dev/null --max-time 2 "http://127.0.0.1:${APP_PORT}"; then UP=1; break; fi
  sleep 2
done
INSTALL_DONE=1   # from here on the container is never removed automatically

CT_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
SETUP_LINE=$(pct exec "$CTID" -- journalctl -u prusa-connect --no-pager -o cat 2>/dev/null \
  | grep -i -m1 -E 'setup' || true)

echo
echo -e "${GN}${BD}==============================================================${CL}"
if (( UP )); then
  echo -e "${GN}${BD}  ${APP_NAME} is running!${CL}"
else
  msg_warn "Web interface did not answer yet. Check: pct exec ${CTID} -- journalctl -u prusa-connect"
fi
echo -e "${GN}${BD}==============================================================${CL}"
echo -e "  Web UI:      ${BD}http://${CT_IP}:${APP_PORT}${CL}"
echo -e "  Container:   ${CTID} (${CT_HOSTNAME})"
echo -e "  Release:     ${REL_TAG}"
if [[ -n "$SETUP_LINE" ]]; then
  echo -e "  Setup code:  ${BD}${SETUP_LINE}${CL}"
else
  echo -e "  Setup code:  not found – show it with:"
  echo -e "               pct exec ${CTID} -- journalctl -u prusa-connect --no-pager"
fi
echo
echo "  Next steps:"
echo "   1. Open the Web UI and enter the setup code in the wizard"
echo "   2. Create the admin account"
echo "   3. Add your printer (settings file via USB, firmware 6.4.0 or newer)"
echo
echo -e "  ${YW}Note:${CL} ${APP_NAME} is still beta (0.x). Take a Proxmox snapshot"
echo "        before every update: pct snapshot ${CTID} before-update"
echo
echo "  from JFFK"
