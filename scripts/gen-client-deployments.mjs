// Derive the browser client's deployments.json from a deploy manifest.
//
// The deploy writes two things: the per-run manifest (deployments/<network>.json —
// sanitized, but with the server's *localhost* service URLs) and, via this script,
// the committed client config (deployments.json at the repo root) that the Vite app
// bundles. The only difference is the service endpoints: the browser can't reach the
// server's loopback-bound katana/torii, so it goes through the public reverse proxy.
//
// Settlement RPC + explorer are already public (taken straight from the manifest);
// the appchain RPC/explorer/torii and the settlement torii are rewritten to the
// PUBLIC backend (nginx vhost paths: /rpc, /rpc/explorer, /torii/game, /torii/score).
//
// Usage: node scripts/gen-client-deployments.mjs <manifest.json> <backendUrl> <out.json>
import { readFileSync, writeFileSync } from "node:fs";

const [manifestPath, backendUrl, outPath] = process.argv.slice(2);
if (!manifestPath || !backendUrl || !outPath) {
  console.error("usage: gen-client-deployments.mjs <manifest.json> <backendUrl> <out.json>");
  process.exit(2);
}

const backend = backendUrl.replace(/\/+$/, ""); // no trailing slash
const m = JSON.parse(readFileSync(manifestPath, "utf-8"));
const s = m.settlement, a = m.appchain;

// Client config shape (app/src/chain.ts) — addresses from the manifest, service
// endpoints pointed at the public backend. No account keys (the manifest has none).
const client = {
  settlement: {
    network: s.network,
    chainId: s.chainId,
    rpcUrl: s.rpcUrl, // already public (e.g. api.cartridge.gg sepolia)
    explorer: s.explorer,
    torii: `${backend}/torii/score`,
    piltover: s.piltover,
    usdc: s.usdc,
    gameToken: s.gameToken,
    goldToken: s.goldToken,
    bankWorld: s.bankWorld,
    bankSystem: s.bankSystem,
    tokenSale: s.tokenSale,
    entry: s.entry,
  },
  appchain: {
    rpcUrl: `${backend}/rpc`,
    explorer: `${backend}/rpc/explorer`,
    torii: `${backend}/torii/game`,
    gameWorld: a.gameWorld,
    gameSystem: a.gameSystem,
  },
};

writeFileSync(outPath, JSON.stringify(client, null, 2) + "\n");
console.error(`wrote ${outPath} (network=${s.network}, backend=${backend})`);
