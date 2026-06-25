# The services: why, where, how

[← architecture](./architecture.md) · Next: [contracts →](./contracts.md)

The processes that make up the running system. The defining trait: **both chains are
external** — there's no local Katana at all. The appchain is operated by
[cartridge-appchain](https://github.com/cartridge-gg/cartridge-appchain) (it runs the
Katana node, owns piltover, and settles itself); we point piltover/Torii at it and at
real Sepolia. This repo runs only the two toriis and the client.

```
   Starknet Sepolia (remote)                     External appchain (cartridge-appchain)
  ┌─────────────────────────────────┐           ┌──────────────────────────────┐
  │ piltover core   score world      │   L1→L2   │  game world (dungeon)        │
  │ GAME_TOKEN  TokenSale  Entry      │ ◄───────► │  Katana rollup + settlement  │
  │       ▲            ▲              │   L2→L1   └───────┬──────────────────────┘
  └───────│────────────│─────────────┘ (settled)         │ update_state (cartridge-appchain)
          │ index      │ index          ◄────────────────┘ (--tee mock)
       Torii(:8091)  Torii(:8092)◄── client ──┐
          (Sepolia)    (appchain)             └── reads/writes
```

## Katana — the appchain (external; we run none)

There is **no local Katana** in this repo. The appchain is the `CARTRIDGE_TESTNET`
rollup deployed and operated by cartridge-appchain — it runs the Katana node, deploys
piltover on Sepolia, and runs the embedded settlement service. We only consume its
RPC (`APPCHAIN_RPC_URL` from `.env`: the public proxy, or `http://localhost:5070` when
you run cartridge-appchain's node locally).

For reference, cartridge-appchain runs Katana roughly like this (see that repo for the
authoritative flags):

```bash
katana --tee mock --dev --dev.no-fee --block-time 5000 \
       --http.port 5070 --explorer --messaging.enabled ...
```

- `--tee mock` — TEE-settled rollup with mock attestation.
- `--messaging.enabled` — watch **Sepolia** and relay L1→L2 messages as `L1HandlerTx`.
  Without this, entries never reach the appchain.
- `--dev --dev.no-fee` — fees off (so play actions are free) on chain id
  `CARTRIDGE_TESTNET`.
- `--block-time 5000` — mine on a steady 5s interval. This changes the timing model
  enough that the client and our game Torii must read/write the **pre-confirmed**
  block. See [interval-mining.md](./interval-mining.md).

The ports we own are `8091`/`8092` (the toriis) and `3002` (the client); the appchain
RPC (`:5070` locally) belongs to cartridge-appchain.

## piltover core — the cross-chain mailbox, on Sepolia

Deployed by cartridge-appchain (via `katana init rollup --tee`) **on Sepolia**, and
supplied to us as `PILTOVER_ADDRESS` in `.env`. Same interface either way —
`send_message_to_appchain` (L1→L2), `consume_message_from_appchain` (L2→L1, succeeds
only after settlement), `get_state` (settled height for the UI gauge). We wire the
bank world + the `entry` contract to it, but we don't deploy or own it.

## Settlement — the external appchain settles itself

Settlement is **embedded in the appchain's Katana** and operated entirely by
cartridge-appchain — there's no prover sidecar here and nothing for this repo to
configure. cartridge-appchain's node (run with `--tee mock`) proves each block and
submits `update_state` to the piltover core **on Sepolia** itself.

What that means for *us*, the consumer:

- **We pay no settlement gas.** The appchain's own settlement account funds every
  `update_state`; that account lives in cartridge-appchain, not in our `.env`.
- **The Poseidon L1→L2 message hash is handled by Katana.** A Starknet-settled
  appchain hashes L1→L2 messages with Poseidon (not keccak); Katana computes that
  itself, so entries settle without a message-hash patch (no old `saya-tee` sidecar).
- **The mock TEE registry** (the on-L1 attestation verifier) and the
  `[settlement.runtime]` config also live in cartridge-appchain — see that repo to
  operate or reset the appchain's settlement.

## Torii — the indexers (one per chain)

Two instances; the settlement one indexes a **Sepolia** world, the game one indexes
the **external appchain** (`appchain.rpcUrl` from `deployments.json`):

```bash
torii --rpc "$SEPOLIA_RPC_URL" --world "$SCORE_WORLD" --http.port 8091 ...                       # Sepolia
torii --rpc "$APPCHAIN_RPC" --world "$GAME_WORLD" --http.port 8092 --indexing.preconfirmed       # appchain (external)
```

Torii resolves the world's deploy block from the contract, so the Sepolia indexer
doesn't rescan the whole chain. Token balances aren't world state, so the client
reads them straight from Sepolia RPC (`balanceOf`), not Torii.

The appchain Torii adds **`--indexing.preconfirmed`** so it indexes the pre-confirmed
block — with 5s `--block-time`, the dungeon view would otherwise lag a full interval
behind each action. The Sepolia bank Torii doesn't need it (real L1 blocks pace it).
See [interval-mining.md](./interval-mining.md).

## Who triggers whom

| Step | Actor | Touches |
| --- | --- | --- |
| Buy GAME | client → `token_sale` (Sepolia) | `USDC.transfer_from` + mint GAME |
| Enter | client → `entry` → piltover (Sepolia) | charge GAME, emit `MessageSent` |
| Relay | appchain Katana (`--messaging.enabled`) | runs `mint_run` |
| Play | client → `game` system (appchain) | one tx per action; `extract` → `send_message_to_l1` |
| Settle | external appchain's settlement → piltover (Sepolia) | registers L2→L1 message hashes |
| Bank | client → `score` (Sepolia) | `consume_message_from_appchain` + mint reward |
| Read | client → Torii ×2 + RPC | run state, feeds, balances, settled height |

Next: [how the contracts implement all this →](./contracts.md)
