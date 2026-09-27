# ABI guide

`Points.json` and `SwapPointsHook.json` are exported with `forge inspect <Contract> abi --json` from
the sources in `src/` at the pinned compiler settings. Regenerate them after any source change:

```
forge inspect src/Points.sol:Points abi --json > docs/abi/Points.json
forge inspect src/SwapPointsHook.sol:SwapPointsHook abi --json > docs/abi/SwapPointsHook.json
```

## Points (PNTS)

Standard OpenZeppelin v5 ERC-20 surface: `name()`, `symbol()`, `decimals()` (18), `totalSupply()`,
`balanceOf`, `transfer`, `approve`, `allowance`, `transferFrom`, `Transfer` and `Approval` events, the
ERC-6093 error set, and one extra constant:

| Item | Notes |
| --- | --- |
| `TOTAL_SUPPLY() → uint256` | `1_000_000_000e18`. Equal to `totalSupply()` forever; there is no mint or burn. |
| constructor | No arguments. Mints the whole supply to `msg.sender`. |

## SwapPointsHook

`PoolId` is a `bytes32`: `keccak256(abi.encode(poolKey))` where the key is
`(currency0, currency1, fee, tickSpacing, hooks)`. For the launch pool that is
`(address(0), <PNTS>, 3000, 60, <hook>)`.

### Views a frontend needs

| Function | Returns | Meaning |
| --- | --- | --- |
| `pointsOf(bytes32 poolId, address user)` | `uint256` | The user's points on that pool, 18 decimals. Divide by 1e18 for whole points. |
| `top10(bytes32 poolId)` | `(address[10] users, uint256[10] scores)` | Leaderboard, best first. Unused slots are `address(0)` / `0`. |
| `multiplierEndsAt(bytes32 poolId)` | `uint256` | Unix time at which 2x stops (the first second that earns 1x). `0` if the pool was never initialised with this hook. Time left = `max(0, multiplierEndsAt − now)`. |
| `startTime(bytes32 poolId)` | `uint256` | Unix time the pool was initialised. |
| `poolManager()` | `address` | The PoolManager the hook trusts. |
| `getHookPermissions()` | `Hooks.Permissions` | afterInitialize and afterSwap true, all else false. |
| `BUY_RATE()`, `SELL_RATE()`, `MULTIPLIER_WINDOW()`, `LAUNCH_MULTIPLIER()`, `TOP_N()` | `uint256` | 10000, 5000, 604800, 2, 10. |

### Event

```
event Points(bytes32 indexed poolId, address indexed user, uint256 earned, uint256 total);
```

Emitted once per swap that credits someone. `earned` already includes the 2x multiplier when it applied;
`total` is the user's running score after the award. Filter by `poolId` for one pool or by `user` for a
wallet's history.

### Crediting a swap

Pass `hookData = abi.encode(userAddress)` (exactly 32 bytes, left-padded address) to the swap. With the
Sepolia `PoolSwapTest` router that is the last argument of
`swap(PoolKey key, SwapParams params, TestSettings settings, bytes hookData)`; the wallet sends the ETH
leg as `msg.value` on a buy. Empty or malformed `hookData` still swaps but credits nobody. Nothing checks
that `userAddress` is the wallet that signed: anyone can credit anyone.

### Callbacks

`afterInitialize` and `afterSwap` are called by the PoolManager only and revert `NotPoolManager()` for
anyone else. The other eight `IHooks` functions exist to satisfy the interface, revert
`HookNotImplemented()`, and are never invoked because the hook's address does not carry their bits.
