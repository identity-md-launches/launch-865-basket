The stateful suite extends the existing unit and 64-asset gas tests. It uses local Stock Token,
factory, and feed mocks on chain id 4663. It needs no network, environment variables, or new
dependencies. Run it with `forge test --match-path test/StatefulAccounting.t.sol`; run the complete
suite with `forge test`.

Each fee configuration runs 256 sequences of 128 handler calls, with unexpected reverts treated
as failures. Four actors can deposit for one another, transfer shares directly or through an
allowance, redeem partially or completely, and claim to another actor. Other actions change token
transfer/read behavior, pause the oracle or deposits, donate, burn vault holdings, flag/recognize
losses, set the permanent fee recipient, and advance time. Issuer faults persist until a recovery
action. The initial deposits ensure that each campaign starts with assets at risk.

The invariant checks exact identities after each call:

- Sum of all actors' shares plus locked shares equals total supply; locked shares remain `1e15`.
- Sum of individual claims equals the asset's total owed.
- Vault token balance + observed payouts + issuer burns = deposits + donations.
- Managed + owed + observed payouts + recognized losses = deposits.

Payout ghosts come from recipients' actual token balance changes. Deposit, donation, and issuer
burn ghosts come from inputs to successful operations. Recognized loss ghosts are bounded by the
recorded and current deficits before recognition. These identities deliberately allow donations,
shortfalls, and underfunded claims: the specification does not promise constant solvency after
issuer burns. The handler also checks failed-call rollback and the loss waiting period. A
deterministic handler scenario proves that deferred payments, claims, recognized losses, and
subsequent deposits are reachable. After every campaign, all actors redeem while deposits are
paused, then attempt claims after token recovery; claims may remain underfunded following burns.

`AdversarialSequences.t.sol` adds 1,000 fuzz cases of repeated basket round trips at fixed,
heterogeneous prices, role rejection checks, competing feed proposals, debt ownership after share
transfers, zero/dust/full exits, and accounting events. The round-trip property compares total
Stock Token value across all legs. It does not classify the explicitly accepted lagging-feed
arbitrage as a defect.

The random handler uses exact-transfer and adversarial failure modes. Taxed transfers, return-data
and gas bombs, callbacks, code removal, and the 64-asset gas ceiling remain covered by the existing
deterministic suite. Live issuer/proxy behavior is outside these offline tests; no fork test is
required or included in this assignment.
