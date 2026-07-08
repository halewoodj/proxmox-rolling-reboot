#!/bin/bash
# =============================================
# Proxmox VE Cluster Rolling Reboot Script
# =============================================
# - Auto-detects cluster nodes via pvecm
# - Reboots one node at a time
# - Migrates VMs/CTs away before rebooting a node
# - Requires cluster quorum and Ceph HEALTH_OK before each reboot
# - Waits for the node and Ceph health to recover before continuing
#
# Requirements:
# - Run as root on a Proxmox VE node
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
EOF
}

# ---- ARRAYS / VARIABLES ----
DRY_RUN=0
ASSUME_YES=0
RUNNING_ONLY=0
CEPH_REQUIRED=1
QM_WITH_LOCAL_DISKS=0
TARGET_STORAGE=""
ONLY_NODES=()
EXCLUDE_NODES=()
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

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo -e "${RED}Error: this script requires Bash 4 or newer.${RESET}"
  exit 1
fi

# ---- FUNCTIONS ----
fail() {
  echo -e "${RED}Error: $*${RESET}" >&2
  exit 1
}

warn() {
  echo -e "${YELLOW}Warning: $*${RESET}" >&2
}

info() {
  echo -e "${CYAN}$*${RESET}"
}

ok() {
  echo -e "${GREEN}$*${RESET}"
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

remote_run() {
  local NODE="$1"
  local TIMEOUT_SECONDS="$2"
  local COMMAND="$3"

  # shellcheck disable=SC2029 # COMMAND is intentionally quoted locally before SSH sends it.
  ssh "${SSH_OPTS[@]}" root@"$NODE" "timeout --preserve-status ${TIMEOUT_SECONDS}s bash -lc $(printf '%q' "$COMMAND")"
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

migrate_guest() {
  local SOURCE="$1"
  local TYPE="$2"
  local VMID="$3"
  local STATUS="$4"
  local LABEL
  local TARGETS=()
  local TARGET
  local COMMAND

  LABEL=$(guest_label "$TYPE" "$VMID" "$STATUS")
  mapfile -t TARGETS < <(candidate_nodes_by_load "$SOURCE")

  if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo -e "${RED}No available migration target found for $LABEL on $SOURCE.${RESET}"
    return 1
  fi

  for TARGET in "${TARGETS[@]}"; do
    COMMAND=$(build_migrate_command "$TYPE" "$VMID" "$STATUS" "$TARGET")

    if [ "$DRY_RUN" -eq 1 ]; then
      echo -e "  - ${BOLD}$LABEL${RESET}: would migrate from ${BOLD}$SOURCE${RESET} to ${BOLD}$TARGET${RESET}"
      return 0
    fi

    info "Migrating $LABEL from $SOURCE to $TARGET..."
    if remote_run "$SOURCE" "$MIGRATION_TIMEOUT" "$COMMAND"; then
      ok "Migrated $LABEL to $TARGET."
      return 0
    fi

    if ! guest_still_on_node "$SOURCE" "$TYPE" "$VMID"; then
      ok "$LABEL is no longer on $SOURCE after migration command returned non-zero."
      return 0
    fi

    warn "Migration of $LABEL to $TARGET failed; trying another target if available."
  done

  echo -e "${RED}Failed to migrate $LABEL away from $SOURCE.${RESET}"
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

  if ! OUTPUT=$(remaining_movable_guests "$NODE"); then
    echo -e "${RED}Could not list guests on $NODE.${RESET}"
    return 1
  fi

  mapfile -t GUESTS < <(printf "%s\n" "$OUTPUT" | sed '/^[[:space:]]*$/d')

  if [ "${#GUESTS[@]}" -eq 0 ]; then
    ok "No guests need migration from $NODE."
    return 0
  fi

  info "Evacuating ${#GUESTS[@]} guest(s) from $NODE..."
  for ENTRY in "${GUESTS[@]}"; do
    IFS='|' read -r TYPE VMID STATUS <<< "$ENTRY"
    migrate_guest "$NODE" "$TYPE" "$VMID" "$STATUS" || return 1
  done

  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  if ! OUTPUT=$(remaining_movable_guests "$NODE"); then
    echo -e "${RED}Could not verify guest evacuation on $NODE.${RESET}"
    return 1
  fi

  mapfile -t REMAINING < <(printf "%s\n" "$OUTPUT" | sed '/^[[:space:]]*$/d')
  if [ "${#REMAINING[@]}" -gt 0 ]; then
    echo -e "${RED}$NODE still has guest(s) after migration attempts:${RESET}"
    for ENTRY in "${REMAINING[@]}"; do
      IFS='|' read -r TYPE VMID STATUS <<< "$ENTRY"
      echo "  - $(guest_label "$TYPE" "$VMID" "$STATUS")"
    done
    return 1
  fi

  ok "$NODE has been evacuated."
}

cluster_has_quorum() {
  pvecm status 2>/dev/null | awk -F: '
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
      echo -e "${RED}Cluster quorum did not become healthy within ${QUORUM_WAIT_TIMEOUT}s ($CONTEXT).${RESET}"
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
  ceph health 2>&1
}

ceph_is_healthy() {
  local HEALTH

  if ! command -v ceph >/dev/null 2>&1; then
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

  if [ "$CEPH_REQUIRED" -eq 0 ]; then
    warn "Ceph health check skipped ($CONTEXT)."
    return 0
  fi

  if ! command -v ceph >/dev/null 2>&1; then
    echo -e "${RED}Ceph command not found; refusing to continue without --skip-ceph-check.${RESET}"
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
      echo -e "${RED}Ceph did not reach HEALTH_OK within ${CEPH_WAIT_TIMEOUT}s ($CONTEXT).${RESET}"
      echo "$HEALTH"
      ceph status 2>/dev/null || true
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

  ssh "${SSH_OPTS[@]}" root@"$NODE" 'nohup sh -c "sleep 2; systemctl reboot" >/dev/null 2>&1 &' >/dev/null 2>&1
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
      echo -e "${RED}$NODE did not complete a reboot cycle within ${REBOOT_TIMEOUT}s.${RESET}"
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
      echo -e "${RED}$NODE Proxmox services did not become ready within ${NODE_READY_TIMEOUT}s.${RESET}"
      return 1
    fi

    if [ $((NOW - LAST_LOG)) -ge 30 ]; then
      info "Waiting for Proxmox services on $NODE..."
      LAST_LOG="$NOW"
    fi

    sleep 5
  done
}

is_local_node() {
  local NODE="$1"

  [ "$NODE" = "$LOCAL_CLUSTER_NODE" ] || [ "$NODE" = "$LOCAL_SHORT_HOSTNAME" ] || [ "$NODE" = "$LOCAL_HOSTNAME" ]
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

  print_title "Rolling Reboot: $NODE"

  wait_for_quorum "before processing $NODE" || return 1
  wait_for_ceph "before processing $NODE" || return 1

  if ! ssh_available "$NODE"; then
    echo -e "${RED}SSH to $NODE failed; refusing to process this node.${RESET}"
    return 1
  fi

  evacuate_node "$NODE" || return 1

  wait_for_quorum "before rebooting $NODE" || return 1
  wait_for_ceph "before rebooting $NODE" || return 1

  if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${CYAN}Dry run: would reboot ${BOLD}$NODE${RESET}${CYAN} now.${RESET}"
    return 0
  fi

  if ! BOOT_ID=$(remote_boot_id "$NODE"); then
    echo -e "${RED}Could not read boot ID from $NODE before reboot.${RESET}"
    return 1
  fi

  if is_local_node "$NODE"; then
    echo -e "${YELLOW}${BOLD}$NODE is the local node.${RESET}"
    echo -e "${YELLOW}It has been evacuated and passed quorum/Ceph checks. Scheduling its reboot now.${RESET}"
    echo -e "${YELLOW}This script cannot verify the local node after SSH drops.${RESET}"
    start_reboot "$NODE" || return 1
    return 2
  fi

  info "Rebooting $NODE..."
  start_reboot "$NODE" || return 1
  wait_for_reboot_cycle "$NODE" "$BOOT_ID" || return 1
  wait_for_node_ready "$NODE" || return 1
  wait_for_quorum "after rebooting $NODE" || return 1
  wait_for_ceph "after rebooting $NODE" || return 1
  ok "$NODE reboot completed safely."
}

# ---- REQUIRE ROOT ----
if [ "$EUID" -ne 0 ]; then
  fail "this script must be run as root."
fi

# ---- REQUIRE COMMANDS ----
for REQUIRED_CMD in pvecm ssh timeout awk sort sed date; do
  if ! command -v "$REQUIRED_CMD" >/dev/null 2>&1; then
    fail "'$REQUIRED_CMD' command not found."
  fi
done

if [ "$CEPH_REQUIRED" -eq 1 ] && ! command -v ceph >/dev/null 2>&1; then
  fail "'ceph' command not found. Use --skip-ceph-check only if this is not a Ceph-backed cluster."
fi

# ---- DETECT CLUSTER NODES ----
info "${BOLD}Detecting Proxmox cluster nodes...${RESET}"

mapfile -t DETECTED_NODES < <(
  pvecm nodes | awk '
    $1 ~ /^[0-9]+$/ && NF >= 3 {print $3}
  '
)

LOCAL_CLUSTER_NODE=$(pvecm nodes | awk '
  $1 ~ /^[0-9]+$/ && NF >= 4 && $NF == "(local)" {print $3; exit}
')
LOCAL_SHORT_HOSTNAME=$(hostname -s 2>/dev/null || hostname)
LOCAL_HOSTNAME=$(hostname 2>/dev/null || printf "%s" "$LOCAL_SHORT_HOSTNAME")

if [ -z "$LOCAL_CLUSTER_NODE" ]; then
  LOCAL_CLUSTER_NODE="$LOCAL_SHORT_HOSTNAME"
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

# Reboot the launching node last so the script can supervise every remote reboot.
ORDERED_NODES=()
LOCAL_SELECTED=0
for NODE in "${SELECTED_NODES[@]}"; do
  if is_local_node "$NODE"; then
    LOCAL_SELECTED=1
  else
    ORDERED_NODES+=("$NODE")
  fi
done

if [ "$LOCAL_SELECTED" -eq 1 ]; then
  ORDERED_NODES+=("$LOCAL_CLUSTER_NODE")
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

print_title "Proxmox VE Cluster Rolling Reboot"
print_meta "Detected nodes" "${DETECTED_NODES[*]}"
print_meta "Selected nodes" "${ORDERED_NODES[*]}"
print_meta "Local node" "$LOCAL_CLUSTER_NODE"
print_meta "Guest scope" "$GUEST_SCOPE"
print_meta "Ceph gate" "$CEPH_MODE"
if [ -n "$TARGET_STORAGE" ]; then
  print_meta "Target storage" "$TARGET_STORAGE"
fi
if [ "$QM_WITH_LOCAL_DISKS" -eq 1 ]; then
  print_meta "QM local disks" "enabled"
fi
if [ "$DRY_RUN" -eq 1 ]; then
  print_meta "Mode" "dry run"
else
  print_meta "Mode" "reboot"
fi

if [ "$LOCAL_SELECTED" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  warn "The local node is selected and has been moved to the end of the reboot order."
  warn "After the local reboot is scheduled, this script will stop because its host is rebooting."
fi

confirm_plan

for NODE in "${ORDERED_NODES[@]}"; do
  process_node "$NODE"
  RESULT=$?

  if [ "$RESULT" -eq 2 ]; then
    print_title "Local Reboot Scheduled"
    echo -e "${GREEN}${BOLD}$NODE was evacuated and its reboot was scheduled.${RESET}"
    echo -e "${YELLOW}Reconnect after it returns and check 'ceph health' before starting other maintenance.${RESET}"
    exit 0
  elif [ "$RESULT" -ne 0 ]; then
    fail "rolling reboot stopped while processing $NODE."
  fi
done

print_title "Rolling Reboot Complete"
ok "All selected nodes were processed."
