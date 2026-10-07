# Basket Protocol

Basket is an immutable index vault for Stock Tokens on Robinhood Chain (chain id **4663**). Its ERC-20 share is **Basket / BASK**, with 18 decimals, zero initial supply and no supply cap. Deposits mint shares; redemptions burn shares. There is no separate launch token, pool or website.

## Build and deployment

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity 0.8.26, optimization at 200 runs, the IR compiler pipeline, Cancun EVM and `bytecode_hash = "none"`. The constant optimizer pass is disabled to keep event-topic data from being interpreted as forbidden opcodes by the pinned linear bytecode scan; optimization remains enabled at 200 runs. Production contracts have no external library dependency. The test dependency, forge-std v1.9.7, is vendored as ordinary source and license files in `lib/forge-std`; compilation and testing need no network once the pinned compiler is installed. No FFI, filesystem cheatcode permissions, forks or environment reads are enabled or used by the project tests.

`launch.json` specifies one nonpayable application constructor:

| Parameter | Literal |
|---|---|
| `BaskVault.owner_` | `0x30B57ECf51D19ABcED7F6f70974e6fBb6f3b9Da3` |
| `BaskVault.guardian_` | `0x5ed39AF86f2C00ad99913B5d727bD68f2A904B68` |
| Source constant `STOCK_FACTORY` | `0x4783C67b63dE2B358Ac5951a7D41F47A38F3C046` |

The constructor rejects zero or equal roles and makes no external calls. Deployment may be through a factory; roles do not depend on its caller. No transactions are broadcast by this project. External addresses and interfaces are assignment inputs, exercised with local mocks on chain id 4663; live factory code and token/feed pairings have not been independently verified here. There is no chain-id switch or network discovery inside the vault.

After deployment the owner lists at least three assets, optionally fixes the permanent fee recipient, and calls `finalizeGenesis()` once. The 72-hour delay starts at finalization. Listings are immediate only before finalization; every other proposal retains its timelock during genesis. Genesis assets have no probation. No assets or feeds are preselected by this project.

## Accounting and exits

Only `managed[token]` contributes to NAV. Direct transfers are ignored. There is no rescue, sweep, rebalance, administrator withdrawal or asset removal. Token quantities and BASK use 18 decimals; feed answers use 8 decimals. USD limits use 18 decimals. Full precision multiplication/division prevents intermediate-product overflow. Bands must fit in uint256.

The fixed entry and exit fee is 50 basis points, rounded up. When a fee recipient is unset, entry fee shares are not minted and exit fee shares are burned. When set, entry fee shares are minted to it and exit fee shares are transferred to it. The recipient is never called. On the first deposit, 1e15 shares are taken from the receiver's post-fee allocation and minted to `0x000000000000000000000000000000000000dEaD`. The receiver must still receive a positive amount meeting its minimum.

Deposits require the UTC weekday/window gate, at least three listed feeds updated within four hours, a valid price for the incoming asset and every managed asset, and readable non-short balances for **all** listed assets. Closed assets still count toward the market freshness test and still require valid prices when managed. The gate counts update times independently of band/answer validity; the separate price checks apply to the incoming and held assets. Incoming collateral must cover its existing owed balances before transfer. Its actual vault balance increase must equal the requested amount.

Limits are checked using pre-deposit NAV plus the rounded-down value of the deposit. The incoming asset's **entire resulting managed balance** is subject to concentration limits. NAV_CAP starts at $1,000,000; raises can never exceed $10,000,000,000. The aggregate bucket decays from the last successful deposit, linearly over a day with the decrement rounded down, and then adds the deposit value. Failed deposits do not change it; redemptions do not reduce it.

`redeem(shares, minimums, deadline)` never reads prices, pause flags or the market gate. For each listed asset it reserves `totalOwed`, takes the smaller of available and managed, and computes the net-share fraction against supply **before** the fee/burn. Missing minimum entries mean zero; extra entries have no asset to constrain. A minimum is a minimum **leg entitlement**, which may become owed if payment fails. It is not a guarantee of immediate delivery. A zero-share redemption is allowed; a one-wei share can be entirely consumed by its rounded-up fee.

Every balance read copies exactly 32 bytes with a 50,000-gas static call; failed calls and any return size other than 32 bytes are unreadable. During redemption an unreadable asset uses managed as its available amount. Each nonzero leg is paid through a self-only external call with 250,000 gas. It accepts no return value or exactly ABI `true` and verifies the vault balance decreased by exactly the leg. Failed calls roll back their token effects, reduce managed by the leg and increase the user's owed balance. The loop does not copy failed payment return data. Successful legs continue even when others fail.

`claim(token, to)` pays the lesser of the caller's owed balance and the vault's readable balance. Its self-call has no 250,000-gas limit; the same bounded balance reads and exact vault-debit check still apply. A failed claim reverts without reducing the debt. Claims are independent of all administrative pauses. Underfunded claims are served in transaction order, without a pro-rata haircut. A recipient may receive less than the nominal leg if the Stock Token taxes the recipient: the specified payment check measures the vault debit, not the recipient credit. A token that lies about its balances can defeat balance-based checks; external token implementations remain a trust dependency.

## Governance and time boundaries

All user-facing mutations are nonReentrant and emit events. The self-only `payLeg` helper runs inside the caller's guard and cannot be used by a role or user directly. BASK transfers/approvals remain available during pauses. Ownership uses proposal/acceptance with no renunciation; owner and guardian remain distinct.

| Action | Who initiates | Effect |
|---|---|---|
| List during genesis | Owner | Immediate, at most 64 assets |
| List after genesis; replace feed | Owner | Proposal; shared 24-hour execution spacing |
| Re-centre band; reopen asset | Owner | Proposal |
| Replace guardian; raise NAV_CAP | Owner | Proposal |
| Execute ready proposal | Anyone | Rechecks applicable conditions |
| Cancel proposal | Owner; guardian except guardian replacement | Immediate |
| Close asset; pause deposits | Owner or guardian | Immediate |
| Unpause deposits; lower NAV_CAP | Owner | Immediate; cap may be lowered to zero |
| Set fee recipient | Owner | Once, nonzero and not the vault |
| Flag deficit; recognize loss | Anyone | See loss accounting below |
| Redeem; claim | Shareholder; creditor respectively | Independent of roles and deposit restrictions |

Proposals are executable at `createdAt + 7 days` and expire at `createdAt + 14 days` (exclusive). Cancelled/executed proposals cannot execute again. A later close invalidates **every** earlier reopen proposal for that asset, including closes in the same timestamp. Feed addresses cannot be shared by different listed assets; a replaced feed becomes available again. Listing and replacement checks run at proposal and execution. Replacements must lie within the current band; they do not change it. A band proposal uses the answer at execution and may move outside the old band.

Price age is valid at exactly 26 hours; the band re-centering answer must be **strictly less** than 26 hours old. Future updates are invalid. Four-hour market freshness is inclusive. The market gate is Monday–Friday, 15:30 inclusive to 19:30 exclusive UTC, independent of holidays and daylight saving time. A deadline equal to the current timestamp is valid. Probation ends at exactly 30 days after a post-genesis listing; during probation the 1%/$5,000 limit applies, then the 5%/$25,000 limit applies. The global bucket uses 25%/$100,000. Time always uses `block.timestamp`.

A short asset retains its managed balance until loss recognition or a redemption leg reduces it. `flagDeficit` records only a strictly larger shortfall and restarts its seven-day clock. Recognition is allowed at exactly seven days, subtracts the lesser of recorded and current shortfall, and clears the record, including when recovery makes the loss zero. An unreadable balance cannot establish a loss. Each successful deposit clears every outstanding record; in practice collateral must first be restored or losses recognized so deposit health checks pass. A complete loss with remaining BASK supply produces zero NAV and prevents further deposits.

## Views and integration

`assets(index)`, `assetCount()`, `assetIndex(token)` (one-based), `managed`, `owed`, `totalOwed`, `deficits`, role getters, `NAV_CAP`, `bucket`, `decayedBucket()`, and proposal getters expose accounting and configuration. `allAssets()` includes token, feed, last answer/time (zero when the read fails), band, open state, current probation, listing time, managed amount, short/readable flags and total owed. Here `readable` describes the token balance read; price validity is evaluated separately.

`previewDeposit(token, amount)` returns receiver and fee shares, includes the first-deposit lock, and enforces current eligibility and amount caps. It cannot predict token transfer behavior, receiver validity, user approvals or later state changes. Its fee output is the calculated fee even when the recipient is unset. `previewRedeem(shares)` returns every leg and the calculated fee without executing payments or requiring the caller to own the shares. `navPerShare()` returns managed USD value per 1e18 shares, or zero with no supply; it requires valid prices for managed assets, and does not subtract an unrecognized shortfall.

`depositStatus(token)` returns the first eligibility failure in the same order used by deposit, as `(Reason, assetAtFault)`. Global failures use the zero address. It does not accept an amount, so caps, minimum shares, receiver, deadline and token transfer checks are handled by the deposit/preview methods. `DepositUnavailable(reason, asset)` carries the same eligibility result; amount cap failures identify the incoming asset.

| Code | Reason |
|---|---|
| 0 | OK |
| 1 | Genesis |
| 2 | OpeningDelay |
| 3 | Paused |
| 4 | NotListed |
| 5 | Closed |
| 6 | Unreadable |
| 7 | OwedUnderfunded |
| 8 | MarketClosed |
| 9 | MarketStale |
| 10 | InvalidPrice |
| 11 | Short |
| 12 | ZeroNAV |
| 13 | NAVCap |
| 14 | AssetCap |
| 15 | BucketCap |

`proposals(id)` exposes every proposal. `pendingProposals()` returns IDs and records that have neither expired nor been cancelled, executed or invalidated by a close, including proposals still waiting. Its scan grows with historical proposal count; indexers may use `proposalCount`, individual getters and events instead. Asset arrays retain listing order forever.

## Accepted risks and operational responsibilities

The accepted design permits deposit-then-redeem profit when a feed lags enough to exceed the approximately 1% round-trip fee. The owner is trusted to pair each Stock Token with its true feed; factory identity and feed interface checks cannot prove that pairing. An untransferable asset retains its feed value until deposits are paused. These are documented design properties; no additional mechanism is introduced.

Stock Token issuers can pause, block, burn holders and upgrade tokens. Operators must monitor feed freshness/bands, transferability, custody balances, queued proposals and issuer changes; use deposit pause/asset close when appropriate; coordinate accurate feed proposals; and publish the permanent fee recipient before setting it. Anyone can flag and later recognize observed custody deficits or execute ready proposals. The owner controls its handover; the guardian must monitor proposals it can cancel. Roles cannot stop vault redemption or claims, although issuer behavior and chain execution can still prevent token delivery. The vault cannot make an unavailable asset transferable or guarantee chain transaction inclusion.

The local suite covers accounting and rounding, time boundaries, permissions, proposal rechecks, losses, hostile token returns, block/pause/upgrade behavior, reentrancy, and redemption gas with 64 assets. It is not an independent audit. No live-chain simulation, broadcast, Slither or Mythril run is claimed. Deployment operators should obtain the separate adversarial review and verify the supplied external dependencies and deployment bytes before release.
