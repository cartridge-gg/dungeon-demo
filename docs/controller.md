# One Controller, both chains

[← client](./client.md) · [guide index](./README.md)

The demo signs with a single **Cartridge Controller** — buy / enter / bank on **real
Sepolia** *and* the dungeon play actions on the **external appchain** — at one address.
It's the only login: the Login button prompts the Controller connect directly.

## How it works

`app/src/wallet.tsx` gives the `ControllerConnector` both chains and exposes two
signers — `l1Account` (Sepolia) and `l2Account` (appchain). Each wraps the raw
`controller.account` and **switches the keychain's chain** around the call: `l2Account`
switches to the appchain's chain id (recorded in `deployments.json` at deploy time,
e.g. `CARTRIDGE_MAINNET`), executes the play action, then switches
back to Sepolia for the next L1 op. The **player** is the Controller address (same on both
chains), so a run entered on Sepolia is played and banked by that same Controller.
Details in [client.md](./client.md#wallets-controller-only).

## Setup (hosted keychain)

By default the app connects to the **hosted Cartridge keychain** (`x.cartridge.gg`) —
your **real Cartridge Controller account**, already deployed by Cartridge. Just:

```bash
./up.sh
```

The **external appchain** (cartridge-appchain) runs Katana with
`--paymaster --cartridge.paymaster --cartridge.controllers`, so it's Controller-capable
out of the box (the settlement side is real Sepolia — Cartridge knows it natively, so
only the appchain needs the middleware). `up.sh` then **declares the Controller account
classes on the appchain** (`scripts/declare-controller-class.ts`, *all* bundled
versions — an account is pinned to the class version it was created with, and the
keychain deploys it at that version on a new chain). On a current appchain the classes
are already in the rollup genesis at their canonical hashes and this declare is a
harmless no-op; otherwise it's what lets the Controller auto-deploy on first play. The
frontend serves HTTPS (`mkcert`), required for the passkey login.

Open `https://localhost:3002`, **Login → Connect Controller** (your cartridge.gg
account), then play: enter (Sepolia) → play (appchain) → withdraw → bank (Sepolia), all
keyed on the one Controller address.

### Funding

Sepolia ops (buy / enter / bank) cost real gas; the appchain is free (`--dev.no-fee`).
Your Controller is a real account, so **fund it with a little STRK on Sepolia** (or rely
on Cartridge paymaster sponsorship if your app is set up for it). For **GAME** to enter,
hit **Dev-mint** (a session policy) once funded, or buy with USDC.

## Gotchas

- **Chrome blocks the hosted keychain → localhost appchain** (Local Network Access). The
  play actions need the `x.cartridge.gg` iframe to reach `:5070`; on the first appchain
  call Chrome shows a *"x.cartridge.gg wants to access devices on your local network"*
  prompt — **allow it**. (On Chrome ≥138 the old `chrome://flags/#local-network-access-check`
  is a no-op; the permission prompt is the actual gate.) If it can't be granted, expose
  the appchain over a public HTTPS tunnel (e.g. `cloudflared tunnel --url
  http://localhost:5070`) and point the connector's appchain RPC at the tunnel URL.
- **Pre-wildcard Controller account** — modern keychains use *wildcard* sessions, which
  need account class **≥ v1.0.9**. If your Controller was created on an older class, its
  fresh appchain deploy lands at that old version and play reverts with
  `session/length-mismatch` — and pre-v1.0.6 classes lack `execute_from_outside_v3`,
  so paymaster-sponsored play fails with `ENTRYPOINT_NOT_FOUND`. Upgrades are
  **per chain**: an account upgraded on one appchain still deploys at its old class
  on the next one. Upgrade the appchain account: on the hosted client add
  `&default_appchain=1` to the URL (locally: `VITE_DEFAULT_APPCHAIN=1` in
  `app/.env.local`) so the keychain sits on the appchain, Connect → it shows an
  **Upgrade** screen → upgrade → drop the param/var. (The upgrade gate reads the *current*
  chain, so on Sepolia — already upgraded — it never offers the appchain upgrade.)
  **Unsetting it matters**: while set, the keychain pins to `http://localhost:5070`,
  which a hidden iframe can't reach under Chrome's Local Network Access rules — the
  silent session probe then finds nothing and auto-reconnect on page load stops working.
- **Per-chain sessions** — a session is stored per chain and its authorization
  signature covers the chain id, so each chain needs its own consent. The app **warms
  both up at connect time** (`warmUpSessions` in `app/src/wallet.tsx`): right after a
  login or silent reconnect it runs the keychain's `updateSession` on the settlement
  chain, then on the appchain, so every consent page shows at load — not in the middle
  of the first move. Each chain's approved policy set is fingerprinted in
  `localStorage` (`ccd.wallet.approved-policies.<chain>`), so the keychain only
  reopens for a policy set that's new to the browser (fresh browser, or a redeploy
  moved the contracts). If a leg is cancelled or fails, nothing breaks — that chain
  just falls back to prompting lazily on first use.
- **HTTPS for WebAuthn** — `./up.sh` serves `https://localhost:3002` via
  `mkcert`; passkey login refuses an untrusted cert.

A Controller login is required to play — there is no other wallet option.

## Self-hosted keychain (fully-local fallback)

For a fully-local Controller — a `localhost` passkey, no cartridge.gg account (e.g.
offline dev) — point the app at a self-hosted keychain instead:

1. Run a self-hosted keychain: clone `cartridge-gg/controller`, mkcert certs, and
   `pnpm keychain dev` on `https://localhost:3010`. Set its `VITE_RPC_SEPOLIA` to your
   **real Sepolia RPC** (`.env` `SETTLEMENT_RPC_URL`).
2. Point the app at it, then start:
   ```bash
   echo 'VITE_KEYCHAIN_URL=https://localhost:3010' > app/.env.local
   ./up.sh
   ```

A self-hosted Controller is a **fresh localhost passkey** (RP-id `localhost`), so its
Sepolia account starts undeployed and unfunded — send its address (shown on connect)
some STRK so it can self-deploy + pay. Keep the keychain (`:3010`) up before connecting.

**Keeping your real cartridge.gg account while self-hosting** — e.g. to test an
*unreleased* keychain change against your real (funded) account: instead of RP-id
`localhost`, serve the self-hosted keychain *as* `x.cartridge.gg`. Resolve
`x.cartridge.gg → 127.0.0.1` (`/etc/hosts`), front it with a reverse proxy on `:443`
using a locally-trusted cert for `x.cartridge.gg` (mkcert), and set the keychain's
`VITE_RP_ID=cartridge.gg` + `VITE_CARTRIDGE_API_URL=https://api.cartridge.gg`. Now the
iframe is a loopback origin (no LNA prompt), `api.cartridge.gg` CORS accepts the real
origin, and the passkey resolves your real account — all while running your patched
keychain. Remove the `/etc/hosts` entry when done to restore the real domain.

---

Back to the [client](./client.md) read/write layer, or the
[guide index](./README.md).
