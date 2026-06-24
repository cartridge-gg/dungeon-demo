#!/usr/bin/env bash
# Appchain Katana node (the local DUNGEON rollup, settling to piltover on Sepolia).
# Controller-capable (paymaster + session middleware) — always on.
# State persists in .run/appchain-db (only the FRESH bootstrap in up.sh wipes it).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

[[ -f "$CHAIN_DIR/config.toml" ]] || svc_fail "no rollup config at $CHAIN_DIR — run ./up.sh first to bootstrap (piltover + genesis)."

free_port "$APPCHAIN_PORT"
mkdir -p "$RUN_DIR/logs"   # katana's --log.file.directory (rotated daily)

# The block explorer is a build-time feature: the asdf/source build (what .tool-versions
# targets) includes it, but the official release tarballs are compiled without it.
# Include --explorer only when this katana actually supports it, so the node still boots
# on an explorer-less release build (a backend node doesn't need the explorer UI).
EXPLORER_FLAG=""
"$KATANA" --help 2>/dev/null | grep -q -- '--explorer' && EXPLORER_FLAG="--explorer"

echo "→ appchain node on :$APPCHAIN_PORT (Controller-capable)"
# --log.file is additive to stdout (separate --log.stdout.format), so systemd/journald
# still capture stdout; the file logs in .run/logs are a rotated sidecar for deep dives.
exec "$KATANA" --chain "$CHAIN_DIR" --tee mock --dev --dev.no-fee --block-time 5000 \
  --data-dir "$APPCHAIN_DB" --http.port "$APPCHAIN_PORT" --http.cors_origins '*' \
  --messaging.enabled $EXPLORER_FLAG \
  --log.file --log.file.directory "$RUN_DIR/logs" --log.file.max-files 7 \
  $CONTROLLER_FLAGS
