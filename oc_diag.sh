#!/usr/bin/env bash
# oc_diag.sh - OpenClaw diagnostic collector tuned for Linux + cloud/local LLM troubleshooting
#
# Goal:
# - Run safe read-only checks
# - Produce ONE report that is easy to paste into another LLM for troubleshooting
# - Highlight likely issues and a concise "LLM TRIAGE PACKET"

set -euo pipefail

UNIT_DEFAULT="openclaw-gateway.service"
SCOPE_DEFAULT="--user"
LINES_DEFAULT=6000
SINCE_DEFAULT="24 hours ago"
UNTIL_DEFAULT="now"

QUIET=0
NO_LOGS=0

UNIT="$UNIT_DEFAULT"
SCOPE="$SCOPE_DEFAULT"
LINES="$LINES_DEFAULT"
SINCE="$SINCE_DEFAULT"
UNTIL="$UNTIL_DEFAULT"
INCIDENT=""
INCIDENT_SPAN_MIN=15

print_help() {
  cat <<'EOF_HELP'
oc_diag.sh - OpenClaw diagnostic collector

Usage:
  ./oc_diag.sh [options]

Options:
  --unit <name>                 systemd unit to inspect (default: openclaw-gateway.service)
  --scope <--user|--system>     scope for systemd/journalctl (default: --user)
  --lines <N>                   max lines for journalctl (default: 6000)
  --since <time>                journalctl start time (default: "24 hours ago")
  --until <time>                journalctl end time (default: "now")
  --incident "YYYY-MM-DD HH:MM" set log window to +/- span around timestamp
  --incident-span-min <N>       minutes before/after incident timestamp (default: 15)
  --quiet                       suppress console UI; still writes report
  --no-logs                     skip journalctl checks
  -h, --help                    show this help

Examples:
  ./oc_diag.sh
  ./oc_diag.sh --quiet
  ./oc_diag.sh --incident "2026-02-21 09:13" --incident-span-min 30
EOF_HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unit) UNIT="${2:-}"; shift 2 ;;
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --lines) LINES="${2:-}"; shift 2 ;;
    --since) SINCE="${2:-}"; shift 2 ;;
    --until) UNTIL="${2:-}"; shift 2 ;;
    --incident) INCIDENT="${2:-}"; shift 2 ;;
    --incident-span-min) INCIDENT_SPAN_MIN="${2:-}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --no-logs) NO_LOGS=1; shift ;;
    -h|--help|-?) print_help; exit 0 ;;
    *)
      echo "Unknown arg: $1"
      echo "Run: $0 --help"
      exit 1
      ;;
  esac
done

if [[ "$SCOPE" != "--user" && "$SCOPE" != "--system" ]]; then
  echo "Invalid --scope: $SCOPE (expected --user or --system)"
  exit 1
fi

if ! [[ "$LINES" =~ ^[0-9]+$ ]]; then
  echo "Invalid --lines: $LINES (must be integer)"
  exit 1
fi

if ! [[ "$INCIDENT_SPAN_MIN" =~ ^[0-9]+$ ]]; then
  echo "Invalid --incident-span-min: $INCIDENT_SPAN_MIN (must be integer)"
  exit 1
fi

if [[ -n "$INCIDENT" ]]; then
  if date -d "$INCIDENT" "+%Y-%m-%d %H:%M:%S" >/dev/null 2>&1; then
    SINCE="$(date -d "${INCIDENT} - ${INCIDENT_SPAN_MIN} minutes" "+%Y-%m-%d %H:%M:%S")"
    UNTIL="$(date -d "${INCIDENT} + ${INCIDENT_SPAN_MIN} minutes" "+%Y-%m-%d %H:%M:%S")"
  else
    echo "Invalid --incident value: ${INCIDENT}"
    echo 'Expected format: "YYYY-MM-DD HH:MM" (local time)'
    exit 1
  fi
fi

HOST="$(hostname)"
TS="$(date "+%Y%m%d_%H%M%S")"
RUN_ID="${HOST}-${TS}"
REPORT="oc_diag_report_${HOST}_${TS}.txt"
TMPDIR="$(mktemp -d -t ocdiag.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

say() {
  [[ "$QUIET" -eq 1 ]] && return 0
  printf "%b\n" "$*"
}

IS_TTY=0
[[ -t 1 ]] && IS_TTY=1
if [[ "$QUIET" -eq 1 || $IS_TTY -eq 0 ]]; then
  c_reset=""; c_bold=""; c_dim=""; c_red=""; c_grn=""; c_cyn=""
else
  c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_cyn=$'\033[36m'
fi

hline() { say "${c_dim}====================================================================${c_reset}"; }
now_local() { date "+%Y-%m-%d %H:%M:%S %Z"; }
now_utc() { date -u "+%Y-%m-%d %H:%M:%S UTC"; }
have() { command -v "$1" >/dev/null 2>&1; }

STEP=0
TOTAL_STEPS=0
declare -a STEP_TITLES=()
declare -a STEP_CMDS=()

aadd_step() { STEP_TITLES+=("$1"); STEP_CMDS+=("$2"); }

run_step() {
  local title="$1"
  local cmd="$2"
  local out="$3"
  local start end dur rc

  STEP=$((STEP+1))
  say
  say "${c_bold}[${STEP}/${TOTAL_STEPS}]${c_reset} ${c_cyn}${title}${c_reset}"
  say "${c_dim}cmd:${c_reset} ${cmd}"

  start="$(date +%s)"
  set +e
  bash -lc "$cmd" >"$out" 2>&1
  rc=$?
  set -e
  end="$(date +%s)"
  dur=$((end-start))

  if [[ $rc -eq 0 ]]; then
    say "${c_grn}ok${c_reset} ${c_dim}(${dur}s)${c_reset}"
  else
    say "${c_red}FAILED${c_reset} ${c_dim}(rc=${rc}, ${dur}s)${c_reset}"
    [[ "$QUIET" -eq 1 ]] || tail -n 12 "$out" | sed 's/^/  /'
  fi

  {
    echo
    echo "${title}"
    echo "------------------------------------------------------------"
    echo "cmd: ${cmd}"
    echo "rc: ${rc}  duration: ${dur}s"
    echo
    cat "$out"
  } >> "$REPORT"
}

systemd_status_both() {
  local unit="$1"
  cat <<EOF_ST
 echo "---- systemctl --user status ${unit} ----"
 systemctl --user status "${unit}" --no-pager 2>&1 || true
 echo
 echo "---- systemctl --system status ${unit} ----"
 systemctl --system status "${unit}" --no-pager 2>&1 || true
EOF_ST
}

journal_both() {
  local unit="$1"
  local since="$2"
  local until="$3"
  local lines="$4"
  cat <<EOF_J
 echo "---- journalctl --user -u ${unit} ----"
 journalctl --user -u "${unit}" --since "${since}" --until "${until}" --no-pager -n "${lines}" 2>&1 || true
 echo
 echo "---- journalctl --system -u ${unit} ----"
 journalctl --system -u "${unit}" --since "${since}" --until "${until}" --no-pager -n "${lines}" 2>&1 || true
EOF_J
}

{
  echo "OpenClaw Diagnostic Report"
  echo "===================================================================="
  echo "Generated by: oc_diag.sh"
  echo "Run ID: ${RUN_ID}"
  echo "Host: ${HOST}"
  echo "Collected at (local): $(now_local)"
  echo "Collected at (utc):   $(now_utc)"
  echo "Unit: ${UNIT} (scope: ${SCOPE})"
  echo "Log window interpreted: since='${SINCE}' until='${UNTIL}' lines=${LINES}"
  echo "Modes: quiet=${QUIET} no_logs=${NO_LOGS}"
  [[ -n "$INCIDENT" ]] && echo "Incident helper: incident='${INCIDENT}' spanMin=${INCIDENT_SPAN_MIN}"
  echo "===================================================================="
  echo
  echo "How to share"
  echo "--------------------------------------------------------------------"
  echo "This file is a diagnostic capture and is safe to share for debugging."
  echo "1) Paste the LLM TRIAGE PACKET block first."
  echo "2) Then paste ISSUES TO INVESTIGATE and the relevant raw sections."
  echo "3) Include what changed (updates, config edits, restarts, incidents)."
} > "$REPORT"

say "${c_bold}OpenClaw diagnostics${c_reset}"
hline
say "Host: ${HOST}"
say "Run ID: ${RUN_ID}"
say "Time (local): $(now_local)"
say "Time (utc):   $(now_utc)"
say "Unit: ${UNIT} (scope: ${SCOPE})"
say "Window: since='${SINCE}' until='${UNTIL}' lines=${LINES}"
say "Modes: quiet=${QUIET} no_logs=${NO_LOGS}"
[[ -n "$INCIDENT" ]] && say "Incident: '${INCIDENT}' (+/- ${INCIDENT_SPAN_MIN} min)"
hline
say "Report: ${c_bold}${REPORT}${c_reset}"

aadd_step "System - uname" 'uname -a || true'
aadd_step "System - OS release" 'cat /etc/os-release 2>/dev/null || true'
aadd_step "System - uptime" 'uptime || true'
aadd_step "System - disk usage" 'df -h || true'
aadd_step "System - memory" 'free -h 2>/dev/null || true'

aadd_step "GPU - inventory" 'nvidia-smi -L 2>/dev/null || true'
aadd_step "GPU - summary" 'nvidia-smi 2>/dev/null || true'
aadd_step "GPU - compute apps" 'nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv,noheader 2>/dev/null || true'
aadd_step "GPU - pmon" 'nvidia-smi pmon -c 1 2>/dev/null || true'

aadd_step "QMD - CLI/version/status" '
if command -v qmd >/dev/null 2>&1; then
  echo "qmd: $(command -v qmd)"
  qmd --version 2>&1 || qmd version 2>&1 || true
  qmd status 2>&1 || qmd info 2>&1 || qmd doctor 2>&1 || true
else
  echo "qmd: not found in PATH"
fi
'
aadd_step "QMD - env vars (names only)" '(env | rg -n "^QMD_" | sed -E "s/=.*$/=<set>/") || true'
aadd_step "QMD - systemd status" "$(systemd_status_both "qmd.service")
$(systemd_status_both "qmd-daemon.service")
$(systemd_status_both "qmd-gateway.service")"
if [[ "$NO_LOGS" -eq 0 ]]; then
  aadd_step "QMD - logs" "$(journal_both "qmd.service" "$SINCE" "$UNTIL" "$LINES")
$(journal_both "qmd-daemon.service" "$SINCE" "$UNTIL" "$LINES")
$(journal_both "qmd-gateway.service" "$SINCE" "$UNTIL" "$LINES")"
fi
aadd_step "QMD - process discovery" 'ps auxww | rg -n "(^| )qmd( |$)|qmd-daemon|qmd-gateway|scheduler|alloc" || true'

aadd_step "OpenClaw - version/capabilities (non-interactive)" '
openclaw --version 2>/dev/null || openclaw version 2>/dev/null || true
echo
if command -v timeout >/dev/null 2>&1; then
  timeout 8s bash -lc "openclaw doctor --help 2>&1 || true" || true
else
  openclaw doctor --help 2>&1 || true
fi
'
aadd_step "OpenClaw - models/plugins" 'openclaw models status 2>&1 || true; echo; openclaw plugins list 2>&1 || true'

CFG="${HOME}/.openclaw/openclaw.json"
aadd_step "Config - file status" "ls -la \"${CFG}\" 2>/dev/null || echo \"Config not found: ${CFG}\""

if have jq; then
  aadd_step "Config - summarized keys" "
if [[ -f \"${CFG}\" ]]; then
  jq '{
    version: .version?,
    defaultModel: .defaultModel?,
    fallbacks: .fallbacks?,
    models: (.models? | keys)?,
    plugins: {allow: .plugins.allow?, entries: (.plugins.entries? | keys)?},
    providers: (.providers? | keys)?,
    envKeys: (.env? | keys)?
  }' \"${CFG}\" 2>/dev/null || true
else
  echo \"Config not found: ${CFG}\"
fi
"
else
  aadd_step "Config - jq missing" 'echo "Install jq for structured config parsing"'
fi

aadd_step "Local LLM runtimes - quick checks" '
if command -v ollama >/dev/null 2>&1; then
  echo "---- ollama version/list/ps ----"
  ollama --version 2>&1 || true
  ollama list 2>&1 || true
  ollama ps 2>&1 || true
else
  echo "ollama: not found"
fi

echo
if command -v vllm >/dev/null 2>&1; then
  echo "vllm: found at $(command -v vllm)"
else
  echo "vllm: not found"
fi

if command -v llama-server >/dev/null 2>&1 || command -v llama.cpp >/dev/null 2>&1; then
  echo "llama.cpp server tooling appears present"
else
  echo "llama.cpp server tooling not found"
fi

ps auxww | rg -n "ollama|vllm|llama-server|text-generation-inference|tgi|lmstudio|open-webui" || true
'

aadd_step "Env - provider vars (names only)" '
(env | rg -n "^(OPENCLAW|OPENAI|ANTHROPIC|AZURE|AWS|GOOGLE|GEMINI|OLLAMA|VLLM|CUDA|NVIDIA)_" | sed -E "s/=.*$/=<set>/") || true
'

aadd_step "Systemd - OpenClaw service status" "systemctl ${SCOPE} status \"${UNIT}\" --no-pager 2>&1 || true"
if [[ "$NO_LOGS" -eq 0 ]]; then
  aadd_step "Systemd - OpenClaw service logs" "journalctl ${SCOPE} -u \"${UNIT}\" --since \"${SINCE}\" --until \"${UNTIL}\" --no-pager -n \"${LINES}\" 2>&1 || true"
fi

TOTAL_STEPS="${#STEP_TITLES[@]}"
say "${c_dim}Running ${TOTAL_STEPS} checks...${c_reset}"
for idx in "${!STEP_TITLES[@]}"; do
  run_step "${STEP_TITLES[$idx]}" "${STEP_CMDS[$idx]}" "${TMPDIR}/step_${idx}.out"
done

rg_lines() { rg -n "$1" "$REPORT" 2>/dev/null || true; }

P_PLUGIN="$(rg_lines 'duplicate plugin id|plugins\.allow is empty|discovered non-bundled plugins|loaded without install|untracked local code|extensions/' | head -n 12)"
A_AUTH="$(rg_lines 'No API key found|Missing auth|unauthorized|forbidden|401|403|invalid api key|credential|auth' | head -n 12)"
M_MODEL="$(rg_lines 'model not allowed|blocked model|context window|Minimum is|ctx=|modelsConfig|sessions\.patch|defaultModel|fallbacks' | head -n 12)"
R_REL="$(rg_lines 'rate limit|quota|429|timeout|timed out|FailoverError|backoff|retry|ECONNRESET|ETIMEDOUT' | head -n 12)"
S_REQ="$(rg_lines 'INVALID_REQUEST|unknown .* id|validation|schema|Unrecognized key|Invalid config' | head -n 12)"
QMD_SIG="$(rg_lines '(^|[^a-z])qmd([^a-z]|$)|qmd\.service|qmd-daemon|allocation|gpu.*alloc|cuda.*alloc|pool|scheduler' | head -n 12)"
LOCAL_SIG="$(rg_lines 'ollama|vllm|llama-server|text-generation-inference|lmstudio|open-webui' | head -n 12)"

{
  echo
  echo "LLM TRIAGE PACKET (paste this first)"
  echo "===================================================================="
  echo "-----START LLM TRIAGE PACKET-----"
  echo "Goal: Troubleshoot OpenClaw on Linux with cloud + local LLM backends."
  echo "Context: unit=${UNIT} scope=${SCOPE} since=${SINCE} until=${UNTIL}"
  echo "What I need from you:"
  echo "1) Rank top 3 likely root causes from evidence below."
  echo "2) Give exact remediation commands/config edits with rollback notes."
  echo "3) Give a minimal verification checklist after each fix."
  echo
  echo "Evidence snippets:"
  [[ -n "$QMD_SIG" ]] && { echo "- QMD signals:"; echo "$QMD_SIG" | sed 's/^/    /'; }
  [[ -n "$LOCAL_SIG" ]] && { echo "- Local runtime signals:"; echo "$LOCAL_SIG" | sed 's/^/    /'; }
  [[ -n "$A_AUTH" ]] && { echo "- Auth signals:"; echo "$A_AUTH" | sed 's/^/    /'; }
  [[ -n "$M_MODEL" ]] && { echo "- Model/context signals:"; echo "$M_MODEL" | sed 's/^/    /'; }
  [[ -n "$R_REL" ]] && { echo "- Reliability signals:"; echo "$R_REL" | sed 's/^/    /'; }
  [[ -z "$QMD_SIG$LOCAL_SIG$A_AUTH$M_MODEL$R_REL" ]] && echo "- No strong pattern signals detected in selected window."
  echo "-----END LLM TRIAGE PACKET-----"

  echo
  echo "ISSUES TO INVESTIGATE"
  echo "===================================================================="
  echo "-----START ISSUES TO INVESTIGATE-----"
  i=1
  if [[ -n "$QMD_SIG" ]]; then
    echo "${i}) QMD allocator/scheduler signals present"
    echo "$QMD_SIG" | sed 's/^/   /'
    i=$((i+1))
  fi
  if [[ -n "$LOCAL_SIG" ]]; then
    echo "${i}) Local runtime signals present (Ollama/vLLM/llama.cpp/etc.)"
    echo "$LOCAL_SIG" | sed 's/^/   /'
    i=$((i+1))
  fi
  if [[ -n "$P_PLUGIN" ]]; then
    echo "${i}) Plugin hygiene signals"
    echo "$P_PLUGIN" | sed 's/^/   /'
    i=$((i+1))
  fi
  if [[ -n "$A_AUTH" ]]; then
    echo "${i}) Auth/provider credential signals"
    echo "$A_AUTH" | sed 's/^/   /'
    i=$((i+1))
  fi
  if [[ -n "$M_MODEL" ]]; then
    echo "${i}) Model selection/context constraints"
    echo "$M_MODEL" | sed 's/^/   /'
    i=$((i+1))
  fi
  if [[ -n "$R_REL" ]]; then
    echo "${i}) Reliability signals (429/timeouts/retries)"
    echo "$R_REL" | sed 's/^/   /'
    i=$((i+1))
  fi
  if [[ -n "$S_REQ" ]]; then
    echo "${i}) Request/schema/unknown-id signals"
    echo "$S_REQ" | sed 's/^/   /'
    i=$((i+1))
  fi
  if [[ $i -eq 1 ]]; then
    echo "1) No major issue patterns matched in this window"
    echo "   Try: ./oc_diag.sh --incident \"YYYY-MM-DD HH:MM\""
  fi
  echo "-----END ISSUES TO INVESTIGATE-----"
} >> "$REPORT"

if [[ "$QUIET" -eq 0 ]]; then
  issue_count=0
  [[ -n "$QMD_SIG" ]] && issue_count=$((issue_count+1))
  [[ -n "$LOCAL_SIG" ]] && issue_count=$((issue_count+1))
  [[ -n "$P_PLUGIN" ]] && issue_count=$((issue_count+1))
  [[ -n "$A_AUTH" ]] && issue_count=$((issue_count+1))
  [[ -n "$M_MODEL" ]] && issue_count=$((issue_count+1))
  [[ -n "$R_REL" ]] && issue_count=$((issue_count+1))
  [[ -n "$S_REQ" ]] && issue_count=$((issue_count+1))

  say
  hline
  say "${c_grn}${c_bold}Done.${c_reset} Share this file: ${c_bold}${REPORT}${c_reset}"
  say
  say "${c_bold}Quick summary for you:${c_reset}"
  if [[ "$issue_count" -eq 0 ]]; then
    say "  - No major pattern-matched issues found in selected time window."
  else
    say "  - ${issue_count} issue categories flagged."
    [[ -n "$QMD_SIG" ]] && say "  - QMD allocator/scheduler signals detected"
    [[ -n "$LOCAL_SIG" ]] && say "  - Local LLM runtime signals detected"
    [[ -n "$P_PLUGIN" ]] && say "  - Plugin hygiene warnings detected"
    [[ -n "$A_AUTH" ]] && say "  - Auth/provider credential warnings detected"
    [[ -n "$M_MODEL" ]] && say "  - Model selection/context warnings detected"
    [[ -n "$R_REL" ]] && say "  - Reliability warnings (429/timeout/retry) detected"
    [[ -n "$S_REQ" ]] && say "  - Request/schema/id warnings detected"
  fi
  say
  say "Copy for LLM helper:"
  say "  sed -n '/-----START LLM TRIAGE PACKET-----/,/-----END LLM TRIAGE PACKET-----/p' \"${REPORT}\""
  say "  sed -n '/-----START ISSUES TO INVESTIGATE-----/,/-----END ISSUES TO INVESTIGATE-----/p' \"${REPORT}\""
  hline
fi

echo "Wrote report: ${REPORT}"
