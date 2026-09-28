# StakeLaunch

A fixed-supply ERC-20 and a non-upgradeable staking vault for the IdentityMD Sepolia test launch.
The token and vault are fully configured in their constructors. Neither constructor transfers launch
tokens away from the deploying factory.

## Build and check

```sh
forge build
forge test
forge fmt --check
```

Foundry uses Solidity **0.8.26**, Cancun, optimizer enabled with 200 runs, and
`bytecode_hash = "none"`. The verifier must provide that compiler. All Solidity dependencies,
including the test library, are vendored as ordinary files in `lib/`; there are no submodules,
package downloads, filesystem permissions, or FFI requirements. Tests need no RPC, keys,
environment variables, or caller-dependent script configuration. See [dependency provenance](lib/README.md).

## Token

`src/LaunchToken.sol:LaunchToken` has no constructor arguments. Its name is **StakeLaunch**, symbol
**STL**, decimals **18**, and supply **1,000,000,000 STL** (`1000000000000000000000000000` minor units).
The entire supply is minted once to the constructor caller, which is ProjectFactory in the launch
pipeline. There are no public mint, burn, owner, fee, pause, blocklist, or upgrade functions.
Transfers and allowances use the vendored OpenZeppelin ERC-20 implementation.

## Staking and rewards

`StakeVault(address token_, address owner_, uint256 lockDuration_)` uses the same token for principal
and rewards. The owner is explicitly supplied; the factory gains no administrative role by deploying it.

| Call | Behavior |
| --- | --- |
| `stake(amount)` | Pulls an approved, positive amount; resets the caller's entire principal lock to now plus the constructor lock. |
| `withdraw(amount)` | Returns only the caller's principal after the lock, including at the exact unlock second. Partial withdrawals leave the remaining lock unchanged. |
| `claimRewards()` | Pays the caller's accrued rewards, even while locked or paused; claiming zero is a successful no-op. |
| `fundRewards(amount)` | Owner-only; pulls approved tokens from the owner and starts a seven-day stream. |
| `setDepositsPaused(bool)` | Owner-only; changes whether new deposits are accepted. Claims, withdrawals and funding remain available. |

The lock parameter for this launch is **604800 seconds (seven days)**. Each user controls only their
own deposits, so another user cannot reset their lock. Principal earns rewards while deposited,
including after its lock expires. Withdrawing all principal preserves any unclaimed reward balance.
There is no automatic compounding, minimum positive deposit, withdrawal fee, or penalty.

Rewards vest linearly over a fixed seven-day duration and are shared according to each user's stake
while that time elapses. For example, with 100 and 300 STL staked for an entire 700 STL reward period,
the accounts earn 175 and 525 STL. A depositor joining midway receives no earlier rewards.

Each top-up first checkpoints past earnings, then schedules the new amount plus the previous period's
unvested rewards and any recorded idle rewards over a new seven days. The owner can therefore extend
the payout date of **unvested** rewards with repeated top-ups; already earned rewards never decrease.
The reward duration is fixed independently of the constructor's principal lock.

If nobody is staked, elapsed rewards become `unallocatedRewards` when next checkpointed. They are
not awarded to the next depositor. A later positive owner top-up schedules them again. Funding of
even one minor unit is accepted: cumulative vesting avoids a per-second rate rounding to zero.
Integer rounding in proportional distribution still leaves small amounts of dust in the reserve.
That dust cannot be swept or rescheduled because it cannot safely be distinguished from outstanding
reward liabilities. Frequent checkpoints can increase this dust. See [accounting details](docs/SECURITY.md).

## Custody and operating assumptions

- Use the paired, unmodified `LaunchToken`. Fee tokens, rebasing assets, dishonest balance reporting,
  and callback tokens are outside the supported deployment. Incoming transfers must increase the
  vault balance by the exact requested amount.
- The vault tracks principal separately from funded rewards. There is no owner withdrawal,
  confiscation, token approval, arbitrary execution, rescue, or upgrade entry point. Even the owner
  can withdraw only their own matured stake.
- The immutable owner can fund and pause deposits. Losing that wallet prevents future funding and
  pause changes, but users can still claim and withdraw. There is no ownership recovery or rotation.
- Approve and call `stake` or `fundRewards`; do not transfer tokens directly to the vault. Direct
  donations and unrelated assets are not credited and cannot be recovered. ETH transfers are rejected.
- The chain timestamp determines reward vesting and lock expiry. No external oracle or keeper is
  required. No reward rate or future funding is guaranteed; users should inspect the active schedule.

## Release handoff

| Item | Required value |
| --- | --- |
| Network | Sepolia, chain ID `11155111` |
| Token artifact | `src/LaunchToken.sol:LaunchToken` |
| Token constructor arguments | none |
| Application identifier | `StakeVault` |
| Application artifact | `src/StakeVault.sol:StakeVault` |
| Constructor types | `address,address,uint256` |
| Constructor arguments | `["$token", "$owner", "604800"]` |
| Constructor ETH value | `0` for both contracts |
| Initial state | Deposits enabled, no stakes, no rewards funded |

The manifest contributor writes `launch.json` from these accepted artifacts, with the token deployed
before the vault and `$owner` supplied by policy. Do not substitute the deploying factory for `$owner`.
The constructors require no initialization transaction. This builder submission intentionally does not
author the pipeline-owned manifest or include a broadcasting script.

The launch pipeline applies the standard policy allocation, including the swarm's ten percent;
distribution and liquidity are factory responsibilities, not token/vault constructor logic. The
provided policy-v5 reference describes 2% to launch contributors plus 8% to eligible preceding-window
contributors, a 20 ETH opening FDV, and native ETH pairing on Sepolia with fee 3000 and tick spacing 60.
The release operator must bind the manifest to the pipeline's admitted policy rather than assume
these reference parameters override it.

The owner must obtain STL from their policy allocation or the market, approve the vault, and call
`fundRewards` after deployment. The UI should show the user's full-lock reset before each deposit,
the unlock time, pause status, reward schedule and claimable balance. Operations should monitor the
schedule and reserve; pausing is only a deposit control and cannot freeze existing assets.

GitHub publication and Sepolia release are authorized for the launch pipeline. The deployer is
responsible for source publication, manifest validation, policy allocation, admitted-bytecode
deployment, explorer verification, and recording transaction/contract addresses. Contributors must
not broadcast or handle wallet keys. No external publication or deployment was performed here.

## Verification status

Tests cover ERC-20 behavior, factory deployment, locks and relocking, owner limits, proportional and
time-dependent rewards, overlapping funding, idle intervals, pause behavior, transfer failures,
reentrancy, and stateful conservation/exit properties. Fuzz tests use 512 cases; invariant tests use
128 histories of 64 actions each and check that all principal can still exit while deposits are paused.

[The separate local adversarial review](docs/REVIEW.md) records findings and limitations. Local tests,
manual review, and invariant fuzzing are not the pipeline's independent attestation or formal proofs.
The independent contributor review/audit panel, Slither/Aderyn reports, any required machine-checked
proofs, final manifest review, GitHub publication, and Sepolia deployment remain release-pipeline
responsibilities. No passing protected harness, external audit, analyzer report, or on-chain release
is claimed by this submission.
