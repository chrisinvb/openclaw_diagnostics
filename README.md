# OpenClaw Diagnostics (`oc_diag.sh`)

`oc_diag.sh` is a safe, read-only Linux diagnostics script for troubleshooting OpenClaw with cloud and local LLM backends.

It collects:
- System + GPU context
- QMD signals (service status/logs/processes)
- OpenClaw version/models/plugins/config summary
- Local runtime clues (Ollama, vLLM, llama.cpp-style tooling)
- Provider env var **names only** (values redacted)
- A copy/paste friendly report with:
  - `LLM TRIAGE PACKET`
  - `ISSUES TO INVESTIGATE`

## Ubuntu: pull this repo and run from shell

### 1) Install git (if needed)

```bash
sudo apt update
sudo apt install -y git
```

### 2) Clone the repository

Replace `<your-repo-url>` with your GitHub repo URL:

```bash
git clone <your-repo-url>
cd openclaw_diagnostics
```

### 3) Pull latest changes (if you already cloned before)

```bash
cd openclaw_diagnostics
git pull --ff-only
```

### 4) Make the script executable and run it

```bash
chmod +x oc_diag.sh
./oc_diag.sh
```

When complete, the script prints the report path:

```text
Wrote report: oc_diag_report_<host>_<timestamp>.txt
```

## Common usage

Run standard diagnostics:

```bash
./oc_diag.sh
```

Run without logs (faster):

```bash
./oc_diag.sh --no-logs
```

Run silently (only writes report):

```bash
./oc_diag.sh --quiet
```

Investigate around an incident timestamp:

```bash
./oc_diag.sh --incident "2026-02-21 09:13" --incident-span-min 30
```

Use a custom service unit/scope:

```bash
./oc_diag.sh --unit openclaw-gateway.service --scope --system
```

## Share with an LLM helper

After a run, copy the structured blocks directly:

```bash
sed -n '/-----START LLM TRIAGE PACKET-----/,/-----END LLM TRIAGE PACKET-----/p' "<report_file>"
sed -n '/-----START ISSUES TO INVESTIGATE-----/,/-----END ISSUES TO INVESTIGATE-----/p' "<report_file>"
```

Recommended sharing order:
1. `LLM TRIAGE PACKET`
2. `ISSUES TO INVESTIGATE`
3. Relevant raw sections from the same report
4. Notes on what changed (updates, config edits, restarts, incident time)

## Notes

- The script is designed to avoid interactive hangs.
- It uses best-effort checks and continues even when some commands/tools are unavailable.
- Log collection can be large; use `--incident` or `--since/--until` to narrow scope.

## Help

```bash
./oc_diag.sh --help
```
