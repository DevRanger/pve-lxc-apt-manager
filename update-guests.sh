#!/usr/bin/env bash
set -Eeuo pipefail

# ====== SETTINGS ======
MAX_JOBS=10
REFRESH_SEC=1

# LOG_LEVEL:
#   2 = (default) high-level overview log (quiet on success; captures apt output on failures)
#   1 = debug (includes apt output for everything)
LOG_LEVEL="${LOG_LEVEL:-2}"

APT_UPGRADE_CMD='DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade'
APT_CLEANUP_CMD='DEBIAN_FRONTEND=noninteractive apt-get -y autoremove && DEBIAN_FRONTEND=noninteractive apt-get -y autoclean'
# ======================

# ====== LOGFILE SETTINGS ======
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUN_TS="$(date '+%Y-%m-%d_%H%M%S')"
LOGFILE="${SCRIPT_DIR}/pve-guest-apt-manager_${RUN_TS}.log"
LOG_USE_COLOR="${LOG_USE_COLOR:-1}"
# ==============================

WORKDIR="$(mktemp -d)"
_cleanup() { rm -rf "$WORKDIR"; }
trap _cleanup EXIT

CLR_CYAN="0;36"
CLR_GREEN="0;32"
CLR_RED="0;31"
CLR_YELLOW="0;33"
CLR_MAGENTA="0;35"
CLR_BOLD="1"
CLR_GRAY="0;90"

c() {
  local code="$1"; shift
  if [[ "$LOG_USE_COLOR" == "1" ]]; then
    printf "\033[%sm%s\033[0m" "$code" "$*"
  else
    printf "%s" "$*"
  fi
}

ts() { date -Is; }
job_count() { jobs -pr | wc -l | tr -d ' '; }
log_hl() { echo "[$(ts)] $*" >> "$LOGFILE"; }

python_json_get() {
  local key="$1"
  python3 -c 'import sys,json
k=sys.argv[1]
s=sys.stdin.read().strip()
try:
  o=json.loads(s) if s else {}
  v=o.get(k,"")
  if isinstance(v,(dict,list)):
    print(json.dumps(v))
  elif v is None:
    print("")
  else:
    print(v)
except Exception:
  print("")
' "$key"
}

looks_base64() {
  local s="$1"
  [[ -z "$s" ]] && return 1
  [[ ${#s} -ge 16 ]] || return 1
  [[ "$s" =~ ^[A-Za-z0-9+/=[:space:]]+$ ]] || return 1
  [[ "$s" == *" "* ]] && return 1
  [[ "$s" == *$'\n'* ]] && return 1
  return 0
}

maybe_b64dec() {
  local s="$1"
  if looks_base64 "$s"; then
    python3 -c 'import sys,base64
s=sys.stdin.read().strip()
try: sys.stdout.write(base64.b64decode(s).decode("utf-8","replace"))
except Exception: sys.stdout.write(s)
' <<<"$s"
  else
    printf "%s" "$s"
  fi
}

guest_exec_capture() {
  local vmid="$1"; shift
  local cmd="$*"

  local resp pid
  resp="$(qm guest exec "$vmid" -- /bin/sh -lc "$cmd" 2>&1 || true)"

  pid="$(printf '%s' "$resp" | python_json_get pid | tr -d '\r\n')"
  if [[ -n "${pid:-}" ]]; then
    local status exited rc out_data err_data out err
    while true; do
      status="$(qm guest exec-status "$vmid" "$pid" 2>&1 || true)"
      exited="$(printf '%s' "$status" | python_json_get exited | tr -d '\r\n')"
      if [[ "$exited" == "true" || "$exited" == "1" ]]; then
        rc="$(printf '%s' "$status" | python_json_get exitcode | tr -d '\r\n')"
        out_data="$(printf '%s' "$status" | python_json_get "out-data")"
        err_data="$(printf '%s' "$status" | python_json_get "err-data")"
        out="$(maybe_b64dec "$out_data")"
        err="$(maybe_b64dec "$err_data")"
        printf "%s" "$out"
        [[ -n "$err" ]] && printf "%s" "$err" >&2
        [[ -n "${rc:-}" ]] || rc=125
        return "$rc"
      fi
      sleep 0.2
    done
  fi

  local rc out_data err_data out err
  rc="$(printf '%s' "$resp" | python_json_get exitcode | tr -d '\r\n')"
  out_data="$(printf '%s' "$resp" | python_json_get "out-data")"
  err_data="$(printf '%s' "$resp" | python_json_get "err-data")"

  if [[ -n "${rc:-}" || -n "${out_data:-}" || -n "${err_data:-}" ]]; then
    out="$(maybe_b64dec "$out_data")"
    err="$(maybe_b64dec "$err_data")"
    printf "%s" "$out"
    [[ -n "$err" ]] && printf "%s" "$err" >&2
    [[ -n "${rc:-}" ]] || rc=125
    return "$rc"
  fi

  echo "$resp" >&2
  return 124
}

vm_probe_apt_exitcode() {
  local vmid="$1"
  local resp rc
  resp="$(qm guest exec "$vmid" -- /bin/sh -lc 'command -v apt-get >/dev/null 2>&1' 2>&1 || true)"
  rc="$(printf '%s' "$resp" | python_json_get exitcode | tr -d '\r\n')"
  if [[ -z "${rc:-}" ]]; then
    echo "$resp"
    return 124
  fi
  echo "$rc"
  return 0
}

guest_cmd_raw() {
  local vmid="$1" cmd="$2"
  qm guest cmd "$vmid" "$cmd" 2>/dev/null || true
}

get_ct_name() {
  local ct="$1"
  local hn
  hn="$(pct config "$ct" 2>/dev/null | awk -F': ' '/^hostname:/{print $2; exit}')"
  [[ -n "${hn:-}" ]] && echo "$hn" || echo "CT$ct"
}

get_vm_name() {
  local vm="$1"
  local nm
  nm="$(qm config "$vm" 2>/dev/null | awk -F': ' '/^name:/{print $2; exit}')"
  [[ -n "${nm:-}" ]] && echo "$nm" || echo "VM$vm"
}

label_for() {
  local kind="$1" id="$2"
  local name
  name="$(cat "${WORKDIR}/name.${kind}.${id}")"
  echo "${name} (${kind} ${id})"
}

count_status() {
  local needle="$1"
  local c=0
  for item in "${ITEMS[@]}"; do
    [[ "$(cat "${WORKDIR}/status.${item}")" == "$needle" ]] && ((c++)) || true
  done
  echo "$c"
}

progress_bar() {
  local done="$1" total="$2" width=40
  local filled=$(( (done * width) / total ))
  local empty=$(( width - filled ))
  printf "[%*s%*s]" "$filled" "" "$empty" "" | tr ' ' '#'
}

render_ui() {
  local complete failed skipped running pending done_count
  complete="$(count_status COMPLETE)"
  failed="$(count_status FAILED)"
  skipped="$(count_status SKIPPED)"
  running="$(count_status RUNNING)"
  pending="$(count_status PENDING)"
  done_count=$((complete + failed + skipped))

  printf "\033[H\033[J"
  echo "pve lxc/vm apt manager  |  host: $(hostname)  |  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "log: $LOGFILE  |  LOG_LEVEL=$LOG_LEVEL"
  echo
  printf "overall: %s %d/%d  |  pending:%d  running:%d  complete:%d  failed:%d  skipped:%d\n" \
    "$(progress_bar "$done_count" "$TOTAL")" "$done_count" "$TOTAL" \
    "$pending" "$running" "$complete" "$failed" "$skipped"
  echo
  printf "%-28s %-10s %s\n" "WORKLOAD" "STATUS" "INFO"
  printf "%-28s %-10s %s\n" "--------" "------" "----"

  for item in "${ITEMS[@]}"; do
    local kind id st msg lbl color
    kind="${item%%:*}"
    id="${item#*:}"
    st="$(cat "${WORKDIR}/status.${item}")"
    msg="$(cat "${WORKDIR}/msg.${item}")"
    lbl="$(label_for "$kind" "$id")"

    case "$st" in
      PENDING)  color="\033[0;37m" ;;
      RUNNING)  color="\033[0;36m" ;;
      COMPLETE) color="\033[0;32m" ;;
      FAILED)   color="\033[0;31m" ;;
      SKIPPED)  color="\033[0;33m" ;;
      *)        color="\033[0m" ;;
    esac

    printf "%-28s ${color}%-10s\033[0m %s\n" "$lbl" "$st" "$msg"
  done
}

log_ui_snapshot() {
  local complete failed skipped running pending done_count
  complete="$(count_status COMPLETE)"
  failed="$(count_status FAILED)"
  skipped="$(count_status SKIPPED)"
  running="$(count_status RUNNING)"
  pending="$(count_status PENDING)"
  done_count=$((complete + failed + skipped))

  {
    echo "----------------------------------------------------------------"
    echo "UI SNAPSHOT @ $(ts)  host: $(hostname)"
    printf "overall: %s %d/%d  |  pending:%d  running:%d  complete:%d  failed:%d  skipped:%d\n" \
      "$(progress_bar "$done_count" "$TOTAL")" "$done_count" "$TOTAL" \
      "$pending" "$running" "$complete" "$failed" "$skipped"
    echo
    printf "%-28s %-10s %s\n" "WORKLOAD" "STATUS" "INFO"
    printf "%-28s %-10s %s\n" "--------" "------" "----"
    for item in "${ITEMS[@]}"; do
      local st msg lbl kind id
      kind="${item%%:*}"
      id="${item#*:}"
      st="$(cat "${WORKDIR}/status.${item}")"
      msg="$(cat "${WORKDIR}/msg.${item}")"
      lbl="$(label_for "$kind" "$id")"
      printf "%-28s %-10s %s\n" "$lbl" "$st" "$msg"
    done
    echo "----------------------------------------------------------------"
  } >> "$LOGFILE"
}

log_header() {
  {
    echo "============================================================"
    echo "PVE LXC/VM apt run: $(ts)"
    echo "Host: $(hostname)"
    echo "MAX_JOBS=${MAX_JOBS}"
    echo "REFRESH_SEC=${REFRESH_SEC}"
    echo "LOG_LEVEL=${LOG_LEVEL}"
    echo "============================================================"
  } >> "$LOGFILE"
}

log_footer_summary() {
  local complete failed skipped pending running
  complete="$(count_status COMPLETE)"
  failed="$(count_status FAILED)"
  skipped="$(count_status SKIPPED)"
  pending="$(count_status PENDING)"
  running="$(count_status RUNNING)"

  {
    echo "------------------------------------------------------------"
    echo "END: $(ts)"
    echo "SUMMARY:"
    echo "  total:     ${TOTAL}"
    echo "  complete:  ${complete}"
    echo "  failed:    ${failed}"
    echo "  skipped:   ${skipped}"
    echo "  running:   ${running}"
    echo "  pending:   ${pending}"
    echo "------------------------------------------------------------"
  } >> "$LOGFILE"
}

is_vm_agent_enabled() {
  local vm="$1"
  local v
  v="$(qm config "$vm" 2>/dev/null | awk -F': ' '/^agent:/{print $2; exit}')"
  [[ "${v:-0}" == "1" ]] && return 0
  echo "$v" | grep -q 'enabled=1' 2>/dev/null && return 0
  return 1
}

vm_agent_ping_ok() {
  qm guest cmd "$1" ping >/dev/null 2>&1 && return 0
  qm agent "$1" ping >/dev/null 2>&1 && return 0
  return 1
}

vm_is_windows_guess() {
  local vm="$1"
  local osinfo
  osinfo="$(guest_cmd_raw "$vm" "get-osinfo")"
  echo "$osinfo" | tr '[:upper:]' '[:lower:]' | grep -q 'windows'
}

do_upgrade_ct() {
  local ct="$1"
  local item="CT:${ct}"
  local label status rc
  label="$(label_for "CT" "$ct")"
  status="$(pct status "$ct" | awk '{print $2}')"

  if [[ "$status" != "running" ]]; then
    echo "SKIPPED" > "${WORKDIR}/status.${item}"
    echo "stopped" > "${WORKDIR}/msg.${item}"
    log_hl "$(c "$CLR_YELLOW" "SKIPPED")  ${label} (not running)"
    return 0
  fi

  echo "RUNNING" > "${WORKDIR}/status.${item}"
  echo "apt update/upgrade" > "${WORKDIR}/msg.${item}"
  log_hl "$(c "$CLR_CYAN" "START")    ${label} upgrade"

  rc=0
  if [[ "$LOG_LEVEL" == "1" ]]; then
    pct exec "$ct" -- bash -lc "$APT_UPGRADE_CMD" 2>&1 | sed -u "s/^/[${label}] /" >> "$LOGFILE" || rc=$?
  else
    pct exec "$ct" -- bash -lc "$APT_UPGRADE_CMD" >>/dev/null 2>&1 || rc=$?
  fi

  if [[ "$rc" -ne 0 ]]; then
    echo "FAILED" > "${WORKDIR}/status.${item}"
    echo "exit=${rc} (apt output captured)" > "${WORKDIR}/msg.${item}"
    log_hl "$(c "$CLR_RED" "FAILED")   ${label} rc=${rc}"
    echo "----- BEGIN APT OUTPUT (failure) : ${label} rc=${rc} -----" >> "$LOGFILE"
    pct exec "$ct" -- bash -lc "$APT_UPGRADE_CMD" 2>&1 | sed -u "s/^/[${label}] /" >> "$LOGFILE" || true
    echo "----- END APT OUTPUT (failure) : ${label} -----" >> "$LOGFILE"
    return "$rc"
  fi

  echo "COMPLETE" > "${WORKDIR}/status.${item}"
  if pct exec "$ct" -- test -f /var/run/reboot-required >/dev/null 2>&1; then
    echo "1" > "${WORKDIR}/reboot.${item}"
    echo "done (reboot required)" > "${WORKDIR}/msg.${item}"
    log_hl "$(c "$CLR_GREEN" "DONE")     ${label} $(c "$CLR_MAGENTA" "(reboot required)")"
  else
    echo "0" > "${WORKDIR}/reboot.${item}"
    echo "done" > "${WORKDIR}/msg.${item}"
    log_hl "$(c "$CLR_GREEN" "DONE")     ${label}"
  fi
}

do_upgrade_vm() {
  local vm="$1"
  local item="VM:${vm}"
  local label status probe_rc probe_raw rc
  label="$(label_for "VM" "$vm")"
  status="$(qm status "$vm" 2>/dev/null | awk '{print $2}')"

  if [[ "$status" != "running" ]]; then
    echo "SKIPPED" > "${WORKDIR}/status.${item}"
    echo "stopped" > "${WORKDIR}/msg.${item}"
    log_hl "$(c "$CLR_YELLOW" "SKIPPED")  ${label} (not running)"
    return 0
  fi

  if ! is_vm_agent_enabled "$vm"; then
    echo "SKIPPED" > "${WORKDIR}/status.${item}"
    echo "agent disabled" > "${WORKDIR}/msg.${item}"
    log_hl "$(c "$CLR_YELLOW" "SKIPPED")  ${label} (guest agent disabled)"
    return 0
  fi

  if ! vm_agent_ping_ok "$vm"; then
    echo "FAILED" > "${WORKDIR}/status.${item}"
    echo "guest agent not responding (E_GA_NO_PING)" > "${WORKDIR}/msg.${item}"
    log_hl "$(c "$CLR_RED" "FAILED")   ${label} guest agent not responding (E_GA_NO_PING)"
    return 70
  fi

  if vm_is_windows_guess "$vm"; then
    echo "SKIPPED" > "${WORKDIR}/status.${item}"
    echo "windows guest" > "${WORKDIR}/msg.${item}"
    log_hl "$(c "$CLR_YELLOW" "SKIPPED")  ${label} (windows guest)"
    return 0
  fi

  probe_raw="$(vm_probe_apt_exitcode "$vm" || true)"
  if [[ "$probe_raw" =~ ^[0-9]+$ ]]; then
    probe_rc="$probe_raw"
  else
    probe_rc=124
  fi

  if [[ "$probe_rc" -ne 0 ]]; then
    echo "SKIPPED" > "${WORKDIR}/status.${item}"
    echo "non-apt OS (probe rc=${probe_rc})" > "${WORKDIR}/msg.${item}"
    log_hl "$(c "$CLR_YELLOW" "SKIPPED")  ${label} (non-apt OS; probe rc=${probe_rc})"
    if [[ "$probe_rc" -eq 124 ]]; then
      log_hl "----- BEGIN APT PROBE RAW : ${label} -----"
      printf "%s\n" "$probe_raw" >> "$LOGFILE"
      log_hl "----- END APT PROBE RAW : ${label} -----"
    fi
    return 0
  fi

  echo "RUNNING" > "${WORKDIR}/status.${item}"
  echo "apt update/upgrade" > "${WORKDIR}/msg.${item}"
  log_hl "$(c "$CLR_CYAN" "START")    ${label} upgrade"

  rc=0
  if [[ "$LOG_LEVEL" == "1" ]]; then
    guest_exec_capture "$vm" "$APT_UPGRADE_CMD" 2>&1 | sed -u "s/^/[${label}] /" >> "$LOGFILE" || rc=$?
  else
    guest_exec_capture "$vm" "$APT_UPGRADE_CMD >/dev/null 2>&1" >/dev/null 2>&1 || rc=$?
  fi

  if [[ "$rc" -ne 0 ]]; then
    echo "FAILED" > "${WORKDIR}/status.${item}"
    echo "exit=${rc} (apt output captured)" > "${WORKDIR}/msg.${item}"
    log_hl "$(c "$CLR_RED" "FAILED")   ${label} rc=${rc} (capturing apt output)"
    echo "----- BEGIN APT OUTPUT (failure) : ${label} rc=${rc} -----" >> "$LOGFILE"
    guest_exec_capture "$vm" "$APT_UPGRADE_CMD" 2>&1 | sed -u "s/^/[${label}] /" >> "$LOGFILE" || true
    echo "----- END APT OUTPUT (failure) : ${label} -----" >> "$LOGFILE"
    return "$rc"
  fi

  echo "COMPLETE" > "${WORKDIR}/status.${item}"
  if guest_exec_capture "$vm" "test -f /var/run/reboot-required" >/dev/null 2>&1; then
    echo "1" > "${WORKDIR}/reboot.${item}"
    echo "done (reboot required)" > "${WORKDIR}/msg.${item}"
    log_hl "$(c "$CLR_GREEN" "DONE")     ${label} $(c "$CLR_MAGENTA" "(reboot required)")"
  else
    echo "0" > "${WORKDIR}/reboot.${item}"
    echo "done" > "${WORKDIR}/msg.${item}"
    log_hl "$(c "$CLR_GREEN" "DONE")     ${label}"
  fi
}

do_cleanup_ct() { pct exec "$1" -- bash -lc "$APT_CLEANUP_CMD" >>/dev/null 2>&1 || true; }
do_cleanup_vm() { guest_exec_capture "$1" "$APT_CLEANUP_CMD >/dev/null 2>&1" >/dev/null 2>&1 || true; }

do_reboot_ct() { pct reboot "$1" >>"$LOGFILE" 2>&1 || true; }
do_reboot_vm() { qm reboot "$1" >>"$LOGFILE" 2>&1 || true; }

print_affects_list() {
  local title="$1"; shift
  local -a items=("$@")
  if [[ ${#items[@]} -eq 0 ]]; then
    echo "  (none)"
    return 0
  fi
  echo "  ${title}:"
  for it in "${items[@]}"; do
    kind="${it%%:*}"
    id="${it#*:}"
    echo "   - $(label_for "$kind" "$id")"
  done
}

log_affects_list() {
  local title="$1"; shift
  local -a items=("$@")
  {
    echo "AFFECTED: ${title}"
    if [[ ${#items[@]} -eq 0 ]]; then
      echo "  (none)"
    else
      for it in "${items[@]}"; do
        kind="${it%%:*}"
        id="${it#*:}"
        echo "  - $(label_for "$kind" "$id")"
      done
    fi
  } >> "$LOGFILE"
}

# ---- PREP / STARTUP MESSAGES ----
echo "$(c "$CLR_GRAY" "[prep]") creating workload list (pct/qm)..."
log_hl "$(c "$CLR_GRAY" "[prep]") creating workload list (pct/qm)..."

ITEMS=()
mapfile -t CTS < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')
for ct in "${CTS[@]:-}"; do ITEMS+=("CT:${ct}"); done
mapfile -t VMS < <(qm list 2>/dev/null | awk 'NR>1 {print $1}')
for vm in "${VMS[@]:-}"; do ITEMS+=("VM:${vm}"); done

[[ ${#ITEMS[@]} -gt 0 ]] || { echo "no workloads found via pct list / qm list"; exit 0; }
TOTAL="${#ITEMS[@]}"

echo "$(c "$CLR_GRAY" "[prep]") resolving names + initializing run state..."
log_hl "$(c "$CLR_GRAY" "[prep]") resolving names + initializing run state..."

for item in "${ITEMS[@]}"; do
  kind="${item%%:*}"
  id="${item#*:}"
  echo "PENDING" > "${WORKDIR}/status.${item}"
  echo ""        > "${WORKDIR}/msg.${item}"
  echo "0"       > "${WORKDIR}/reboot.${item}"
  if [[ "$kind" == "CT" ]]; then
    echo "$(get_ct_name "$id")" > "${WORKDIR}/name.${kind}.${id}"
  else
    echo "$(get_vm_name "$id")" > "${WORKDIR}/name.${kind}.${id}"
  fi
done

echo "$(c "$CLR_GRAY" "[prep]") starting UI..."
log_hl "$(c "$CLR_GRAY" "[prep]") starting UI..."

log_header
log_hl "$(c "$CLR_BOLD" "MODE")     LOG_LEVEL=${LOG_LEVEL}"
log_hl "$(c "$CLR_BOLD" "LOGFILE")  ${LOGFILE}"

(
  while true; do
    render_ui
    sleep "$REFRESH_SEC"
    complete="$(count_status COMPLETE)"
    failed="$(count_status FAILED)"
    skipped="$(count_status SKIPPED)"
    done_count=$((complete + failed + skipped))
    [[ "$done_count" -ge "$TOTAL" ]] && break
  done
  render_ui
) &
UI_PID=$!

for item in "${ITEMS[@]}"; do
  while [[ "$(job_count)" -ge "$MAX_JOBS" ]]; do sleep 0.1; done
  kind="${item%%:*}"
  id="${item#*:}"
  if [[ "$kind" == "CT" ]]; then
    do_upgrade_ct "$id" &
  else
    do_upgrade_vm "$id" &
  fi
done

wait || true
wait "$UI_PID" 2>/dev/null || true

log_footer_summary
log_ui_snapshot

REBOOT_LIST=()
CLEAN_LIST=()
for item in "${ITEMS[@]}"; do
  [[ "$(cat "${WORKDIR}/reboot.${item}")" == "1" ]] && REBOOT_LIST+=("$item")
  [[ "$(cat "${WORKDIR}/status.${item}")" == "COMPLETE" ]] && CLEAN_LIST+=("$item")
done

echo
echo "summary: total=$TOTAL complete=$(count_status COMPLETE) failed=$(count_status FAILED) skipped=$(count_status SKIPPED)"
echo "logfile: $LOGFILE"
echo

if [[ ${#CLEAN_LIST[@]} -gt 0 ]]; then
  echo
  echo "$(c "$CLR_BOLD" "cleanup will affect:")"
  print_affects_list "workloads" "${CLEAN_LIST[@]}"
  log_affects_list "cleanup" "${CLEAN_LIST[@]}"
  read -r -p "run cleanup on completed workloads? [y/N]: " ans
  if [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; then
    log_hl "$(c "$CLR_BOLD" "CLEANUP") start"
    for item in "${CLEAN_LIST[@]}"; do
      kind="${item%%:*}"
      id="${item#*:}"
      [[ "$kind" == "CT" ]] && do_cleanup_ct "$id" || do_cleanup_vm "$id"
    done
    log_hl "$(c "$CLR_BOLD" "CLEANUP") end"
    echo "cleanup done."
  else
    log_hl "$(c "$CLR_BOLD" "CLEANUP") skipped by user"
    echo "cleanup skipped."
  fi
fi

if [[ ${#REBOOT_LIST[@]} -gt 0 ]]; then
  echo
  echo "$(c "$CLR_BOLD" "reboot will affect:")"
  print_affects_list "workloads" "${REBOOT_LIST[@]}"
  log_affects_list "reboot-required" "${REBOOT_LIST[@]}"
  read -r -p "reboot workloads that reported reboot-required? [y/N]: " ans
  if [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; then
    log_hl "$(c "$CLR_BOLD" "REBOOT") start"
    for item in "${REBOOT_LIST[@]}"; do
      kind="${item%%:*}"
      id="${item#*:}"
      [[ "$kind" == "CT" ]] && do_reboot_ct "$id" || do_reboot_vm "$id"
    done
    log_hl "$(c "$CLR_BOLD" "REBOOT") end"
    echo "reboots issued."
  else
    log_hl "$(c "$CLR_BOLD" "REBOOT") skipped by user"
    echo "reboots skipped."
  fi
fi

log_hl "$(c "$CLR_BOLD" "DONE") run complete"
echo
echo "done. logfile: $LOGFILE"
echo "view log with: less -R $LOGFILE"
