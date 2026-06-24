#!/usr/bin/env bash
# Bring up the cross-chain-dungeon demo. The settlement layer is REAL Starknet
# Sepolia (remote) — only the appchain runs locally:
#
#   Starknet Sepolia (remote)
#     + piltover core         (deployed by `katana init rollup --tee`)
#     + mock TEE registry     (already deployed — reused, see TEE_REGISTRY_ADDRESS)
#     + GAME_TOKEN / TokenSale / Entry / score world  (deployed by scripts/deploy.ts)
#   appchain Katana (:5070, rollup, --tee mock) settling to piltover on Sepolia,
#     with its embedded settlement service (the [settlement.runtime] section)
#     proving each block and submitting update_state itself — no saya-tee sidecar.
#   two torii indexers (Sepolia score :8091, appchain game :8092)
#   React frontend (:3002)
#
# Requires a funded Sepolia operator + saya account and a USDC address — see
# .env.example (copy to .env). These deploys cost real Sepolia gas. Also requires
# katana >= 1.8.0-rc.4 (embedded settlement), pinned in .tool-versions (asdf).
#
# Ctrl-C tears down the appchain node and the toriis.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DEMO_DIR/../.." && pwd)"
RUN_DIR="$DEMO_DIR/.run"
CHAIN_DIR="$RUN_DIR/chain-config"
APPCHAIN_DB="$RUN_DIR/appchain-db"   # persistent appchain state — survives restarts
SERVICES="$DEMO_DIR/scripts/services"   # per-service launchers (each runnable standalone)
mkdir -p "$RUN_DIR"

# Ports.
APPCHAIN_PORT=5070
TORII_SCORE_HTTP=8091; TORII_SCORE_GRPC=50091; TORII_SCORE_RELAY=9191
TORII_GAME_HTTP=8092;  TORII_GAME_GRPC=50092;  TORII_GAME_RELAY=9194
FRONTEND_PORT=3002

# The mock TEE registry is already deployed on Sepolia (deterministic salt 0x7ee), so
# we reuse it instead of redeploying via saya-ops. Override TEE_REGISTRY_ADDRESS in
# .env for a different network (e.g. a mainnet registry).
TEE_REGISTRY_ADDRESS="${TEE_REGISTRY_ADDRESS:-0x37189b1807f1358074b70b3dc8ab79167bbf72cff1296286052f6dfe31c8f15}"

fail() { echo "error: $1" >&2; exit 1; }

# ── Load .env ──────────────────────────────────────────────────────────────────
[[ -f "$DEMO_DIR/.env" ]] || fail "no .env — copy .env.example to .env and fill in the operator/saya accounts + USDC address."
set -a; # shellcheck disable=SC1091
source "$DEMO_DIR/.env"; set +a

# ── Settlement network (Sepolia by default; Mainnet supported) ──────────────────
# The RPC + USDC come from .env (per network); the chain id, explorer, and display
# name are derived here. SETTLEMENT_RPC_URL is preferred; SEPOLIA_RPC_URL still works.
SETTLEMENT_NETWORK="${SETTLEMENT_NETWORK:-sepolia}"
SETTLEMENT_RPC_URL="${SETTLEMENT_RPC_URL:-${SEPOLIA_RPC_URL:-}}"
case "$SETTLEMENT_NETWORK" in
  sepolia) SETTLEMENT_CHAIN_ID="SN_SEPOLIA"; SETTLEMENT_EXPLORER="https://sepolia.voyager.online"; SETTLEMENT_NAME="Starknet Sepolia" ;;
  mainnet) SETTLEMENT_CHAIN_ID="SN_MAIN";    SETTLEMENT_EXPLORER="https://voyager.online";          SETTLEMENT_NAME="Starknet Mainnet" ;;
  *) fail "SETTLEMENT_NETWORK must be 'sepolia' or 'mainnet' (got '$SETTLEMENT_NETWORK')." ;;
esac

[[ -n "$SETTLEMENT_RPC_URL" ]] || fail "set SETTLEMENT_RPC_URL (or SEPOLIA_RPC_URL) in .env."
for v in OPERATOR_ADDRESS OPERATOR_PRIVATE_KEY SAYA_ADDRESS SAYA_PRIVATE_KEY USDC_ADDRESS; do
  [[ -n "${!v:-}" ]] || fail "missing $v in .env (see .env.example)."
done

# ── Preflight ────────────────────────────────────────────────────────────────
echo "→ preflight…"
if command -v asdf >/dev/null 2>&1; then
  ( cd "$DEMO_DIR" && asdf install ) || echo "  warning: 'asdf install' had issues; verifying tools below…" >&2
else
  echo "  warning: asdf not found — install it, or put sozo/torii/scarb on PATH (see .tool-versions)." >&2
fi

# katana — the appchain node, which settles to piltover itself (embedded settlement
# service; no saya-tee sidecar). Needs katana >= 1.8.0-rc.4, pinned in .tool-versions
# (asdf) like sozo/torii/scarb. Honor a pre-set $KATANA to override (e.g. a local build);
# else take it from PATH. Mirrors scripts/services/_common.sh.
if   [[ -n "${KATANA:-}" && -x "${KATANA:-}" ]]; then :
elif command -v katana >/dev/null 2>&1;          then KATANA="$(command -v katana)"
else fail "katana not found. Run 'asdf install' in this directory (pinned in .tool-versions), or set KATANA to a katana >= 1.8.0-rc.4 binary."; fi

# The mock TEE registry is already deployed on Sepolia and reused (TEE_REGISTRY_ADDRESS),
# so saya-ops is no longer needed. Settlement is done by katana's embedded service, so
# saya-tee and its Poseidon-hash patch are gone too.
for bin in sozo torii scarb; do
  command -v "$bin" >/dev/null 2>&1 || fail "'$bin' not found on PATH. Run 'asdf install' in this directory (see .tool-versions)."
done
echo "→ katana: $KATANA"
echo "→ settlement: $SETTLEMENT_NAME ($SETTLEMENT_RPC_URL)"

# Cartridge Controller (one identity on both chains) — always on. The APPCHAIN is
# Controller-capable — the paymaster/session middleware + Controller auto-deploy — so
# the same Controller that signs buy/enter/bank on Sepolia can also sign the play
# actions here. Settlement is real Sepolia (Cartridge knows it natively), so ONLY the
# appchain needs these flags. The app uses the hosted keychain (x.cartridge.gg) by
# default — a real Cartridge Controller account; set VITE_KEYCHAIN_URL in
# app/.env.local to point at a self-hosted keychain instead (fully-local fallback).
# See docs/controller.md.
CONTROLLER_FLAGS="--paymaster --cartridge.paymaster --cartridge.controllers"
command -v paymaster-service >/dev/null 2>&1 \
  || echo "  note: 'paymaster-service' not on PATH — katana will try to fetch it (cartridge-gg/paymaster); see docs/controller.md." >&2
echo "→ appchain is Controller-capable. Login with a Cartridge Controller (hosted keychain)."

APPCHAIN_PID=""; TORII_SCORE_PID=""; TORII_GAME_PID=""
cleanup() {
  echo ""; echo "→ shutting down…"
  [[ -n "$TORII_GAME_PID" ]] && kill "$TORII_GAME_PID" 2>/dev/null || true
  [[ -n "$TORII_SCORE_PID" ]] && kill "$TORII_SCORE_PID" 2>/dev/null || true
  [[ -n "$APPCHAIN_PID" ]] && kill "$APPCHAIN_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "→ installing JS dependencies…"
( cd "$DEMO_DIR" && bun install >/dev/null )
( cd "$DEMO_DIR/app" && bun install >/dev/null )

# 1. Piltover core on Sepolia — a gas-costing real deploy. The mock TEE registry is
#    reused (already on Sepolia), not redeployed. Skip the bootstrap if a previous run
#    already wrote this chain dir (set FRESH=1 to force a fresh bootstrap). saya is the
#    piltover operator (the only update_state caller) and must differ from the operator.
TEE_REGISTRY="$TEE_REGISTRY_ADDRESS"
echo "$TEE_REGISTRY" > "$RUN_DIR/tee_registry"   # for _common.sh / metadata readers
if [[ -z "${FRESH:-}" && -f "$CHAIN_DIR/config.toml" ]]; then
  echo "→ reusing existing Sepolia bootstrap (set FRESH=1 to redeploy)…"
else
  echo "→ reusing mock TEE registry on $SETTLEMENT_NAME: $TEE_REGISTRY"
  echo "→ deploying piltover core + generating rollup config (katana init rollup --tee)…"
  # Fresh chain config ⇒ fresh genesis, so drop any stale appchain db that was built
  # from a previous genesis (a persisted db must match the chain it was initialized from).
  rm -rf "$CHAIN_DIR" "$APPCHAIN_DB"
  "$KATANA" init rollup \
    --id CARTRIDGE_TESTNET \
    --settlement-chain "$SETTLEMENT_RPC_URL" \
    --settlement-account-address "$SAYA_ADDRESS" \
    --settlement-account-private-key "$SAYA_PRIVATE_KEY" \
    --tee \
    --tee-registry-address "$TEE_REGISTRY" \
    --output-path "$CHAIN_DIR" > "$RUN_DIR/init.log" 2>&1
fi
echo "   tee_registry=$TEE_REGISTRY"
PILTOVER=$(sed -nE 's/^core_contract = "(0x[0-9a-fA-F]+)".*/\1/p' "$CHAIN_DIR/config.toml")
[[ -n "$PILTOVER" ]] || { echo "error: could not parse piltover address from config.toml" >&2; cat "$RUN_DIR/init.log" 2>/dev/null >&2; exit 1; }
echo "   piltover=$PILTOVER"

# Enable katana's embedded settlement service. `init rollup` writes only the
# settlement *layer*; the operator adds the [settlement.runtime] section (the saya
# account + key, TEE registry, batching) that turns the appchain node into an active
# settler — it proves each block and submits update_state itself, the job that used
# to belong to the saya-tee sidecar. Idempotent: the chain config persists across
# runs, so only append when the section isn't already there. The private key lands
# in .run/chain-config/config.toml in plaintext — operator-local (.run is gitignored).
if ! grep -q '^\[settlement.runtime\]' "$CHAIN_DIR/config.toml"; then
  echo "→ adding [settlement.runtime] (embedded settlement, replaces saya-tee)…"
  cat >> "$CHAIN_DIR/config.toml" <<EOF

[settlement.runtime]
account-address = "$SAYA_ADDRESS"
account-private-key = "$SAYA_PRIVATE_KEY"
tee-registry = "$TEE_REGISTRY"
batch-size = ${SAYA_BATCH_SIZE:-1}
EOF
fi

# 3. Base deployments.json (settlement network/rpc/accounts, piltover, USDC). The
#    appchain account comes from the generated rollup genesis.
echo "→ writing base deployments.json…"
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

# 4. Appchain rollup node, settling to piltover on Sepolia, L1→L2 messaging on.
#    --block-time 5000 mines on a 5s interval (instead of instant) so the embedded settlement service settles
#    at a steady cadence rather than bursting a block per action.
#    --data-dir persists appchain state to disk so a katana restart keeps the game
#    world + runs (an in-memory chain would lose them and force a full redeploy).
echo "→ starting appchain node on :${APPCHAIN_PORT}…"
"$SERVICES/appchain.sh" > "$RUN_DIR/appchain.log" 2>&1 &
APPCHAIN_PID=$!
until curl -s -o /dev/null "http://localhost:$APPCHAIN_PORT/" 2>/dev/null; do sleep 0.5; done

# 5. Settlement: handled by the appchain node's embedded settlement service
#    (configured via the [settlement.runtime] section written above). It proves each
#    appchain block (--tee mock) and submits update_state to piltover on Sepolia —
#    no external saya-tee sidecar.

# 6. Deploy the economy + worlds (GAME_TOKEN, score, game, TokenSale, Entry, grants).
( cd "$DEMO_DIR" && bun run scripts/deploy.ts )

# 6b. Declare the Controller account class on the appchain.
#     Workaround for katana #584: `katana init rollup` round-trips genesis.json,
#     shifting the embedded controller class hash, so the canonical class the keychain
#     deploys isn't present after boot. Without it the Controller can't auto-deploy on
#     the appchain and its play actions fall back to the settlement chain. Declaring the
#     on-disk artifact here lands the canonical hash so the Controller can sign appchain txs.
echo "→ declaring Controller account class on the appchain (katana #584 workaround)…"
#     The class artifacts live in the vendor/controller submodule (controller-rs);
#     init it on demand so a fresh clone works without --recurse-submodules.
[ -e "$DEMO_DIR/vendor/controller/account_sdk/artifacts/classes" ] \
  || ( cd "$DEMO_DIR" && git submodule update --init vendor/controller )
( cd "$DEMO_DIR" && bun run scripts/declare-controller-class.ts )

# 7. Torii indexers (bank world on Sepolia, game world on the appchain). RESET=1 wipes
#    each db for a clean re-index on a full bring-up; restarting either script on its
#    own resumes from its db (pass RESET=1 to force a re-index after a flaky-RPC gap).
echo "→ starting torii ($SETTLEMENT_NAME: bank world) on :${TORII_SCORE_HTTP}…"
RESET=1 "$SERVICES/torii-bank.sh" > "$RUN_DIR/torii-score.log" 2>&1 &
TORII_SCORE_PID=$!

echo "→ starting torii (appchain: game world) on :${TORII_GAME_HTTP}…"
RESET=1 "$SERVICES/torii-game.sh" > "$RUN_DIR/torii-game.log" 2>&1 &
TORII_GAME_PID=$!
until curl -s -o /dev/null "http://localhost:$TORII_GAME_HTTP/" 2>/dev/null; do sleep 0.5; done

echo ""
echo "✓ Demo is up:"
echo "    settlement     : $SETTLEMENT_NAME ($SETTLEMENT_RPC_URL)"
echo "    appchain RPC   : http://localhost:$APPCHAIN_PORT   explorer: http://localhost:$APPCHAIN_PORT/explorer  (embedded settlement)"
echo "    torii (score)  : http://localhost:$TORII_SCORE_HTTP/sql   (.run/torii-score.log)"
echo "    torii (game)   : http://localhost:$TORII_GAME_HTTP/sql    (.run/torii-game.log)"
# Frontend is HTTPS by default (mkcert); set HTTP=1 to serve plain http.
APP_SCHEME=https; [[ "${HTTP:-}" == "1" ]] && APP_SCHEME=http
echo "    frontend       : $APP_SCHEME://localhost:$FRONTEND_PORT"
echo ""

# 8. Frontend (foreground; Ctrl-C stops everything via the trap above). Not exec'd, so
#    up.sh stays alive to run the cleanup trap when the frontend exits.
"$SERVICES/frontend.sh"
