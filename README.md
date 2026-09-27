# Points (PNTS) and SwapPointsHook

A Sepolia `univ4_hook` launch: a fixed-supply ERC-20 called **Points (PNTS)** and a Uniswap v4 hook,
**SwapPointsHook**, that awards non-transferable points to whoever swaps on the token's native-ETH pool.

> Points is a Sepolia test toy. PNTS, the points and any pot have **no value**, nothing here promises a
> return, and points can be farmed by round-tripping at the cost of LP fees and gas. Anyone can credit
> points to any address, because the identity carried in `hookData` is not authenticated.

## Contents

| Path | What it is |
| --- | --- |
| `src/Points.sol` | The PNTS token. Zero-argument constructor, 1,000,000,000 × 10¹⁸ minted once to `msg.sender`, no owner, no mint, no admin. |
| `src/SwapPointsHook.sol` | The hook. Constructor takes only the PoolManager. Permissions: afterInitialize + afterSwap (address bits `0x1040`). |
| `src/HookFlags.sol` | Permission-bit constants and `flagsOf` / `matches` helpers used by the miner, the script and the admission tests. |
| `src/HookMiner.sol` | Pure CREATE2 salt search for a given flag pattern. |
| `script/Deploy.s.sol` | Reference deployment. Reads no environment; the tests call `deploy()` directly. |
| `test/` | Foundry suite (73 tests): launch rehearsal, pool-driven behaviour, direct-callback unit and fuzz tests, token tests, script test. |
| `docs/abi/` | Exported ABIs (`Points.json`, `SwapPointsHook.json`) and a guide to the functions and events a frontend needs. |
| `lib/` | Vendored dependencies as plain files (no submodules): v4-core `46c6834`, forge-std v1.9.7, OpenZeppelin v5.4.0 (ERC20 only), solmate `Owned`. |

## Behaviour

**afterInitialize** stores `startTime[poolId] = block.timestamp` for every pool that names this hook.

**afterSwap** reads the swapper's currency0 (ETH) delta as settled by the pool and credits the address
carried in `hookData`:

| Direction | Settled ETH leg | Points (18 decimals) |
| --- | --- | --- |
| Buy (ETH in, PNTS out) | `delta.amount0() < 0` | `ethPaid × 10,000` (10 points per 0.001 ETH) |
| Sell (PNTS in, ETH out) | `delta.amount0() > 0` | `ethReceived × 5,000` (5 points per 0.001 ETH) |

Both rates are doubled while `block.timestamp < startTime[poolId] + 7 days`. At exactly
`startTime + 7 days` the multiplier is gone; `multiplierEndsAt(poolId)` returns that timestamp. Amounts
are the pool's own `BalanceDelta`, so exact-output swaps earn on what they actually cost or paid out,
LP fee included. One wei of ETH earns 10,000 or 5,000 point-units: nothing rounds to zero.

**Identity rule.** The credited address is `abi.decode(hookData, (address))` when `hookData` is exactly
32 bytes, fits in 160 bits and is non-zero. Anything else (empty, 20 bytes, 64 bytes, dirty high bits,
the zero address) credits nobody, and the swap proceeds untouched. The `sender` argument (a router) is
never credited. The decode is done by hand so malformed data cannot revert the swap.

**Leaderboard.** Each pool keeps a top 10 sorted by points, maintained in O(10) storage operations per
credited swap. Ties keep the address that reached the score first ahead; a newcomer must strictly beat
the tenth entry to evict it. Evicted users keep their points and can re-enter.

**Views.** `pointsOf(poolId, user)`, `top10(poolId) → (address[10], uint256[10])`,
`multiplierEndsAt(poolId)`, plus the public `startTime(poolId)` and the rate constants.

**Event.** `Points(bytes32 indexed poolId, address indexed user, uint256 earned, uint256 total)` once per
credited swap.

**What the hook does not do.** It never returns a non-zero delta, holds no funds, takes no fee, and has
no owner, admin, setter, pause, upgrade, sweep, delegatecall or selfdestruct. Every callback other than
the two it enables reverts `HookNotImplemented`, and the PoolManager never calls them because the
address does not carry their bits. Every callback requires `msg.sender == poolManager`. A pool on this
hook whose currency0 is not native ETH gets zero deltas and earns nothing; its `startTime` is still
recorded, which is harmless.

## Assumptions

- **Chain and PoolManager.** Sepolia (11155111), PoolManager `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`.
  The hook trusts whatever PoolManager it is constructed with; it never checks the chain id.
- **Pool key.** currency0 = native ETH (`address(0)`), currency1 = PNTS, fee 3000, tick spacing 60. The
  hook learns everything from the key: it holds no token address. Any other native-ETH pool that names
  this hook also earns points, on its own `poolId` tally and its own 7-day window.
- **Launch price.** The hook is price-agnostic. The rehearsal uses 1 ETH = 1,000,000 PNTS
  (`sqrtPriceX96 = 79228162514264337593543950336000`) and also fuzzes 1 ETH = 10¹ … 10⁹ PNTS; the real
  number belongs to `launch.json`.
- **Seeding.** The factory seeds one-sided PNTS liquidity below the current tick and adds no ETH, so the
  first buy lands in a pool that holds no ETH. The hook enables no liquidity callbacks, so nothing it
  does can revert the initialise or the seed.
- **Time.** `block.timestamp` is used for a coarse 7-day calendar rule. Second-level validator drift can
  move a swap across the boundary; that is accepted.
- **Overflow.** `eth × 20,000` fits comfortably in `uint256` for any `int128` delta; a user's running
  total cannot realistically overflow (it would need ~10⁷² wei of settled ETH). Checked arithmetic is
  kept so an impossible overflow would fail loudly rather than corrupt the tally.

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Token constructor arguments | none |
| Token supply / decimals | 1,000,000,000 PNTS / 18, minted to the deployer (the factory) |
| Hook constructor argument | `IPoolManager` = `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Hook permission bits | `0x1040` (afterInitialize `1<<12`, afterSwap `1<<6`), all others false |
| Hook address | CREATE2 with a salt mined so the low 14 bits equal `0x1040`; the constructor calls `Hooks.validateHookPermissions` and reverts `HookAddressNotValid` at any other address |
| Rates and window | `BUY_RATE = 10_000`, `SELL_RATE = 5_000`, `MULTIPLIER_WINDOW = 7 days`, `LAUNCH_MULTIPLIER = 2`, `TOP_N = 10`, all source constants |
| Compiler | solc 0.8.26, EVM cancun, optimizer 200 runs, `via_ir = false`, `bytecode_hash = "none"` (see `foundry.toml`) |
| Hook runtime size | ~4.3 kB (limit 24,576) |

The salt depends on the CREATE2 deployer address. `HookMiner.find(deployer, 0x1040, creationCode, n)`
returns it for any deployer; `script/Deploy.s.sol` mines for forge's deterministic CREATE2 proxy
(`0x4e59b44847b379578588920cA78FbF26c0B4956C`) when broadcasting and for its own address when the
tests call `deploy()`. The factory mines for itself.

## Operational responsibilities

- **Factory / services** deploy PNTS and the hook from the attested creation code, mine the salt,
  initialise the pool at the manifest price, seed one-sided PNTS liquidity, publish source, attest and
  admit. `launch.json` is written by the manifest assignment, not here.
- **Frontend / routers** must put the swapper's address in `hookData` as `abi.encode(address)`. A swap
  without it credits nobody; a router can never claim points for itself.
- **Nobody** operates the hook after deployment. There is no key to hold, no parameter to tune and no
  funds to sweep. The only operational fact to publish is that points are worthless and unauthenticated.
- **Review.** Tests passing are not an audit. The workflow requires a separate read-only adversarial
  review of the points arithmetic, the multiplier boundary, top-10 correctness and gas, and hookData
  spoofing before release. This repository authorises no transactions and controls no wallet.

## Security notes for the reviewer

- **hookData spoofing.** By design, anyone can credit anyone. A griefing vector is limited to inflating a
  stranger's score; there is nothing to steal.
- **Wash farming.** A round trip earns `buy + sell` points and loses only the 0.3% LP fee twice plus gas
  (`testFuzz_roundTripFarmsPointsAtTheCostOfFees`). Leaderboard position is therefore a function of fees
  burned, not skill.
- **Router allowlisting** is intentionally absent: with no value at stake it would only add an owner.
- **Gas** (cold storage, 0.8.26 / 200 runs, measured in `test_gas_afterSwapTiers`):

  | afterSwap path | Gas |
  | --- | --- |
  | no / malformed hookData | ~5.3k |
  | first credit on an empty board | ~56k |
  | repeat credit, rank unchanged | ~19k |
  | newcomer below the tenth on a full board | ~59k |
  | existing tenth, rank unchanged | ~42k |
  | worst case: newcomer evicts the tenth and climbs to first | ~112k |

## Running the checks

```
forge build
forge test
forge fmt --check
```

The suite deploys a real v4-core `PoolManager`, places the hook at a mined CREATE2 address in every
`setUp`, and drives it through v4-core's `PoolSwapTest` and `PoolModifyLiquidityTest` routers. Tests read
no environment variables, depend on no caller address and pass in any order or in parallel.

| Suite | Covers |
| --- | --- |
| `LaunchRehearsal.t.sol` | Initialise at the manifest price, one-sided PNTS seed with zero ETH, first buy into the ETH-less pool, sells and exact-output both ways, LP unwind, window close, a spread of other launch prices. |
| `SwapPointsHook.t.sol` | Permissions and address bits, constructor rejection at wrong addresses, non-PoolManager callers, disabled callbacks, buy/sell rates for exact-in and exact-out, dust, 2x boundary at 7 days − 1 s and exactly 7 days, no / malformed hookData, unauthenticated identity, non-ETH currency0 pool, pool isolation, top-10 insertion / update / ties / eviction, fuzzed sizes, round-trip farming. |
| `SwapPointsHookUnit.t.sol` | Exact deltas via a pranked manager: formula fuzz, int128 extremes, never-revert fuzz over deltas / hookData / timestamps, 32-byte hookData fuzz, top-10 invariants under random sequences, gas tiers. |
| `Points.t.sol` | Metadata, single mint to deployer, exact transfers, allowance, absence of mint/admin entry points, supply conservation fuzz. |
| `Deploy.t.sol` | `deploy()` lands the hook on `0x1040` and mints to the deployer; salt mining is deterministic. |

The admission floor supplied with the assignment (`Hook.protected.t.sol`, `Token.protected.t.sol`) was
also run locally against the built creation code with `IMD_HOOK_FLAGS=0x1040` and the Sepolia PoolManager
address: 9 of 9 pass. Those files are not part of this repository; they need `src/HookFlags.sol` and
`test/mocks/MockERC20.sol`, both of which are.
