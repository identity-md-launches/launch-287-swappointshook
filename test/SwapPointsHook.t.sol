// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PointsFixture} from "./utils/PointsFixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {SwapPointsHook} from "../src/SwapPointsHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @dev Executes CREATE2 from its own address so a failing constructor surfaces as a plain revert.
contract Create2Helper {
    function deploy(bytes32 salt, bytes memory creationCode) external returns (address at) {
        assembly ("memory-safe") {
            at := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        require(at != address(0), "create2 failed");
    }
}

/// @notice Behaviour of SwapPointsHook driven through a real PoolManager and the v4-core routers.
contract SwapPointsHookTest is PointsFixture {
    event Points(PoolId indexed poolId, address indexed user, uint256 earned, uint256 total);

    // ---------------------------------------------------------------------------------------------
    // Permissions and construction
    // ---------------------------------------------------------------------------------------------

    function test_permissions_exactlyAfterInitializeAndAfterSwap() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    function test_addressCarriesExactlyTheDeclaredBits() public view {
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.AFTER_INITIALIZE | HookFlags.AFTER_SWAP);
        assertEq(HookFlags.flagsOf(address(hook)), 0x1040);
        assertTrue(HookFlags.matches(address(hook), HookFlags.SWAP_POINTS_HOOK));
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_constructor_revertsAtAnUnminedAddress() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SwapPointsHook(manager);
    }

    function test_constructor_revertsWhenTheAddressCarriesAnExtraBit() public {
        Create2Helper helper = new Create2Helper();
        bytes memory creationCode = abi.encodePacked(type(SwapPointsHook).creationCode, abi.encode(address(manager)));
        uint160 wrong = HookFlags.SWAP_POINTS_HOOK | HookFlags.BEFORE_SWAP;
        (address predicted, bytes32 salt) = HookMiner.find(address(helper), wrong, creationCode, 1_000_000);
        assertEq(HookFlags.flagsOf(predicted), wrong);
        vm.expectRevert("create2 failed");
        helper.deploy(salt, creationCode);
    }

    function test_constructor_revertsWhenTheAddressLacksABit() public {
        Create2Helper helper = new Create2Helper();
        bytes memory creationCode = abi.encodePacked(type(SwapPointsHook).creationCode, abi.encode(address(manager)));
        (, bytes32 salt) = HookMiner.find(address(helper), HookFlags.AFTER_SWAP, creationCode, 1_000_000);
        vm.expectRevert("create2 failed");
        helper.deploy(salt, creationCode);
    }

    function test_constants() public view {
        assertEq(hook.BUY_RATE(), 10_000);
        assertEq(hook.SELL_RATE(), 5_000);
        assertEq(hook.MULTIPLIER_WINDOW(), 7 days);
        assertEq(hook.LAUNCH_MULTIPLIER(), 2);
        assertEq(hook.TOP_N(), 10);
    }

    // ---------------------------------------------------------------------------------------------
    // Caller restrictions
    // ---------------------------------------------------------------------------------------------

    function test_afterInitialize_rejectsNonPoolManager() public {
        vm.expectRevert(SwapPointsHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);

        vm.prank(alice);
        vm.expectRevert(SwapPointsHook.NotPoolManager.selector);
        hook.afterInitialize(alice, key, SQRT_PRICE_1_1, 0);
        assertEq(hook.startTime(poolId), 0, "a stranger set startTime");
    }

    function test_afterSwap_rejectsNonPoolManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        BalanceDelta delta = toBalanceDelta(-1 ether, 1 ether);

        vm.expectRevert(SwapPointsHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, delta, hd(alice));

        vm.prank(address(swapRouter));
        vm.expectRevert(SwapPointsHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, delta, hd(alice));
        assertEq(hook.pointsOf(poolId, alice), 0, "a stranger minted points");
    }

    function test_disabledCallbacks_revert() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        SwapParams memory sp = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        BalanceDelta zero = toBalanceDelta(0, 0);

        vm.startPrank(address(manager));
        vm.expectRevert(SwapPointsHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(SwapPointsHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(SwapPointsHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(SwapPointsHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(SwapPointsHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(SwapPointsHook.HookNotImplemented.selector);
        hook.beforeSwap(address(this), key, sp, "");
        vm.expectRevert(SwapPointsHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(SwapPointsHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------------------------------

    function test_afterInitialize_storesStartTimeAndWindowEnd() public {
        assertEq(hook.startTime(poolId), 0);
        assertEq(hook.multiplierEndsAt(poolId), 0, "unknown pool has no window");

        uint256 t0 = block.timestamp;
        initPool(SQRT_PRICE_1_1);
        assertEq(hook.startTime(poolId), t0);
        assertEq(hook.multiplierEndsAt(poolId), t0 + 7 days);
    }

    function test_liquidityAddAndRemove_areNotGated() public {
        initPool(SQRT_PRICE_1_1);
        addFullRangeLiquidity(1_000 ether);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(TICK_SPACING),
            tickUpper: TickMath.maxUsableTick(TICK_SPACING),
            liquidityDelta: -int256(1_000 ether),
            salt: bytes32(0)
        });
        BalanceDelta delta = lpRouter.modifyLiquidity(key, params, "");
        assertGt(delta.amount0(), 0);
        assertGt(delta.amount1(), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Rates: buys and sells, exact-in and exact-out (all inside the 2x window)
    // ---------------------------------------------------------------------------------------------

    function test_buyExactIn_earnsEthTimes10000Doubled() public {
        setUpLiquidPool();
        uint256 ethIn = 1 ether;

        vm.expectEmit(true, true, true, true, address(hook));
        emit Points(poolId, alice, buyPoints(ethIn, true), buyPoints(ethIn, true));
        BalanceDelta delta = buyExactIn(ethIn, hd(alice));

        assertEq(ethPaid(delta), ethIn, "exact-in should settle the full amount");
        assertGt(delta.amount1(), 0, "buyer got PNTS");
        assertEq(hook.pointsOf(poolId, alice), 20_000 ether, "1 ETH => 20,000 points during launch");
    }

    function test_buyExactOut_earnsOnEthActuallyPaid() public {
        setUpLiquidPool();
        uint256 pntsOut = 1_000 ether;

        BalanceDelta delta = buyExactOut(pntsOut, 1_100 ether, hd(alice));
        assertEq(delta.amount1(), int256(pntsOut), "exact-out delivers the requested PNTS");
        uint256 paid = ethPaid(delta);
        assertGt(paid, pntsOut, "fee makes the ETH cost exceed 1:1");
        assertEq(hook.pointsOf(poolId, alice), buyPoints(paid, true));
    }

    function test_sellExactIn_earnsEthTimes5000Doubled() public {
        setUpLiquidPool();
        uint256 pntsIn = 1_000 ether;

        BalanceDelta delta = sellExactIn(pntsIn, hd(bob));
        assertEq(delta.amount1(), -int256(pntsIn));
        uint256 received = ethReceived(delta);
        assertLt(received, pntsIn, "fee makes ETH out fall short of 1:1");
        assertEq(hook.pointsOf(poolId, bob), sellPoints(received, true));
    }

    function test_sellExactOut_earnsOnEthActuallyReceived() public {
        setUpLiquidPool();
        uint256 ethOut = 0.5 ether;

        vm.expectEmit(true, true, true, true, address(hook));
        emit Points(poolId, bob, sellPoints(ethOut, true), sellPoints(ethOut, true));
        BalanceDelta delta = sellExactOut(ethOut, hd(bob));

        assertEq(ethReceived(delta), ethOut);
        assertEq(hook.pointsOf(poolId, bob), 5_000 ether, "0.5 ETH => 5,000 points during launch");
    }

    function test_pointsAccumulateAcrossSwaps() public {
        setUpLiquidPool();
        buyExactIn(0.001 ether, hd(alice)); // 10 points doubled = 20
        buyExactIn(0.002 ether, hd(alice)); // 20 points doubled = 40
        BalanceDelta sell = sellExactIn(1 ether, hd(alice));
        uint256 expected = 60 ether + sellPoints(ethReceived(sell), true);

        vm.expectEmit(true, true, true, true, address(hook));
        emit Points(poolId, alice, 20 ether, expected + 20 ether);
        buyExactIn(0.001 ether, hd(alice));
        assertEq(hook.pointsOf(poolId, alice), expected + 20 ether);
    }

    function test_dustBuy_oneWeiEarnsTwentyThousandUnits() public {
        setUpLiquidPool();
        BalanceDelta delta = buyExactIn(1, hd(alice));
        assertEq(delta.amount0(), -1);
        assertEq(hook.pointsOf(poolId, alice), 20_000, "1 wei * 10,000 * 2");
    }

    function test_dustSell_thatReturnsNoEthEarnsNothing() public {
        setUpLiquidPool();
        vm.recordLogs();
        BalanceDelta delta = sellExactIn(1, hd(alice));
        assertEq(delta.amount0(), 0, "1 wei of PNTS buys no ETH after the fee");
        assertEq(hook.pointsOf(poolId, alice), 0);
        assertEq(countPointsEvents(vm.getRecordedLogs()), 0);
    }

    function test_dustSellExactOut_oneWeiEarnsTenThousandUnits() public {
        setUpLiquidPool();
        BalanceDelta delta = sellExactOut(1, hd(alice));
        assertEq(delta.amount0(), 1);
        assertEq(hook.pointsOf(poolId, alice), 10_000, "1 wei * 5,000 * 2");
    }

    // ---------------------------------------------------------------------------------------------
    // Multiplier boundary
    // ---------------------------------------------------------------------------------------------

    function test_multiplier_doubledUntilTheLastSecond() public {
        uint256 t0 = block.timestamp;
        setUpLiquidPool();

        vm.warp(t0 + 7 days - 1);
        buyExactIn(1 ether, hd(alice));
        assertEq(hook.pointsOf(poolId, alice), 20_000 ether, "still 2x one second before the end");
    }

    function test_multiplier_singleExactlyAtSevenDays() public {
        uint256 t0 = block.timestamp;
        setUpLiquidPool();

        uint256 windowEnd = t0 + 7 days;
        vm.warp(windowEnd);
        buyExactIn(1 ether, hd(alice));
        assertEq(hook.pointsOf(poolId, alice), 10_000 ether, "1x exactly at startTime + 7 days");
        assertEq(hook.multiplierEndsAt(poolId), windowEnd);
    }

    function test_multiplier_singleForSellsAfterTheWindow() public {
        uint256 t0 = block.timestamp;
        setUpLiquidPool();
        vm.warp(t0 + 30 days);
        BalanceDelta delta = sellExactOut(1 ether, hd(bob));
        assertEq(ethReceived(delta), 1 ether);
        assertEq(hook.pointsOf(poolId, bob), 5_000 ether);
    }

    function test_multiplier_isPerPoolStartTime() public {
        // A second ETH pool opened later has its own window.
        uint256 t0 = block.timestamp;
        setUpLiquidPool();
        uint256 t1 = t0 + 6 days;
        vm.warp(t1);
        PoolKey memory late = PoolKey(key.currency0, key.currency1, 500, 10, key.hooks);
        manager.initialize(late, SQRT_PRICE_1_1);
        assertEq(hook.multiplierEndsAt(late.toId()), t1 + 7 days);
        assertEq(hook.multiplierEndsAt(poolId), t0 + 7 days);
    }

    // ---------------------------------------------------------------------------------------------
    // Identity rule and hookData
    // ---------------------------------------------------------------------------------------------

    function test_noHookData_creditsNobody() public {
        setUpLiquidPool();
        vm.recordLogs();
        BalanceDelta delta = buyExactIn(1 ether, "");
        assertEq(ethPaid(delta), 1 ether, "the swap itself still happens");
        assertEq(countPointsEvents(vm.getRecordedLogs()), 0);
        assertEq(hook.pointsOf(poolId, address(this)), 0, "the caller is not credited");
        assertEq(hook.pointsOf(poolId, address(swapRouter)), 0, "the router is not credited");
        assertEq(topUsers(poolId)[0], address(0), "leaderboard untouched");
    }

    function test_malformedHookData_creditsNobodyAndNeverReverts() public {
        setUpLiquidPool();
        bytes[] memory bad = new bytes[](6);
        bad[0] = abi.encodePacked(alice); // 20 bytes
        bad[1] = abi.encodePacked(bytes31(bytes32(uint256(uint160(alice))))); // 31 bytes
        bad[2] = abi.encodePacked(abi.encode(alice), bytes1(0x01)); // 33 bytes
        bad[3] = abi.encode(alice, uint256(1)); // 64 bytes
        bad[4] = abi.encode(address(0)); // zero address
        bad[5] = abi.encodePacked(bytes12(0xffffffffffffffffffffffff), alice); // dirty upper bits

        vm.recordLogs();
        for (uint256 i = 0; i < bad.length; ++i) {
            buyExactIn(0.01 ether, bad[i]);
        }
        assertEq(countPointsEvents(vm.getRecordedLogs()), 0);
        assertEq(hook.pointsOf(poolId, alice), 0);
        assertEq(hook.pointsOf(poolId, address(0)), 0);
    }

    function test_hookDataIsUnauthenticated_anyoneCanCreditAnyone() public {
        setUpLiquidPool();
        // The caller of the router is this contract, yet bob is credited.
        buyExactIn(1 ether, hd(bob));
        assertEq(hook.pointsOf(poolId, bob), 20_000 ether);
        assertEq(hook.pointsOf(poolId, address(this)), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Non-ETH pools and pool isolation
    // ---------------------------------------------------------------------------------------------

    function test_nonEthCurrency0_swapsWorkAndEarnNothing() public {
        MockERC20 a = new MockERC20("A", "A", 1_000_000 ether);
        MockERC20 b = new MockERC20("B", "B", 1_000_000 ether);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        t0.approve(address(lpRouter), type(uint256).max);
        t1.approve(address(lpRouter), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);

        PoolKey memory erc20Key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolId erc20Id = erc20Key.toId();

        uint256 t = block.timestamp;
        manager.initialize(erc20Key, SQRT_PRICE_1_1);
        assertEq(hook.startTime(erc20Id), t, "startTime is recorded for every pool");

        lpRouter.modifyLiquidity(
            erc20Key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 100_000 ether, bytes32(0)
            ),
            ""
        );

        vm.recordLogs();
        BalanceDelta d1 =
            swapRouter.swap(erc20Key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), settings, hd(alice));
        BalanceDelta d2 =
            swapRouter.swap(erc20Key, SwapParams(false, 1 ether, TickMath.MAX_SQRT_PRICE - 1), settings, hd(alice));
        assertEq(d1.amount0(), -1 ether, "the swap is unaffected");
        assertEq(d2.amount0(), 1 ether, "the swap is unaffected");
        assertEq(countPointsEvents(vm.getRecordedLogs()), 0);
        assertEq(hook.pointsOf(erc20Id, alice), 0);
        assertEq(topUsers(erc20Id)[0], address(0));
    }

    function test_pointsAreKeyedByPool() public {
        setUpLiquidPool();
        // Second ETH pool on the same hook with a different token: earns on its own tally.
        MockERC20 other = new MockERC20("Other", "OTH", 10_000_000 ether);
        other.approve(address(lpRouter), type(uint256).max);
        other.approve(address(swapRouter), type(uint256).max);
        PoolKey memory otherKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(other)), 500, 10, key.hooks);
        manager.initialize(otherKey, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity{value: 2_000_000 ether}(
            otherKey,
            ModifyLiquidityParams(TickMath.minUsableTick(10), TickMath.maxUsableTick(10), 1_000_000 ether, bytes32(0)),
            ""
        );

        buyExactIn(1 ether, hd(alice));
        swapRouter.swap{value: 2 ether}(
            otherKey, SwapParams(true, -2 ether, TickMath.MIN_SQRT_PRICE + 1), settings, hd(alice)
        );

        assertEq(hook.pointsOf(poolId, alice), 20_000 ether);
        assertEq(hook.pointsOf(otherKey.toId(), alice), 40_000 ether);
        assertEq(topUsers(poolId)[0], alice);
        assertEq(topScores(otherKey.toId())[0], 40_000 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Leaderboard through the pool
    // ---------------------------------------------------------------------------------------------

    function test_top10_insertionSortsByPoints() public {
        setUpLiquidPool();
        buyExactIn(1 ether, hd(alice));
        buyExactIn(3 ether, hd(bob));
        buyExactIn(2 ether, hd(carol));

        address[10] memory users = topUsers(poolId);
        uint256[10] memory scores = topScores(poolId);
        assertEq(users[0], bob);
        assertEq(users[1], carol);
        assertEq(users[2], alice);
        assertEq(users[3], address(0));
        assertEq(scores[0], 60_000 ether);
        assertEq(scores[1], 40_000 ether);
        assertEq(scores[2], 20_000 ether);
        assertEq(scores[3], 0);
    }

    function test_top10_updateMovesAnExistingEntryUp() public {
        setUpLiquidPool();
        buyExactIn(1 ether, hd(alice));
        buyExactIn(3 ether, hd(bob));
        buyExactIn(2 ether, hd(carol));

        buyExactIn(3 ether, hd(alice)); // alice: 80,000 > bob: 60,000
        address[10] memory users = topUsers(poolId);
        assertEq(users[0], alice);
        assertEq(users[1], bob);
        assertEq(users[2], carol);
        assertEq(topScores(poolId)[0], 80_000 ether);
    }

    function test_top10_tiesKeepTheEarlierAddressAhead() public {
        setUpLiquidPool();
        buyExactIn(1 ether, hd(alice));
        buyExactIn(1 ether, hd(bob)); // ties alice, arrived later
        address[10] memory users = topUsers(poolId);
        assertEq(users[0], alice);
        assertEq(users[1], bob);

        buyExactIn(1 ether, hd(carol)); // 20,000, ties both
        buyExactIn(1 ether, hd(carol)); // 40,000, now strictly ahead
        buyExactIn(1 ether, hd(bob)); // 40,000, ties carol but carol got there first
        users = topUsers(poolId);
        assertEq(users[0], carol);
        assertEq(users[1], bob);
        assertEq(users[2], alice);
    }

    function test_top10_evictsTheLowestOnlyWhenStrictlyBeaten() public {
        setUpLiquidPool();
        address[] memory users = new address[](12);
        for (uint256 i = 0; i < 12; ++i) {
            users[i] = address(uint160(0x1000 + i));
        }
        // Ten users with 10, 9, ..., 1 units of 0.001 ETH: user[0] has the most.
        for (uint256 i = 0; i < 10; ++i) {
            buyExactIn((10 - i) * 0.001 ether, hd(users[i]));
        }
        address[10] memory board = topUsers(poolId);
        for (uint256 i = 0; i < 10; ++i) {
            assertEq(board[i], users[i]);
        }

        // Newcomer equal to the tenth (0.001 ETH => 20 points) is not admitted.
        buyExactIn(0.001 ether, hd(users[10]));
        board = topUsers(poolId);
        assertEq(board[9], users[9]);
        assertEq(hook.pointsOf(poolId, users[10]), 20 ether, "points are still tallied off-board");

        // Newcomer strictly above the tenth replaces it and lands in the right spot.
        buyExactIn(0.0055 ether, hd(users[11])); // 110 points: between user[4] (120) and user[5] (100)
        board = topUsers(poolId);
        assertEq(board[4], users[4]);
        assertEq(board[5], users[11]);
        assertEq(board[6], users[5]);
        assertEq(board[9], users[8]);
        assertEq(hook.pointsOf(poolId, users[9]), 20 ether, "evicted user keeps points");

        // The evicted user can come back by earning enough.
        buyExactIn(0.02 ether, hd(users[9])); // 420 points total: top of the board
        board = topUsers(poolId);
        assertEq(board[0], users[9]);
        assertEq(board[1], users[0]);
        assertEq(board[9], users[7]);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzzed sizes through the pool
    // ---------------------------------------------------------------------------------------------

    function testFuzz_buyExactIn(uint256 ethIn, bool afterWindow) public {
        ethIn = bound(ethIn, 1, 50_000 ether);
        uint256 t0 = block.timestamp;
        setUpLiquidPool();
        if (afterWindow) vm.warp(t0 + 7 days);

        BalanceDelta delta = buyExactIn(ethIn, hd(alice));
        assertEq(ethPaid(delta), ethIn);
        assertEq(hook.pointsOf(poolId, alice), buyPoints(ethIn, !afterWindow));
    }

    function testFuzz_buyExactOut(uint256 pntsOut) public {
        pntsOut = bound(pntsOut, 1, 50_000 ether);
        setUpLiquidPool();

        BalanceDelta delta = buyExactOut(pntsOut, 200_000 ether, hd(alice));
        assertEq(delta.amount1(), int256(pntsOut));
        assertEq(hook.pointsOf(poolId, alice), buyPoints(ethPaid(delta), true));
    }

    function testFuzz_sellExactIn(uint256 pntsIn, bool afterWindow) public {
        pntsIn = bound(pntsIn, 1_000, 50_000 ether);
        uint256 t0 = block.timestamp;
        setUpLiquidPool();
        if (afterWindow) vm.warp(t0 + 7 days);

        BalanceDelta delta = sellExactIn(pntsIn, hd(bob));
        assertEq(delta.amount1(), -int256(pntsIn));
        assertEq(hook.pointsOf(poolId, bob), sellPoints(ethReceived(delta), !afterWindow));
    }

    function testFuzz_sellExactOut(uint256 ethOut) public {
        ethOut = bound(ethOut, 1, 50_000 ether);
        setUpLiquidPool();

        BalanceDelta delta = sellExactOut(ethOut, hd(bob));
        assertEq(ethReceived(delta), ethOut);
        assertEq(hook.pointsOf(poolId, bob), sellPoints(ethOut, true));
    }

    function testFuzz_roundTripFarmsPointsAtTheCostOfFees() public {
        // Documents the wash-trading property: a round trip earns points and loses only the LP fee.
        setUpLiquidPool();
        uint256 ethBefore = address(this).balance;
        BalanceDelta buy = buyExactIn(1 ether, hd(alice));
        BalanceDelta sell = sellExactIn(uint256(int256(buy.amount1())), hd(alice));
        uint256 ethAfter = address(this).balance;

        assertLt(ethAfter, ethBefore, "the round trip costs fees");
        assertGt(ethAfter, ethBefore - 0.01 ether, "but less than 1%");
        assertEq(hook.pointsOf(poolId, alice), buyPoints(1 ether, true) + sellPoints(ethReceived(sell), true));
    }
}
