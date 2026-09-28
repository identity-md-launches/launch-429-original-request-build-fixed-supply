# Independent local adversarial review

Review date: 2026-09-28. A separate review agent inspected the implementation and wrote
`test/StakeVaultAdversarial.t.sol` independently of the implementation's functional and invariant
tests. This is a local review within the same assignment. It is **not** the launch pipeline's
required audit by an independent contributor, a release approval, or evidence that Slither,
Aderyn, or formal proofs have run. Those release checks remain the pipeline's responsibility.

## Scope and method

The review covered `src/LaunchToken.sol`, `src/StakeVault.sol`, and the relevant vendored
OpenZeppelin ERC-20, transfer-wrapper, math, and reentrancy behavior. The supplied protected
checks were read to understand the deployment floor. They do not establish application
correctness. No mainnet or Sepolia transactions, wallet access, source publication, or external
audit service calls were performed.

Manual inspection focused on fixed supply, explicit constructor ownership, principal custody,
reward liabilities, checkpoint order, top-ups and empty-pool periods, rounding, lock boundaries,
administrative limits, failed transfers, and callbacks. The review's CREATE2 deployment test
checks that the factory retains the entire token supply and receives no implicit vault privileges.
It also checks both deployed runtimes against the 24,576-byte limit and scans for DELEGATECALL,
CALLCODE, and SELFDESTRUCT while skipping PUSH immediate data.

## Results

No concrete principal-theft, unauthorized administration, or reward-reserve insolvency defect
was found in the reviewed use with the paired LaunchToken. This is a bounded finding, not a
guarantee that no vulnerability exists. No source repair was requested by this reviewer.

The local adversarial suite passes 20 tests with Solidity 0.8.26, including two fuzz tests at
512 runs each. Reproduce it from the repository root with:

```sh
forge test --match-path test/StakeVaultAdversarial.t.sol
```

Covered cases include:

- Staggered entrants compared with an independent token-unit and elapsed-time allocation
  calculation, followed by claims and return of all principal; total payouts never exceed funding.
- Last-second entrants and same-block deposit attempts, which cannot receive prior rewards.
- Empty-pool emissions and recycling on a later funding action, including a gap between stakers.
- One-minor-unit funding, expired schedules, and preservation of earned rewards across top-ups.
- Owner attempts to withdraw another user's stake or call common rescue/upgrade selectors.
- False-returning inbound/outbound token operations, with complete rollback and successful retry.
- Rejection and rollback of fee-taking deposits and reward funding.
- Malicious token callbacks during deposits, funding, principal withdrawal, and reward claims,
  checked against the reentrancy guard's specific revert data.
- Donations and rounding residue remaining outside withdrawable principal.

The parent implementation suite separately checks ordinary token, stake, reward, lock, pause,
constructor, and invariant behavior. The results above count only this review's own test file.

## Observations and assumptions

1. **Owner top-ups extend the unvested schedule.** Funding checkpoints the already released
   rewards, then schedules new funding plus remaining scheduled and idle rewards over a fresh
   seven days. Previously earned rewards stay claimable. Repeated top-ups can defer when the
   remaining pool finishes vesting. This is an operational discretion of the owner and should
   be disclosed to stakers. The test `test_TopUpPreservesEarnedRewardsButRestartsUnvestedSchedule`
   demonstrates it.

2. **Integer rounding can leave permanently reserved dust.** Both the global reward index and
   account rewards round down. Fractions are not carried per account; frequent checkpoints can
   accumulate dust. A stake of three minor units with one minor unit of funding is a concrete
   example where the reward remains reserved after all principal exits. Donations also remain
   in custody and never become rewards automatically. There is intentionally no owner rescue
   function. Operators should fund using `fundRewards`, avoid tiny schedules, and not promise
   recovery of donations or dust.

3. **The launch asset is the supported asset.** The constructor checks that the token address
   contains code, not that it is a genuine LaunchToken. Exact inbound balance checks reject
   fee-taking incoming transfers, but they are not a guarantee against malicious balance
   reporting, future rebases, or outgoing transfer taxes. The admitted manifest must reference
   the paired, immutable LaunchToken. The hostile test asset exercises defensive behavior; it
   does not establish safe operation with arbitrary ERC-20s.

4. **The owner cannot service emergencies by moving custody.** The owner's only operational
   actions are funding and pausing/resuming deposits. Withdrawals remain available after each
   caller's lock, and claims remain available while paused or locked. There is no administrative
   sweep, forced withdrawal, owner replacement, or upgrade path. This reduces custodial powers
   and makes incorrect constructor configuration or accidental transfers irreversible.

5. **The clock and lock are intentional.** All of an account's principal receives a fresh lock
   on each additional deposit. Withdrawals become possible at `unlockAt`, but rewards continue
   while that principal remains staked. Block timestamps control both the lock and seven-day
   vesting; the design does not provide exact wall-clock execution guarantees.

## Lint interpretation and release limits

Forge's timestamp warnings concern the deliberately chosen lock and reward clock. The strict
balance-comparison warning refers to rejecting an incoming transfer whose received amount
differs from its requested amount. Post-transfer event warnings do not identify an unguarded
custody write: principal and reward liability changes precede outgoing transfers, and all
functions performing token transfers have `nonReentrant`. The paired LaunchToken has no callback
hook; hostile-token tests additionally confirm guarded callback rejection. These explanations
are scoped review judgments, not a blanket waiver of static-analysis results.

The intended application constructor is `StakeVault($token, $owner, 604800)`; ownership must
come from the admitted policy, not the factory caller. A separate reviewer must inspect the
final source and manifest together, including the resolved privileged owner and token address.
The deployer remains responsible for policy allocation, GitHub publication, Sepolia deployment,
and address/source verification. This review neither implements nor validates the factory's
liquidity, distributor, contributor/swarm split, or deployment pipeline.

The test suite uses finite examples and fuzz samples. It supplies no machine-checked proof
of conservation, liveness, or absence of reachable forbidden behavior. Slither, Aderyn, the
independent contributor audit, manifest review, and any required proof artifacts must be
recorded separately before release.
