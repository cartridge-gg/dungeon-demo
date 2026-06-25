# Cross-Chain Dungeon

A Katana appchain example that **settles to a real Starknet network** (Sepolia by
default, **mainnet supported** via `SETTLEMENT_NETWORK`) and **depends
on an external settlement-layer contract (USDC)**. It's a push-your-luck dungeon
roguelite with a **two-token economy**: buy **GAME** with USDC and spend it to enter,
descend with **one appchain transaction per action**, collect **GOLD**, and either
**extract** (bank the run's gold into your on-L2 vault) or **die** (forfeit the
in-progress haul). Then **bank once** — withdraw the whole vault to Sepolia, where
GOLD is minted on L1. The point: appchain value is provisional until you commit it
to the settlement layer.

It runs **one** local Katana (the appchain) and settles to a **real public chain**,
with a token economy layered on top of an external contract (USDC).

> New to the appchain architecture? Read the [guide](./docs/README.md) — it builds
> the mental model (worlds, messaging, settlement, Torii) using this game as the example.

## Highlights

| | |
| --- | --- |
| Settlement layer | **real Starknet** (Sepolia default, mainnet supported) |
| Local nodes | **1** — the appchain only |
| Economy | **two tokens**: GAME (USDC→play) + GOLD (winnings, minted on bank) |
| External dependency | **Circle USDC** on the settlement layer |
| Gameplay | a dungeon run, **one tx per action**; vault many runs, bank once |
| Ports | appchain `5070`, torii `8091`/`8092`, frontend `3002` |
| Controller | one identity signs **both chains** (hosted keychain; funded on real Sepolia) |

## Prerequisites

This is *not* fully one-click — settling to a real chain needs real accounts.

1. **katana ≥ 1.8.0-rc.4** — the appchain node settles to piltover itself via its
   embedded settlement service (no saya-tee sidecar). Pinned in `.tool-versions` and
   installed by `asdf install`, so normally it just lands on PATH; set `KATANA` in
   `.env` only to override with a local build.
2. **Mock TEE registry** — already deployed on Sepolia and reused (no `saya-ops`
   needed); override with `TEE_REGISTRY_ADDRESS` in `.env` for another network. The
   `saya-tee` sidecar and its Poseidon message-hash patch are no longer needed either
   (katana computes the Poseidon hash itself).
3. **Dojo toolchain** (`katana`/`sozo`/`torii`/`scarb`) via `asdf install` (all pinned
   in `.tool-versions`). The cairo worlds pull **Dojo from the Scarb registry**
   (`dojo = "1.8.0"`), so no separate dojo checkout is needed.
4. **Bun**.
5. A funded Sepolia **operator** account and a separate funded **settlement** account,
   and a **USDC** address — all in `.env` (see below).

## Run it

```bash
git submodule update --init vendor/controller   # Controller account classes (controller-rs); up.sh also does this on demand
cp .env.example .env     # fill in KATANA, SEPOLIA_RPC_URL, operator + settlement accounts, USDC
./up.sh                  # appchain :5070 (settles → Sepolia), torii ×2, frontend :3002
```

`up.sh` deploys the piltover core on Sepolia (reusing the already-deployed mock TEE
registry), starts the appchain (whose embedded settlement service settles to piltover itself), deploys the
economy + worlds (`scripts/deploy.ts`), starts both Torii indexers, and serves the
client. `./down.sh` stops the local processes.

Then open `http://localhost:3002`, **Dev-mint** some GAME (or **Buy** it with
USDC), start a **New Game** (each dive is its own run — you can keep several open and
continue any of them from the lobby), play, **Extract** to bank gold into your vault,
then on the **Bank** tab withdraw the vault to Sepolia to mint **GOLD**.

## Funding & costs

Every deploy and every `update_state` is a **real Sepolia transaction**:

- The **operator** pays for piltover, the GAME/GOLD/sale/entry contracts, and the
  bank-world migration (the mock TEE registry is reused, not redeployed).
- The **settlement account** pays for `update_state` on every settled batch
  (recurring) — the appchain's embedded settlement service submits these. Give it a
  **dedicated** funded account, never shared with the operator (nonce contention
  stalls settlement).
- The **player** path: `Dev-mint` needs only Sepolia gas (no USDC); `Buy` needs
  real test **USDC**. The dev-mint faucet exists so the demo is playable without it.

## Using Controller (optional)

Nothing signs by default — **log in** (the lobby button) with a
[Cartridge Controller](https://github.com/cartridge-gg/controller), ONE identity that
signs on **both chains**: buy / enter / bank on real Sepolia *and* the dungeon
play actions on the local appchain, at the same address. The appchain is
Controller-capable out of the box (`./up.sh` always enables it, plus HTTPS via
`mkcert`); just log in with a Cartridge Controller — the **hosted keychain**
(x.cartridge.gg) by default, with a self-hosted keychain as a fully-local fallback. Fund the Controller with a little STRK on real Sepolia. Full
walkthrough: [docs/controller.md](./docs/controller.md).

## What's where

| Path | What |
| --- | --- |
| `cairo/game` | appchain dungeon world (`game` namespace) — run, actions, GOLD vault, leaderboard |
| `cairo/score` | settlement `bank` world (`bank` namespace) — mints GOLD when a withdrawal settles |
| `cairo/token` | `game_token` (GAME), `gold_token` (GOLD), `token_sale` (USDC→GAME), `entry` (charge + L1→L2) |
| `scripts/` | `deploy.ts` + `lib.ts` (deploy economy + migrate worlds), `declare-controller-class.ts` |
| `scripts/services/` | one launcher per long-lived service — `appchain.sh` (runs katana incl. the embedded settlement service), `torii-bank.sh`, `torii-game.sh`, `frontend.sh`. Run any on its own (e.g. `RESET=1 scripts/services/torii-bank.sh` to re-index the bank indexer); `up.sh` does the bootstrap/deploy then delegates to these |
| `app/` | React + Vite terminal client (`app/src/chain.ts`, `App.tsx`, `wallet.tsx`) |
| `design/ui-mockup.html` | the standalone terminal-UI design mockup |
| `up.sh` / `down.sh` | one-command bring-up / teardown |
| `docs/` | the architecture guide |
| `PLAN.md` | the full implementation spec |

## Deployed contracts

From a fresh deploy (`FRESH=1`) on **2026-06-24**. Settlement is real
**Starknet Sepolia**; the appchain is the `CARTRIDGE_TESTNET` rollup (public RPC at
`https://sepolia-appchain.cartridge.gg/rpc`). The Sepolia contracts
(piltover, tokens, worlds) are **redeployed on every `FRESH=1`** — the always-current source
is `deployments.json` (repo root). The appchain world/system and the TEE-registry mock are
derived from fixed seeds/salts, so they're stable across redeploys.

### Settlement — Starknet Sepolia ([Voyager](https://sepolia.voyager.online))

| Contract | Address |
| --- | --- |
| piltover (rollup settlement core) | [`0x4dc5dea5c8b22a298d6a1f91a0dd3687c2cdf13149f773812ace1f3ac6baf30`](https://sepolia.voyager.online/contract/0x4dc5dea5c8b22a298d6a1f91a0dd3687c2cdf13149f773812ace1f3ac6baf30) |
| TEE registry (mock attestation) | [`0x37189b1807f1358074b70b3dc8ab79167bbf72cff1296286052f6dfe31c8f15`](https://sepolia.voyager.online/contract/0x37189b1807f1358074b70b3dc8ab79167bbf72cff1296286052f6dfe31c8f15) |
| GAME token (entry credit) | [`0x48ea38627cda858ab37277b1b236ff00ead235f60a6ea42ec4d00fe2fc14fd8`](https://sepolia.voyager.online/contract/0x48ea38627cda858ab37277b1b236ff00ead235f60a6ea42ec4d00fe2fc14fd8) |
| GOLD token (winnings) | [`0x13d51f19cc118ffb8a68f59b7e31900e7909d6d11ee197b28b5baf63d077077`](https://sepolia.voyager.online/contract/0x13d51f19cc118ffb8a68f59b7e31900e7909d6d11ee197b28b5baf63d077077) |
| bank world | [`0xf4518e2a91b78caf361ab1dbf5c9276c1400644304aa32a2b4e4179a77867c`](https://sepolia.voyager.online/contract/0xf4518e2a91b78caf361ab1dbf5c9276c1400644304aa32a2b4e4179a77867c) |
| bank system (consumes withdrawals → mints GOLD) | [`0x393fb235f4ec2396dd79268ce24adc52d94c47d13bae67e7f8cf3ed89819c20`](https://sepolia.voyager.online/contract/0x393fb235f4ec2396dd79268ce24adc52d94c47d13bae67e7f8cf3ed89819c20) |
| Entry (charge GAME + L1→L2 enter) | [`0x72344a18e676f782448b4dcde87635de94bf8864532745954ab07802ded9dd3`](https://sepolia.voyager.online/contract/0x72344a18e676f782448b4dcde87635de94bf8864532745954ab07802ded9dd3) |
| TokenSale (USDC→GAME — wired; contract-only, UI uses Dev-mint) | [`0x21675ca6794932e5e2faec5fc814bd37f7890ddb6a24e5186d43547f749548f`](https://sepolia.voyager.online/contract/0x21675ca6794932e5e2faec5fc814bd37f7890ddb6a24e5186d43547f749548f) |
| USDC (external dependency — Circle, 6 decimals; TokenSale spends it) | [`0x0512feAc6339Ff7889822cb5aA2a86C848e9D392bB0E3E237C008674feeD8343`](https://sepolia.voyager.online/contract/0x0512feAc6339Ff7889822cb5aA2a86C848e9D392bB0E3E237C008674feeD8343) |

### Appchain — `CARTRIDGE_TESTNET` rollup (`http://localhost:5070` · public `https://sepolia-appchain.cartridge.gg/rpc`)

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
| Operator (settlement deploys + dev signer) | [`0x00ddeE62091d2F9De6FF534a951a6202372Bfe1f3803ae5c1a73010F6AF4248f`](https://sepolia.voyager.online/contract/0x00ddeE62091d2F9De6FF534a951a6202372Bfe1f3803ae5c1a73010F6AF4248f) |
| Settlement account (piltover operator — the embedded service's `update_state` signer) | [`0x0639956bAB912477F04fa7b9189d014E785092E795b3B57E9481f89642cde52B`](https://sepolia.voyager.online/contract/0x0639956bAB912477F04fa7b9189d014E785092E795b3B57E9481f89642cde52B) |
| Appchain dev account (default play signer) | `0xdcbeb1f415c0c3e8ae300f3550ff9d649c03c2aeea5ec15f9862139ac3857b` |
