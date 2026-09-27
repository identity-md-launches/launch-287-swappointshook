// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title SwapPointsHook
/// @notice A Uniswap v4 hook that awards non-transferable points for swapping on a native-ETH pool.
///
/// Rates (points carry 18 decimals, so one wei of ETH already earns whole point-units and nothing
/// rounds away):
///  - a buy (swapper pays ETH, currency0 delta negative) earns `ethPaid * 10_000`;
///  - a sell (swapper receives ETH, currency0 delta positive) earns `ethReceived * 5_000`;
///  - both are doubled while `block.timestamp < startTime[poolId] + 7 days`, where `startTime`
///    is the block timestamp at which the pool was initialised.
/// ETH amounts are the amounts actually settled by the pool (the swap's `BalanceDelta`), so an
/// exact-output buy earns on the ETH it really cost and an exact-output sell on the ETH it really
/// paid out, LP fee included.
///
/// Identity: the credited address is `abi.decode(hookData, (address))` when `hookData` is exactly
/// 32 bytes, decodes to an address and that address is non-zero. Otherwise the swap credits nobody.
/// The `sender` argument (a router) is never credited.
///
/// @dev SECURITY NOTE: `hookData` is not authenticated. Any swapper can put any address in it,
/// so anyone can credit points to anyone; points can also be farmed by round-tripping at the cost
/// of LP fees and gas. Points have no monetary value and are never redeemable for anything from
/// this contract. This is a Sepolia test toy.
///
/// The hook holds no funds, takes no fee, returns zero deltas, and has no owner, admin, setter,
/// pause, upgrade or sweep. Every rate, window and size is a source constant. All state is keyed
/// by `PoolId`; a pool on this hook whose currency0 is not native ETH earns nothing and is
/// otherwise unaffected. `afterSwap` never reverts for a swap the pool accepts, and nothing in
/// this hook can revert a pool initialisation or a liquidity change.
contract SwapPointsHook is IHooks {
    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Point-units earned per wei of ETH paid on a buy (10 points per 0.001 ETH).
    uint256 public constant BUY_RATE = 10_000;
    /// @notice Point-units earned per wei of ETH received on a sell (5 points per 0.001 ETH).
    uint256 public constant SELL_RATE = 5_000;
    /// @notice Length of the launch window during which every award is doubled.
    uint256 public constant MULTIPLIER_WINDOW = 7 days;
    /// @notice The launch-window multiplier.
    uint256 public constant LAUNCH_MULTIPLIER = 2;
    /// @notice Size of the per-pool leaderboard.
    uint256 public constant TOP_N = 10;

    /// @notice The only address allowed to drive the callbacks.
    IPoolManager public immutable poolManager;

    // ---------------------------------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------------------------------

    /// @notice Block timestamp at which each pool was initialised. Zero for pools this hook never saw.
    mapping(PoolId poolId => uint256 timestamp) public startTime;

    /// @dev Points per user per pool. No transfer, approve or burn exists: the tally only grows.
    mapping(PoolId poolId => mapping(address user => uint256 points)) private _points;

    /// @dev Per-pool leaderboard, sorted by points descending, packed from index 0 with
    /// `address(0)` marking unused slots. Ties keep the address that reached the board first ahead.
    mapping(PoolId poolId => address[10] board) private _top;

    // ---------------------------------------------------------------------------------------------
    // Events & errors
    // ---------------------------------------------------------------------------------------------

    /// @notice Emitted once per credited swap.
    /// @param poolId The pool the swap happened on.
    /// @param user The address decoded from hookData.
    /// @param earned Point-units awarded by this swap, multiplier already applied.
    /// @param total The user's points on this pool after the award.
    event Points(PoolId indexed poolId, address indexed user, uint256 earned, uint256 total);

    /// @notice A callback was invoked by something other than the PoolManager.
    error NotPoolManager();
    /// @notice A callback this hook does not enable was invoked.
    error HookNotImplemented();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    /// @param _poolManager The Uniswap v4 PoolManager (Sepolia: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543).
    /// @dev Reverts with `Hooks.HookAddressNotValid` unless the deployment address carries exactly
    /// the afterInitialize and afterSwap bits (0x1040), so a mis-mined salt fails at deploy time
    /// instead of at the first pool call.
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    /// @notice The permissions this hook implements: afterInitialize and afterSwap, nothing else.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Points `user` has earned on `poolId` (18 decimals).
    function pointsOf(PoolId poolId, address user) external view returns (uint256) {
        return _points[poolId][user];
    }

    /// @notice The pool's leaderboard, best first. Unused slots are `address(0)` with a score of 0.
    function top10(PoolId poolId) external view returns (address[10] memory users, uint256[10] memory scores) {
        address[10] storage board = _top[poolId];
        for (uint256 i = 0; i < TOP_N; ++i) {
            address user = board[i];
            if (user == address(0)) break;
            users[i] = user;
            scores[i] = _points[poolId][user];
        }
    }

    /// @notice Timestamp at which the 2x launch window closes: the first second that earns 1x.
    /// Zero for a pool this hook never initialised.
    function multiplierEndsAt(PoolId poolId) external view returns (uint256) {
        uint256 start = startTime[poolId];
        return start == 0 ? 0 : start + MULTIPLIER_WINDOW;
    }

    // ---------------------------------------------------------------------------------------------
    // Enabled callbacks
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Records the launch time. Never reverts for the PoolManager, whatever the currencies.
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        startTime[key.toId()] = block.timestamp;
        return IHooks.afterInitialize.selector;
    }

    /// @inheritdoc IHooks
    /// @dev Credits the hookData address for the ETH side of the settled delta. Returns a zero
    /// delta in every path and never reverts once the PoolManager is the caller: a malformed
    /// hookData, a zero ETH leg or a non-ETH pool all fall through to a plain return.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata hookData)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        // Only pools whose currency0 is native ETH earn points; anything else is a no-op.
        if (!key.currency0.isAddressZero()) return (IHooks.afterSwap.selector, 0);

        address user = _creditedAddress(hookData);
        if (user == address(0)) return (IHooks.afterSwap.selector, 0);

        // The swapper's currency0 delta: negative means ETH paid in (a buy), positive ETH taken out
        // (a sell). Widened to int256 before negation so int128.min cannot overflow.
        int256 amount0 = delta.amount0();
        if (amount0 == 0) return (IHooks.afterSwap.selector, 0);

        uint256 eth;
        uint256 rate;
        if (amount0 < 0) {
            // casting to 'uint256' is safe because -amount0 is a positive int256 (int128.min widened first)
            // forge-lint: disable-next-line(unsafe-typecast)
            eth = uint256(-amount0);
            rate = BUY_RATE;
        } else {
            // casting to 'uint256' is safe because amount0 is strictly positive here
            // forge-lint: disable-next-line(unsafe-typecast)
            eth = uint256(amount0);
            rate = SELL_RATE;
        }

        PoolId poolId = key.toId();
        uint256 earned = eth * rate;
        // The launch window is a coarse 7-day calendar rule; second-level timestamp drift is intended to matter.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < startTime[poolId] + MULTIPLIER_WINDOW) earned *= LAUNCH_MULTIPLIER;

        uint256 total = _points[poolId][user] + earned;
        _points[poolId][user] = total;
        emit Points(poolId, user, earned, total);

        _updateTop(poolId, user, total);
        return (IHooks.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Disabled callbacks (the address does not carry their bits, so the PoolManager never calls them)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev The identity rule. Exactly 32 bytes that decode to a non-zero address; anything else
    /// (empty, other lengths, a word that does not fit in 160 bits, the zero address) is nobody.
    /// Implemented by hand instead of `abi.decode` so a dirty word cannot make afterSwap revert.
    function _creditedAddress(bytes calldata hookData) internal pure returns (address) {
        if (hookData.length != 32) return address(0);
        // casting to 'bytes32' is safe because the length was just checked to be exactly 32
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 word = uint256(bytes32(hookData));
        if (word > type(uint160).max) return address(0);
        // casting to 'uint160' is safe because the word was just bounded to 160 bits
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(word));
    }

    /// @dev O(TOP_N) leaderboard maintenance. The board is sorted descending and packed from the
    /// front. `total` is the user's new score, which only ever increases, so an existing entry can
    /// only move up. Strict comparisons keep an earlier address ahead on ties, and a newcomer must
    /// strictly beat the tenth entry to evict it.
    function _updateTop(PoolId poolId, address user, uint256 total) internal {
        address[10] storage board = _top[poolId];
        mapping(address => uint256) storage points = _points[poolId];

        uint256 pos = TOP_N; // sentinel: not on the board
        uint256 firstEmpty = TOP_N;
        for (uint256 i = 0; i < TOP_N; ++i) {
            address entry = board[i];
            if (entry == user) {
                pos = i;
                break;
            }
            if (entry == address(0)) {
                firstEmpty = i;
                break; // packed from the front: nothing beyond this slot
            }
        }

        bool inserted = false;
        if (pos == TOP_N) {
            if (firstEmpty < TOP_N) {
                pos = firstEmpty;
            } else {
                if (total <= points[board[TOP_N - 1]]) return; // does not beat the tenth
                pos = TOP_N - 1;
            }
            inserted = true;
        }

        // Bubble the hole at `pos` upward past every strictly-lower entry.
        uint256 hole = pos;
        while (hole > 0) {
            address above = board[hole - 1];
            if (points[above] >= total) break;
            board[hole] = above;
            unchecked {
                --hole;
            }
        }
        if (inserted || hole != pos) board[hole] = user;
    }
}
