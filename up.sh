#!/usr/bin/env bash
# Bring up the cross-chain-dungeon demo. cross-chain-dungeon is an APP that runs
# against an EXTERNAL appchain (deployed + operated by cartridge-gg/cartridge-appchain)
# and settles to REAL Starknet Sepolia (remote). Nothing of the appchain runs here:
#
#   external appchain Katana (CARTRIDGE_MAINNET / CARTRIDGE_TESTNET) — owned by cartridge-appchain.
#     It already settles to its own piltover core on Sepolia; we only consume its RPC.
#   Starknet Sepolia (remote)
#     + GAME_TOKEN / TokenSale / Entry / score world  (deployed by scripts/deploy.ts)
#   the game world, deployed to the external appchain by scripts/deploy.ts
#   two torii indexers (Sepolia score :8091, appchain game :8092)
#   React frontend (:3002)
#
# Requires the external appchain's RPC + a deploy-capable account on it
# (APPCHAIN_RPC_URL / APPCHAIN_ACCOUNT_*), its piltover core (PILTOVER_ADDRESS), a
# funded Sepolia operator account, and a USDC address — see .env.example (copy to .env).
# The Sepolia deploys cost real gas. For a fully-local stack, run cartridge-appchain
# locally first (it brings up the katana node on :5070), then point APPCHAIN_RPC_URL at
# it. Requires sozo/torii/scarb, pinned in .tool-versions (asdf).
#
# Ctrl-C tears down our toriis + frontend. The appchain is external — left running.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DEMO_DIR/../.." && pwd)"
RUN_DIR="$DEMO_DIR/.run"
SERVICES="$DEMO_DIR/scripts/services"   # per-service launchers (each runnable standalone)
mkdir -p "$RUN_DIR"

# Ports (our toriis + frontend; the appchain RPC comes from .env).
TORII_SCORE_HTTP=8091; TORII_SCORE_GRPC=50091; TORII_SCORE_RELAY=9191
TORII_GAME_HTTP=8092;  TORII_GAME_GRPC=50092;  TORII_GAME_RELAY=9194
FRONTEND_PORT=3002

fail() { echo "error: $1" >&2; exit 1; }

# ── Load .env ──────────────────────────────────────────────────────────────────
[[ -f "$DEMO_DIR/.env" ]] || fail "no .env — copy .env.example to .env and fill in the external appchain (APPCHAIN_*/PILTOVER_ADDRESS), the operator account, and the USDC address."
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
for v in OPERATOR_ADDRESS OPERATOR_PRIVATE_KEY USDC_ADDRESS \
         APPCHAIN_RPC_URL APPCHAIN_ACCOUNT_ADDRESS APPCHAIN_ACCOUNT_PRIVATE_KEY PILTOVER_ADDRESS; do
  [[ -n "${!v:-}" ]] || fail "missing $v in .env (see .env.example)."
done

# ── Preflight ────────────────────────────────────────────────────────────────
echo "→ preflight…"
if command -v asdf >/dev/null 2>&1; then
  ( cd "$DEMO_DIR" && asdf install ) || echo "  warning: 'asdf install' had issues; verifying tools below…" >&2
else
  echo "  warning: asdf not found — install it, or put sozo/torii/scarb on PATH (see .tool-versions)." >&2
fi

# The appchain is external — no katana binary needed here. We deploy with sozo, index
# with torii, and build worlds with scarb.
for bin in sozo torii scarb; do
  command -v "$bin" >/dev/null 2>&1 || fail "'$bin' not found on PATH. Run 'asdf install' in this directory (see .tool-versions)."
done
echo "→ appchain (external): $APPCHAIN_RPC_URL"
echo "→ settlement: $SETTLEMENT_NAME ($SETTLEMENT_RPC_URL)"
echo "→ Controller support depends on the appchain: the mock rollup runs the paymaster +"
echo "   Controller middleware; the enclave rollups do not (play falls back to the dev"
echo "   account signer). See docs/controller.md."

TORII_SCORE_PID=""; TORII_GAME_PID=""
cleanup() {
  echo ""; echo "→ shutting down…"
  [[ -n "$TORII_GAME_PID" ]] && kill "$TORII_GAME_PID" 2>/dev/null || true
  [[ -n "$TORII_SCORE_PID" ]] && kill "$TORII_SCORE_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "→ installing JS dependencies…"
( cd "$DEMO_DIR" && bun install >/dev/null )
( cd "$DEMO_DIR/app" && bun install >/dev/null )

# 1. Wait for the external appchain RPC. It's owned by cartridge-appchain — for a local
#    stack, start that repo's katana node first; for a remote one, point APPCHAIN_RPC_URL
#    at the public proxy. A JSON-RPC endpoint answers GETs with an HTTP status (often
#    405), which is enough to confirm reachability before we deploy against it.
echo "→ checking external appchain RPC ($APPCHAIN_RPC_URL)…"
for i in $(seq 1 30); do
  curl -s -o /dev/null "$APPCHAIN_RPC_URL" 2>/dev/null && break
  [[ "$i" -eq 30 ]] && fail "appchain RPC unreachable at $APPCHAIN_RPC_URL — start cartridge-appchain first (see its README) or fix APPCHAIN_RPC_URL in .env."
  echo "  waiting for the appchain at $APPCHAIN_RPC_URL …"
  sleep 2
done

# 2. Base deployments.json (settlement network/rpc/accounts, piltover, USDC; the external
#    appchain RPC + deploy account). Everything comes from .env — nothing is bootstrapped
#    here. scripts/deploy.ts fills in the deployed contract/world addresses afterwards.
echo "→ writing base deployments.json…"
APPCHAIN_EXPLORER="${APPCHAIN_RPC_URL%/rpc}/explorer"
SETTLEMENT_RPC_URL="$SETTLEMENT_RPC_URL" \
SETTLEMENT_NETWORK="$SETTLEMENT_NETWORK" \
SETTLEMENT_CHAIN_ID="$SETTLEMENT_CHAIN_ID" \
SETTLEMENT_EXPLORER="$SETTLEMENT_EXPLORER" \
OPERATOR_ADDRESS="$OPERATOR_ADDRESS" \
OPERATOR_PRIVATE_KEY="$OPERATOR_PRIVATE_KEY" \
PILTOVER_ADDRESS="$PILTOVER_ADDRESS" \
USDC_ADDRESS="$USDC_ADDRESS" \
APPCHAIN_RPC_URL="$APPCHAIN_RPC_URL" \
APPCHAIN_EXPLORER="$APPCHAIN_EXPLORER" \
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

# 3. Deploy the economy + worlds (GAME_TOKEN, score, game, TokenSale, Entry, grants).
( cd "$DEMO_DIR" && bun run scripts/deploy.ts )

# 3b. Declare the Controller account class on the appchain.
#     Workaround for katana #584: `katana init rollup` round-trips genesis.json,
#     shifting the embedded controller class hash, so the canonical class the keychain
#     deploys isn't present after boot. Without it the Controller can't auto-deploy on
#     the appchain and its play actions fall back to the settlement chain. Declaring the
#     on-disk artifact here lands the canonical hash so the Controller can sign appchain
#     txs. Idempotent — a no-op once the class is already declared.
echo "→ declaring Controller account class on the appchain (katana #584 workaround)…"
#     The class artifacts live in the vendor/controller submodule (controller-rs);
#     init it on demand so a fresh clone works without --recurse-submodules.
[ -e "$DEMO_DIR/vendor/controller/account_sdk/artifacts/classes" ] \
  || ( cd "$DEMO_DIR" && git submodule update --init vendor/controller )
( cd "$DEMO_DIR" && bun run scripts/declare-controller-class.ts )

# 4. Torii indexers (bank world on Sepolia, game world on the appchain). RESET=1 wipes
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
echo "    appchain RPC   : $APPCHAIN_RPC_URL   explorer: $APPCHAIN_EXPLORER  (external — cartridge-appchain)"
echo "    torii (score)  : http://localhost:$TORII_SCORE_HTTP/sql   (.run/torii-score.log)"
echo "    torii (game)   : http://localhost:$TORII_GAME_HTTP/sql    (.run/torii-game.log)"
# Frontend is HTTPS by default (mkcert); set HTTP=1 to serve plain http.
APP_SCHEME=https; [[ "${HTTP:-}" == "1" ]] && APP_SCHEME=http
echo "    frontend       : $APP_SCHEME://localhost:$FRONTEND_PORT"
echo ""

# 5. Frontend (foreground; Ctrl-C stops everything via the trap above). Not exec'd, so
#    up.sh stays alive to run the cleanup trap when the frontend exits.
"$SERVICES/frontend.sh"
