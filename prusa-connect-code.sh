#!/usr/bin/env bash
# =============================================================================
#  Prusa Connect Local – show setup code
#  Version: 1.0.0
#  Author:  JFFK (github.com/dzeykop)
#  Repo:    https://github.com/dzeykop/proxmox-prusa-connect-lxc
#
#  Lists all LXC containers, recommends the Prusa Connect container and shows
#  its web address and the current one-time setup code.
#  The code is only needed until the setup wizard is finished.
#
#  Run on the Proxmox host as root:
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/dzeykop/proxmox-prusa-connect-lxc/main/prusa-connect-code.sh)"
# =============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
APP_NAME="Prusa Connect Local"
APP_DIR="/opt/prusa-connect"
APP_PORT="8080"
TITLE="Prusa Connect Local – Setup Code v${SCRIPT_VERSION}"

# ---------- output helpers ----------------------------------------------------
GN="\e[32m"; YW="\e[33m"; RD="\e[31m"; BL="\e[36m"; CL="\e[0m"; BD="\e[1m"
msg_info() { echo -e " ${BL}[INFO]${CL} $*"; }
msg_ok()   { echo -e " ${GN}[ OK ]${CL} $*"; }
msg_warn() { echo -e " ${YW}[WARN]${CL} $*"; }
msg_err()  { echo -e " ${RD}[FAIL]${CL} $*" >&2; }
die()      { msg_err "$*"; echo; exit 1; }

cancelled() { echo; msg_warn "Cancelled by user."; exit 0; }

# ---------- pre-flight checks ---------------------------------------------------
clear
echo -e "${BD}${TITLE}${CL}\n"

[[ $EUID -eq 0 ]] || die "Please run this script as root."
command -v pct >/dev/null && command -v pveversion >/dev/null \
  || die "This script must run on a Proxmox VE host."
command -v whiptail >/dev/null || die "whiptail not found."

# ---------- read all LXC containers ---------------------------------------------
msg_info "Reading LXC containers..."
MENU=()
BEST_ID=""
BEST_SCORE=0
while read -r id status; do
  name=$(pct config "$id" 2>/dev/null | awk '/^hostname:/ {print $2}')
  name="${name:-unknown}"
  lname="${name,,}"

  # recommendation: "prusa" counts most, then "connect", then "local"
  score=0
  [[ "$lname" == *prusa*   ]] && score=$((score + 3))
  [[ "$lname" == *connect* ]] && score=$((score + 2))
  [[ "$lname" == *local*   ]] && score=$((score + 1))
  [[ "$status" == "running" ]] && (( score > 0 )) && score=$((score + 1))

  label="${name}  (${status})"
  if (( score > BEST_SCORE )); then
    BEST_SCORE=$score
    BEST_ID=$id
  fi
  MENU+=("$id" "$label")
done < <(pct list | awk 'NR>1 {print $1, $2}')

(( ${#MENU[@]} )) || die "No LXC containers found on this host."
msg_ok "Found $(( ${#MENU[@]} / 2 )) container(s)"

# mark the recommended container
DEFAULT_ARGS=()
PROMPT="Show the setup code of which container?"
if [[ -n "$BEST_ID" ]]; then
  for ((i = 0; i < ${#MENU[@]}; i += 2)); do
    [[ "${MENU[i]}" == "$BEST_ID" ]] && MENU[i+1]="${MENU[i+1]}  <- recommended"
  done
  DEFAULT_ARGS=(--default-item "$BEST_ID")
  PROMPT="${PROMPT}\n\nRecommended: ${BEST_ID} – just press Enter to confirm."
fi

CTID=$(whiptail --title "$TITLE" "${DEFAULT_ARGS[@]}" --menu "$PROMPT" 18 70 8 \
  "${MENU[@]}" 3>&1 1>&2 2>&3) || cancelled
CT_NAME=$(pct config "$CTID" | awk '/^hostname:/ {print $2}')
msg_ok "Selected container ${CTID} (${CT_NAME:-unknown})"

# ---------- checks on the selected container ------------------------------------
STATUS=$(pct status "$CTID" | awk '{print $2}')
if [[ "$STATUS" != "running" ]]; then
  die "Container ${CTID} is not running (status: ${STATUS}).
        Start it with:  pct start ${CTID}
        Then run this script again."
fi

if ! pct exec "$CTID" -- test -x "${APP_DIR}/prusa_connect" 2>/dev/null; then
  die "${APP_NAME} is not installed in container ${CTID} (${APP_DIR}/prusa_connect not found).
        Did you choose the right container?"
fi

if ! pct exec "$CTID" -- systemctl is-active --quiet prusa-connect 2>/dev/null; then
  die "The service prusa-connect is not running in container ${CTID}.
        Start it with:  pct exec ${CTID} -- systemctl start prusa-connect
        Then run this script again (a start prints a new code)."
fi

# ---------- read setup code + IP ------------------------------------------------
# Only the log of the CURRENT service run is read – codes from earlier runs
# are invalid. No code in this run means the setup wizard is finished.
INV_ID=$(pct exec "$CTID" -- systemctl show -p InvocationID --value prusa-connect 2>/dev/null || true)
CODE=""
if [[ -n "$INV_ID" ]]; then
  CODE=$(pct exec "$CTID" -- journalctl --no-pager -o cat "_SYSTEMD_INVOCATION_ID=${INV_ID}" 2>/dev/null \
    | grep -o 'setup_code=[^ ]*' | tail -n1 | cut -d= -f2- | tr -d '"' || true)
fi
CT_IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')

# ---------- result --------------------------------------------------------------
echo
echo -e "${GN}${BD}==============================================================${CL}"
echo -e "  Container:   ${CTID} (${CT_NAME:-unknown})"
echo -e "  Web UI:      ${BD}http://${CT_IP:-<container-ip>}:${APP_PORT}${CL}"
echo
if [[ -n "$CODE" ]]; then
  echo -e "  Setup code:  ${GN}${BD}${CODE}${CL}"
  echo    "               Works once – a restart of the service prints a new one."
else
  echo -e "  Setup code:  ${YW}${BD}Setup already finished – no code needed.${CL}"
  echo    "               Log in at the Web UI with your admin account."
fi
echo -e "${GN}${BD}==============================================================${CL}"
echo
echo "  from JFFK"
