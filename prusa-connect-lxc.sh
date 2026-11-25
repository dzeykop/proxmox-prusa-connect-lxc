#!/usr/bin/env bash
# =============================================================================
#  Prusa Connect Local – Proxmox LXC installer
#  Version: 1.4.0
#  Author:  JFFK (github.com/dzeykop)
#  Repo:    https://github.com/dzeykop/proxmox-prusa-connect-lxc
#
#  Creates an unprivileged Debian LXC container on Proxmox VE and installs
#  Prusa Connect Local (binary + systemd service) inside it.
#
#  Run on the Proxmox host as root:
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/dzeykop/proxmox-prusa-connect-lxc/main/prusa-connect-lxc.sh)"
# =============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="1.4.0"
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

# Progress
STEP=0
TOTAL_STEPS=8

# ---------- output helpers ----------------------------------------------------
GN="\e[32m"; YW="\e[33m"; RD="\e[31m"; BL="\e[36m"; CL="\e[0m"; BD="\e[1m"
msg_info() { echo -e " ${BL}[INFO]${CL} $*"; }
msg_ok()   { echo -e " ${GN}[ OK ]${CL} $*"; }
msg_warn() { echo -e " ${YW}[WARN]${CL} $*"; }
msg_err()  { echo -e " ${RD}[FAIL]${CL} $*" >&2; }
die()      { msg_err "$*"; exit 1; }

# Prints a numbered step header, e.g. "[3/8] Preparing Debian template"
step() {
  STEP=$((STEP + 1))
  echo
  echo -e "${BD}[${STEP}/${TOTAL_STEPS}] $*${CL}"
}

# Runs a command in the background and shows a spinner with elapsed seconds.
# On failure the last lines of its output are shown.
run_spin() {
  local msg="$1"; shift
  local log="$TMP_DIR/step.log"
  local sp='|/-\' i=0 start=$SECONDS
  "$@" >"$log" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r ${BL}[ %s ]${CL} %s ... %ds " "${sp:i++%4:1}" "$msg" $((SECONDS - start))
    sleep 0.2
  done
  if wait "$pid"; then
    printf "\r\e[K"
    msg_ok "$msg ($((SECONDS - start))s)"
  else
    printf "\r\e[K"
    msg_err "$msg failed – last output:"
    tail -n 20 "$log" >&2
    return 1
  fi
}

# Shows a waiting line with elapsed time; $1 = message, $2 = elapsed, $3 = max
show_wait() { printf "\r ${BL}[WAIT]${CL} %s ... %ds / max %ds " "$1" "$2" "$3"; }

cleanup() {
  local rc=$?
  rm -rf "$TMP_DIR"
  if [[ $rc -ne 0 && $CT_CREATED -eq 1 && $INSTALL_DONE -eq 0 && -n "$CTID" ]]; then
    echo
    msg_warn "[ROLLBACK] Installation failed – removing unfinished container ${CTID}"
    pct stop "$CTID" >/dev/null 2>&1 || true
    pct destroy "$CTID" --purge >/dev/null 2>&1 || true
    msg_ok "[ROLLBACK] Container ${CTID} removed"
  fi
}
trap cleanup EXIT
trap 'msg_err "Error in line $LINENO: $BASH_COMMAND"' ERR

cancelled() { echo; msg_warn "Cancelled by user – nothing was changed."; exit 0; }

# ---------- pre-flight checks ---------------------------------------------------
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

# ---------- existing Prusa Connect containers? ----------------------------------
# Running containers: look inside for the program.
# Stopped containers: recognised by the description/tag this installer sets.
msg_info "Checking for existing Prusa Connect containers..."
EXISTING=()          # lines for the warning dialog
EXISTING_NAMES=()    # hostnames, to avoid duplicates
while read -r id status; do
  cfg=$(pct config "$id" 2>/dev/null || true)
  found=0
  if grep -qiE 'proxmox-prusa-connect|^tags:.*prusa' <<<"$cfg"; then
    found=1
  elif [[ "$status" == "running" ]] && pct exec "$id" -- test -x "${APP_DIR}/prusa_connect" 2>/dev/null; then
    found=1
  fi
  if (( found )); then
    name=$(awk '/^hostname:/ {print $2}' <<<"$cfg")
    EXISTING+=("  ${id}  ${name:-unknown}  (${status})")
    EXISTING_NAMES+=("${name:-}")
  fi
done < <(pct list | awk 'NR>1 {print $1, $2}')

DEFAULT_HOSTNAME="prusa-connect"
if (( ${#EXISTING[@]} )); then
  msg_warn "Found ${#EXISTING[@]} existing Prusa Connect container(s)"
  whiptail --title "$TITLE" --defaultno --yesno \
"${APP_NAME} is already installed on this host:\n
$(printf '%s\n' "${EXISTING[@]}")\n
Your printer is connected to only ONE server – the one whose settings file it loaded. A second container is fine for testing.\n
Install another container anyway?" 18 72 || cancelled

  # suggest a hostname that is not used yet (two servers with the same name
  # would both announce themselves as <name>.local in the network)
  DEFAULT_HOSTNAME="prusa-connect-test"
  n=2
  while printf '%s\n' "${EXISTING_NAMES[@]}" | grep -qx "$DEFAULT_HOSTNAME"; do
    DEFAULT_HOSTNAME="prusa-connect-test${n}"; n=$((n + 1))
  done
  msg_info "Installing an additional container (suggested name: ${DEFAULT_HOSTNAME})"
else
  msg_ok "No existing Prusa Connect container found"
fi

# ---------- host resources ------------------------------------------------------
HOST_CORES=$(nproc)
HOST_RAM_FREE=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)

# ---------- settings ------------------------------------------------------------
NEXT_ID=$(pvesh get /cluster/nextid)
CTID=$(whiptail --title "$TITLE" --inputbox "Container ID:" 9 60 "$NEXT_ID" 3>&1 1>&2 2>&3) || cancelled
[[ "$CTID" =~ ^[0-9]+$ ]] || die "Invalid container ID."
if pct status "$CTID" >/dev/null 2>&1 || qm status "$CTID" >/dev/null 2>&1; then
  die "ID ${CTID} is already in use."
fi

CT_HOSTNAME=$(whiptail --title "$TITLE" --inputbox "Hostname:" 9 60 "$DEFAULT_HOSTNAME" 3>&1 1>&2 2>&3) || cancelled
[[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9-]+$ ]] || die "Invalid hostname."
if (( ${#EXISTING_NAMES[@]} )) && printf '%s\n' "${EXISTING_NAMES[@]}" | grep -qx "$CT_HOSTNAME"; then
  whiptail --title "$TITLE" --defaultno --yesno \
"The hostname '${CT_HOSTNAME}' is already used by another Prusa Connect container.\n\nBoth servers would announce themselves as '${CT_HOSTNAME}.local' and are easy to mix up.\n\nUse this name anyway?" 13 70 || cancelled
fi

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
  Type:          unprivileged LXC\n
(Start at boot is asked at the end.)\n
Create the container now?" 20 64 || cancelled

clear
echo -e "${BD}${TITLE}${CL}"
echo -e "Installing container ${CTID} (${CT_HOSTNAME}) – this takes about 1–3 minutes."
INSTALL_START=$SECONDS

# ---------- [1] find the newest release (pre-releases included) -----------------
step "Looking up the newest ${APP_NAME} release"
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

# ---------- [2] download + verify -----------------------------------------------
step "Downloading ${ASSET_NAME}"
curl -fL --progress-bar "$ASSET_URL" -o "$TMP_DIR/$ASSET_NAME" || die "Download failed."
msg_ok "Downloaded ($(du -h "$TMP_DIR/$ASSET_NAME" | cut -f1))"
if [[ "$ASSET_DIGEST" == sha256:* ]]; then
  echo "${ASSET_DIGEST#sha256:}  $TMP_DIR/$ASSET_NAME" | sha256sum -c --status \
    || die "Checksum mismatch – download damaged. Nothing was installed."
  msg_ok "Checksum verified (SHA256)"
else
  msg_warn "No checksum published by GitHub – verification skipped"
fi

# ---------- [3] Debian template -------------------------------------------------
step "Preparing Debian template"
run_spin "Updating template list" pveam update || msg_warn "Template list update failed – using cached list"
TEMPLATE=$(pveam available --section system | awk '{print $2}' \
  | grep -E '^debian-[0-9]+-standard_.*_amd64\.tar\.(zst|gz|xz)$' | sort -V | tail -n1)
[[ -n "$TEMPLATE" ]] || die "No Debian template found."
TPL_STORAGE=$(pvesm status -content vztmpl | awk 'NR>1 && $3=="active" {print $1; exit}')
[[ -n "$TPL_STORAGE" ]] || die "No storage for templates found."
if pveam list "$TPL_STORAGE" | grep -q "$TEMPLATE"; then
  msg_ok "Template already present: ${TEMPLATE}"
else
  run_spin "Downloading template ${TEMPLATE} (about 120 MB)" pveam download "$TPL_STORAGE" "$TEMPLATE"
fi

# ---------- [4] create + start container ----------------------------------------
step "Creating and starting container ${CTID}"
DESCRIPTION="<h3>${APP_NAME}</h3><p>Installed with proxmox-prusa-connect-lxc v${SCRIPT_VERSION}<br>Release: ${REL_TAG}<br>Web UI: port ${APP_PORT}</p><p>from JFFK</p>"
CT_CREATED=1   # set before create, so a half-created container is also rolled back
run_spin "Creating container" pct create "$CTID" "${TPL_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CORES" --memory "$RAM" --swap 256 \
  --rootfs "${CT_STORAGE}:${DISK}" \
  --net0 "$NET_CFG" \
  --unprivileged 1 --features nesting=1 \
  --onboot 0 --ostype debian \
  --tags "prusa;3d-printing" \
  --description "$DESCRIPTION"
run_spin "Starting container" pct start "$CTID"

MAX=60; start=$SECONDS; ONLINE=0
while (( SECONDS - start < MAX )); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then ONLINE=1; break; fi
  show_wait "Waiting for network in the container" $((SECONDS - start)) "$MAX"
  sleep 2
done
printf "\r\e[K"
(( ONLINE )) || die "Container has no network/DNS."
msg_ok "Container is online"

# ---------- [5] update container system -----------------------------------------
step "Updating the container system"
run_spin "Reading package lists" pct exec "$CTID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get update"
run_spin "Installing updates" pct exec "$CTID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get -y upgrade"
run_spin "Installing curl and certificates" pct exec "$CTID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get -y install curl ca-certificates"

# ---------- [6] install Prusa Connect -------------------------------------------
step "Installing ${APP_NAME} ${REL_TAG}"
pct exec "$CTID" -- bash -c "id ${APP_USER} >/dev/null 2>&1 || useradd --system --home ${APP_DIR} --shell /usr/sbin/nologin ${APP_USER}; mkdir -p ${APP_DIR}"
msg_ok "User '${APP_USER}' and folder ${APP_DIR} created"
pct push "$CTID" "$TMP_DIR/$ASSET_NAME" "${APP_DIR}/prusa_connect" --perms 0755
pct exec "$CTID" -- bash -c "echo '${REL_TAG}' > ${APP_DIR}/VERSION; chown -R ${APP_USER}:${APP_USER} ${APP_DIR}"
msg_ok "Program copied into the container"

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
msg_ok "systemd service created"

# ---------- [7] start service + wait for web UI ---------------------------------
step "Starting ${APP_NAME}"
pct exec "$CTID" -- systemctl daemon-reload
run_spin "Enabling and starting service" pct exec "$CTID" -- systemctl enable --now prusa-connect

MAX=120; start=$SECONDS; UP=0
while (( SECONDS - start < MAX )); do
  if pct exec "$CTID" -- curl -fs -o /dev/null --max-time 2 "http://127.0.0.1:${APP_PORT}"; then UP=1; break; fi
  show_wait "Waiting for the web interface on port ${APP_PORT}" $((SECONDS - start)) "$MAX"
  sleep 2
done
printf "\r\e[K"
INSTALL_DONE=1   # from here on the container is never removed automatically
if (( UP )); then msg_ok "Web interface answers"; else msg_warn "Web interface did not answer within ${MAX}s"; fi

# ---------- [8] read IP + setup code --------------------------------------------
step "Reading address and setup code"
CT_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
[[ -n "$CT_IP" ]] && msg_ok "IP address: ${CT_IP}" || msg_warn "IP address not found"

# The server logs a line like:  ... level=WARN msg="..." setup="POST /api/v1/setup" setup_code=XXXX
# A restart prints a new code, so always take the LAST one.
get_setup_code() {
  pct exec "$CTID" -- journalctl -u prusa-connect --no-pager -o cat 2>/dev/null \
    | grep -o 'setup_code=[^ ]*' | tail -n1 | cut -d= -f2- | tr -d '"' || true
}
SETUP_CODE=""
MAX=30; start=$SECONDS
while (( SECONDS - start < MAX )); do
  SETUP_CODE=$(get_setup_code)
  [[ -n "$SETUP_CODE" ]] && break
  show_wait "Waiting for the setup code in the log" $((SECONDS - start)) "$MAX"
  sleep 2
done
printf "\r\e[K"
[[ -n "$SETUP_CODE" ]] && msg_ok "Setup code found" || msg_warn "Setup code not found in the log"
ELAPSED=$((SECONDS - INSTALL_START))

# ---------- start at boot? ------------------------------------------------------
if whiptail --title "$TITLE" --yesno \
"Installation finished.\n\nShould container ${CTID} start automatically when the Proxmox host boots?\n\n(Recommended: Yes – otherwise Prusa Connect is offline after every host restart.)" 13 68; then
  pct set "$CTID" --onboot 1
  ONBOOT="yes"
  msg_ok "Start at boot: enabled"
else
  ONBOOT="no"
  msg_warn "Start at boot: disabled – start it manually with: pct start ${CTID}"
fi
echo
echo -e "${GN}${BD}==============================================================${CL}"
if (( UP )); then
  echo -e "${GN}${BD}  ${APP_NAME} is running!  (installed in $((ELAPSED / 60))m $((ELAPSED % 60))s)${CL}"
else
  msg_warn "Web interface did not answer yet. Check: pct exec ${CTID} -- journalctl -u prusa-connect"
fi
echo -e "${GN}${BD}==============================================================${CL}"
echo -e "  Web UI:      ${BD}http://${CT_IP}:${APP_PORT}${CL}"
echo -e "  Container:   ${CTID} (${CT_HOSTNAME})"
echo -e "  Autostart:   ${ONBOOT}"
echo -e "  Release:     ${REL_TAG}"
echo
if [[ -n "$SETUP_CODE" ]]; then
  echo -e "  Setup code:  ${GN}${BD}${SETUP_CODE}${CL}"
  echo    "               (works once – a restart of the service prints a new one)"
else
  echo -e "  Setup code:  not found yet"
fi
echo "  Show the current code again:"
echo "    pct exec ${CTID} -- journalctl -u prusa-connect --no-pager | grep -o 'setup_code=[^ ]*' | tail -n1"
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
