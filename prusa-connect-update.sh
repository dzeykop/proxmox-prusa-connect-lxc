#!/usr/bin/env bash
# =============================================================================
#  Prusa Connect Local – LXC update script
#  Version: 1.0.0
#  Author:  JFFK (github.com/dzeykop)
#  Repo:    https://github.com/dzeykop/proxmox-prusa-connect-lxc
#
#  Checks a Prusa Connect Local LXC container (created with
#  prusa-connect-lxc.sh) for a newer release. Nothing is installed without
#  your confirmation. Before the update a Proxmox snapshot is taken; if the
#  update fails, the container is rolled back automatically.
#
#  Run on the Proxmox host as root:
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/dzeykop/proxmox-prusa-connect-lxc/main/prusa-connect-update.sh)"
# =============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
APP_NAME="Prusa Connect Local"
GH_REPO="prusa3d/prusa-connect"
ASSET_NAME="prusa_connect_amd64"
APP_DIR="/opt/prusa-connect"
APP_USER="prusa-connect"
APP_PORT="8080"
SNAP_PREFIX="pre_update_"
TITLE="Prusa Connect Local Updater v${SCRIPT_VERSION}"

TMP_DIR="$(mktemp -d)"
CTID=""
SNAP_NAME=""
UPDATE_STARTED=0
UPDATE_OK=0
STEP=0
TOTAL_STEPS=6

# ---------- output helpers ----------------------------------------------------
GN="\e[32m"; YW="\e[33m"; RD="\e[31m"; BL="\e[36m"; CL="\e[0m"; BD="\e[1m"
msg_info() { echo -e " ${BL}[INFO]${CL} $*"; }
msg_ok()   { echo -e " ${GN}[ OK ]${CL} $*"; }
msg_warn() { echo -e " ${YW}[WARN]${CL} $*"; }
msg_err()  { echo -e " ${RD}[FAIL]${CL} $*" >&2; }
die()      { msg_err "$*"; exit 1; }

step() {
  STEP=$((STEP + 1))
  echo
  echo -e "${BD}[${STEP}/${TOTAL_STEPS}] $*${CL}"
}

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
    printf "\r\e[K"; msg_ok "$msg ($((SECONDS - start))s)"
  else
    printf "\r\e[K"; msg_err "$msg failed – last output:"
    tail -n 20 "$log" >&2
    return 1
  fi
}

show_wait() { printf "\r ${BL}[WAIT]${CL} %s ... %ds / max %ds " "$1" "$2" "$3"; }

# Puts the container back to the state before the update
rollback() {
  echo
  if [[ -n "$SNAP_NAME" ]]; then
    msg_warn "[ROLLBACK] Restoring snapshot '${SNAP_NAME}'..."
    pct stop "$CTID" >/dev/null 2>&1 || true
    if pct rollback "$CTID" "$SNAP_NAME" >/dev/null 2>&1 && pct start "$CTID" >/dev/null 2>&1; then
      msg_ok "[ROLLBACK] Container ${CTID} is back on the old version"
    else
      msg_err "[ROLLBACK] Automatic rollback failed – do it in Proxmox: Container ${CTID} → Snapshots → ${SNAP_NAME} → Rollback"
    fi
  else
    msg_warn "[ROLLBACK] Restoring the old program file..."
    if pct exec "$CTID" -- bash -c "systemctl stop prusa-connect; cp -a ${APP_DIR}/prusa_connect.bak ${APP_DIR}/prusa_connect && cp -a ${APP_DIR}/VERSION.bak ${APP_DIR}/VERSION && systemctl start prusa-connect" >/dev/null 2>&1; then
      msg_ok "[ROLLBACK] Old version restored"
    else
      msg_err "[ROLLBACK] Restore failed – check: pct exec ${CTID} -- ls -l ${APP_DIR}"
    fi
  fi
}

cleanup() {
  local rc=$?
  rm -rf "$TMP_DIR"
  if [[ $rc -ne 0 && $UPDATE_STARTED -eq 1 && $UPDATE_OK -eq 0 ]]; then
    rollback
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

msg_info "Checking internet connection..."
curl -fsS --max-time 10 -o /dev/null https://api.github.com \
  || die "No internet connection (api.github.com not reachable)."
msg_ok "Internet connection OK"

# ---------- [1] find Prusa Connect containers ----------------------------------
step "Looking for Prusa Connect containers"
CANDIDATES=()
while read -r id status _; do
  [[ "$status" == "running" ]] || continue
  if pct exec "$id" -- test -x "${APP_DIR}/prusa_connect" 2>/dev/null; then
    name=$(pct config "$id" | awk '/^hostname:/ {print $2}')
    CANDIDATES+=("$id" "${name:-unknown}")
  fi
done < <(pct list | awk 'NR>1 {print $1, $2}')

(( ${#CANDIDATES[@]} )) || die "No running container with ${APP_DIR}/prusa_connect found. Is the container started?"

if (( ${#CANDIDATES[@]} == 2 )); then
  CTID="${CANDIDATES[0]}"
  msg_ok "Found container ${CTID} (${CANDIDATES[1]})"
else
  CTID=$(whiptail --title "$TITLE" --menu "Which container should be checked?" 15 60 6 "${CANDIDATES[@]}" 3>&1 1>&2 2>&3) || cancelled
  msg_ok "Selected container ${CTID}"
fi

# ---------- [2] compare versions ------------------------------------------------
step "Comparing versions"
CUR_VER=$(pct exec "$CTID" -- cat "${APP_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]' || true)
if [[ -z "$CUR_VER" ]]; then
  # fallback: version from the start line in the log
  CUR_VER=$(pct exec "$CTID" -- journalctl -u prusa-connect --no-pager -o cat 2>/dev/null \
    | grep -o 'msg=starting version=[^ ]*' | tail -n1 | cut -d= -f3 || true)
fi
[[ -n "$CUR_VER" ]] || die "Could not read the installed version."

curl -fsSL "https://api.github.com/repos/${GH_REPO}/releases?per_page=10" -o "$TMP_DIR/releases.json" \
  || die "Could not read releases from GitHub."
read -r NEW_VER ASSET_URL ASSET_DIGEST REL_URL < <(perl -MJSON::PP -e '
  local $/; my $r = decode_json(<STDIN>);
  for my $rel (@$r) {
    next if $rel->{draft};
    for my $a (@{$rel->{assets}}) {
      if ($a->{name} eq $ARGV[0]) {
        print join(" ", $rel->{tag_name}, $a->{browser_download_url}, ($a->{digest} // "none"), $rel->{html_url}), "\n";
        exit 0;
      }
    }
  }' "$ASSET_NAME" < "$TMP_DIR/releases.json") || true
[[ -n "${ASSET_URL:-}" ]] || die "Release file ${ASSET_NAME} not found on GitHub."

echo -e "  Installed:  ${BD}${CUR_VER}${CL}"
echo -e "  Newest:     ${BD}${NEW_VER}${CL}"

if [[ "${CUR_VER#v}" == "${NEW_VER#v}" ]]; then
  echo
  msg_ok "Container ${CTID} is up to date – nothing to do."
  exit 0
fi
# dpkg understands pre-releases when "-" becomes "~" (0.1.0~beta.2 < 0.1.0)
CUR_CMP="${CUR_VER#v}"; NEW_CMP="${NEW_VER#v}"
if ! dpkg --compare-versions "${CUR_CMP//-/\~}" lt "${NEW_CMP//-/\~}"; then
  echo
  msg_ok "Installed version is newer than the newest release – nothing to do."
  exit 0
fi

whiptail --title "$TITLE" --defaultno --yesno \
"Update available for container ${CTID}:\n
  Installed:  ${CUR_VER}
  Newest:     ${NEW_VER}\n
Release notes:\n${REL_URL}\n
Prusa Connect Local is still beta – read the release notes first.\n
Install the update now? (A snapshot is taken first.)" 18 72 || cancelled

# ---------- [3] download + verify ----------------------------------------------
step "Downloading ${NEW_VER}"
curl -fL --progress-bar "$ASSET_URL" -o "$TMP_DIR/$ASSET_NAME" || die "Download failed – nothing was changed."
if [[ "$ASSET_DIGEST" == sha256:* ]]; then
  echo "${ASSET_DIGEST#sha256:}  $TMP_DIR/$ASSET_NAME" | sha256sum -c --status \
    || die "Checksum mismatch – download damaged. Nothing was changed."
  msg_ok "Checksum verified (SHA256)"
else
  msg_warn "No checksum published by GitHub – verification skipped"
fi

# ---------- [4] snapshot -------------------------------------------------------
step "Taking a safety snapshot"
SNAP_TRY="${SNAP_PREFIX}$(date +%Y%m%d_%H%M)"
if run_spin "Snapshot '${SNAP_TRY}'" pct snapshot "$CTID" "$SNAP_TRY" \
     --description "Before update ${CUR_VER} -> ${NEW_VER} (prusa-connect-update.sh)"; then
  SNAP_NAME="$SNAP_TRY"
else
  whiptail --title "$TITLE" --defaultno --yesno \
"A snapshot is not possible on this storage (snapshots need e.g. local-lvm or ZFS).\n\nContinue anyway? Only the old program file is kept as a backup – settings are NOT protected." 13 72 \
    || cancelled
  msg_warn "Continuing without snapshot"
fi

# ---------- [5] install --------------------------------------------------------
step "Installing ${NEW_VER}"
UPDATE_STARTED=1   # from here on any error triggers the automatic rollback
run_spin "Stopping service" pct exec "$CTID" -- systemctl stop prusa-connect
pct exec "$CTID" -- bash -c "cp -a ${APP_DIR}/prusa_connect ${APP_DIR}/prusa_connect.bak; cp -a ${APP_DIR}/VERSION ${APP_DIR}/VERSION.bak 2>/dev/null || echo '${CUR_VER}' > ${APP_DIR}/VERSION.bak"
msg_ok "Old program file kept as prusa_connect.bak"
pct push "$CTID" "$TMP_DIR/$ASSET_NAME" "${APP_DIR}/prusa_connect" --perms 0755
pct exec "$CTID" -- bash -c "echo '${NEW_VER}' > ${APP_DIR}/VERSION; chown -R ${APP_USER}:${APP_USER} ${APP_DIR}"
msg_ok "New program file installed"
RESTART_TS=$(pct exec "$CTID" -- date +%s)
run_spin "Starting service" pct exec "$CTID" -- systemctl start prusa-connect

# ---------- [6] health check ---------------------------------------------------
step "Checking that ${APP_NAME} works"
MAX=90; start=$SECONDS; UP=0
while (( SECONDS - start < MAX )); do
  if pct exec "$CTID" -- systemctl is-active --quiet prusa-connect \
     && pct exec "$CTID" -- curl -fs -o /dev/null --max-time 2 "http://127.0.0.1:${APP_PORT}/api/v1/health"; then
    UP=1; break
  fi
  show_wait "Waiting for the web interface" $((SECONDS - start)) "$MAX"
  sleep 3
done
printf "\r\e[K"
(( UP )) || die "The new version does not answer on port ${APP_PORT}."
UPDATE_OK=1
msg_ok "Web interface answers – update successful"

# setup code only appears if the setup wizard was never finished
SETUP_CODE=$(pct exec "$CTID" -- journalctl -u prusa-connect --no-pager -o cat --since "@${RESTART_TS}" 2>/dev/null \
  | grep -o 'setup_code=[^ ]*' | tail -n1 | cut -d= -f2- | tr -d '"' || true)

# ---------- clean up old snapshots ---------------------------------------------
mapfile -t OLD_SNAPS < <(pct listsnapshot "$CTID" 2>/dev/null \
  | grep -o "${SNAP_PREFIX}[0-9_]*" | sort -u | grep -vx "${SNAP_NAME:-none}" || true)
if (( ${#OLD_SNAPS[@]} )); then
  if whiptail --title "$TITLE" --yesno \
"Update successful.\n\nDelete ${#OLD_SNAPS[@]} snapshot(s) from EARLIER updates?\n\n$(printf '  %s\n' "${OLD_SNAPS[@]}")\n\nThe snapshot of this update (${SNAP_NAME:-none}) is kept, so you can still go back if a problem shows up later." 18 72; then
    for s in "${OLD_SNAPS[@]}"; do
      run_spin "Deleting snapshot ${s}" pct delsnapshot "$CTID" "$s" || msg_warn "Could not delete ${s}"
    done
  else
    msg_info "Old snapshots kept"
  fi
fi

CT_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo
echo -e "${GN}${BD}==============================================================${CL}"
echo -e "${GN}${BD}  Updated: ${CUR_VER}  →  ${NEW_VER}${CL}"
echo -e "${GN}${BD}==============================================================${CL}"
echo -e "  Web UI:      ${BD}http://${CT_IP}:${APP_PORT}${CL}"
echo -e "  Container:   ${CTID}"
[[ -n "$SNAP_NAME" ]] && echo -e "  Snapshot:    ${SNAP_NAME} (Proxmox → Container ${CTID} → Snapshots)"
[[ -n "$SETUP_CODE" ]] && echo -e "  Setup code:  ${GN}${BD}${SETUP_CODE}${CL} (wizard not finished yet)"
echo
echo "  Something wrong after the update? Go back with:"
if [[ -n "$SNAP_NAME" ]]; then
  echo "    pct stop ${CTID} && pct rollback ${CTID} ${SNAP_NAME} && pct start ${CTID}"
else
  echo "    pct exec ${CTID} -- bash -c 'systemctl stop prusa-connect; cp -a ${APP_DIR}/prusa_connect.bak ${APP_DIR}/prusa_connect; systemctl start prusa-connect'"
fi
echo
echo "  from JFFK"
