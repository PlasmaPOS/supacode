#!/usr/bin/env bash
#
# supacode remote-mode bootstrap
#
# Provisions a remote host so Supacode's `.remote(...)` clients can talk to it.
# Idempotent — safe to re-run on the same host (skips installs that are already
# satisfied).
#
# Usage:
#   ./scripts/remote-bootstrap.sh user@host                     # default Repos dir + binary paths
#   ./scripts/remote-bootstrap.sh user@host --repos-dir /custom # override
#   ./scripts/remote-bootstrap.sh user@host --verbose           # echo each step
#
# Requires:
#   - SSH key auth (or ssh-agent loaded). Bootstrap never prompts for passwords.
#   - macOS or Linux remote with brew (macOS) OR apt-get (Debian/Ubuntu).
#
# What it does (in order):
#   1. Verify ssh reachability (`ssh -O check` style)
#   2. Detect remote OS (macOS / Linux) + package manager
#   3. Verify or install `git`, `gh`, `fswatch` via brew/apt
#   4. SCP the bundled `wt` bash script to ~/.local/bin/wt + chmod +x
#   5. Build + SCP the `zmx` universal binary to ~/.local/bin/zmx (if not present)
#      — Slice 7 v1 falls back to "user installs zmx themselves" if zmx isn't
#        in the local Resources tree; the rest of the bootstrap still completes.
#   6. Create the repos dir if missing
#   7. Run a smoke test: `ssh remote 'wt --help && zmx ls --short && gh --version'`
#
# On exit:
#   - 0  → ready. Set the remote host in Supacode's Remote Settings tab.
#   - 1  → unrecoverable error (printed to stderr, no host modifications attempted)
#   - 2  → recoverable partial success (some tools installed, one or more failed;
#          rerun after fixing the printed issue)

set -euo pipefail

# ─── arg parsing ──────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  cat <<EOF >&2
Usage: $(basename "$0") <user@host> [--repos-dir <path>] [--wt-path <path>] [--zmx-path <path>] [--verbose]

  --repos-dir <path>   default: ~/.supacode/repos
  --wt-path <path>     default: ~/.local/bin/wt
  --zmx-path <path>    default: ~/.local/bin/zmx
  --verbose            echo every ssh/scp invocation
EOF
  exit 1
fi

HOST="$1"
shift

REPOS_DIR="~/.supacode/repos"
WT_PATH="~/.local/bin/wt"
ZMX_PATH="~/.local/bin/zmx"
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repos-dir) REPOS_DIR="$2"; shift 2 ;;
    --wt-path) WT_PATH="$2"; shift 2 ;;
    --zmx-path) ZMX_PATH="$2"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCAL_WT="${REPO_ROOT}/Resources/git-wt/wt"
LOCAL_ZMX="${REPO_ROOT}/ThirdParty/zmx/zig-out/bin/zmx"  # if user has built it

log() {
  echo "→ $*" >&2
}

run_ssh() {
  [[ $VERBOSE -eq 1 ]] && echo "    \$ ssh ${HOST} '$*'" >&2
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${HOST}" "$@"
}

run_scp() {
  [[ $VERBOSE -eq 1 ]] && echo "    \$ scp $1 ${HOST}:$2" >&2
  scp -o BatchMode=yes -o ConnectTimeout=10 "$1" "${HOST}:$2"
}

# ─── 1. reachability ─────────────────────────────────────────────────────────

log "Checking SSH reachability to ${HOST}"
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o PreferredAuthentications=publickey "${HOST}" "true" 2>/dev/null; then
  echo "✗ Cannot reach ${HOST} via SSH key auth." >&2
  echo "  Fix: ensure your key is loaded (ssh-add -L) and the host accepts publickey." >&2
  exit 1
fi
log "Reachable ✓"

# ─── 2. detect OS + package manager ──────────────────────────────────────────

OS="$(run_ssh "uname -s")"
case "${OS}" in
  Darwin) PKG=brew; PKG_INSTALL="brew install" ;;
  Linux)
    if run_ssh "command -v apt-get >/dev/null"; then
      PKG=apt; PKG_INSTALL="sudo apt-get install -y"
    elif run_ssh "command -v dnf >/dev/null"; then
      PKG=dnf; PKG_INSTALL="sudo dnf install -y"
    elif run_ssh "command -v pacman >/dev/null"; then
      PKG=pacman; PKG_INSTALL="sudo pacman -S --noconfirm"
    else
      echo "✗ Remote Linux has no known package manager (apt/dnf/pacman)." >&2
      exit 1
    fi
    ;;
  *) echo "✗ Unsupported remote OS: ${OS}" >&2; exit 1 ;;
esac
log "Remote OS: ${OS} (using ${PKG})"

# ─── 3. tool verification + install ─────────────────────────────────────────

ensure_tool() {
  local tool="$1"
  local pkg="${2:-$tool}"
  if run_ssh "command -v ${tool} >/dev/null 2>&1"; then
    log "${tool} ✓ already installed"
    return 0
  fi
  log "Installing ${tool} via ${PKG}…"
  if ! run_ssh "${PKG_INSTALL} ${pkg}"; then
    echo "✗ Failed to install ${tool}. Install it manually then re-run." >&2
    return 1
  fi
}

PARTIAL=0
ensure_tool git || PARTIAL=1
ensure_tool gh || PARTIAL=1
# fswatch is optional — degrades to polling if missing. Don't fail on absence.
if ! ensure_tool fswatch; then
  log "fswatch missing — remote watcher will use polling (acceptable)"
fi

# ─── 4. install wt ──────────────────────────────────────────────────────────

if [[ ! -f "${LOCAL_WT}" ]]; then
  echo "✗ Local wt script not found at ${LOCAL_WT}." >&2
  echo "  Run: git submodule update --init Resources/git-wt" >&2
  exit 1
fi

log "Pushing wt to ${HOST}:${WT_PATH}"
WT_DIR=$(dirname "${WT_PATH}")
run_ssh "mkdir -p ${WT_DIR}"
run_scp "${LOCAL_WT}" "${WT_PATH}"
run_ssh "chmod +x ${WT_PATH}"
log "wt installed ✓"

# ─── 5. install zmx ─────────────────────────────────────────────────────────

if [[ -f "${LOCAL_ZMX}" ]]; then
  log "Pushing zmx to ${HOST}:${ZMX_PATH}"
  ZMX_DIR=$(dirname "${ZMX_PATH}")
  run_ssh "mkdir -p ${ZMX_DIR}"
  run_scp "${LOCAL_ZMX}" "${ZMX_PATH}"
  run_ssh "chmod +x ${ZMX_PATH}"
  log "zmx installed ✓"
else
  log "Local zmx binary not found at ${LOCAL_ZMX}"
  log "  (build it first: cd ThirdParty/zmx && zig build -Drelease)"
  log "  Skipping zmx push — remote terminal sessions won't persist until you"
  log "  build and push zmx separately."
  PARTIAL=1
fi

# ─── 6. create repos dir ────────────────────────────────────────────────────

log "Ensuring ${REPOS_DIR} exists"
run_ssh "mkdir -p ${REPOS_DIR}"
log "Repos dir ready ✓"

# ─── 7. smoke test ──────────────────────────────────────────────────────────

log "Running smoke test"
SMOKE=$(run_ssh "
  echo wt: \$(${WT_PATH} --help 2>&1 | head -1 || echo MISSING)
  echo gh: \$(gh --version 2>&1 | head -1 || echo MISSING)
  if [ -f ${ZMX_PATH} ]; then
    echo zmx: \$(${ZMX_PATH} --version 2>/dev/null || ${ZMX_PATH} ls --short 2>&1 | head -1 || echo MISSING)
  else
    echo zmx: NOT-INSTALLED
  fi
")
echo "${SMOKE}" >&2

# ─── exit ───────────────────────────────────────────────────────────────────

if [[ $PARTIAL -eq 1 ]]; then
  log "Bootstrap finished with warnings. Re-run after addressing the items above."
  exit 2
fi

log "✓ Done. Set the remote host in Supacode → Settings → Remote and reconnect."
exit 0
