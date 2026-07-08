#!/usr/bin/env bash
# =============================================
# Proxmox VE Cluster Rolling Reboot Script
# =============================================
# - Auto-detects cluster nodes via pvecm
# - Reboots one node at a time
# - Migrates VMs/CTs away before rebooting a node
# - Requires cluster quorum and Ceph HEALTH_OK before each reboot
# - Waits for the node and Ceph health to recover before continuing
# - Can run on a Proxmox node or from a workstation via --cluster-host
#
# Requirements:
# - Run as root on a Proxmox VE node, or use --cluster-host from a workstation
# - SSH key-based login between cluster nodes (root)
# - Shared or otherwise migratable guest storage, unless suitable
#   migration options are provided
# =============================================

# ---- COLORS ----
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -n, --dry-run             Show what would be migrated/rebooted, but do not change anything
  -y, --yes                 Do not prompt for confirmation before starting
      --cluster-host HOST   Run Proxmox/Ceph commands through this cluster node over SSH
      --ssh-user USER       SSH user for hosts without an explicit user@ prefix (default: root)
      --ssh-option OPTION   Extra local SSH -o option, may be repeated
      --direct-node-ssh     In --cluster-host mode, connect to cluster nodes directly instead of through the cluster host
      --nodes LIST          Only reboot comma-separated node names
      --exclude LIST        Exclude comma-separated node names from reboot
      --running-only        Only migrate running guests; stopped guests may remain on the node
      --target-storage NAME Pass target storage to migrations
      --qm-with-local-disks Pass --with-local-disks 1 to qm migrate
      --skip-ceph-check     Disable Ceph health gates (not recommended for Ceph clusters)
      --migration-timeout N Seconds allowed for each guest migration (default: 14400)
      --reboot-timeout N    Seconds allowed for each node reboot cycle (default: 1800)
      --ceph-timeout N      Seconds to wait for Ceph HEALTH_OK (default: 1800)
  -h, --help                Show this help message

By default the script migrates all VMs/CTs it finds on each node before rebooting
that node. Use --running-only if your policy is to drain only active workloads.

From macOS or another workstation, use --cluster-host with a Proxmox node that
can run pvecm, ceph, qm, and pct. Other node SSH commands are relayed through
that host by default, using the cluster's existing inter-node SSH access.
EOF
}

# ---- ARRAYS / VARIABLES ----
DRY_RUN=0
ASSUME_YES=0
RUNNING_ONLY=0
CEPH_REQUIRED=1
QM_WITH_LOCAL_DISKS=0
CLUSTER_HOST=""
SSH_USER="root"
DIRECT_NODE_SSH=0
TARGET_STORAGE=""
ONLY_NODES=()
EXCLUDE_NODES=()
EXTRA_SSH_OPTS=()
TUI_ENABLED=0
TUI_DIR=""
LOG_FILE=""
REMOTE_CHECK_TIMEOUT=120
MIGRATION_TIMEOUT=14400
REBOOT_TIMEOUT=1800
CEPH_WAIT_TIMEOUT=1800
QUORUM_WAIT_TIMEOUT=300
NODE_READY_TIMEOUT=600
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ConnectionAttempts=1
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=4
)

# ---- ARGUMENT PARSING ----
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -y|--yes)
      ASSUME_YES=1
      shift
      ;;
    --cluster-host)
      if [ -z "${2:-}" ]; then
        echo -e "${RED}Error: --cluster-host requires a host name or user@host target.${RESET}"
        exit 1
      fi
      CLUSTER_HOST="$2"
      shift 2
      ;;
    --ssh-user)
      if [ -z "${2:-}" ]; then
        echo -e "${RED}Error: --ssh-user requires a user name.${RESET}"
        exit 1
      fi
      SSH_USER="$2"
      shift 2
      ;;
    --ssh-option)
      if [ -z "${2:-}" ]; then
        echo -e "${RED}Error: --ssh-option requires an OpenSSH option value, for example StrictHostKeyChecking=accept-new.${RESET}"
        exit 1
      fi
      EXTRA_SSH_OPTS+=(-o "$2")
      shift 2
      ;;
    --direct-node-ssh)
      DIRECT_NODE_SSH=1
      shift
      ;;
    --nodes)
      if [ -z "${2:-}" ]; then
        echo -e "${RED}Error: --nodes requires a comma-separated node list.${RESET}"
        exit 1
      fi
      IFS=',' read -r -a ONLY_NODES <<< "$2"
      shift 2
      ;;
    --exclude)
      if [ -z "${2:-}" ]; then
        echo -e "${RED}Error: --exclude requires a comma-separated node list.${RESET}"
        exit 1
      fi
      IFS=',' read -r -a EXCLUDE_NODES <<< "$2"
      shift 2
      ;;
    --running-only)
      RUNNING_ONLY=1
      shift
      ;;
    --target-storage)
      if [ -z "${2:-}" ]; then
        echo -e "${RED}Error: --target-storage requires a storage name.${RESET}"
        exit 1
      fi
      TARGET_STORAGE="$2"
      shift 2
      ;;
    --qm-with-local-disks)
      QM_WITH_LOCAL_DISKS=1
      shift
      ;;
    --skip-ceph-check)
      CEPH_REQUIRED=0
      shift
      ;;
    --migration-timeout)
      if [ -z "${2:-}" ] || [[ ! "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
        echo -e "${RED}Error: --migration-timeout requires a positive integer.${RESET}"
        exit 1
      fi
      MIGRATION_TIMEOUT="$2"
      shift 2
      ;;
    --reboot-timeout)
      if [ -z "${2:-}" ] || [[ ! "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
        echo -e "${RED}Error: --reboot-timeout requires a positive integer.${RESET}"
        exit 1
      fi
      REBOOT_TIMEOUT="$2"
      shift 2
      ;;
    --ceph-timeout)
      if [ -z "${2:-}" ] || [[ ! "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
        echo -e "${RED}Error: --ceph-timeout requires a positive integer.${RESET}"
        exit 1
      fi
      CEPH_WAIT_TIMEOUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}Error: unknown option '$1'.${RESET}"
      usage
      exit 1
      ;;
  esac
done

if [ -z "${BASH_VERSINFO:-}" ] ||
  [ "${BASH_VERSINFO[0]}" -lt 3 ] ||
  { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  echo -e "${RED}Error: this script requires Bash 3.2 or newer.${RESET}"
  exit 1
fi

# ---- FUNCTIONS ----
fail() {
  if [ "${TUI_ENABLED:-0}" -eq 1 ]; then
    emit_message "ERROR" "$RED" "$*"
  else
    echo -e "${RED}Error: $*${RESET}" >&2
  fi
  exit 1
}

emit_message() {
  local LEVEL="$1"
  local COLOR="$2"
  shift 2
  local MESSAGE="$*"
  local TIMESTAMP

  TIMESTAMP=$(date '+%H:%M:%S')

  if [ -n "${LOG_FILE:-}" ]; then
    printf "%s [%s] %s\n" "$TIMESTAMP" "$LEVEL" "$MESSAGE" >> "$LOG_FILE"
  fi

  if [ "${TUI_ENABLED:-0}" -eq 1 ]; then
    render_tui
  else
    printf "%b%s%b\n" "$COLOR" "$MESSAGE" "$RESET"
  fi
}

log_command_output() {
  local OUTPUT="$1"
  local LINE

  if [ -z "$OUTPUT" ]; then
    return
  fi

  while IFS= read -r LINE; do
    if [ -n "$LINE" ]; then
      emit_message "CMD" "$RESET" "$LINE"
    fi
  done <<< "$OUTPUT"
}

error_msg() {
  emit_message "ERROR" "$RED" "$*"
}

warn() {
  emit_message "WARN" "$YELLOW" "Warning: $*"
}

info() {
  emit_message "INFO" "$CYAN" "$*"
}

ok() {
  emit_message "OK" "$GREEN" "$*"
}

clear_screen() {
  if [ -t 1 ]; then
    if command -v clear >/dev/null 2>&1; then
      clear
    else
      printf "\033[H\033[2J"
    fi
  fi
}

list_contains() {
  local NEEDLE="$1"
  shift

  for ITEM in "$@"; do
    if [ "$ITEM" = "$NEEDLE" ]; then
      return 0
    fi
  done

  return 1
}

ssh_destination() {
  local HOST="$1"

  if [[ "$HOST" == *@* ]]; then
    printf "%s" "$HOST"
  else
    printf "%s@%s" "$SSH_USER" "$HOST"
  fi
}

strip_ssh_user() {
  local DEST="$1"

  printf "%s" "${DEST#*@}"
}

strip_ssh_port() {
  local HOST="$1"

  printf "%s" "${HOST%%:*}"
}

node_matches_control() {
  local NODE="$1"
  local CONTROL_HOST_ONLY

  CONTROL_HOST_ONLY=$(strip_ssh_port "$(strip_ssh_user "$CONTROL_SSH_DEST")")

  [ "$NODE" = "$CONTROL_CLUSTER_NODE" ] ||
    [ "$NODE" = "$CONTROL_SHORT_HOSTNAME" ] ||
    [ "$NODE" = "$CONTROL_HOSTNAME" ] ||
    [ "$NODE" = "$CONTROL_HOST_ONLY" ]
}

ssh_run() {
  local DEST="$1"
  shift

  # shellcheck disable=SC2029 # Callers intentionally pass the remote command as SSH arguments.
  ssh "${SSH_OPTS[@]}" "${EXTRA_SSH_OPTS[@]}" "$DEST" "$@"
}

cluster_run() {
  local TIMEOUT_SECONDS="$1"
  local COMMAND="$2"

  if [ "$RUN_CONTEXT" = "remote" ]; then
    # shellcheck disable=SC2029 # COMMAND is intentionally quoted locally before SSH sends it.
    ssh_run "$CONTROL_SSH_DEST" "timeout --preserve-status ${TIMEOUT_SECONDS}s bash -lc $(printf '%q' "$COMMAND")"
  else
    bash -lc "$COMMAND"
  fi
}

control_to_node_ssh_command() {
  local NODE="$1"
  shift
  local DEST
  local ARGS=()

  DEST=$(ssh_destination "$NODE")
  ARGS=(ssh "${SSH_OPTS[@]}" "$DEST" "$@")
  shell_join "${ARGS[@]}"
}

remote_run() {
  local NODE="$1"
  local TIMEOUT_SECONDS="$2"
  local COMMAND="$3"
  local DEST
  local TARGET_COMMAND
  local CONTROL_COMMAND

  TARGET_COMMAND="timeout --preserve-status ${TIMEOUT_SECONDS}s bash -lc $(printf '%q' "$COMMAND")"

  if [ "$RUN_CONTEXT" = "remote" ] &&
    ! node_matches_control "$NODE" &&
    [ "$DIRECT_NODE_SSH" -eq 0 ]; then
    CONTROL_COMMAND=$(control_to_node_ssh_command "$NODE" "$TARGET_COMMAND")
    cluster_run "$TIMEOUT_SECONDS" "$CONTROL_COMMAND"
    return
  fi

  if [ "$RUN_CONTEXT" = "remote" ] && node_matches_control "$NODE"; then
    DEST="$CONTROL_SSH_DEST"
  else
    DEST=$(ssh_destination "$NODE")
  fi

  # shellcheck disable=SC2029 # COMMAND is intentionally quoted locally before SSH sends it.
  ssh "${SSH_OPTS[@]}" "${EXTRA_SSH_OPTS[@]}" "$DEST" "$TARGET_COMMAND"
}

ssh_available() {
  local NODE="$1"

  remote_run "$NODE" "$REMOTE_CHECK_TIMEOUT" 'true' >/dev/null 2>&1
}

print_rule() {
  local WIDTH="${RULE_WIDTH:-80}"
  local LINE

  LINE=$(printf "%*s" "$WIDTH" "" | tr ' ' '=')
  printf "%b\n" "${CYAN}${LINE}${RESET}"
}

print_title() {
  local TITLE="$1"

  print_rule
  printf "%b\n" "${CYAN}${BOLD}$TITLE${RESET}"
  print_rule
}

print_meta() {
  local LABEL="$1"
  local VALUE="$2"
  local WIDTH="${3:-18}"

  printf "%b%-*s%b %s\n" "$BOLD" "$WIDTH" "$LABEL:" "$RESET" "$VALUE"
}

terminal_width() {
  local WIDTH

  WIDTH=$(tput cols 2>/dev/null || true)
  if [[ ! "$WIDTH" =~ ^[0-9]+$ ]] || [ "$WIDTH" -lt 40 ]; then
    WIDTH=80
  fi

  printf "%s" "$WIDTH"
}

terminal_height() {
  local HEIGHT

  HEIGHT=$(tput lines 2>/dev/null || true)
  if [[ ! "$HEIGHT" =~ ^[0-9]+$ ]] || [ "$HEIGHT" -lt 16 ]; then
    HEIGHT=24
  fi

  printf "%s" "$HEIGHT"
}

truncate_text() {
  local TEXT="$1"
  local WIDTH="$2"

  if [ "$WIDTH" -le 0 ]; then
    return
  fi

  if [ "${#TEXT}" -le "$WIDTH" ]; then
    printf "%s" "$TEXT"
  elif [ "$WIDTH" -eq 1 ]; then
    printf ">"
  else
    printf "%s>" "${TEXT:0:$((WIDTH - 1))}"
  fi
}

repeat_char() {
  local CHAR="$1"
  local COUNT="$2"

  printf "%*s" "$COUNT" "" | tr ' ' "$CHAR"
}

node_status_file() {
  local NODE="$1"
  local SAFE_NODE

  SAFE_NODE=$(printf "%s" "$NODE" | sed 's/[^A-Za-z0-9_.-]/_/g')
  printf "%s/%s.status" "$TUI_DIR" "$SAFE_NODE"
}

tui_set_node() {
  local NODE="$1"
  local PHASE="$2"
  local GUESTS="$3"
  local MESSAGE="$4"
  local STATUS_FILE

  if [ "${TUI_ENABLED:-0}" -ne 1 ]; then
    return
  fi

  STATUS_FILE=$(node_status_file "$NODE")
  {
    printf "%s\n" "$PHASE"
    printf "%s\n" "$GUESTS"
    printf "%s\n" "$MESSAGE"
  } > "$STATUS_FILE"

  render_tui
}

tui_read_node_field() {
  local NODE="$1"
  local FIELD="$2"
  local DEFAULT="$3"
  local STATUS_FILE
  local VALUE

  if [ "${TUI_ENABLED:-0}" -ne 1 ]; then
    printf "%s" "$DEFAULT"
    return
  fi

  STATUS_FILE=$(node_status_file "$NODE")
  if [ -f "$STATUS_FILE" ]; then
    VALUE=$(sed -n "${FIELD}p" "$STATUS_FILE")
  fi

  if [ -z "$VALUE" ]; then
    VALUE="$DEFAULT"
  fi

  printf "%s" "$VALUE"
}

render_tui() {
  local WIDTH
  local HEIGHT
  local NODE_COL_WIDTH=16
  local PHASE_COL_WIDTH=14
  local GUESTS_COL_WIDTH=7
  local MESSAGE_COL_WIDTH
  local NODE
  local PHASE
  local GUESTS
  local MESSAGE
  local COMPLETE_COUNT=0
  local TOP_LINES
  local MAX_NODE_ROWS
  local NODE_ROWS_PRINTED=0
  local LOG_LINES
  local TITLE="Proxmox VE Cluster Rolling Reboot"
  local CONTEXT_LABEL

  if [ "${TUI_ENABLED:-0}" -ne 1 ]; then
    return
  fi

  WIDTH=$(terminal_width)
  HEIGHT=$(terminal_height)
  MESSAGE_COL_WIDTH=$((WIDTH - NODE_COL_WIDTH - PHASE_COL_WIDTH - GUESTS_COL_WIDTH - 10))
  if [ "$MESSAGE_COL_WIDTH" -lt 16 ]; then
    MESSAGE_COL_WIDTH=16
  fi

  TOP_LINES=$((10 + ${#ORDERED_NODES[@]}))
  if [ "$TOP_LINES" -gt $((HEIGHT - 6)) ]; then
    TOP_LINES=$((HEIGHT - 6))
  fi
  if [ "$TOP_LINES" -lt 10 ]; then
    TOP_LINES=10
  fi

  MAX_NODE_ROWS=$((TOP_LINES - 9))
  if [ "$MAX_NODE_ROWS" -lt 1 ]; then
    MAX_NODE_ROWS=1
  fi

  LOG_LINES=$((HEIGHT - TOP_LINES - 2))
  if [ "$LOG_LINES" -lt 4 ]; then
    LOG_LINES=4
  fi

  for NODE in "${ORDERED_NODES[@]}"; do
    PHASE=$(tui_read_node_field "$NODE" 1 "Pending")
    case "$PHASE" in
      Complete|Dry-run|Local\ reboot\ scheduled|Failed)
        COMPLETE_COUNT=$((COMPLETE_COUNT + 1))
        ;;
    esac
  done

  if [ "$RUN_CONTEXT" = "remote" ]; then
    CONTEXT_LABEL="remote via $CONTROL_SSH_DEST"
  else
    CONTEXT_LABEL="local Proxmox node"
  fi

  printf "\033[H\033[2J"
  printf "%b%s%b\n" "$CYAN$BOLD" "$(truncate_text "$TITLE" "$WIDTH")" "$RESET"
  printf "%s\n" "$(repeat_char "=" "$WIDTH")"
  printf "Context: %s | Mode: %s | Ceph: %s | Progress: %s/%s\n" \
    "$(truncate_text "$CONTEXT_LABEL" 24)" \
    "$RUN_MODE" \
    "$(truncate_text "$CEPH_MODE" 18)" \
    "$COMPLETE_COUNT" \
    "${#ORDERED_NODES[@]}"
  printf "Control: %s | Guests: %s\n" \
    "$(truncate_text "$CONTROL_CLUSTER_NODE" 22)" \
    "$(truncate_text "$GUEST_SCOPE" $((WIDTH - 34)))"
  printf "%s\n" "$(repeat_char "-" "$WIDTH")"
  printf "%-*s  %-*s  %-*s  %s\n" "$NODE_COL_WIDTH" "Node" "$PHASE_COL_WIDTH" "State" "$GUESTS_COL_WIDTH" "Guests" "Status"
  printf "%-*s  %-*s  %-*s  %s\n" \
    "$NODE_COL_WIDTH" "$(repeat_char "-" "$NODE_COL_WIDTH")" \
    "$PHASE_COL_WIDTH" "$(repeat_char "-" "$PHASE_COL_WIDTH")" \
    "$GUESTS_COL_WIDTH" "$(repeat_char "-" "$GUESTS_COL_WIDTH")" \
    "$(repeat_char "-" "$MESSAGE_COL_WIDTH")"

  for NODE in "${ORDERED_NODES[@]}"; do
    if [ "$NODE_ROWS_PRINTED" -ge "$MAX_NODE_ROWS" ]; then
      printf "... %s more node(s)\n" "$((${#ORDERED_NODES[@]} - NODE_ROWS_PRINTED))"
      break
    fi

    PHASE=$(tui_read_node_field "$NODE" 1 "Pending")
    GUESTS=$(tui_read_node_field "$NODE" 2 "-")
    MESSAGE=$(tui_read_node_field "$NODE" 3 "Queued")

    printf "%-*s  %-*s  %-*s  %s\n" \
      "$NODE_COL_WIDTH" "$(truncate_text "$NODE" "$NODE_COL_WIDTH")" \
      "$PHASE_COL_WIDTH" "$(truncate_text "$PHASE" "$PHASE_COL_WIDTH")" \
      "$GUESTS_COL_WIDTH" "$(truncate_text "$GUESTS" "$GUESTS_COL_WIDTH")" \
      "$(truncate_text "$MESSAGE" "$MESSAGE_COL_WIDTH")"
    NODE_ROWS_PRINTED=$((NODE_ROWS_PRINTED + 1))
  done

  printf "%s\n" "$(repeat_char "=" "$WIDTH")"
  printf "%bLogs%b\n" "$BOLD" "$RESET"
  if [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
    tail -n "$LOG_LINES" "$LOG_FILE" | while IFS= read -r LINE; do
      printf "%s\n" "$(truncate_text "$LINE" "$WIDTH")"
    done
  fi
}

init_tui() {
  local NODE
  local MESSAGE

  if [ ! -t 1 ]; then
    TUI_ENABLED=0
    return
  fi

  TUI_DIR=$(mktemp -d /tmp/proxmox-rolling-reboot.XXXXXX) || {
    TUI_ENABLED=0
    return
  }
  LOG_FILE="$TUI_DIR/run.log"
  : > "$LOG_FILE"
  TUI_ENABLED=1

  for NODE in "${ORDERED_NODES[@]}"; do
    MESSAGE="Queued"
    if is_control_node "$NODE"; then
      MESSAGE="Control node, queued last"
    fi
    tui_set_node "$NODE" "Pending" "-" "$MESSAGE"
  done

  render_tui
}

cleanup_tui() {
  if [ -n "${TUI_DIR:-}" ] && [ -d "$TUI_DIR" ]; then
    rm -rf "$TUI_DIR"
  fi
}

now_epoch() {
  date +%s
}

shell_join() {
  local QUOTED=""
  local OUT=""
  local ARG

  for ARG in "$@"; do
    printf -v QUOTED "%q" "$ARG"
    OUT+="$QUOTED "
  done

  printf "%s" "${OUT% }"
}

guest_label() {
  local TYPE="$1"
  local VMID="$2"
  local STATUS="$3"

  if [ "$TYPE" = "qemu" ]; then
    printf "VM %s (%s)" "$VMID" "$STATUS"
  else
    printf "CT %s (%s)" "$VMID" "$STATUS"
  fi
}

guest_should_move() {
  local STATUS="$1"

  if [ "$RUNNING_ONLY" -eq 1 ] && [ "$STATUS" != "running" ]; then
    return 1
  fi

  return 0
}

list_guests_on_node() {
  local NODE="$1"
  local COMMAND

  COMMAND="
qm list 2>/dev/null | awk 'NR>1 {print \"qemu|\" \$1 \"|\" \$3}'
pct list 2>/dev/null | awk 'NR>1 {print \"lxc|\" \$1 \"|\" \$2}'
"

  remote_run "$NODE" "$REMOTE_CHECK_TIMEOUT" "$COMMAND"
}

count_guests_on_node() {
  local NODE="$1"
  local OUTPUT
  local TYPE
  local VMID
  local STATUS
  local COUNT=0

  if ! OUTPUT=$(list_guests_on_node "$NODE" 2>/dev/null); then
    return 1
  fi

  while IFS='|' read -r TYPE VMID STATUS; do
    if [ -z "$TYPE$VMID$STATUS" ]; then
      continue
    fi
    COUNT=$((COUNT + 1))
  done <<< "$OUTPUT"

  printf "%s\n" "$COUNT"
}

candidate_nodes_by_load() {
  local SOURCE="$1"
  local CANDIDATE
  local COUNT

  for CANDIDATE in "${DETECTED_NODES[@]}"; do
    if [ "$CANDIDATE" = "$SOURCE" ]; then
      continue
    fi

    if ! ssh_available "$CANDIDATE"; then
      continue
    fi

    if ! COUNT=$(count_guests_on_node "$CANDIDATE"); then
      continue
    fi

    printf "%06d|%s\n" "$COUNT" "$CANDIDATE"
  done | sort -n | awk -F'|' '{print $2}'
}

build_migrate_command() {
  local TYPE="$1"
  local VMID="$2"
  local STATUS="$3"
  local TARGET="$4"
  local ARGS=()

  if [ "$TYPE" = "qemu" ]; then
    ARGS=(qm migrate "$VMID" "$TARGET")

    if [ "$STATUS" = "running" ]; then
      ARGS+=(--online 1)
    fi

    if [ "$QM_WITH_LOCAL_DISKS" -eq 1 ]; then
      ARGS+=(--with-local-disks 1)
    fi

    if [ -n "$TARGET_STORAGE" ]; then
      ARGS+=(--targetstorage "$TARGET_STORAGE")
    fi
  else
    ARGS=(pct migrate "$VMID" "$TARGET")

    if [ "$STATUS" = "running" ]; then
      ARGS+=(--online 1)
    fi

    if [ -n "$TARGET_STORAGE" ]; then
      ARGS+=(--target-storage "$TARGET_STORAGE")
    fi
  fi

  shell_join "${ARGS[@]}"
}

guest_still_on_node() {
  local NODE="$1"
  local TYPE_TO_FIND="$2"
  local VMID_TO_FIND="$3"
  local OUTPUT
  local TYPE
  local VMID
  local STATUS

  if ! OUTPUT=$(list_guests_on_node "$NODE" 2>/dev/null); then
    return 0
  fi

  while IFS='|' read -r TYPE VMID STATUS; do
    if [ "$TYPE" = "$TYPE_TO_FIND" ] && [ "$VMID" = "$VMID_TO_FIND" ]; then
      return 0
    fi
  done <<< "$OUTPUT"

  return 1
}

wait_for_guest_to_leave_node() {
  local NODE="$1"
  local TYPE="$2"
  local VMID="$3"
  local LABEL="$4"
  local TIMEOUT_SECONDS="$5"
  local START
  local NOW
  local LAST_LOG=0

  START=$(now_epoch)
  while :; do
    if ! guest_still_on_node "$NODE" "$TYPE" "$VMID"; then
      ok "$LABEL is no longer on $NODE."
      return 0
    fi

    NOW=$(now_epoch)
    if [ $((NOW - START)) -ge "$TIMEOUT_SECONDS" ]; then
      error_msg "$LABEL was still listed on $NODE after waiting ${TIMEOUT_SECONDS}s."
      return 1
    fi

    if [ $((NOW - LAST_LOG)) -ge 30 ]; then
      info "Waiting for $LABEL to leave $NODE..."
      LAST_LOG="$NOW"
    fi

    sleep 5
  done
}

migrate_guest() {
  local SOURCE="$1"
  local TYPE="$2"
  local VMID="$3"
  local STATUS="$4"
  local LABEL
  local TARGETS=()
  local TARGET
  local COMMAND
  local MIGRATION_OUTPUT
  local GUEST_COUNT

  LABEL=$(guest_label "$TYPE" "$VMID" "$STATUS")
  GUEST_COUNT=$(tui_read_node_field "$SOURCE" 2 "-")
  while IFS= read -r TARGET; do
    if [ -n "$TARGET" ]; then
      TARGETS+=("$TARGET")
    fi
  done < <(candidate_nodes_by_load "$SOURCE")

  if [ "${#TARGETS[@]}" -eq 0 ]; then
    error_msg "No available migration target found for $LABEL on $SOURCE."
    return 1
  fi

  for TARGET in "${TARGETS[@]}"; do
    COMMAND=$(build_migrate_command "$TYPE" "$VMID" "$STATUS" "$TARGET")

    if [ "$DRY_RUN" -eq 1 ]; then
      info "$LABEL would migrate from $SOURCE to $TARGET."
      return 0
    fi

    tui_set_node "$SOURCE" "Migrating" "$GUEST_COUNT" "$LABEL to $TARGET"
    info "Migrating $LABEL from $SOURCE to $TARGET..."
    MIGRATION_OUTPUT=""
    if MIGRATION_OUTPUT=$(remote_run "$SOURCE" "$MIGRATION_TIMEOUT" "$COMMAND" 2>&1); then
      log_command_output "$MIGRATION_OUTPUT"
      ok "Migration request for $LABEL to $TARGET completed."
      tui_set_node "$SOURCE" "Waiting" "$GUEST_COUNT" "$LABEL leaving source"
      wait_for_guest_to_leave_node "$SOURCE" "$TYPE" "$VMID" "$LABEL" "$MIGRATION_TIMEOUT" || return 1
      ok "Migrated $LABEL to $TARGET."
      return 0
    fi

    log_command_output "$MIGRATION_OUTPUT"
    tui_set_node "$SOURCE" "Checking" "$GUEST_COUNT" "$LABEL after migration error"
    if wait_for_guest_to_leave_node "$SOURCE" "$TYPE" "$VMID" "$LABEL" 30; then
      ok "$LABEL left $SOURCE after migration command returned non-zero."
      return 0
    fi

    warn "Migration of $LABEL to $TARGET failed; trying another target if available."
  done

  error_msg "Failed to migrate $LABEL away from $SOURCE."
  return 1
}

remaining_movable_guests() {
  local NODE="$1"
  local OUTPUT
  local TYPE
  local VMID
  local STATUS

  if ! OUTPUT=$(list_guests_on_node "$NODE" 2>/dev/null); then
    return 1
  fi

  while IFS='|' read -r TYPE VMID STATUS; do
    if [ -z "$TYPE$VMID$STATUS" ]; then
      continue
    fi

    if guest_should_move "$STATUS"; then
      printf "%s|%s|%s\n" "$TYPE" "$VMID" "$STATUS"
    fi
  done <<< "$OUTPUT"
}

evacuate_node() {
  local NODE="$1"
  local OUTPUT
  local GUESTS=()
  local REMAINING=()
  local ENTRY
  local TYPE
  local VMID
  local STATUS
  local TOTAL_GUESTS

  if ! OUTPUT=$(remaining_movable_guests "$NODE"); then
    error_msg "Could not list guests on $NODE."
    return 1
  fi

  while IFS= read -r ENTRY; do
    if [ -n "$ENTRY" ]; then
      GUESTS+=("$ENTRY")
    fi
  done < <(printf "%s\n" "$OUTPUT" | sed '/^[[:space:]]*$/d')

  if [ "${#GUESTS[@]}" -eq 0 ]; then
    tui_set_node "$NODE" "Drained" "0" "No guests need migration"
    ok "No guests need migration from $NODE."
    return 0
  fi

  TOTAL_GUESTS=${#GUESTS[@]}
  tui_set_node "$NODE" "Draining" "$TOTAL_GUESTS" "Evacuating guests"
  info "Evacuating $TOTAL_GUESTS guest(s) from $NODE..."
  for ENTRY in "${GUESTS[@]}"; do
    IFS='|' read -r TYPE VMID STATUS <<< "$ENTRY"
    migrate_guest "$NODE" "$TYPE" "$VMID" "$STATUS" || return 1
  done

  if [ "$DRY_RUN" -eq 1 ]; then
    tui_set_node "$NODE" "Dry-run" "$TOTAL_GUESTS" "Evacuation preview complete"
    return 0
  fi

  if ! OUTPUT=$(remaining_movable_guests "$NODE"); then
    error_msg "Could not verify guest evacuation on $NODE."
    return 1
  fi

  while IFS= read -r ENTRY; do
    if [ -n "$ENTRY" ]; then
      REMAINING+=("$ENTRY")
    fi
  done < <(printf "%s\n" "$OUTPUT" | sed '/^[[:space:]]*$/d')

  if [ "${#REMAINING[@]}" -gt 0 ]; then
    tui_set_node "$NODE" "Failed" "${#REMAINING[@]}" "Guests remain after migration"
    error_msg "$NODE still has guest(s) after migration attempts:"
    for ENTRY in "${REMAINING[@]}"; do
      IFS='|' read -r TYPE VMID STATUS <<< "$ENTRY"
      error_msg "  - $(guest_label "$TYPE" "$VMID" "$STATUS")"
    done
    return 1
  fi

  tui_set_node "$NODE" "Drained" "0" "All guests evacuated"
  ok "$NODE has been evacuated."
}

cluster_has_quorum() {
  cluster_run "$REMOTE_CHECK_TIMEOUT" 'pvecm status' 2>/dev/null | awk -F: '
    /^[[:space:]]*Quorate:/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      if ($2 == "Yes") found=1
    }
    END { exit(found ? 0 : 1) }
  '
}

wait_for_quorum() {
  local CONTEXT="$1"
  local START
  local NOW
  local LAST_LOG=0

  START=$(now_epoch)
  while :; do
    if cluster_has_quorum; then
      ok "Cluster quorum is healthy ($CONTEXT)."
      return 0
    fi

    NOW=$(now_epoch)
    if [ $((NOW - START)) -ge "$QUORUM_WAIT_TIMEOUT" ]; then
      error_msg "Cluster quorum did not become healthy within ${QUORUM_WAIT_TIMEOUT}s ($CONTEXT)."
      return 1
    fi

    if [ $((NOW - LAST_LOG)) -ge 30 ]; then
      warn "Waiting for cluster quorum ($CONTEXT)..."
      LAST_LOG="$NOW"
    fi

    sleep 5
  done
}

ceph_health_text() {
  cluster_run "$REMOTE_CHECK_TIMEOUT" 'ceph health' 2>&1
}

ceph_is_healthy() {
  local HEALTH

  if ! cluster_run "$REMOTE_CHECK_TIMEOUT" 'command -v ceph >/dev/null 2>&1'; then
    return 1
  fi

  HEALTH=$(ceph_health_text)
  [[ "$HEALTH" == HEALTH_OK* ]]
}

wait_for_ceph() {
  local CONTEXT="$1"
  local START
  local NOW
  local LAST_LOG=0
  local HEALTH
  local CEPH_STATUS_OUTPUT

  if [ "$CEPH_REQUIRED" -eq 0 ]; then
    warn "Ceph health check skipped ($CONTEXT)."
    return 0
  fi

  if ! cluster_run "$REMOTE_CHECK_TIMEOUT" 'command -v ceph >/dev/null 2>&1'; then
    error_msg "Ceph command not found; refusing to continue without --skip-ceph-check."
    return 1
  fi

  START=$(now_epoch)
  while :; do
    HEALTH=$(ceph_health_text)
    if [[ "$HEALTH" == HEALTH_OK* ]]; then
      ok "Ceph is HEALTH_OK ($CONTEXT)."
      return 0
    fi

    NOW=$(now_epoch)
    if [ $((NOW - START)) -ge "$CEPH_WAIT_TIMEOUT" ]; then
      error_msg "Ceph did not reach HEALTH_OK within ${CEPH_WAIT_TIMEOUT}s ($CONTEXT)."
      error_msg "$HEALTH"
      CEPH_STATUS_OUTPUT=$(cluster_run "$REMOTE_CHECK_TIMEOUT" 'ceph status' 2>/dev/null || true)
      log_command_output "$CEPH_STATUS_OUTPUT"
      return 1
    fi

    if [ $((NOW - LAST_LOG)) -ge 30 ]; then
      warn "Waiting for Ceph HEALTH_OK ($CONTEXT): $HEALTH"
      LAST_LOG="$NOW"
    fi

    sleep 10
  done
}

start_reboot() {
  local NODE="$1"
  local DEST
  local CONTROL_COMMAND
  local REBOOT_COMMAND='nohup sh -c "sleep 2; systemctl reboot" >/dev/null 2>&1 &'

  if [ "$RUN_CONTEXT" = "remote" ] &&
    ! node_matches_control "$NODE" &&
    [ "$DIRECT_NODE_SSH" -eq 0 ]; then
    CONTROL_COMMAND=$(control_to_node_ssh_command "$NODE" "$REBOOT_COMMAND")
    cluster_run "$REMOTE_CHECK_TIMEOUT" "$CONTROL_COMMAND" >/dev/null 2>&1
    return
  fi

  if [ "$RUN_CONTEXT" = "remote" ] && node_matches_control "$NODE"; then
    DEST="$CONTROL_SSH_DEST"
  else
    DEST=$(ssh_destination "$NODE")
  fi

  # shellcheck disable=SC2029 # REBOOT_COMMAND is intentionally sent as the remote SSH command.
  ssh "${SSH_OPTS[@]}" "${EXTRA_SSH_OPTS[@]}" "$DEST" "$REBOOT_COMMAND" >/dev/null 2>&1
}

remote_boot_id() {
  local NODE="$1"

  remote_run "$NODE" "$REMOTE_CHECK_TIMEOUT" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null
}

wait_for_reboot_cycle() {
  local NODE="$1"
  local OLD_BOOT_ID="$2"
  local START
  local NOW
  local LAST_LOG=0
  local CURRENT_BOOT_ID

  START=$(now_epoch)
  while :; do
    CURRENT_BOOT_ID=$(remote_boot_id "$NODE" || true)
    if [ -n "$CURRENT_BOOT_ID" ] && [ "$CURRENT_BOOT_ID" != "$OLD_BOOT_ID" ]; then
      ok "$NODE has returned after reboot."
      return 0
    fi

    NOW=$(now_epoch)
    if [ $((NOW - START)) -ge "$REBOOT_TIMEOUT" ]; then
      error_msg "$NODE did not complete a reboot cycle within ${REBOOT_TIMEOUT}s."
      return 1
    fi

    if [ $((NOW - LAST_LOG)) -ge 30 ]; then
      info "Waiting for $NODE to reboot..."
      LAST_LOG="$NOW"
    fi

    sleep 5
  done
}

wait_for_node_ready() {
  local NODE="$1"
  local START
  local NOW
  local LAST_LOG=0
  local COMMAND

  COMMAND='pveversion >/dev/null 2>&1 && systemctl is-active --quiet pve-cluster pvedaemon pvestatd pveproxy'
  START=$(now_epoch)
  while :; do
    if remote_run "$NODE" "$REMOTE_CHECK_TIMEOUT" "$COMMAND" >/dev/null 2>&1; then
      ok "$NODE Proxmox services are active."
      return 0
    fi

    NOW=$(now_epoch)
    if [ $((NOW - START)) -ge "$NODE_READY_TIMEOUT" ]; then
      error_msg "$NODE Proxmox services did not become ready within ${NODE_READY_TIMEOUT}s."
      return 1
    fi

    if [ $((NOW - LAST_LOG)) -ge 30 ]; then
      info "Waiting for Proxmox services on $NODE..."
      LAST_LOG="$NOW"
    fi

    sleep 5
  done
}

is_control_node() {
  local NODE="$1"

  node_matches_control "$NODE"
}

confirm_plan() {
  local ANSWER

  if [ "$DRY_RUN" -eq 1 ] || [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi

  if [ ! -t 0 ]; then
    fail "Refusing to run non-interactively without --yes."
  fi

  echo
  echo -e "${YELLOW}${BOLD}This will migrate guests and reboot the selected nodes one at a time.${RESET}"
  echo -e "${YELLOW}Type 'reboot' to continue.${RESET}"
  read -r -p "> " ANSWER

  if [ "$ANSWER" != "reboot" ]; then
    fail "Confirmation was not provided."
  fi
}

process_node() {
  local NODE="$1"
  local BOOT_ID

  tui_set_node "$NODE" "Checking" "-" "Checking quorum and Ceph"
  info "Starting rolling reboot for $NODE."

  wait_for_quorum "before processing $NODE" || { tui_set_node "$NODE" "Failed" "-" "Quorum check failed"; return 1; }
  wait_for_ceph "before processing $NODE" || { tui_set_node "$NODE" "Failed" "-" "Ceph check failed"; return 1; }

  if ! ssh_available "$NODE"; then
    tui_set_node "$NODE" "Failed" "-" "SSH connection failed"
    error_msg "SSH to $NODE failed; refusing to process this node."
    return 1
  fi

  evacuate_node "$NODE" || { tui_set_node "$NODE" "Failed" "-" "Evacuation failed"; return 1; }

  tui_set_node "$NODE" "Checking" "0" "Final safety checks"
  wait_for_quorum "before rebooting $NODE" || { tui_set_node "$NODE" "Failed" "0" "Pre-reboot quorum failed"; return 1; }
  wait_for_ceph "before rebooting $NODE" || { tui_set_node "$NODE" "Failed" "0" "Pre-reboot Ceph failed"; return 1; }

  if [ "$DRY_RUN" -eq 1 ]; then
    tui_set_node "$NODE" "Dry-run" "0" "Would reboot now"
    info "Dry run: would reboot $NODE now."
    return 0
  fi

  if ! BOOT_ID=$(remote_boot_id "$NODE"); then
    tui_set_node "$NODE" "Failed" "0" "Could not read boot ID"
    error_msg "Could not read boot ID from $NODE before reboot."
    return 1
  fi

  if is_control_node "$NODE" && [ "$RUN_CONTEXT" = "local" ]; then
    tui_set_node "$NODE" "Local reboot" "0" "Scheduling local reboot"
    warn "$NODE is the local control node."
    warn "It has been evacuated and passed quorum/Ceph checks. Scheduling its reboot now."
    warn "This script cannot verify the local node after SSH drops."
    start_reboot "$NODE" || return 1
    tui_set_node "$NODE" "Local reboot scheduled" "0" "Reconnect after node returns"
    return 2
  fi

  if is_control_node "$NODE" && [ "$RUN_CONTEXT" = "remote" ]; then
    info "$NODE is the remote control node; rebooting it last and waiting for it to return."
  fi

  tui_set_node "$NODE" "Rebooting" "0" "Reboot command sent"
  info "Rebooting $NODE..."
  start_reboot "$NODE" || { tui_set_node "$NODE" "Failed" "0" "Reboot command failed"; return 1; }
  tui_set_node "$NODE" "Waiting" "0" "Waiting for reboot"
  wait_for_reboot_cycle "$NODE" "$BOOT_ID" || { tui_set_node "$NODE" "Failed" "0" "Reboot wait failed"; return 1; }
  tui_set_node "$NODE" "Waiting" "0" "Waiting for Proxmox services"
  wait_for_node_ready "$NODE" || { tui_set_node "$NODE" "Failed" "0" "Services not ready"; return 1; }
  tui_set_node "$NODE" "Checking" "0" "Post-reboot quorum/Ceph"
  wait_for_quorum "after rebooting $NODE" || { tui_set_node "$NODE" "Failed" "0" "Post-reboot quorum failed"; return 1; }
  wait_for_ceph "after rebooting $NODE" || { tui_set_node "$NODE" "Failed" "0" "Post-reboot Ceph failed"; return 1; }
  tui_set_node "$NODE" "Complete" "0" "Reboot complete"
  ok "$NODE reboot completed safely."
}

# ---- RUN CONTEXT ----
if [ -n "$CLUSTER_HOST" ]; then
  RUN_CONTEXT="remote"
  CONTROL_SSH_DEST=$(ssh_destination "$CLUSTER_HOST")
else
  RUN_CONTEXT="local"
  CONTROL_SSH_DEST=""
fi

clear_screen

# ---- REQUIRE ROOT / COMMANDS ----
if [ "$RUN_CONTEXT" = "local" ] && [ "$EUID" -ne 0 ]; then
  fail "this script must be run as root when running directly on a Proxmox node. Use --cluster-host to run from a workstation."
fi

for REQUIRED_CMD in ssh awk sort sed date hostname; do
  if ! command -v "$REQUIRED_CMD" >/dev/null 2>&1; then
    fail "'$REQUIRED_CMD' command not found."
  fi
done

if [ "$RUN_CONTEXT" = "remote" ]; then
  if ! cluster_run "$REMOTE_CHECK_TIMEOUT" 'true' >/dev/null 2>&1; then
    fail "could not connect to cluster host '$CONTROL_SSH_DEST' over SSH."
  fi
fi

if ! cluster_run "$REMOTE_CHECK_TIMEOUT" 'command -v pvecm >/dev/null 2>&1'; then
  fail "'pvecm' command not found on the cluster control host."
fi

if [ "$CEPH_REQUIRED" -eq 1 ] && ! cluster_run "$REMOTE_CHECK_TIMEOUT" 'command -v ceph >/dev/null 2>&1'; then
  fail "'ceph' command not found on the cluster control host. Use --skip-ceph-check only if this is not a Ceph-backed cluster."
fi

# ---- DETECT CLUSTER NODES ----
info "${BOLD}Detecting Proxmox cluster nodes...${RESET}"

PVE_NODES_OUTPUT=$(cluster_run "$REMOTE_CHECK_TIMEOUT" 'pvecm nodes') || {
  fail "could not detect cluster nodes via 'pvecm nodes'."
}

DETECTED_NODES=()
while IFS= read -r NODE; do
  if [ -n "$NODE" ]; then
    DETECTED_NODES+=("$NODE")
  fi
done < <(
  printf "%s\n" "$PVE_NODES_OUTPUT" | awk '
    $1 ~ /^[0-9]+$/ && NF >= 3 {print $3}
  '
)

CONTROL_CLUSTER_NODE=$(printf "%s\n" "$PVE_NODES_OUTPUT" | awk '
  $1 ~ /^[0-9]+$/ && NF >= 4 && $NF == "(local)" {print $3; exit}
')
CONTROL_SHORT_HOSTNAME=$(cluster_run "$REMOTE_CHECK_TIMEOUT" 'hostname -s 2>/dev/null || hostname' 2>/dev/null || true)
CONTROL_HOSTNAME=$(cluster_run "$REMOTE_CHECK_TIMEOUT" 'hostname 2>/dev/null || hostname -s' 2>/dev/null || true)

if [ -z "$CONTROL_CLUSTER_NODE" ]; then
  CONTROL_CLUSTER_NODE="$CONTROL_SHORT_HOSTNAME"
fi

if [ "${#DETECTED_NODES[@]}" -eq 0 ]; then
  fail "No cluster nodes detected via 'pvecm nodes'."
fi

if [ "${#ONLY_NODES[@]}" -gt 0 ]; then
  for NODE in "${ONLY_NODES[@]}"; do
    if ! list_contains "$NODE" "${DETECTED_NODES[@]}"; then
      fail "requested node '$NODE' was not detected by 'pvecm nodes'."
    fi
  done
fi

if [ "${#EXCLUDE_NODES[@]}" -gt 0 ]; then
  for NODE in "${EXCLUDE_NODES[@]}"; do
    if ! list_contains "$NODE" "${DETECTED_NODES[@]}"; then
      fail "excluded node '$NODE' was not detected by 'pvecm nodes'."
    fi
  done
fi

SELECTED_NODES=()
for NODE in "${DETECTED_NODES[@]}"; do
  if [ "${#ONLY_NODES[@]}" -gt 0 ] && ! list_contains "$NODE" "${ONLY_NODES[@]}"; then
    continue
  fi

  if [ "${#EXCLUDE_NODES[@]}" -gt 0 ] && list_contains "$NODE" "${EXCLUDE_NODES[@]}"; then
    continue
  fi

  SELECTED_NODES+=("$NODE")
done

if [ "${#SELECTED_NODES[@]}" -eq 0 ]; then
  fail "node filters matched no nodes."
fi

# Reboot the control node last. In local mode, the script cannot supervise its own host after reboot starts.
ORDERED_NODES=()
CONTROL_SELECTED=0
for NODE in "${SELECTED_NODES[@]}"; do
  if is_control_node "$NODE"; then
    CONTROL_SELECTED=1
  else
    ORDERED_NODES+=("$NODE")
  fi
done

if [ "$CONTROL_SELECTED" -eq 1 ]; then
  ORDERED_NODES+=("$CONTROL_CLUSTER_NODE")
fi

if [ "$RUNNING_ONLY" -eq 1 ]; then
  GUEST_SCOPE="running guests only"
else
  GUEST_SCOPE="all VMs/CTs"
fi

if [ "$CEPH_REQUIRED" -eq 1 ]; then
  CEPH_MODE="require HEALTH_OK"
else
  CEPH_MODE="skipped"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  RUN_MODE="dry run"
else
  RUN_MODE="reboot"
fi

print_title "Proxmox VE Cluster Rolling Reboot"
if [ "$RUN_CONTEXT" = "remote" ]; then
  print_meta "Run context" "remote via $CONTROL_SSH_DEST"
else
  print_meta "Run context" "local Proxmox node"
fi
print_meta "Detected nodes" "${DETECTED_NODES[*]}"
print_meta "Selected nodes" "${ORDERED_NODES[*]}"
print_meta "Control node" "$CONTROL_CLUSTER_NODE"
print_meta "Guest scope" "$GUEST_SCOPE"
print_meta "Ceph gate" "$CEPH_MODE"
if [ -n "$TARGET_STORAGE" ]; then
  print_meta "Target storage" "$TARGET_STORAGE"
fi
if [ "$QM_WITH_LOCAL_DISKS" -eq 1 ]; then
  print_meta "QM local disks" "enabled"
fi
print_meta "Mode" "$RUN_MODE"

if [ "$CONTROL_SELECTED" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  warn "The control node is selected and has been moved to the end of the reboot order."
  if [ "$RUN_CONTEXT" = "local" ]; then
    warn "After the local reboot is scheduled, this script will stop because its host is rebooting."
  else
    warn "Because this script is running remotely, it will wait for the control node to return."
  fi
fi

confirm_plan
init_tui
trap cleanup_tui EXIT
info "Rolling reboot started."

for NODE in "${ORDERED_NODES[@]}"; do
  process_node "$NODE"
  RESULT=$?

  if [ "$RESULT" -eq 2 ]; then
    ok "$NODE was evacuated and its reboot was scheduled."
    warn "Reconnect after it returns and check 'ceph health' before starting other maintenance."
    exit 0
  elif [ "$RESULT" -ne 0 ]; then
    fail "rolling reboot stopped while processing $NODE."
  fi
done

ok "All selected nodes were processed."
