# The services: why, where, how

[← architecture](./architecture.md) · Next: [contracts →](./contracts.md)

The processes that make up the running system. The defining trait: **the settlement
layer is remote** — there's no second local Katana; piltover/Torii point at real
Sepolia, and the appchain settles to it through its own embedded service.

```
   Starknet Sepolia (remote)                     Local appchain (Katana rollup, :5070)
  ┌─────────────────────────────────┐           ┌──────────────────────────────┐
  │ piltover core   score world      │   L1→L2   │  game world (dungeon)        │
  │ GAME_TOKEN  TokenSale  Entry      │ ◄───────► │  + embedded settlement       │
  │       ▲            ▲              │   L2→L1   └───────┬──────────────────────┘
  └───────│────────────│─────────────┘ (settled)         │ update_state
          │ index      │ index          ◄────────────────┘ (--tee mock)
       Torii(:8091)  Torii(:8092)◄── client ──┐
          (Sepolia)    (appchain)             └── reads/writes
```

## Katana — the sequencer (you run one)

Only the **appchain** is a local Katana here; the settlement role is filled by real
Sepolia. The appchain is created by `katana init rollup` (which deploys piltover on
Sepolia and writes the chain config) and runs as a rollup:

```bash
katana --chain "$CHAIN_DIR" --tee mock --dev --dev.no-fee --block-time 5000 \
       --data-dir .run/appchain-db --http.port 5070 --explorer --messaging.enabled
```

- `--tee mock` — TEE-settled rollup with mock attestation locally.
- `--messaging.enabled` — watch **Sepolia** and relay L1→L2 messages as
  `L1HandlerTx`. Without this, entries never reach the appchain.
- `--dev --dev.no-fee` — fees off (so play actions are free) on chain id `DUNGEON`.
- `--block-time 5000` + `--data-dir` — mine on a steady 5s interval and persist
  state to disk. Both are deliberate; they change the timing model enough that the
  client and Torii must read/write the **pre-confirmed** block. See
  [interval-mining.md](./interval-mining.md).

The service ports are `5070` (appchain), `8091`/`8092` (the toriis), and `3002`
(the client).

## piltover core — the cross-chain mailbox, on Sepolia

Deployed by `katana init rollup --tee` **on Sepolia** (a real, gas-costing
deploy). Same interface as before — `send_message_to_appchain` (L1→L2),
`consume_message_from_appchain` (L2→L1, succeeds only after settlement),
`get_state` (settled height for the UI gauge). The difference is purely that it
lives on a public chain, so its operator account must be funded with real STRK.

## Settlement — the appchain settles itself

Settlement is **embedded in the appchain Katana** — there's no separate prover
sidecar. `init rollup` writes the settlement *layer* (where to settle) into the
chain config; the operator then adds a `[settlement.runtime]` section (the settling
account + key, TEE registry, batching) that turns the node into an active settler:

```toml
# .run/chain-config/config.toml  (appended by up.sh / deploy.sh)
[settlement.runtime]
account-address = "<SAYA_ADDRESS>"
account-private-key = "<SAYA_PRIVATE_KEY>"
tee-registry = "<TEE_REGISTRY>"
batch-size = 1
```

With that present, the node (run with `--tee mock`) proves each block and submits
`update_state` to the piltover core **on Sepolia** itself — the job that used to
belong to the `saya-tee` sidecar.

Two consequences of settling to a real chain:

- **The settlement account pays real gas** for every `update_state`. Give it a
  **dedicated** funded account, distinct from the operator — sharing one causes
  nonce contention that stalls settlement. `init rollup` and the
  `[settlement.runtime]` account must be the *same* (the piltover operator is the
  only `update_state` caller).
- **`--tee mock` still applies.** It exercises the settlement plumbing (message
  hashes, state roots) against a real chain without a real SP1/TEE prover. The old
  Poseidon L1→L2 hash patch is **no longer needed** — katana computes the Poseidon
  message hash itself, so entries settle without the keccak/Poseidon mismatch.

The **mock TEE registry** (the on-L1 attestation verifier) is still deployed on
Sepolia, by `saya-ops`, before `init rollup`.

## Torii — the indexers (one per chain)

Two instances, as before, but the settlement one indexes a **Sepolia** world:

```bash
torii --rpc "$SEPOLIA_RPC_URL" --world "$SCORE_WORLD" --http.port 8091 ...                       # Sepolia
torii --rpc http://localhost:5070 --world "$GAME_WORLD" --http.port 8092 --indexing.preconfirmed # appchain
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
| Settle | appchain's embedded settlement → piltover (Sepolia) | registers L2→L1 message hashes |
| Bank | client → `score` (Sepolia) | `consume_message_from_appchain` + mint reward |
| Read | client → Torii ×2 + RPC | run state, feeds, balances, settled height |

Next: [how the contracts implement all this →](./contracts.md)
