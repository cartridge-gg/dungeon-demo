#!/usr/bin/env bash
# Fresh Sepolia deployment of the cross-chain-dungeon stack, driven from a
# self-contained checkout of THIS repo (no monorepo layout required).
#
# Runs ON the remote TEE server (see .github/workflows/deploy-sepolia.yml, which
# fresh-clones the repo and invokes this). Two phases:
#
#   prepare   make the checkout build standalone — resolve the Controller class
#             artifacts, install JS deps, and build the cairo packages (Dojo comes
#             from the Scarb registry, so no checkout to wire up). Idempotent;
#             touches nothing that's running.
#   bring-up  tear down any running stack, deploy the economy + worlds against the
#             EXTERNAL appchain (real Sepolia gas for the settlement-side contracts),
#             start the backend toriis under systemd (system units, Restart=always,
#             enabled for boot), and health-check them (a failed check fails the
#             deploy before the manifest is recorded). DESTRUCTIVE — kills the live
#             toriis (the appchain is external and left untouched).
#
# The appchain is NOT deployed or operated here — it's owned by
# cartridge-gg/cartridge-appchain. This consumes its RPC (APPCHAIN_RPC_URL) and its
# piltover core (PILTOVER_ADDRESS), supplied via .env.
#
# PREPARE_ONLY=1 stops after `prepare` (cairo build), spending no gas and leaving
# any running stack alone — use it to validate the standalone build.
#
# Env knobs (all optional):
#   CONTROLLER_CLASSES_DIR  Controller artifact dir (default: vendor/controller submodule)
#   PREPARE_ONLY          1 = stop after the standalone build
set -euo pipefail

# This script lives at scripts/remote/deploy.sh → the repo root is two levels up.
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVICES="$DEMO_DIR/scripts/services"
RUN_DIR="$DEMO_DIR/.run"

# Match the PATH the server's other launchers use (bun + scarb live under ~).
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/.bun/bin:/usr/local/bin:$PATH"

say()  { echo "→ $*"; }
fail() { echo "error: $*" >&2; exit 1; }

# systemd supervision for the backend services (units_install/start/enable/stop_all).
# shellcheck source=scripts/remote/units.sh
source "$DEMO_DIR/scripts/remote/units.sh"

# ── prepare: make this checkout build on its own ────────────────────────────────
prepare() {
  command -v scarb  >/dev/null || fail "scarb not found on PATH (need 2.13.1)."
  command -v sozo   >/dev/null || fail "sozo not found on PATH (need 1.8.7)."
  command -v bun    >/dev/null || fail "bun not found on PATH."
  # No katana here — the appchain is external (cartridge-appchain).

  # 1. Controller class artifacts ship in the vendor/controller submodule
  #    (cartridge-gg/controller-rs). Init it so this checkout is self-contained;
  #    declare-controller-class.ts then finds the classes without any external
  #    katana checkout. CONTROLLER_CLASSES_DIR still overrides for out-of-tree use.
  # Init on demand so a fresh git clone is self-contained; skip when the classes are
  # already present (e.g. an rsync deploy with no .git), matching up.sh's guard.
  local default_classes="$DEMO_DIR/vendor/controller/account_sdk/artifacts/classes"
  [ -e "$default_classes" ] \
    || { say "initializing vendor/controller submodule…"; ( cd "$DEMO_DIR" && git submodule update --init vendor/controller ); }
  CONTROLLER_CLASSES_DIR="${CONTROLLER_CLASSES_DIR:-$default_classes}"
  [[ -d "$CONTROLLER_CLASSES_DIR" ]] \
    || fail "Controller classes dir not found: $CONTROLLER_CLASSES_DIR — run 'git submodule update --init vendor/controller' or set CONTROLLER_CLASSES_DIR."
  export CONTROLLER_CLASSES_DIR
  say "controller classes: $CONTROLLER_CLASSES_DIR"

  # 2. JS deps (deploy scripts + frontend).
  say "installing JS deps…"
  ( cd "$DEMO_DIR" && bun install >/dev/null )
  ( cd "$DEMO_DIR/app" && bun install >/dev/null )

  # 3. Build the cairo packages now so a broken standalone build fails here, before
  #    we spend any gas or touch the running stack. Dojo resolves from the Scarb
  #    registry (see cairo/{game,score}/Scarb.toml) — nothing to clone.
  say "building cairo packages (standalone build check)…"
  ( cd "$DEMO_DIR/cairo/token" && scarb build )
  ( cd "$DEMO_DIR/cairo/game"  && scarb build )
  ( cd "$DEMO_DIR/cairo/score" && scarb build )
  say "standalone build OK."
}

# ── env + settlement derivation (shared with the launchers) ─────────────────────
load_common() {
  [[ -f "$DEMO_DIR/.env" ]] || fail "no .env in $DEMO_DIR — the workflow installs it from the DEPLOY_ENV secret."
  # shellcheck disable=SC1091
  source "$SERVICES/_common.sh"
}

# ── tear down any running stack ─────────────────────────────────────────────────
teardown() {
  say "tearing down running stack…"
  # Stop+disable any dungeon units FIRST so Restart=always doesn't respawn them the
  # moment we free their ports. (install rewrites the unit set during bring-up.)
  units_stop_all
  # Kill the legacy tmux session too (migration from the pre-systemd model).
  for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^dungeon[0-9]*$' || true); do
    say "  killing tmux session $s"
    tmux kill-session -t "$s" 2>/dev/null || true
  done
  for p in "$TORII_SCORE_HTTP" "$TORII_SCORE_GRPC" "$TORII_SCORE_RELAY" $((TORII_SCORE_RELAY+1)) $((TORII_SCORE_RELAY+2)) \
           "$TORII_GAME_HTTP"  "$TORII_GAME_GRPC"  "$TORII_GAME_RELAY"  $((TORII_GAME_RELAY+1))  $((TORII_GAME_RELAY+2)); do
    free_port "$p"
  done
}

# ── base deployments.json from .env (settlement + EXTERNAL appchain) ─────────────
# No bootstrap: the appchain (piltover core, dev account, chain config) is owned by
# cartridge-appchain. We just record its RPC + piltover from .env so scripts/deploy.ts
# can deploy the economy/worlds against it. FRESH wipes the torii dbs so the toriis
# re-index from scratch (the units run the service scripts WITHOUT RESET, resuming on
# restart; the one-time FRESH wipe happens here instead).
write_deployments() {
  mkdir -p "$RUN_DIR"
  rm -rf "$RUN_DIR/torii-score.db" "$RUN_DIR/torii-game.db"

  for v in APPCHAIN_RPC_URL APPCHAIN_ACCOUNT_ADDRESS APPCHAIN_ACCOUNT_PRIVATE_KEY \
           PILTOVER_ADDRESS OPERATOR_ADDRESS OPERATOR_PRIVATE_KEY USDC_ADDRESS; do
    [[ -n "${!v:-}" ]] || fail "missing $v in .env (see .env.example)."
  done
  say "settlement piltover (from cartridge-appchain): $PILTOVER_ADDRESS"
  say "external appchain RPC: $APPCHAIN_RPC_URL"

  say "writing base deployments.json…"
  local appchain_explorer="${APPCHAIN_RPC_URL%/rpc}/explorer"
  SETTLEMENT_RPC_URL="$SETTLEMENT_RPC_URL" \
  SETTLEMENT_NETWORK="$SETTLEMENT_NETWORK" \
  SETTLEMENT_CHAIN_ID="$SETTLEMENT_CHAIN_ID" \
  SETTLEMENT_EXPLORER="$SETTLEMENT_EXPLORER" \
  OPERATOR_ADDRESS="$OPERATOR_ADDRESS" \
  OPERATOR_PRIVATE_KEY="$OPERATOR_PRIVATE_KEY" \
  PILTOVER_ADDRESS="$PILTOVER_ADDRESS" \
  USDC_ADDRESS="$USDC_ADDRESS" \
  APPCHAIN_RPC_URL="$APPCHAIN_RPC_URL" \
  APPCHAIN_EXPLORER="$appchain_explorer" \
  APPCHAIN_ACCOUNT_ADDRESS="$APPCHAIN_ACCOUNT_ADDRESS" \
  APPCHAIN_ACCOUNT_PRIVATE_KEY="$APPCHAIN_ACCOUNT_PRIVATE_KEY" \
  TORII_SCORE_HTTP="$TORII_SCORE_HTTP" \
  TORII_GAME_HTTP="$TORII_GAME_HTTP" \
  DEPLOY_OUT="$DEMO_DIR/deployments.json" \
  node -e '
    const fs = require("node:fs");
    const e = process.env;
    const d = {
      settlement: {
        network: e.SETTLEMENT_NETWORK, chainId: e.SETTLEMENT_CHAIN_ID,
        rpcUrl: e.SETTLEMENT_RPC_URL, explorer: e.SETTLEMENT_EXPLORER,
        torii: "http://localhost:" + e.TORII_SCORE_HTTP,
        account: { address: e.OPERATOR_ADDRESS, privateKey: e.OPERATOR_PRIVATE_KEY },
        piltover: e.PILTOVER_ADDRESS, usdc: e.USDC_ADDRESS,
      },
      appchain: {
        rpcUrl: e.APPCHAIN_RPC_URL,
        explorer: e.APPCHAIN_EXPLORER,
        torii: "http://localhost:" + e.TORII_GAME_HTTP,
        account: { address: e.APPCHAIN_ACCOUNT_ADDRESS, privateKey: e.APPCHAIN_ACCOUNT_PRIVATE_KEY },
      },
    };
    fs.writeFileSync(e.DEPLOY_OUT, JSON.stringify(d, null, 2) + "\n");
  '
}

wait_http() { until curl -s -o /dev/null "$1" 2>/dev/null; do sleep 0.5; done; }

# ── health check: assert every service actually responds after bring-up. Catches a
#    service that systemd started but that crashed seconds later (bad world address,
#    flaky RPC, port clash) — so a green deploy means a live stack, not just "units
#    started". Runs BEFORE the manifest, so a broken deploy doesn't get
#    recorded/committed. Checks loopback only (the authoritative signal); the public
#    reverse-proxy URL is out of scope here. ──────────────────────────────────────
health() {
  say "health check…"
  local ok=1
  # check <label> <url> [extra curl args…] — retries ~30s; any HTTP reply = up.
  check() {
    local label="$1" url="$2"; shift 2
    local i=0
    while ! curl -sS -m 4 -o /dev/null "$@" "$url" 2>/dev/null; do
      i=$((i + 1))
      if [[ $i -ge 30 ]]; then say "  ✗ $label ($url) not responding"; ok=0; return 0; fi
      sleep 1
    done
    say "  ✓ $label"
    return 0
  }
  # The appchain is external (cartridge-appchain) — assert its RPC is reachable so we
  # fail fast if it's down/misconfigured, but it's not ours to restart.
  check "appchain RPC (external) $APPCHAIN_RPC_URL" "$APPCHAIN_RPC_URL" \
    -X POST -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"starknet_chainId","params":[]}'
  check "torii bank :$TORII_SCORE_HTTP" "http://localhost:$TORII_SCORE_HTTP/"
  check "torii game :$TORII_GAME_HTTP" "http://localhost:$TORII_GAME_HTTP/"
  [[ "$ok" == "1" ]] || fail "health check failed — not all services are responding (check: sudo systemctl status 'dungeon-*' ; journalctl -u dungeon-torii-game -n50)."
  say "all services healthy."
}

# ── write a sanitized deployment manifest (NO private keys) for the workflow to
#    commit. Projects deployments.json + the TEE registry + run metadata
#    down to addresses / URLs / account addresses only. ─────────────────────────
manifest() {
  local out_dir="$DEMO_DIR/deployments"
  mkdir -p "$out_dir"
  say "writing deployment manifest → deployments/<network>.json…"
  DEPLOYMENTS_FILE="$DEMO_DIR/deployments.json" \
  GIT_REF="${GIT_REF:-$(git -C "$DEMO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)}" \
  GIT_SHA="${GIT_SHA:-$(git -C "$DEMO_DIR" rev-parse HEAD 2>/dev/null || true)}" \
  DEPLOYED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  OUT_DIR="$out_dir" \
  node -e '
    const fs = require("node:fs");
    const e = process.env;
    const d = require(e.DEPLOYMENTS_FILE);
    const s = d.settlement, a = d.appchain;
    const manifest = {
      meta: { network: s.network, deployedAt: e.DEPLOYED_AT, gitRef: e.GIT_REF || null, gitSha: e.GIT_SHA || null },
      settlement: {
        network: s.network, chainId: s.chainId, rpcUrl: s.rpcUrl, explorer: s.explorer, torii: s.torii,
        piltover: s.piltover, usdc: s.usdc,
        gameToken: s.gameToken, goldToken: s.goldToken,
        bankWorld: s.bankWorld, bankSystem: s.bankSystem,
        tokenSale: s.tokenSale, entry: s.entry,
        operator: s.account?.address ?? null,        // address only — never the key
      },
      appchain: {
        rpcUrl: a.rpcUrl, explorer: a.explorer, torii: a.torii,
        chainId: a.chainId ?? null,                   // short string, e.g. CARTRIDGE_MAINNET
        gameWorld: a.gameWorld, gameSystem: a.gameSystem,
        devAccount: a.account?.address ?? null,       // address only — never the key
      },
    };
    fs.writeFileSync(`${e.OUT_DIR}/${s.network}.json`, JSON.stringify(manifest, null, 2) + "\n");
    console.log(`  ${s.network}.json`);
  '
}

# ── bring the backend toriis up under systemd + deploy the economy/worlds ────────
# deploy.ts runs INLINE (before the toriis) — never as a unit, so a reboot restarts
# the toriis without re-deploying contracts (no gas). The appchain is external, so
# there's no appchain unit to start here.
bringup() {
  units_install

  say "deploying economy + worlds (scripts/deploy.ts)…"
  ( cd "$DEMO_DIR" && bun run scripts/deploy.ts )

  say "declaring Controller account classes on the appchain…"
  ( cd "$DEMO_DIR" && CONTROLLER_CLASSES_DIR="$CONTROLLER_CLASSES_DIR" bun run scripts/declare-controller-class.ts )

  say "starting toriis (dungeon-torii-bank :$TORII_SCORE_HTTP, dungeon-torii-game :$TORII_GAME_HTTP)…"
  units_start torii-bank torii-game
  wait_http "http://localhost:$TORII_GAME_HTTP/"

  say "enabling units to start on boot…"
  units_enable
}

main() {
  say "fresh deploy from $DEMO_DIR"
  prepare

  if [[ "${PREPARE_ONLY:-}" == "1" ]]; then
    say "PREPARE_ONLY=1 — standalone build verified, stopping before teardown/deploy."
    return 0
  fi

  load_common
  teardown
  write_deployments
  bringup
  health
  manifest

  echo ""
  say "✓ fresh deploy complete — backend toriis under systemd (enabled for boot):"
  echo "    settlement    : $SETTLEMENT_NAME ($SETTLEMENT_RPC_URL)"
  echo "    appchain RPC  : $APPCHAIN_RPC_URL  (external — cartridge-appchain)"
  echo "    torii (bank)  : http://localhost:$TORII_SCORE_HTTP/sql"
  echo "    torii (game)  : http://localhost:$TORII_GAME_HTTP/sql"
  echo "    manage        : sudo systemctl status 'dungeon-*'  |  journalctl -u dungeon-torii-game -f"
  echo ""
  say "deployment manifest (sanitized — committed by the workflow):"
  cat "$DEMO_DIR/deployments/$SETTLEMENT_NETWORK.json"
}

main "$@"
