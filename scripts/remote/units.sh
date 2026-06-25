#!/usr/bin/env bash
# systemd supervision for the dungeon BACKEND toriis (system-level units, run as
# the deploy user). Keeps the indexers alive across crashes (Restart=always) and server
# reboots (enabled, WantedBy=multi-user.target). Toriis only — the appchain is external
# (cartridge-appchain) and there's no frontend; the public client is GitHub Pages.
#
# Sourced by scripts/remote/deploy.sh (uses the units_* functions), and also runnable
# standalone to migrate an ALREADY-DEPLOYED stack onto systemd with no redeploy/gas,
# and for day-to-day ops (per-service restart/reset, log viewing):
#
#   bash scripts/remote/units.sh up                # install units + start (resume) + enable
#   bash scripts/remote/units.sh restart torii-game # bounce one service
#   bash scripts/remote/units.sh reset torii-game  # wipe its db + re-index
#   bash scripts/remote/units.sh logs -f           # follow all services' journals
#   bash scripts/remote/units.sh remove-all        # stop, disable, delete the unit files
#   bash scripts/remote/units.sh status
#
# deploy.ts is deliberately NOT a unit: a unit would re-run it (re-spending gas) on
# every boot. The long-lived services resume from on-disk state instead.
set -euo pipefail

_UNITS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="${DEMO_DIR:-$(cd "$_UNITS_DIR/../.." && pwd)}"
RUN_DIR="${RUN_DIR:-$DEMO_DIR/.run}"
DEPLOY_USER="$(id -un)"
SYSTEMD_DIR=/etc/systemd/system
PFX=dungeon
# Units get a minimal env; PATH covers torii/sozo (+ ~/.local, ~/.bun). systemd does
# not expand ~ or $HOME, so spell them out.
RUNTIME_PATH="$HOME/.local/bin:$HOME/.bun/bin:/usr/local/bin:/usr/bin:/bin"

# The toriis we supervise. Both index against external chains (bank → Sepolia, game →
# the external appchain), so there's no inter-unit start order to enforce.
UNIT_NAMES=(torii-bank torii-game)

usay() { echo "→ $*"; }

# Validate a service short-name (torii-bank | torii-game).
_is_service() {
  local n
  for n in "${UNIT_NAMES[@]}"; do [[ "$n" == "$1" ]] && return 0; done
  echo "error: unknown service '$1' (expected: ${UNIT_NAMES[*]})" >&2; return 1
}

# The on-disk db dir a torii indexer re-indexes into (see scripts/services/torii-*.sh).
# Note the bank indexer's db is torii-score.db, NOT torii-bank.db.
_db_dir() {
  case "$1" in
    torii-bank) echo "$RUN_DIR/torii-score.db" ;;
    torii-game) echo "$RUN_DIR/torii-game.db" ;;
    *) return 1 ;;
  esac
}

# name|script|After-extra|Description  (one per backend service)
_unit_table() {
  cat <<EOF
torii-bank|torii-bank.sh||Dungeon torii — bank world (Starknet Sepolia)
torii-game|torii-game.sh||Dungeon torii — game world (external appchain)
EOF
}

# Stop+disable+delete EVERY dungeon-*.service (current or stale, e.g. an old
# standalone dungeon-katana), then reload. Idempotent.
units_remove_all() {
  local f u found=0
  while IFS= read -r f; do
    found=1; u="$(basename "$f")"
    sudo systemctl disable --now "$u" >/dev/null 2>&1 || true
    sudo rm -f "$f"
  done < <(find "$SYSTEMD_DIR" -maxdepth 1 -name "${PFX}-*.service" 2>/dev/null)
  [[ "$found" == 1 ]] && sudo systemctl daemon-reload || true
}

# Stop+disable existing dungeon units WITHOUT deleting (deploy teardown: keep them
# from auto-restarting while we free ports / redeploy; install rewrites them after).
units_stop_all() {
  local f u
  while IFS= read -r f; do
    u="$(basename "$f")"
    sudo systemctl disable --now "$u" >/dev/null 2>&1 || true
  done < <(find "$SYSTEMD_DIR" -maxdepth 1 -name "${PFX}-*.service" 2>/dev/null)
}

# (Re)write the unit files from the table — replacing any stale set first.
units_install() {
  usay "installing systemd units (run as $DEPLOY_USER) → $SYSTEMD_DIR/${PFX}-*.service"
  units_remove_all
  local name script after desc
  while IFS='|' read -r name script after desc; do
    [[ -z "$name" ]] && continue
    sudo tee "$SYSTEMD_DIR/${PFX}-${name}.service" >/dev/null <<UNIT
[Unit]
Description=$desc
After=network-online.target$after
Wants=network-online.target

[Service]
Type=simple
User=$DEPLOY_USER
Group=$DEPLOY_USER
WorkingDirectory=$DEMO_DIR
Environment=PATH=$RUNTIME_PATH
ExecStart=/bin/bash $DEMO_DIR/scripts/services/$script
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
    usay "  ${PFX}-${name}.service"
  done < <(_unit_table)
  sudo systemctl daemon-reload
}

units_start()   { local n; for n in "$@"; do _is_service "$n" || return 1; sudo systemctl start   "${PFX}-$n.service"; done; }
units_stop()    { local n; for n in "$@"; do _is_service "$n" || return 1; sudo systemctl stop    "${PFX}-$n.service"; done; }
units_restart() { local n; for n in "$@"; do _is_service "$n" || return 1; sudo systemctl restart "${PFX}-$n.service"; done; }
units_enable()  { local n u=(); for n in "${UNIT_NAMES[@]}"; do u+=("${PFX}-$n.service"); done; sudo systemctl enable "${u[@]}" >/dev/null; }

# status [name…] — given names, just those; no args → all units (callers rely on this).
units_status() {
  local u=()
  if [[ $# -gt 0 ]]; then
    local n; for n in "$@"; do _is_service "$n" || return 1; u+=("${PFX}-$n"); done
  else
    local n; for n in "${UNIT_NAMES[@]}"; do u+=("${PFX}-$n"); done
  fi
  sudo systemctl --no-pager --output=short status "${u[@]}" 2>&1 || true
}

# reset <name> — wipe a torii's db and let it re-index from the world's deploy block.
# The unit's ExecStart re-runs the torii script with no RESET, which recreates the db.
# `systemctl stop` is synchronous, so the wipe can't race the running indexer. (The
# appchain is external — to reset it, use cartridge-appchain's own tooling.)
units_reset() {
  local n="${1:-}"
  [[ -n "$n" ]] || { echo "usage: units.sh reset <torii-bank|torii-game>" >&2; return 2; }
  _is_service "$n" || return 1
  local db; db="$(_db_dir "$n")" || { echo "error: no db mapping for '$n'" >&2; return 1; }
  usay "resetting $n (wipe $db + re-index)…"
  sudo systemctl stop "${PFX}-$n.service"
  rm -rf "$db"
  sudo systemctl start "${PFX}-$n.service"
  usay "  $n restarted — re-indexing; follow with: journalctl -u ${PFX}-$n -f"
}

# logs [name] [-f] [-n N] — journalctl for one service, or all (-u 'dungeon-*'). No
# sudo: the deploy user reads its own units' journal (deploy.sh's health check too).
units_logs() {
  local sel=(-u "${PFX}-*") rest=()   # quoted pattern → journalctl globs it, not the shell
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--follow) rest+=(-f) ;;
      -n) rest+=(-n "${2:-}"); shift ;;
      -*) rest+=("$1") ;;
      *) _is_service "$1" || return 1; sel=(-u "${PFX}-$1") ;;
    esac
    shift
  done
  journalctl "${sel[@]}" --no-pager "${rest[@]}"
}

# Install + start (resuming on-disk state) + enable for boot. For migrating an
# already-deployed stack — does NOT run deploy.ts. The appchain is external, so only
# the toriis are started here.
units_up() {
  units_install
  usay "starting toriis…"; units_start torii-bank torii-game
  until curl -s -o /dev/null http://localhost:8092/ 2>/dev/null; do sleep 0.5; done
  usay "enabling units for boot…"; units_enable
  usay "done."; units_status
}

# CLI dispatch only when executed directly (sourcing just defines the functions).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    install)    units_install ;;
    start)      shift; units_start "$@" ;;
    stop)       shift; units_stop "$@" ;;
    restart)    shift; units_restart "$@" ;;
    reset)      shift; units_reset "$@" ;;
    logs)       shift; units_logs "$@" ;;
    enable)     units_enable ;;
    stop-all)   units_stop_all ;;
    remove-all) units_remove_all ;;
    up)         units_up ;;
    status)     shift; units_status "$@" ;;
    *) cat >&2 <<'USAGE'; exit 2 ;;
usage: units.sh <cmd> [args]   (services: torii-bank | torii-game)
  up                       install + start (resume) + enable for boot
  install                  (re)write the unit files
  start|stop|restart <name…>   per-service lifecycle
  reset <torii-name>       wipe the indexer's db + re-index
  logs [name] [-f] [-n N]  journalctl for one service, or all
  status [name…]           systemctl status (all units if no name)
  stop-all | remove-all    stop+disable (and delete) every dungeon unit
  enable                   enable all units for boot
USAGE
  esac
fi
