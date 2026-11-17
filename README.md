# Pincer smart contracts

Solidity sources for Pincer, the system that turns a private company's share classes into tokens on Robinhood Chain. This file covers the codebase: structure, rule configuration, permissions, testing and deployment. Product guides for issuers and investors are at [docs.usepincer.org](https://docs.usepincer.org).

## Key specs

| | |
| --- | --- |
| Chain | Robinhood Chain, an Arbitrum chain settling to Ethereum. Mainnet is 4663 and testnet is 46630 |
| Compiler | Foundry with solc 0.8.26, via-IR enabled, EVM version Cancun |
| Libraries | OpenZeppelin Contracts 5.2.0 and forge-std 1.9.7, installed through Soldeer |
| Test coverage | 74 cases across seven suites, mixing unit and end-to-end flows |

Each company gets a dedicated bundle of contracts, and each of its share classes is a `PincerEquityToken`. The token itself enforces transfer restrictions, so a non-compliant trade simply cannot settle. Raises, trading windows, signed quote fills, payouts, ballots and document anchoring all live in that same bundle. Because everything is emitted as events, a company's full history can be audited by anyone, and no personal information is ever written on-chain.

## Repository map

```
src/
  interfaces/      IPincerDeployer, IPincerEquityToken, IHolderRegistry, IVerifierList,
                   ITransferPolicy, IPolicyRule, IValuationFeed
  platform/        PincerDeployer, PincerEquityToken, CompanyTimelock
  policy/          TransferPolicy
    rules/         PolicyRuleBase, HolderBalanceRuleBase, and the eight rules built on them
  registry/        HolderRegistry, VerifierList
  trading/         RaiseEscrow, WindowMarket, QuoteSettlement, PoolGuard
  corporate/       PayoutVault, ShareholderBallot, DocumentAnchor, ValuationFeed
  common/          AccessRoles, CheckCodes, ClaimTopics, TimeSource
  mocks/           TestDollar (freely mintable 6-decimal USDG substitute)
script/            Bootstrap.s.sol and DemoData.s.sol
test/              TestBase.t.sol fixture plus a suite for each area
deployments/       per-chain address files written by Bootstrap
```

File names match the main contract they declare.

## Deployed contract graph

Everything starts from `PincerDeployer`, which deliberately retains no role in the contracts it creates.

```
PincerDeployer (owned by Pincer)
 └── for each company
      ├── CompanyTimelock       M-of-N multisig with mandatory delays; DEFAULT_ADMIN over every contract below
      ├── VerifierList          maps identity providers to the claim topics they may attest
      ├── HolderRegistry        links wallets to identities and stores signed claims, no personal data
      ├── RaiseEscrow           escrowed primary raises with pro-rata allocation, minting at close, refunds
      ├── WindowMarket          uniform-price batch auctions or fixed-price tenders, first refusal handled first
      ├── QuoteSettlement       atomic settlement of EIP-712 signed quotes between eligible holders
      ├── PayoutVault           payouts fixed at a record block and claimed by each holder
      ├── ShareholderBallot     cross-class snapshot voting with checkpointed delegation
      ├── DocumentAnchor        SHA-256 fingerprints of company documents
      └── for each share class
           ├── PincerEquityToken   UUPS proxy ERC-20 with ERC-3643 functions and an ERC-8056 multiplier
           ├── TransferPolicy ──► dedicated clones of whichever rules are enabled
           ├── ValuationFeed       reference price exposed via Chainlink's AggregatorV3 interface
           └── PoolGuard           present only when the class trades in permissioned AMM pools
```

Company contracts and rules are deployed as EIP-1167 clones of shared implementations. Equity tokens use ERC1967 proxies instead so they can be upgraded if needed, but any upgrade has to go through the company's timelock with a seven-day wait.

## Validating a transfer

`canTransfer(from, to, amount)` evaluates three stages and returns as soon as one fails.

| Stage | Conditions | Possible codes |
| --- | --- | --- |
| Token | Not paused, neither wallet frozen or mid-recovery, sender has enough unlocked balance | `TOKEN_PAUSED` / `FROZEN` / `INSUFFICIENT_UNLOCKED_BALANCE` |
| Identity | Every non-agent party has a registered identity with valid `IDENTITY_VERIFIED` and `SCREENED` claims | `SENDER_NOT_VERIFIED` / `RECIPIENT_NOT_VERIFIED` / `CLAIM_EXPIRED` |
| Rules | Each enabled rule, in the company's chosen order | The code from the first rule that rejects |

`transfer`, `transferFrom` and `mint` share this logic and revert with `TransferNotAllowed(reasonCode)` on failure. Codes are left-aligned `bytes32` strings defined in `src/common/CheckCodes.sol`.

Agents bypass the identity stage, and each rule ignores the agent's side of a transfer. At deployment the company's `WindowMarket` is made an agent; the timelock manages others through `setAgent`, and any contract carrying a valid `VENUE` claim for the token (such as an approved pool) counts as well. This way the restrictions land on the real buyer and seller rather than on an intermediary escrow.

## Rule catalogue

| Id | Contract | `abi.encode` config and what each field means | Failure code |
| --- | --- | --- | --- |
| `REGION` | `JurisdictionRule` | `(uint8, bytes2[])`: 0 for allowlist or 1 for blocklist, then the region codes | `REGION_BLOCKED` |
| `ELIGIBILITY` | `InvestorTierRule` | `(uint8, bool)`: lowest accepted tier, whether employees are exempt | `NOT_ELIGIBLE` |
| `HOLDING_PERIOD` | `LockupRule` | `(uint32, bytes32[], uint32[], address[], bytes32[])`: fallback period, source ids, period for each source, operator addresses, source tagged by each operator | `HOLDING_PERIOD_ACTIVE` |
| `HOLDER_CAP` | `HolderLimitRule` | `(uint32)`: holder count limit | `HOLDER_CAP_REACHED` |
| `TRANSFER_WINDOW` | `TradingWindowRule` | `(Window[], bool, address)`: allowed windows, whether `WindowMarket` sessions also count as open, address of that `WindowMarket` | `WINDOW_CLOSED` |
| `ROFR` | `FirstRefusalRule` | `(address, uint32, address[])`: who holds the right, notice length, venues that bypass it | `ROFR_PENDING` |
| `MAX_OWNERSHIP` | `OwnershipCeilingRule` | `(uint16, bool, address[])`: cap in basis points, whether minting is also capped, exempt identities | `MAX_OWNERSHIP_EXCEEDED` |
| `EMPLOYEE_VESTING` | `VestingScheduleRule` | `(uint8, bytes)`: action selector and its payload; grants are loaded by the registrar via `addGrants` | `UNVESTED` |

Enable identity-counting rules before the first mint. `HolderLimitRule`, `OwnershipCeilingRule` and `VestingScheduleRule` maintain per-identity tallies from the moment they are switched on and cannot reconstruct earlier balances. `LockupRule` works differently, keeping lots per wallet and spending the oldest first.

## Permissions and timelocks

| Role | Assigned to | Allows |
| --- | --- | --- |
| `DEFAULT_ADMIN_ROLE` | `CompanyTimelock` | Changing rules, upgrading, editing verifiers, setting fees and agents, assigning roles |
| `ISSUER_ADMIN` | Company multisig | Raises, windows, payouts, ballots, scheduling multiplier updates |
| `REGISTRAR` | Company registrar | Mint, burn, freeze, execute recoveries, add vesting grants |
| `OPERATOR` | Per-company Pincer relayer | Register identities, co-sign recoveries |
| `PAUSER` | Issuer admin and registrar | Instant pause and unpause |
| `MINTER` | `RaiseEscrow` | Mint allocations at raise close |
| `ANCHORER` | Issuer admin and registrar | Write document hashes to `DocumentAnchor` |
| `PUBLISHER` | Issuer admin, `RaiseEscrow`, `WindowMarket` | Push valuations to `ValuationFeed` |

The delays are floors: a company may raise them but can never go lower.

| Operation | Floor |
| --- | --- |
| `upgradeToAndCall` on a token | 7 days |
| Adding, removing or reconfiguring a rule | 24 hours |
| Any other timelocked call | 48 hours |
| Scheduled multiplier change on a token | 48 hours |
| Wallet recovery (two of issuer admin, registrar, operator must approve) | 72 hours by default, 48 hours minimum |

## Snapshot blocks on Arbitrum

Arbitrum reports the L1 height as `block.number`, which advances far too slowly for record dates. To get usable snapshots, `TimeSource` (`src/common/TimeSource.sol`) reads the L2 block number from the ArbSys precompile when setting a payout record block or a ballot snapshot. Where the precompile is absent, as in local tests, it falls back to `block.number`.

## Build and test

```sh
forge soldeer install                                   # download dependencies into dependencies/
forge build
forge test
forge test -vvv --match-path test/WindowMarket.t.sol    # single suite, verbose traces
```

| File | Contracts exercised |
| --- | --- |
| `test/Deployer.t.sol` | `PincerDeployer`, `CompanyTimelock`, `DocumentAnchor`, `ValuationFeed`, `PoolGuard` |
| `test/EquityToken.t.sol` | `PincerEquityToken` |
| `test/PolicyRules.t.sol` | `TransferPolicy` plus all eight rules |
| `test/RaiseEscrow.t.sol` | `RaiseEscrow` |
| `test/WindowMarket.t.sol` | `WindowMarket` |
| `test/QuoteSettlement.t.sol` | `QuoteSettlement` |
| `test/PayoutsAndBallots.t.sol` | `PayoutVault`, `ShareholderBallot` |

`test_DocumentedAuctionExample` in `test/WindowMarket.t.sol` reproduces the auction walkthrough from the docs step by step. If the docs and the contract ever disagree, the test suite breaks.

## Deployment

Create `.env` from `.env.example`, complete it, and point the bootstrap script at the testnet alias from `foundry.toml`:

```sh
forge script script/Bootstrap.s.sol --broadcast --verify --rpc-url robinhood_testnet
```

`Bootstrap` publishes all implementations and the `PincerDeployer`, registers the eight rule implementations, assigns the default verifier to every claim topic, and writes the resulting addresses to `deployments/<chainId>.json`. The last testnet deployment consumed about 40.6M gas.

The script also creates **Larkway Labs**, a fictional company in which the deployer holds every role, unless you set `DEPLOY_DEMO=false`:

* `COMMON` blocks a set of sanctioned regions, requires tier 1 with an exemption for employees, caps holders at 2,000, and applies a 90-day lockup to shares bought in a raise.
* `SERIES_B` requires tier 2 and stops any holder from passing 25% of the class through transfers.
* If the deployer doubles as the verifier, it gets verified, is issued 1,000,000 Common and 250,000 Series B shares, and a Series B raise opens for 30 days at 25 USDG per share.

Leaving `USDG` empty makes the script deploy `TestDollar`, an openly mintable 6-decimal token for testing only. On mainnet (4663) the script will not deploy it.

### Sample history

Once a bootstrap with the demo company has run, `DemoData` populates it with believable activity: six verified investors, secondary transfers, subscriptions into two raises, a window auction, quote fills, a dividend and two ballots. Since windows, raises and ballots can only finalize once their on-chain close time passes, it is split into three steps:

```sh
forge script script/DemoData.s.sol --broadcast --slow --rpc-url robinhood_testnet --sig "open()"
# wait SETTLE_DELAY (10 minutes)
forge script script/DemoData.s.sol --broadcast --slow --rpc-url robinhood_testnet --sig "settle()"
# wait VOTE_PERIOD (10 minutes)
forge script script/DemoData.s.sol --broadcast --slow --rpc-url robinhood_testnet --sig "finalize()"
```

The demo investor keys derive from `PRIVATE_KEY`, meaning the holder of that key also controls every demo investor. Their addresses go to `deployments/<chainId>.seed.json`. `open()` will not execute on mainnet.
