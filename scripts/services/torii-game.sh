#!/usr/bin/env bash
# Torii indexer for the game world on the (external) appchain. --indexing.preconfirmed
# indexes the pre-confirmed (pending) block so a play action's model writes appear
# immediately instead of waiting for the 5s block tick. RESET=1 wipes the db to
# re-index (up.sh passes it; standalone resumes by default).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

GAME_WORLD="$(read_deployment appchain.gameWorld)" || svc_fail "no appchain.gameWorld in deployments.json — run ./up.sh (deploy step) first."
# The appchain is external (owned by cartridge-appchain); take its RPC from deployments.json
# (appchain.rpcUrl), not a hard-coded localhost port.
APPCHAIN_RPC="$(read_deployment appchain.rpcUrl)" || svc_fail "no appchain.rpcUrl in deployments.json — set APPCHAIN_RPC_URL in .env and run ./up.sh."

free_port "$TORII_GAME_HTTP"; free_port "$TORII_GAME_GRPC"
for p in "$TORII_GAME_RELAY" $((TORII_GAME_RELAY+1)) $((TORII_GAME_RELAY+2)); do free_port "$p"; done
[[ "${RESET:-}" == "1" ]] && rm -rf "$RUN_DIR/torii-game.db"
echo "→ torii (game world $GAME_WORLD on appchain $APPCHAIN_RPC) on :$TORII_GAME_HTTP"
exec torii --rpc "$APPCHAIN_RPC" --world "$GAME_WORLD" \
  --http.port "$TORII_GAME_HTTP" --grpc.port "$TORII_GAME_GRPC" \
  --relay.port "$TORII_GAME_RELAY" --relay.webrtc_port $((TORII_GAME_RELAY+1)) --relay.websocket_port $((TORII_GAME_RELAY+2)) \
  --http.cors_origins '*' --indexing.preconfirmed \
  --db-dir "$RUN_DIR/torii-game.db"
