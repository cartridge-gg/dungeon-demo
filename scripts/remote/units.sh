#!/usr/bin/env bash
# systemd supervision for the dungeon BACKEND services (system-level units, run as
# the deploy user). Keeps the stack alive across crashes (Restart=always) and server
# reboots (enabled, WantedBy=multi-user.target). Backend only — no frontend; the
# public client is GitHub Pages.
#
# Sourced by scripts/remote/deploy.sh (uses the units_* functions), and also runnable
# standalone to migrate an ALREADY-DEPLOYED stack onto systemd with no redeploy/gas:
#
#   bash scripts/remote/units.sh up          # install units + start (resume) + enable
#   bash scripts/remote/units.sh remove-all  # stop, disable, delete the unit files
#   bash scripts/remote/units.sh status
#
# deploy.ts is deliberately NOT a unit: a unit would re-run it (re-spending gas) on
# every boot. The long-lived services resume from on-disk state instead.
set -euo pipefail

_UNITS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="${DEMO_DIR:-$(cd "$_UNITS_DIR/../.." && pwd)}"
RUN_DIR="${RUN_DIR:-$DEMO_DIR/.run}"
KATANA="${KATANA:-$HOME/katana/target/release/katana}"
DEPLOY_USER="$(id -un)"
SYSTEMD_DIR=/etc/systemd/system
PFX=dungeon
# Units get a minimal env; PATH covers torii/sozo (+ ~/.local, ~/.bun) and KATANA is
# absolute. systemd does not expand ~ or $HOME, so spell them out.
RUNTIME_PATH="$HOME/.local/bin:$HOME/.bun/bin:/usr/local/bin:/usr/bin:/bin"

# Start order matters: the game torii needs the appchain first. The appchain unit
# settles to piltover itself (embedded settlement) — there is no separate saya unit.
UNIT_NAMES=(appchain torii-bank torii-game)

usay() { echo "→ $*"; }

# name|script|After-extra|Description  (one per backend service)
_unit_table() {
  cat <<EOF
appchain|appchain.sh||Dungeon appchain (katana rollup, embedded settlement → Sepolia)
torii-bank|torii-bank.sh||Dungeon torii — bank world (Starknet Sepolia)
torii-game|torii-game.sh| ${PFX}-appchain.service|Dungeon torii — game world (appchain)
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
  [[ -x "$KATANA" ]] || { echo "error: katana not executable: $KATANA" >&2; exit 1; }
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
Environment=KATANA=$KATANA
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

units_start()  { local n; for n in "$@"; do sudo systemctl start "${PFX}-$n.service"; done; }
units_enable() { local n u=(); for n in "${UNIT_NAMES[@]}"; do u+=("${PFX}-$n.service"); done; sudo systemctl enable "${u[@]}" >/dev/null; }
units_status() { sudo systemctl --no-pager --output=short status "${PFX}-appchain" "${PFX}-torii-bank" "${PFX}-torii-game" 2>&1 || true; }

# Install + start in dependency order (resuming on-disk state) + enable for boot.
# For migrating an already-deployed stack — does NOT run deploy.ts.
units_up() {
  units_install
  usay "starting appchain…"; units_start appchain
  until curl -s -o /dev/null http://localhost:5070/ 2>/dev/null; do sleep 0.5; done
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
    enable)     units_enable ;;
    stop-all)   units_stop_all ;;
    remove-all) units_remove_all ;;
    up)         units_up ;;
    status)     units_status ;;
    *) echo "usage: units.sh {install|start <name…>|enable|stop-all|remove-all|up|status}" >&2; exit 2 ;;
  esac
fi
