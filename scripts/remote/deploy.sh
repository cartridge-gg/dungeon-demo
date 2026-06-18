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
#   bring-up  tear down any running stack, FRESH-bootstrap piltover + the rollup,
#             deploy the economy + worlds (real Sepolia gas), start the backend
#             services under systemd (system units, Restart=always, enabled for
#             boot), and health-check them (a failed check fails the deploy before
#             the manifest is recorded). DESTRUCTIVE — kills the live demo.
#
# PREPARE_ONLY=1 stops after `prepare` (cairo build), spending no gas and leaving
# any running stack alone — use it to validate the standalone build.
#
# Env knobs (all optional):
#   KATANA                katana binary (default: $HOME/katana/target/release/katana
#                         — the build whose `init rollup --settlement-chain` takes an
#                         RPC URL; the system katana on PATH may be too old)
#   CONTROLLER_CLASSES_DIR  Controller artifact dir (default: $HOME/katana/...)
#   PREPARE_ONLY          1 = stop after the standalone build
set -euo pipefail

# This script lives at scripts/remote/deploy.sh → the repo root is two levels up.
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVICES="$DEMO_DIR/scripts/services"
RUN_DIR="$DEMO_DIR/.run"

TEE_REGISTRY_SALT="0x7ee"

# The rollup tooling needs the katana build whose `init rollup --settlement-chain`
# takes an RPC URL (the system PATH katana may predate that). _common.sh and the
# systemd units honor this KATANA.
KATANA="${KATANA:-$HOME/katana/target/release/katana}"
export KATANA

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
  [[ -x "$KATANA" ]] || fail "katana not found/executable: $KATANA (set KATANA=… to the rollup-capable build)."

  # 1. Controller class artifacts (ship with katana). No monorepo parent here, so
  #    point declare-controller-class.ts at an existing katana checkout. Override
  #    with CONTROLLER_CLASSES_DIR; default to the server's katana checkout.
  local default_classes="$HOME/katana/crates/contracts/contracts/controller/account_sdk/artifacts/classes"
  CONTROLLER_CLASSES_DIR="${CONTROLLER_CLASSES_DIR:-$default_classes}"
  [[ -d "$CONTROLLER_CLASSES_DIR" ]] \
    || fail "Controller classes dir not found: $CONTROLLER_CLASSES_DIR — set CONTROLLER_CLASSES_DIR to a katana checkout's account_sdk/artifacts/classes."
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

# ── env / settlement derivation + katana binary (shared with the launchers) ─────
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
  for p in "$APPCHAIN_PORT" \
           "$TORII_SCORE_HTTP" "$TORII_SCORE_GRPC" "$TORII_SCORE_RELAY" $((TORII_SCORE_RELAY+1)) $((TORII_SCORE_RELAY+2)) \
           "$TORII_GAME_HTTP"  "$TORII_GAME_GRPC"  "$TORII_GAME_RELAY"  $((TORII_GAME_RELAY+1))  $((TORII_GAME_RELAY+2)); do
    free_port "$p"
  done
}

# ── FRESH bootstrap: mock TEE registry + piltover core + rollup config on Sepolia ─
bootstrap() {
  mkdir -p "$RUN_DIR"
  # FRESH: wipe the indexer/prover state so the new chain re-indexes from scratch.
  # (The units run the service scripts WITHOUT RESET, so they resume on restart; the
  # one-time FRESH wipe happens here instead.)
  rm -rf "$RUN_DIR/saya-db" "$RUN_DIR/torii-score.db" "$RUN_DIR/torii-game.db"
  say "deploying mock TEE registry on $SETTLEMENT_NAME (saya-ops)…"
  local reg_out tee_registry
  reg_out=$(SETTLEMENT_RPC_URL="$SETTLEMENT_RPC_URL" \
    SETTLEMENT_ACCOUNT_ADDRESS="$OPERATOR_ADDRESS" \
    SETTLEMENT_ACCOUNT_PRIVATE_KEY="$OPERATOR_PRIVATE_KEY" \
    SETTLEMENT_CHAIN_ID="$SETTLEMENT_CHAIN_ID" \
    saya-ops core-contract declare-and-deploy-tee-registry-mock --salt "$TEE_REGISTRY_SALT" 2>&1)
  tee_registry=$(echo "$reg_out" | sed -nE 's/.*TEE registry mock address:[[:space:]]*(0x[0-9a-fA-F]+).*/\1/p' | tail -1)
  [[ -n "$tee_registry" ]] || { echo "$reg_out" >&2; fail "could not parse TEE registry address."; }
  echo "$tee_registry" > "$RUN_DIR/tee_registry"
  say "  tee_registry=$tee_registry"

  say "deploying piltover core + rollup config (katana init rollup --tee)…"
  rm -rf "$CHAIN_DIR" "$APPCHAIN_DB"
  "$KATANA" init rollup \
    --id DUNGEON \
    --settlement-chain "$SETTLEMENT_RPC_URL" \
    --settlement-account-address "$SAYA_ADDRESS" \
    --settlement-account-private-key "$SAYA_PRIVATE_KEY" \
    --tee \
    --tee-registry-address "$tee_registry" \
    --output-path "$CHAIN_DIR" > "$RUN_DIR/init.log" 2>&1
  PILTOVER="$(read_piltover)"
  [[ -n "$PILTOVER" ]] || { cat "$RUN_DIR/init.log" >&2; fail "could not parse piltover from $CHAIN_DIR/config.toml."; }
  say "  piltover=$PILTOVER"

  # Enable katana's embedded settlement service: add the operator-owned
  # [settlement.runtime] section so the appchain node settles itself (proves each
  # block + submits update_state), replacing the old saya-tee sidecar. The saya
  # account's key lands in config.toml in plaintext — server-local (.run is gitignored).
  if ! grep -q '^\[settlement.runtime\]' "$CHAIN_DIR/config.toml"; then
    say "  adding [settlement.runtime] (embedded settlement)…"
    cat >> "$CHAIN_DIR/config.toml" <<EOF

[settlement.runtime]
account-address = "$SAYA_ADDRESS"
account-private-key = "$SAYA_PRIVATE_KEY"
tee-registry = "$tee_registry"
batch-size = ${SAYA_BATCH_SIZE:-1}
EOF
  fi

  say "writing base deployments.json…"
  node -e '
    const fs = require("node:fs");
    const g = require(process.argv[1]);
    const [addr, acct] = Object.entries(g.accounts)[0];
    const d = {
      settlement: {
        network: process.argv[11], chainId: process.argv[12],
        rpcUrl: process.argv[2], explorer: process.argv[10],
        torii: "http://localhost:" + process.argv[8],
        account: { address: process.argv[3], privateKey: process.argv[4] },
        piltover: process.argv[5], usdc: process.argv[6],
      },
      appchain: {
        rpcUrl: "http://localhost:" + process.argv[7],
        explorer: "http://localhost:" + process.argv[7] + "/explorer",
        torii: "http://localhost:" + process.argv[9],
        account: { address: addr, privateKey: acct.privateKey },
      },
    };
    fs.writeFileSync(process.argv[13], JSON.stringify(d, null, 2) + "\n");
  ' "$CHAIN_DIR/genesis.json" "$SETTLEMENT_RPC_URL" "$OPERATOR_ADDRESS" "$OPERATOR_PRIVATE_KEY" \
    "$PILTOVER" "$USDC_ADDRESS" "$APPCHAIN_PORT" "$TORII_SCORE_HTTP" "$TORII_GAME_HTTP" \
    "$SETTLEMENT_EXPLORER" "$SETTLEMENT_NETWORK" "$SETTLEMENT_CHAIN_ID" \
    "$DEMO_DIR/deployments.json"
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
  check "appchain RPC :$APPCHAIN_PORT" "http://localhost:$APPCHAIN_PORT" \
    -X POST -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"starknet_chainId","params":[]}'
  check "torii bank :$TORII_SCORE_HTTP" "http://localhost:$TORII_SCORE_HTTP/"
  check "torii game :$TORII_GAME_HTTP" "http://localhost:$TORII_GAME_HTTP/"
  # Settlement runs inside the appchain node now (the embedded service has no HTTP
  # endpoint) — assert it started from the appchain unit's journal.
  if journalctl -u "${PFX}-appchain" --no-pager 2>/dev/null | grep -q "Settlement service started"; then
    say "  ✓ embedded settlement"
  else
    say "  ✗ embedded settlement not started (journalctl -u ${PFX}-appchain)"; ok=0
  fi
  [[ "$ok" == "1" ]] || fail "health check failed — not all services are responding (check: sudo systemctl status 'dungeon-*' ; journalctl -u dungeon-appchain -n50)."
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
  TEE_REGISTRY="$(cat "$RUN_DIR/tee_registry" 2>/dev/null || true)" \
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
        piltover: s.piltover, teeRegistry: e.TEE_REGISTRY || null, usdc: s.usdc,
        gameToken: s.gameToken, goldToken: s.goldToken,
        bankWorld: s.bankWorld, bankSystem: s.bankSystem,
        tokenSale: s.tokenSale, entry: s.entry,
        operator: s.account?.address ?? null,        // address only — never the key
      },
      appchain: {
        rpcUrl: a.rpcUrl, explorer: a.explorer, torii: a.torii,
        gameWorld: a.gameWorld, gameSystem: a.gameSystem,
        devAccount: a.account?.address ?? null,       // address only — never the key
      },
    };
    fs.writeFileSync(`${e.OUT_DIR}/${s.network}.json`, JSON.stringify(manifest, null, 2) + "\n");
    console.log(`  ${s.network}.json`);
  '
}

# ── bring the backend services up under systemd + deploy the economy/worlds ──────
# deploy.ts runs INLINE (between the appchain and the toriis) — never as a unit, so
# a reboot restarts the services without re-deploying contracts (no gas).
bringup() {
  units_install

  # The appchain unit runs katana with the [settlement.runtime] section, so it
  # settles to piltover itself — no separate saya unit.
  say "starting appchain (dungeon-appchain) on :$APPCHAIN_PORT…"
  units_start appchain
  wait_http "http://localhost:$APPCHAIN_PORT/"

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
  bootstrap
  bringup
  health
  manifest

  echo ""
  say "✓ fresh deploy complete — backend under systemd (enabled for boot):"
  echo "    settlement    : $SETTLEMENT_NAME ($SETTLEMENT_RPC_URL)"
  echo "    appchain RPC  : http://localhost:$APPCHAIN_PORT"
  echo "    torii (bank)  : http://localhost:$TORII_SCORE_HTTP/sql"
  echo "    torii (game)  : http://localhost:$TORII_GAME_HTTP/sql"
  echo "    manage        : sudo systemctl status 'dungeon-*'  |  journalctl -u dungeon-appchain -f"
  echo ""
  say "deployment manifest (sanitized — committed by the workflow):"
  cat "$DEMO_DIR/deployments/$SETTLEMENT_NETWORK.json"
}

main "$@"
