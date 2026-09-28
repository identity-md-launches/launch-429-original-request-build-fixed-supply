# Accounting and security model

## Reward calculation

For a reward period with budget `B`, start `s` and fixed duration `D = 604800`, cumulative release is
`V(t) = floor(B * clamp(t - s, 0, D) / D)`. Each checkpoint accounts for
`V(now) - V(lastUpdateTime)`, so arbitrary claim timing does not truncate a per-second reward rate.
OpenZeppelin `Math.mulDiv` performs the products without intermediate overflow.

When aggregate stake `S > 0`, released amount `d` adds `floor(d * 10^27 / S)` to the global
reward-per-token accumulator. An account accrues
`floor(balance * (accumulator - paidAccumulator) / 10^27)`. Every stake change checkpoints the
affected account and the global accumulator before changing balances. When `S = 0`, the released
amount is stored as unallocated rewards, without changing the accumulator. Read-only `earned`
includes elapsed rewards without modifying state.

Funding checkpoints the old period before replacing it. New budget is exactly:

```text
new amount + (old budget - old cumulative release at now) + unallocated rewards
```

Already released rewards assigned to stakers are excluded from the new budget, whether or not
users have claimed them. Idle rewards are included only once, then their counter is reset. Funding
and deposits measure actual receipt and revert on any amount mismatch. Failed external transfers
revert the entire state transition. All token-moving public entry points are non-reentrant.

## Conservation argument and tested properties

For the specified LaunchToken, initially all vault quantities are zero. Let `P` be aggregate
principal, `R` the reward reserve, `F` cumulative owner funding, `C` cumulative reward payouts,
and `U` direct, unaccounted donations. The transitions preserve:

```text
vault token balance = P + R + U
R = F - C
P = sum of individual principal balances
sum of claimable rewards <= R
```

Deposits increase the actual balance and `P` equally; withdrawals decrease both equally.
Funding increases the balance and `R` equally; claiming decreases both equally. Schedule and pause
changes transfer no funds. Accumulator and account rounding round down. No function removes funds
except a caller's own principal withdrawal or reward claim. The immutable owner's two powers do not
write user principal, locks, or accrued rewards. Thus an owner without a stake cannot remove principal,
and properly accounted reward claims leave principal backed.

`test/StakeVaultInvariant.t.sol` runs randomized interleavings of deposits, withdrawals, claims,
funding, time advances, pauses and donations, checking these relationships against separate ghost
counters. Each history finishes by advancing past every lock and exiting all users while paused.
This is a bounded randomized check and an informal argument, not an exhaustive or machine-checked
proof. The independent pipeline remains responsible for its required proof obligations.

## Rounding and liveness limitations

The paired token's total supply is `10^27`, so total stake is never greater than accumulator precision.
Each global checkpoint can leave less than one minor token unit undistributed from accumulator
rounding. Each account checkpoint can additionally discard less than one minor unit of fractional
entitlement. Fractions are not carried between checkpoints; sufficiently frequent interactions can
make the cumulative loss material for very small stakes or rewards. Lost fractions stay in `R` and
cannot be swept. A third party cannot directly checkpoint another account, but their interactions can
increase the number of global checkpoints. This is not an exact fractional distribution mechanism.

The owner may repeatedly restart the unvested schedule with positive funding, delaying unvested
rewards. Principal withdrawal after the constructor lock and claiming accrued rewards remain live.
An idle period's rewards need another positive owner funding call to resume distribution. No keeper
is necessary for normal vesting or withdrawals. Unlocks and schedules use consensus timestamps and
are not promises of exact wall-clock settlement.

Only the fixed-supply, exact-transfer LaunchToken is supported. Constructor code-existence validation
does not prove arbitrary ERC-20 code is honest. Exact incoming balance checks and reentrancy guards
are defense in depth; they do not support a token that later confiscates balances, changes its
behavior, rebases, charges outgoing fees, or lies about transfer success/balances. Final review must
verify that `$token` resolves to the admitted LaunchToken artifact.

## Tool findings and release review

Foundry's linter flags timestamp comparison at the lock boundary, post-transfer events, and exact
balance equality. These are reviewed choices: timestamps implement the specified lock; token-moving
entry points are guarded by `nonReentrant` and failed calls roll back state/events; exact incoming
balance equality rejects non-exact transfers. The supported token makes no callbacks. The adversarial
tests exercise callback rejection on other tokens but do not expand the supported asset model.

Before release, independently review the actual manifest's token and owner substitutions, compiler
settings, constructor arguments, dependency provenance, reward scheduling tradeoffs, and the
absence of privileged withdrawal or runtime escape opcodes. Run the pipeline's analyzers and proof
steps against the admitted source. This document does not substitute for their outputs.
