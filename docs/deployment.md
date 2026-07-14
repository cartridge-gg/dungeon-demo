# Build, deploy, and run the stack

[← contracts](./contracts.md) · Next: [client →](./client.md)

From source to a running system. The toolchain is `scarb 2.13.1` / `sozo 1.8.7` /
`torii 1.8.16`, with Dojo pulled from the Scarb registry (`dojo = "1.8.0"`, standard `sozo
migrate` mechanics). What's new here: **plain-contract deploys alongside the Dojo migrations**,
**minter grants**, and deploying against an **external appchain + real Sepolia** that
need funded accounts. (The appchain itself — its Katana node, piltover, and settlement
— is deployed and operated separately by
[cartridge-appchain](https://github.com/cartridge-gg/cartridge-appchain).)

## Configuration (`.env`)

Because the appchain is external and settlement is a real chain, the appchain
endpoint, the network choice, accounts, and external USDC address all come from the
environment (`.env.example` → `.env`):

```
APPCHAIN_RPC_URL=…                          # external appchain RPC (public proxy, or http://localhost:5070 for a local cartridge-appchain)
APPCHAIN_ACCOUNT_ADDRESS=…                  # a deploy-capable account on the appchain (its fee-less dev account)
APPCHAIN_ACCOUNT_PRIVATE_KEY=…
PILTOVER_ADDRESS=…                          # the appchain's piltover core (from cartridge-appchain)
SETTLEMENT_NETWORK=sepolia                  # sepolia (default) or mainnet
SETTLEMENT_RPC_URL=…                        # RPC for that network (SEPOLIA_RPC_URL still works)
OPERATOR_ADDRESS=…  OPERATOR_PRIVATE_KEY=…   # deploys contracts + migrates the bank world on Sepolia
USDC_ADDRESS=…                              # real Circle USDC for the chosen network (verify it)
GAME_RATE=… ENTRY_FEE=… REWARD_PER_GOLD=…    # economy (base units)
```

`APPCHAIN_*`/`PILTOVER_ADDRESS` describe the external appchain you deploy against — the
demo never bootstraps it. `SETTLEMENT_NETWORK` selects the chain id (`SN_SEPOLIA` /
`SN_MAIN`), the explorer, and the display name; `up.sh` records all of these (plus the
appchain endpoint) into `deployments.json` so the app is network-agnostic. The RPC and
USDC must match the chosen network — **mainnet means real funds**. `scripts/config.ts`
loads the economy values as base units (GAME/GOLD have 18 decimals, USDC 6) so the rate
carries the decimal conversion.

## Two kinds of deploy

`scripts/deploy.ts` does both, in dependency order, recording everything into
`deployments.json` (repo root):

- **Dojo worlds** via `sozo migrate` (`migrateWorld` in `scripts/lib.ts`) — the
  `score` world on Sepolia, the `game` world on the appchain.
- **Plain Starknet contracts** via starknet.js `declareAndDeploy` (`game_token`,
  `token_sale`, `entry`) — these aren't worlds, so they're declared + deployed
  directly, then configured with `invoke` (the minter grants).

```ts
const gameToken = await declareAndDeploy(operator, "token", "game_token", { owner }); // GAME
const goldToken = await declareAndDeploy(operator, "token", "gold_token", { owner }); // GOLD
const bank  = migrateWorld({ pkg: "score", namespace: "bank", … initArgs: [piltover, goldToken, ...u256(rewardPerGold)] });
const game  = migrateWorld({ pkg: "game",  … initArgs: [bank.system] });
const tokenSale = await declareAndDeploy(operator, "token", "token_sale", { usdc, game_token: gameToken, treasury, rate });
const entry     = await declareAndDeploy(operator, "token", "entry", { game_token: gameToken, entry_fee, piltover, appchain_game: game.system });
await invoke(operator, gameToken, "set_minter", [tokenSale, "0x1"]);   // sale mints GAME
await invoke(operator, goldToken, "set_minter", [bank.system, "0x1"]); // bank mints GOLD
```

(`scripts/deploy.ts`.) The order matters: the token before the world+sale that
reference it; the score world before the game world (which needs its address); the
game world before `entry` (which addresses it); the grants last.

## The full bring-up sequence

`up.sh` orchestrates it. The appchain is external; the settlement steps run against
**real Sepolia**:

1. **Preflight** — `asdf install`, verify sozo·torii·scarb, and that `.env` is filled.
2. **External appchain check** — wait until `APPCHAIN_RPC_URL` is reachable (for a
   local stack, start cartridge-appchain's Katana node first), and fail with a hint if
   it isn't.
3. **Base `deployments.json`** — written from `.env`: settlement network/rpc/accounts,
   `PILTOVER_ADDRESS`, USDC, and the external appchain rpc/account.
4. **Deploy economy + worlds** (`scripts/deploy.ts`) — settlement contracts + bank
   world on Sepolia, the `game` world on the external appchain.
5. **Declare the Controller account class** on the appchain
   (`scripts/declare-controller-class.ts`).
6. **Two Torii instances** — Sepolia `score` (`:8091`), appchain `game` (`:8092`).
7. **Client** (Vite, `:3002`).

```bash
cp .env.example .env && ./up.sh     # Ctrl-C / ./down.sh tears down our toriis (appchain stays up — it's external)
```

## Costs & gotchas (real chain)

- Every settlement-side deploy costs real Sepolia STRK. Fund the operator generously.
  (Settlement gas — piltover's `update_state` — is paid by the external appchain's own
  account in cartridge-appchain, not by anything here.)
- The Poseidon L1→L2 message hash is handled by the appchain's Katana, not this repo —
  no saya-tee / message-hash patch (see
  [contracts.md](./contracts.md#the-message-hash-gotcha)).
- **Blake2s compiled-class hash (Starknet ≥ 0.14.1).** Sepolia/mainnet compute the
  `compiled_class_hash` with **Blake2s**, not Poseidon, and reject a declare that
  sends the old hash with `Mismatch compiled class hash`. So the deploy scripts pin
  **starknet.js 10.x** (whose `computeCompiledClassHash` is Blake2s); 8.x's Poseidon
  hash is rejected. `sozo 1.8.7` already emits Blake2s, so the worlds are fine. A local
  Katana settlement layer accepts either hash, so this only bites against a real
  Starknet settlement chain (Sepolia/mainnet). The cairo **compiler** version is
  unrelated — scarb stays 2.13.1.

## Verify each stage

```bash
node -e 'console.log(require("./deployments.json"))'   # all addresses filled?
# score world indexed on Sepolia?
curl "http://localhost:8091/sql?query=SELECT%20*%20FROM%20%22score-Leaderboard%22"
# settled vs tip (the UI gauge): piltover get_state vs appchain block height
```

The real test is a full round trip: dev-mint → enter → a few actions → extract →
wait for settlement → bank. The [client chapter](./client.md) shows the calls.

## Managing the running stack (remote / systemd)

On a server our long-lived services are just the **two toriis per stack** under
systemd (`dungeon-torii-bank`, `dungeon-torii-game`; a non-primary stack suffixes its
name — e.g. `dungeon-torii-bank-sepolia` — and uses its own port block, see
`DUNGEON_STACK` in `.env.example`), supervised by `scripts/remote/units.sh`
(`Restart=always`, enabled on boot). Every `units.sh` verb is scoped to the stack of
the checkout it runs from (its `.env`), so operating one stack never touches the
other. The appchain is external
(cartridge-appchain) — it's supervised over there, not here. Day-to-day ops go through
that script — it's the single source of truth:

```bash
# on the server:
bash scripts/remote/units.sh status [svc]          # systemctl status (both toriis if no svc)
bash scripts/remote/units.sh logs [svc] [-f]       # journalctl, one service or all
bash scripts/remote/units.sh restart torii-game    # bounce one torii
bash scripts/remote/units.sh reset torii-game      # wipe its db + re-index from the world block
```

`reset` re-indexes a **torii** (drift behind on a flaky RPC → re-index, no gas). To
operate or reset the appchain itself, use cartridge-appchain's tooling. A `FRESH=1 bash
scripts/remote/deploy.sh` re-runs the economy/world deploy and wipes the torii dbs.

If the toriis sit behind a reverse proxy (the live deploy routes
`dungeon-backend.cartridge.gg/torii/*` through nginx), the proxy MUST disable
response buffering for those locations (`proxy_buffering off;` + a long
`proxy_read_timeout`): the client's live updates are gRPC-web **subscription
streams**, and a buffering proxy holds the events back — every action then appears
to take ~5s (the client's fallback poll) instead of being instant.

Drive all of this from your laptop without SSHing in by hand with
`scripts/remote/dungeonctl` (pure SSH transport to the same `units.sh` verbs):

```bash
export DUNGEON_HOST=user@server                    # DUNGEON_DIR defaults to ~/dungeon-deploy/dungeon-demo
# For the sepolia stack: export DUNGEON_DIR='$HOME/dungeon-deploy/dungeon-demo-sepolia'
scripts/remote/dungeonctl logs -f                  # follow all services from here
scripts/remote/dungeonctl reset torii-bank
scripts/remote/dungeonctl restart torii-game
```

Next: [how the client queries and drives all this →](./client.md)
