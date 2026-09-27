// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {SwapPointsHook} from "../src/SwapPointsHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @dev Stands in for the PoolManager so gas can be metered from inside a real call frame, with no
/// cheatcode overhead in the measurement.
contract ManagerStub {
    function drive(SwapPointsHook hook, PoolKey calldata key, int128 amount0, bytes calldata hookData)
        external
        returns (uint256 used)
    {
        SwapParams memory params = SwapParams(true, -1, 0);
        BalanceDelta delta = toBalanceDelta(amount0, 0);
        uint256 before = gasleft();
        hook.afterSwap(address(this), key, params, delta, hookData);
        used = before - gasleft();
    }
}

/// @notice Direct-callback tests. The "PoolManager" here is a pranked address, which lets every
/// delta, timestamp and hookData be chosen exactly; the pool-driven suite covers the real manager.
contract SwapPointsHookUnitTest is Test {
    uint256 constant BUY_RATE = 10_000;
    uint256 constant SELL_RATE = 5_000;

    address manager;
    SwapPointsHook hook;
    PoolKey key;
    PoolId poolId;
    uint256 t0;

    event Points(PoolId indexed poolId, address indexed user, uint256 earned, uint256 total);

    function setUp() public {
        vm.warp(1_760_000_000);
        t0 = block.timestamp;
        manager = address(new ManagerStub());

        bytes memory creationCode = abi.encodePacked(type(SwapPointsHook).creationCode, abi.encode(manager));
        (, bytes32 salt) = HookMiner.find(address(this), HookFlags.SWAP_POINTS_HOOK, creationCode, 1_000_000);
        hook = new SwapPointsHook{salt: salt}(IPoolManager(manager));

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(makeAddr("token")),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        vm.prank(manager);
        hook.afterInitialize(address(this), key, 0, 0);
    }

    function swapParams() internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
    }

    /// @dev Calls afterSwap as the manager with a crafted currency0 delta.
    function credit(int128 amount0, address user) internal {
        vm.prank(manager);
        hook.afterSwap(address(this), key, swapParams(), toBalanceDelta(amount0, 0), abi.encode(user));
    }

    function creditRaw(int128 amount0, bytes memory hookData) internal returns (bytes4 sel, int128 d) {
        vm.prank(manager);
        (sel, d) = hook.afterSwap(address(this), key, swapParams(), toBalanceDelta(amount0, 0), hookData);
    }

    function expected(int128 amount0, uint256 timestamp) internal view returns (uint256) {
        if (amount0 == 0) return 0;
        uint256 eth = amount0 < 0 ? uint256(-int256(amount0)) : uint256(int256(amount0));
        uint256 p = eth * (amount0 < 0 ? BUY_RATE : SELL_RATE);
        return timestamp < t0 + 7 days ? p * 2 : p;
    }

    // ---------------------------------------------------------------------------------------------
    // Arithmetic
    // ---------------------------------------------------------------------------------------------

    function test_buyAndSellUnits() public {
        credit(-0.001 ether, address(1));
        assertEq(hook.pointsOf(poolId, address(1)), 20 ether, "0.001 ETH buy: 10 points, doubled");

        credit(0.001 ether, address(2));
        assertEq(hook.pointsOf(poolId, address(2)), 10 ether, "0.001 ETH sell: 5 points, doubled");

        vm.warp(t0 + 7 days);
        credit(-0.001 ether, address(3));
        credit(0.001 ether, address(4));
        assertEq(hook.pointsOf(poolId, address(3)), 10 ether, "0.001 ETH buy after launch: 10 points");
        assertEq(hook.pointsOf(poolId, address(4)), 5 ether, "0.001 ETH sell after launch: 5 points");
    }

    function testFuzz_pointsFormula(int128 amount0, address user, uint256 dt) public {
        vm.assume(user != address(0));
        dt = bound(dt, 0, 365 days);
        vm.warp(t0 + dt);

        uint256 want = expected(amount0, block.timestamp);
        if (want > 0) {
            vm.expectEmit(true, true, true, true, address(hook));
            emit Points(poolId, user, want, want);
        }
        credit(amount0, user);
        assertEq(hook.pointsOf(poolId, user), want);
    }

    function test_multiplierBoundaryExact() public {
        vm.warp(t0 + 7 days - 1);
        credit(-1 ether, address(1));
        assertEq(hook.pointsOf(poolId, address(1)), 20_000 ether);

        vm.warp(t0 + 7 days);
        credit(-1 ether, address(2));
        assertEq(hook.pointsOf(poolId, address(2)), 10_000 ether);

        vm.warp(t0 + 7 days + 1);
        credit(1 ether, address(3));
        assertEq(hook.pointsOf(poolId, address(3)), 5_000 ether);
    }

    function test_extremeDeltasDoNotOverflow() public {
        credit(type(int128).min, address(1));
        assertEq(hook.pointsOf(poolId, address(1)), uint256(2 ** 127) * BUY_RATE * 2);
        credit(type(int128).max, address(2));
        assertEq(hook.pointsOf(poolId, address(2)), uint256(uint128(type(int128).max)) * SELL_RATE * 2);
    }

    // ---------------------------------------------------------------------------------------------
    // Never reverts for the manager
    // ---------------------------------------------------------------------------------------------

    function testFuzz_afterSwapNeverRevertsForTheManager(
        int128 amount0,
        int128 amount1,
        bytes memory hookData,
        uint64 dt,
        bool zeroForOne,
        int256 amountSpecified
    ) public {
        vm.warp(t0 + dt);
        SwapParams memory params = SwapParams(zeroForOne, amountSpecified, 0);
        vm.prank(manager);
        (bytes4 sel, int128 d) = hook.afterSwap(address(this), key, params, toBalanceDelta(amount0, amount1), hookData);
        assertEq(sel, IHooks.afterSwap.selector);
        assertEq(d, 0);
    }

    function testFuzz_afterSwapOnUninitialisedPoolIdNeverReverts(int128 amount0, address user) public {
        // Defensive: the manager cannot swap on a pool it never initialised, but the hook still
        // must not be the thing that reverts if it ever were.
        PoolKey memory other = PoolKey(key.currency0, Currency.wrap(makeAddr("other")), 500, 10, key.hooks);
        vm.prank(manager);
        (bytes4 sel,) = hook.afterSwap(address(this), other, swapParams(), toBalanceDelta(amount0, 0), abi.encode(user));
        assertEq(sel, IHooks.afterSwap.selector);
    }

    function testFuzz_afterInitializeNeverRevertsForTheManager(
        address sender,
        address c0,
        address c1,
        uint24 fee,
        int24 spacing,
        uint160 sqrtPrice,
        int24 tick
    ) public {
        PoolKey memory anyKey = PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, key.hooks);
        vm.prank(manager);
        bytes4 sel = hook.afterInitialize(sender, anyKey, sqrtPrice, tick);
        assertEq(sel, IHooks.afterInitialize.selector);
        assertEq(hook.startTime(anyKey.toId()), block.timestamp);
    }

    // ---------------------------------------------------------------------------------------------
    // Identity rule
    // ---------------------------------------------------------------------------------------------

    function testFuzz_hookDataOfWrongLengthCreditsNobody(bytes memory hookData) public {
        vm.assume(hookData.length != 32);
        vm.recordLogs();
        creditRaw(-1 ether, hookData);
        assertEq(vm.getRecordedLogs().length, 0, "no Points event");
    }

    function testFuzz_thirtyTwoByteHookData(bytes32 word) public {
        vm.recordLogs();
        creditRaw(-1 ether, abi.encodePacked(word));
        bool valid = uint256(word) <= type(uint160).max && word != bytes32(0);
        assertEq(vm.getRecordedLogs().length, valid ? 1 : 0);
        if (valid) assertEq(hook.pointsOf(poolId, address(uint160(uint256(word)))), 20_000 ether);
    }

    function test_zeroDeltaCreditsNobody() public {
        vm.recordLogs();
        creditRaw(0, abi.encode(address(1)));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(hook.pointsOf(poolId, address(1)), 0);
    }

    function test_nonEthPoolCreditsNobody() public {
        PoolKey memory erc20Key = PoolKey(Currency.wrap(makeAddr("weth")), key.currency1, 3_000, 60, key.hooks);
        vm.prank(manager);
        hook.afterInitialize(address(this), erc20Key, 0, 0);
        vm.recordLogs();
        vm.prank(manager);
        hook.afterSwap(address(this), erc20Key, swapParams(), toBalanceDelta(-1 ether, 0), abi.encode(address(1)));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(hook.pointsOf(erc20Key.toId(), address(1)), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Leaderboard
    // ---------------------------------------------------------------------------------------------

    function userAt(uint256 i) internal pure returns (address) {
        return address(uint160(0xA000 + i));
    }

    function board() internal view returns (address[10] memory users, uint256[10] memory scores) {
        return hook.top10(poolId);
    }

    function test_top10_fillsInOrderThenSorts() public {
        for (uint256 i = 0; i < 10; ++i) {
            credit(-int128(int256((i + 1) * 1e15)), userAt(i)); // userAt(9) highest
        }
        (address[10] memory users, uint256[10] memory scores) = board();
        for (uint256 i = 0; i < 10; ++i) {
            assertEq(users[i], userAt(9 - i));
            assertEq(scores[i], (10 - i) * 1e15 * BUY_RATE * 2);
        }
    }

    function test_top10_lastSlotClimbsToFirst() public {
        for (uint256 i = 0; i < 10; ++i) {
            credit(-int128(int256((10 - i) * 1e15)), userAt(i)); // userAt(0) highest, userAt(9) lowest
        }
        credit(-1 ether, userAt(9));
        (address[10] memory users,) = board();
        assertEq(users[0], userAt(9));
        for (uint256 i = 1; i < 10; ++i) {
            assertEq(users[i], userAt(i - 1));
        }
    }

    function test_top10_updateWithoutRankChangeKeepsOrder() public {
        credit(-3e15, userAt(0));
        credit(-2e15, userAt(1));
        credit(-1e15, userAt(2));
        credit(-1, userAt(1)); // still second
        (address[10] memory users,) = board();
        assertEq(users[0], userAt(0));
        assertEq(users[1], userAt(1));
        assertEq(users[2], userAt(2));
        assertEq(users[3], address(0));
    }

    function test_top10_evictionAndReentry() public {
        for (uint256 i = 0; i < 10; ++i) {
            credit(-int128(int256((10 - i) * 1e15)), userAt(i)); // userAt(9) is tenth with 20 points
        }
        credit(-1e15, userAt(10)); // equal to tenth: rejected
        (address[10] memory users,) = board();
        assertEq(users[9], userAt(9));

        credit(-1e15 + 1, userAt(11)); // one wei short: rejected
        (users,) = board();
        assertEq(users[9], userAt(9));

        credit(-1e15 - 1, userAt(12)); // one wei more: evicts userAt(9)
        (users,) = board();
        assertEq(users[8], userAt(8));
        assertEq(users[9], userAt(12));
        for (uint256 i = 0; i < 10; ++i) {
            assertTrue(users[i] != userAt(9), "evicted");
        }

        credit(-5e15, userAt(9)); // 6e15 worth: re-enters at position 4 (behind userAt(4) with 6e15, a tie)
        (users,) = board();
        assertEq(users[4], userAt(4));
        assertEq(users[5], userAt(9));
        assertEq(users[9], userAt(8));
    }

    function test_top10_tieBreaksFavourTheEarlierEntry() public {
        credit(-1e15, userAt(0));
        credit(-1e15, userAt(1));
        credit(-1e15, userAt(2));
        (address[10] memory users,) = board();
        assertEq(users[0], userAt(0));
        assertEq(users[1], userAt(1));
        assertEq(users[2], userAt(2));

        credit(-1e15, userAt(2)); // 2x: strictly ahead of both
        credit(-1e15, userAt(1)); // 2x: ties userAt(2), who got there first
        (users,) = board();
        assertEq(users[0], userAt(2));
        assertEq(users[1], userAt(1));
        assertEq(users[2], userAt(0));
    }

    /// @dev Random sequences over 14 users: the board must stay sorted, packed, duplicate-free,
    /// consistent with pointsOf, and contain every user that outscores the tenth.
    function testFuzz_top10_invariants(uint8[40] memory who, uint64[40] memory amount) public {
        for (uint256 s = 0; s < who.length; ++s) {
            uint256 u = who[s] % 14;
            int128 a = -int128(uint128(amount[s]) + 1);
            credit(a, userAt(u));
            checkBoard();
        }
    }

    function checkBoard() internal view {
        (address[10] memory users, uint256[10] memory scores) = board();
        uint256 filled = 0;
        while (filled < 10 && users[filled] != address(0)) ++filled;
        for (uint256 i = filled; i < 10; ++i) {
            assertEq(users[i], address(0), "packed");
            assertEq(scores[i], 0);
        }
        for (uint256 i = 0; i < filled; ++i) {
            assertEq(scores[i], hook.pointsOf(poolId, users[i]), "score matches pointsOf");
            assertGt(scores[i], 0);
            if (i > 0) assertGe(scores[i - 1], scores[i], "sorted");
            for (uint256 j = i + 1; j < filled; ++j) {
                assertTrue(users[i] != users[j], "no duplicates");
            }
        }
        uint256 tenth = filled == 10 ? scores[9] : 0;
        for (uint256 u = 0; u < 14; ++u) {
            uint256 p = hook.pointsOf(poolId, userAt(u));
            bool onBoard = false;
            for (uint256 i = 0; i < filled; ++i) {
                if (users[i] == userAt(u)) onBoard = true;
            }
            if (p > tenth) assertTrue(onBoard, "anyone above the tenth is on the board");
            if (p == 0) assertFalse(onBoard, "nobody with zero points is on the board");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Gas
    // ---------------------------------------------------------------------------------------------

    /// @dev Meters one afterSwap from inside the stub manager, with the hook's storage cooled so the
    /// numbers reflect a fresh transaction.
    function measure(int128 amount0, bytes memory hookData) internal returns (uint256 used) {
        vm.cool(address(hook));
        used = ManagerStub(manager).drive(hook, key, amount0, hookData);
    }

    /// @dev Measured on 0.8.26 / 200 optimizer runs / cold storage (see README for the table):
    /// no hookData ~5.3k, first credit on an empty board ~56k, repeat credit keeping rank ~19k,
    /// rejected newcomer on a full board ~59k, worst case (newcomer evicts the tenth and climbs to
    /// first) ~112k. The assertions are ceilings with headroom, not targets.
    function test_gas_afterSwapTiers() public {
        assertLt(measure(-1 ether, ""), 10_000, "no hookData");
        assertLt(measure(-1e15, abi.encode(userAt(0))), 70_000, "first credit, empty board");
        assertLt(measure(-1, abi.encode(userAt(0))), 25_000, "repeat credit, no rank change");

        for (uint256 i = 1; i < 10; ++i) {
            credit(-int128(int256((10 - i) * 1e15)), userAt(i));
        }
        assertLt(measure(-1, abi.encode(userAt(50))), 70_000, "newcomer below the tenth: tally + event only");
        assertLt(measure(-1, abi.encode(userAt(9))), 55_000, "existing tenth, no rank change");
        assertLt(measure(-1 ether, abi.encode(userAt(99))), 130_000, "newcomer evicts the tenth and climbs to first");
    }
}
