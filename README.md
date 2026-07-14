# Cross-Chain Dungeon

An app that runs against an **external Katana appchain** (the `CARTRIDGE_MAINNET`
enclave rollup — a real **AMD SEV-SNP TEE** with **SP1 proofs** — deployed + operated by
[cartridge-appchain](https://github.com/cartridge-gg/cartridge-appchain)) and **settles
to real Starknet mainnet** (Sepolia also supported via `SETTLEMENT_NETWORK`), with a
token economy that **depends on an external settlement-layer contract (USDC)**. It's a push-your-luck dungeon roguelite with a
**two-token economy**: buy **GAME** with USDC and spend it to enter, descend with
**one appchain transaction per action**, collect **GOLD**, and either **extract**
(bank the run's gold into your on-L2 vault) or **die** (forfeit the in-progress
haul). Then **bank once** — withdraw the whole vault to the settlement layer, where
GOLD is minted on L1. The point: appchain value is provisional until you commit it to the settlement
layer.

This demo **does not run or bootstrap the appchain** — it consumes the appchain's RPC
and deploys its game world there, while deploying the economy + settlement world to a
**real public chain**. The appchain itself (its Katana node, piltover core, and
settlement) lives in cartridge-appchain.

> New to the appchain architecture? Read the [guide](./docs/README.md) — it builds
> the mental model (worlds, messaging, settlement, Torii) using this game as the example.

## Highlights

| | |
| --- | --- |
| Appchain | **external** — the `CARTRIDGE_MAINNET` enclave rollup, real SEV-SNP attestation + SP1 proving ([cartridge-appchain](https://github.com/cartridge-gg/cartridge-appchain)) |
| Settlement layer | **real Starknet mainnet** (Sepolia also supported) |
| Local nodes | **0** — the appchain is external; we run only the two toriis + the client |
| Economy | **two tokens**: GAME (USDC→play) + GOLD (winnings, minted on bank) |
| External dependency | **Circle USDC** on the settlement layer |
| Gameplay | a dungeon run, **one tx per action**; vault many runs, bank once |
| Ports | torii `8091`/`8092`, frontend `3002` (appchain RPC is external) |
| Controller | one identity signs **both chains** (hosted keychain; play is paymaster-sponsored on the appchain) |

## Live deployment

Deployed **2026-07-10** to Starknet **mainnet** with **real proving**: the appchain is
the `CARTRIDGE_MAINNET` **enclave** rollup — an AMD SEV-SNP confidential VM producing
**SP1 Groth16** proofs, verified on-chain by the real `AMDTeeRegistry` (see
[cartridge-appchain](https://github.com/cartridge-gg/cartridge-appchain)).

Two stacks run side by side (`DUNGEON_STACK` namespaces units + ports; see
`.env.example`): **mainnet** (the primary) and **sepolia**, which targets the sepolia
**TEE enclave** rollup (`CARTRIDGE_TESTNET`, real proving, settling to Starknet
Sepolia). The client serves both — mainnet by default, sepolia via
`?network=sepolia`.

| URL | What | Where it runs |
| --- | --- | --- |
| <https://dungeon-demo.cartridge.gg> | the game client (mainnet; `?network=sepolia` for the sepolia stack) | GitHub Pages ([`deploy-pages.yml`](.github/workflows/deploy-pages.yml)) |
| <https://dungeon-backend.cartridge.gg/torii/score> | bank-world torii (Starknet mainnet) | TEE host, systemd `dungeon-torii-bank` (`:8091`) |
| <https://dungeon-backend.cartridge.gg/torii/game> | game-world torii (mainnet appchain) | TEE host, systemd `dungeon-torii-game` (`:8092`) |
| <https://dungeon-backend.cartridge.gg/sepolia/torii/score> | bank-world torii (Starknet Sepolia) | TEE host, systemd `dungeon-torii-bank-sepolia` (`:8093`) |
| <https://dungeon-backend.cartridge.gg/sepolia/torii/game> | game-world torii (sepolia appchain) | TEE host, systemd `dungeon-torii-game-sepolia` (`:8094`) |
| <https://appchain.cartridge.gg/mainnet/rpc> | mainnet appchain RPC (external) | cartridge-appchain's mainnet enclave |
| <https://appchain.cartridge.gg/sepolia/rpc> | sepolia appchain RPC (external) | cartridge-appchain's sepolia enclave |

How it gets there: **Actions → Deploy fresh stack (TEE server)**
([`deploy.yml`](.github/workflows/deploy.yml)). The runner SSHes to the TEE host,
installs `.env` from the `DEPLOY_ENV` secret — which is what selects the deployment:
appchain RPC + piltover, settlement network/RPC, operator, USDC — and runs
[`scripts/remote/deploy.sh`](scripts/remote/deploy.sh) (teardown → contract deploys,
**real gas** → toriis under systemd → health check). It then commits the sanitized
manifest (`deployments/<network>.json`) + the regenerated client config
(`deployments.json`) and dispatches the Pages rebuild, so the live client always
tracks the latest deploy. The `PUBLIC_APPCHAIN_URL` repo variable must point at the
same appchain as `DEPLOY_ENV`.

A fresh deploy **replaces its own stack in place** and never touches the other. The
workflow inputs select the stack: the mainnet stack is the no-input default; the
sepolia stack runs with `stack=sepolia`, `deploy_dir=dungeon-deploy/dungeon-demo-sepolia`,
`env_secret=DEPLOY_ENV_SEPOLIA`, `public_backend_url=…/sepolia`,
`public_appchain_url=…/sepolia`. The primary stack's client config is
`deployments.json`; secondary stacks land in `deployments.<network>.json` and the
client picks by `?network=`.

What real proving changes (vs the sepolia mock):

- **Banking is slower by design** — a withdrawal mints GOLD only after its appchain
  block is proven (a real SP1 proof) and settled on mainnet: minutes, not seconds.
- **First action after an idle period can be slow** — the Controller keychain
  iframe re-hydrates after the browser freezes it, so the first move pays a
  cold-start (seconds); steady-state actions run ~1s.

Torii ops (status / logs / restart / re-index):
[docs/deployment.md](./docs/deployment.md#managing-the-running-stack-remote--systemd).

## Prerequisites

This is *not* fully one-click — settling to a real chain needs real accounts.

1. **An external appchain** — a shared rollup from
   [cartridge-appchain](https://github.com/cartridge-gg/cartridge-appchain). Point
   `APPCHAIN_RPC_URL` at it: the mainnet enclave proxy
   `https://appchain.cartridge.gg/mainnet/rpc` (the live deploy), or the sepolia mock
   `https://sepolia-appchain.cartridge.gg/rpc`. You also need a deploy-capable account on that appchain
   (`APPCHAIN_ACCOUNT_*`, the appchain's fee-less dev account from its genesis) and its
   piltover core address (`PILTOVER_ADDRESS`). This repo does **not** run Katana,
   deploy piltover, or operate settlement — that's all cartridge-appchain's job.
2. **Dojo toolchain** (`sozo`/`torii`/`scarb`) via `asdf install` (all pinned in
   `.tool-versions`). The cairo worlds pull **Dojo from the Scarb registry**
   (`dojo = "1.8.0"`), so no separate dojo checkout is needed.
3. **Bun**.
4. A funded Sepolia **operator** account and a **USDC** address — both in `.env` (see
   below).

## Run it

```bash
git submodule update --init vendor/controller   # Controller account classes (controller-rs); up.sh also does this on demand
cp .env.example .env     # fill in APPCHAIN_RPC_URL + APPCHAIN_ACCOUNT_* + PILTOVER_ADDRESS, SETTLEMENT_RPC_URL, operator, USDC
# The example points at the mainnet enclave rollup; for the sepolia mock, swap the appchain/piltover/USDC/settlement values
./up.sh                  # consumes the external appchain, deploys economy + worlds, runs torii ×2 + frontend :3002
```

`up.sh` checks the external appchain RPC is reachable, writes `deployments.json` from
your `.env`, deploys the economy + worlds (`scripts/deploy.ts` — the settlement
contracts + bank world on the settlement network, the game world on the external
appchain), declares the Controller class on the appchain, starts both Torii indexers,
and serves the client. `./down.sh` stops our toriis (the appchain is external — left running).

Then open `http://localhost:3002`, **Dev-mint** some GAME (or **Buy** it with
USDC), start a **New Game** (each dive is its own run — you can keep several open and
continue any of them from the lobby), play, **Extract** to bank gold into your vault,
then on the **Bank** tab withdraw the vault to the settlement layer to mint **GOLD**.
On the mainnet enclave, a withdrawal only banks after its appchain block is **proven
and settled** (a real SP1 proof), so expect minutes rather than seconds.

## Funding & costs

The economy/world deploys are **real settlement-network transactions** (real funds on
mainnet):

- The **operator** pays for the GAME/GOLD/sale/entry contracts and the bank-world
  migration on the settlement network.
- **Settlement gas is not this repo's concern.** piltover deploy and the recurring
  `update_state` settlement txns are paid by cartridge-appchain's own settlement
  account — the external appchain settles itself.
- The **player** path: `Dev-mint` needs only settlement-network gas (no USDC); `Buy`
  needs real **USDC**. The dev-mint faucet exists so the demo is playable without it.

## Using Controller (optional)

Nothing signs by default — **log in** (the lobby button) with a
[Cartridge Controller](https://github.com/cartridge-gg/controller), ONE identity that
signs on **both chains**: buy / enter / bank on the real settlement network *and* the
dungeon play actions on the external appchain, at the same address. Caveat by rollup:
both the mock and the current enclave images run the paymaster + Controller
middleware, so play actions are session-signed and fee-sponsored on the appchain.
`./up.sh` declares the Controller account class on the appchain and serves the
client over HTTPS via `mkcert`. Log in with the **hosted keychain** (x.cartridge.gg) by
default, or a self-hosted keychain as a fully-local fallback; fund the Controller with
a little STRK on the settlement network. Full walkthrough:
[docs/controller.md](./docs/controller.md).

## What's where

| Path | What |
| --- | --- |
| `cairo/game` | appchain dungeon world (`game` namespace) — run, actions, GOLD vault, leaderboard |
| `cairo/score` | settlement `bank` world (`bank` namespace) — mints GOLD when a withdrawal settles |
| `cairo/token` | `game_token` (GAME), `gold_token` (GOLD), `token_sale` (USDC→GAME), `entry` (charge + L1→L2) |
| `scripts/` | `deploy.ts` + `lib.ts` (deploy economy + migrate worlds), `declare-controller-class.ts` |
| `scripts/services/` | one launcher per long-lived service — `torii-bank.sh`, `torii-game.sh`, `frontend.sh` (the appchain is external, so no katana launcher). Run any on its own (e.g. `RESET=1 scripts/services/torii-bank.sh` to re-index the bank indexer); `up.sh` does the deploy then delegates to these |
| `app/` | React + Vite terminal client (`app/src/chain.ts`, `App.tsx`, `wallet.tsx`) |
| `design/ui-mockup.html` | the standalone terminal-UI design mockup |
| `up.sh` / `down.sh` | one-command bring-up / teardown |
| `docs/` | the architecture guide |
| `PLAN.md` | the full implementation spec |

## Deployed contracts

From the fresh **mainnet** deploy on **2026-07-10**. Settlement is real **Starknet
mainnet**; the appchain is the external `CARTRIDGE_MAINNET` **enclave** rollup — real
SEV-SNP attestation + SP1 proofs — (public RPC at
`https://appchain.cartridge.gg/mainnet/rpc`, owned by
[cartridge-appchain](https://github.com/cartridge-gg/cartridge-appchain)). The economy
contracts + worlds (tokens, sale, entry, bank world, game world) are **redeployed on
every fresh deploy** — the always-current source is `deployments.json` (repo root) and
the per-network manifests in `deployments/`. The piltover core + TEE registry belong
to the appchain (cartridge-appchain) and are stable; the appchain game world/system
are derived from fixed seeds, so they're stable across redeploys. The previous sepolia
(mock-proving) deploy is recorded in `deployments/sepolia.json`; its backend toriis
are retired.

### Settlement — Starknet Mainnet ([Voyager](https://voyager.online))

| Contract | Address |
| --- | --- |
| piltover (rollup settlement core — owned by cartridge-appchain) | [`0x506732b3a74da0fb514c158cb866d87fc355ea37014c5cb0003cbe01e991010`](https://voyager.online/contract/0x506732b3a74da0fb514c158cb866d87fc355ea37014c5cb0003cbe01e991010) |
| TEE fact registry (`AMDTeeRegistry`, real attestation — owned by cartridge-appchain) | [`0x04ec71aee9b92315ec2a7368eace15fd82fd816dd74ce9d0afcfc7077cf9fe2d`](https://voyager.online/contract/0x04ec71aee9b92315ec2a7368eace15fd82fd816dd74ce9d0afcfc7077cf9fe2d) |
| GAME token (entry credit) | [`0x13bbbb742226889c73a84675c17652aa1d3759f2e7a3d2b13fb04a5c95931f2`](https://voyager.online/contract/0x13bbbb742226889c73a84675c17652aa1d3759f2e7a3d2b13fb04a5c95931f2) |
| GOLD token (winnings) | [`0x75cf01878f93155d24dfdc6f1e8ed54716f3ab34532978a010e0dc9feac4edc`](https://voyager.online/contract/0x75cf01878f93155d24dfdc6f1e8ed54716f3ab34532978a010e0dc9feac4edc) |
| bank world | [`0x1ba9162a90e95800ce6dbcb3f156488625c0f1d2fb17e65c6d7a2351e1d88b4`](https://voyager.online/contract/0x1ba9162a90e95800ce6dbcb3f156488625c0f1d2fb17e65c6d7a2351e1d88b4) |
| bank system (consumes withdrawals → mints GOLD) | [`0x5e8cc427b7a68ad0ae327d043f94a74e97d239afabe5b5b61ad41890e13c241`](https://voyager.online/contract/0x5e8cc427b7a68ad0ae327d043f94a74e97d239afabe5b5b61ad41890e13c241) |
| Entry (charge GAME + L1→L2 enter) | [`0x2a2cb353e12dabe2e532ba46a8c197e8be95faf551dab98a217f63e172b45e0`](https://voyager.online/contract/0x2a2cb353e12dabe2e532ba46a8c197e8be95faf551dab98a217f63e172b45e0) |
| TokenSale (USDC→GAME — wired; contract-only, UI uses Dev-mint) | [`0x475e6da62dd3604472f53ecd2e276da68fbdf4062592082132ab9cc1a917737`](https://voyager.online/contract/0x475e6da62dd3604472f53ecd2e276da68fbdf4062592082132ab9cc1a917737) |
| USDC (external dependency — Circle, 6 decimals; TokenSale spends it) | [`0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8`](https://voyager.online/contract/0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8) |

### Appchain — external `CARTRIDGE_MAINNET` enclave rollup (public `https://appchain.cartridge.gg/mainnet/rpc`)

| Contract | Address |
| --- | --- |
| game world | `0x7f6c1c800301783a1a5a9378a6c3cdf237ad9ae21bb715c0bf5e408a450ab6e` |
| game system (move / attack / loot / use / extract / withdraw) | `0x6d3d2eab82c4b17ee17eeae58f9981db04a8e9beeaa887b355ce7e57f085e97` |

### Cartridge Controller account classes (declared on the appchain)

All bundled versions are declared so a Controller auto-deploys at the version it was created
with (see `scripts/declare-controller-class.ts`).

| Version | Class hash |
| --- | --- |
| v1.0.9 (latest) | `0x743c83c41ce99ad470aa308823f417b2141e02e04571f5c0004e743556e7faf` |
| v1.0.8 | `0x511dd75da368f5311134dee2356356ac4da1538d2ad18aa66d57c47e3757d59` |
| v1.0.7 | `0x3e0a04bab386eaa51a41abe93d8035dccc96bd9d216d44201266fe0b8ea1115` |
| v1.0.6 | `0x59e4405accdf565112fe5bf9058b51ab0b0e63665d280b816f9fe4119554b77` |
| v1.0.5 | `0x32e17891b6cc89e0c3595a3df7cee760b5993744dc8dfef2bd4d443e65c0f40` |
| v1.0.4 | `0x24a9edbfa7082accfceabf6a92d7160086f346d622f28741bf1c651c412c9ab` |

### Accounts

| Role | Address |
| --- | --- |
| Operator (settlement-side deploys + dev signer — also cartridge-appchain's mainnet saya) | [`0x00ddeE62091d2F9De6FF534a951a6202372Bfe1f3803ae5c1a73010F6AF4248f`](https://voyager.online/contract/0x00ddeE62091d2F9De6FF534a951a6202372Bfe1f3803ae5c1a73010F6AF4248f) |
| Appchain dev account (default play signer — from the appchain's genesis) | `0xdcbeb1f415c0c3e8ae300f3550ff9d649c03c2aeea5ec15f9862139ac3857b` |
