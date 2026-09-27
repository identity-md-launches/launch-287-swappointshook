// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {PointsFixture} from "./utils/PointsFixture.sol";

/// @notice Rehearses the launch the factory performs: initialise the ETH/PNTS pool at the manifest
/// price, seed one-sided PNTS liquidity, then make the first buy into a pool that holds no ETH.
/// Nothing the hook does may revert any of these steps.
contract LaunchRehearsalTest is PointsFixture {
    using StateLibrary for IPoolManager;

    /// @dev Rehearsal starting price: 1 ETH = 1,000,000 PNTS, i.e. sqrt(1e6) * 2^96. The real
    /// number comes from launch.json; the hook does not depend on it, and `test_otherPrices`
    /// rehearses a spread of alternatives.
    uint160 internal constant REHEARSAL_SQRT_PRICE_X96 = 79228162514264337593543950336000;
    /// @dev Half the supply, the kind of one-sided seed a factory places.
    uint256 internal constant SEED_PNTS = 500_000_000e18;

    int24 internal seedTickLower;
    int24 internal seedTickUpper;

    /// @dev Mirrors the factory: initialise, then place `SEED_PNTS` as PNTS-only liquidity strictly
    /// below the current price (currency1 sits below the price in v4), funded with zero ETH.
    function launch(uint160 sqrtPriceX96) internal returns (int24 tick) {
        tick = initPool(sqrtPriceX96);

        // Highest usable tick at or below the current one: the range [min, upper] holds only PNTS.
        int24 upper = (tick / TICK_SPACING) * TICK_SPACING;
        if (upper > tick) upper -= TICK_SPACING; // rounding toward zero on negatives
        seedTickLower = TickMath.minUsableTick(TICK_SPACING);
        seedTickUpper = upper;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(seedTickLower), TickMath.getSqrtPriceAtTick(seedTickUpper), SEED_PNTS
        );

        uint256 ethBefore = address(manager).balance;
        BalanceDelta seed = lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(seedTickLower, seedTickUpper, int256(uint256(liquidity)), bytes32(0)), ""
        );
        assertEq(seed.amount0(), 0, "the seed needs no ETH");
        assertLt(seed.amount1(), 0, "the seed is paid in PNTS");
        assertEq(address(manager).balance, ethBefore, "the pool holds no ETH after seeding");
    }

    function test_rehearsal_initialiseSeedAndFirstBuy() public {
        uint256 t0 = block.timestamp;
        int24 tick = launch(REHEARSAL_SQRT_PRICE_X96);

        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        assertEq(price, REHEARSAL_SQRT_PRICE_X96, "initialised at the manifest price");
        assertEq(hook.startTime(poolId), t0, "afterInitialize ran");
        assertEq(hook.multiplierEndsAt(poolId), t0 + 7 days);
        assertEq(
            IPoolManager(address(manager)).getLiquidity(poolId),
            0,
            "seed sits below the current tick, so no active liquidity yet"
        );
        assertEq(address(manager).balance, 0, "the pool holds no ETH");
        assertGt(tick, seedTickUpper - TICK_SPACING);

        // The first buy lands in an ETH-less pool.
        uint256 pntsBefore = token.balanceOf(address(this));
        BalanceDelta first = buyExactIn(0.01 ether, hd(alice));
        assertEq(ethPaid(first), 0.01 ether);
        assertGt(first.amount1(), 0, "the buyer received PNTS");
        assertEq(token.balanceOf(address(this)) - pntsBefore, uint256(int256(first.amount1())));
        assertEq(address(manager).balance, 0.01 ether, "the pool now holds the first ETH");
        assertEq(hook.pointsOf(poolId, alice), 200 ether, "0.01 ETH => 100 points, doubled");
        assertEq(topUsers(poolId)[0], alice);
        assertEq(topScores(poolId)[0], 200 ether);

        // Roughly the manifest price: 0.01 ETH buys about 10,000 PNTS less fee and impact.
        uint256 got = uint256(int256(first.amount1()));
        assertGt(got, 9_900e18);
        assertLt(got, 10_000e18);
    }

    function test_rehearsal_sellAfterTheFirstBuyReturnsEth() public {
        launch(REHEARSAL_SQRT_PRICE_X96);
        BalanceDelta buy = buyExactIn(1 ether, hd(alice));
        uint256 bought = uint256(int256(buy.amount1()));

        // bob sells half of what alice's buy pulled out; the pool pays from the ETH alice put in.
        BalanceDelta sell = sellExactIn(bought / 2, hd(bob));
        uint256 got = ethReceived(sell);
        assertGt(got, 0.49 ether);
        assertLt(got, 0.5 ether);
        assertEq(hook.pointsOf(poolId, bob), sellPoints(got, true));
        assertEq(address(manager).balance, 1 ether - got);
    }

    function test_rehearsal_exactOutputBothWays() public {
        launch(REHEARSAL_SQRT_PRICE_X96);

        BalanceDelta buy = buyExactOut(5_000e18, 1 ether, hd(alice));
        assertEq(buy.amount1(), 5_000e18);
        uint256 paid = ethPaid(buy);
        assertGt(paid, 0.005 ether, "fee and impact make it cost more than 0.005 ETH");
        assertEq(hook.pointsOf(poolId, alice), buyPoints(paid, true));

        BalanceDelta sell = sellExactOut(0.001 ether, hd(bob));
        assertEq(ethReceived(sell), 0.001 ether);
        assertEq(hook.pointsOf(poolId, bob), 10 ether, "0.001 ETH => 5 points, doubled");
    }

    function test_rehearsal_seedAndUnwindEarnNothing() public {
        launch(REHEARSAL_SQRT_PRICE_X96);
        assertEq(topUsers(poolId)[0], address(0), "seeding credits nobody");

        buyExactIn(0.1 ether, hd(alice));
        vm.recordLogs();
        // The LP unwinds its position: afterRemoveLiquidity is not enabled, nothing can block it.
        (uint128 liquidity,,) =
            IPoolManager(address(manager)).getPositionInfo(poolId, address(lpRouter), seedTickLower, seedTickUpper, 0);
        BalanceDelta out = lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(seedTickLower, seedTickUpper, -int256(uint256(liquidity)), bytes32(0)), ""
        );
        assertGt(out.amount0(), 0, "the LP takes the ETH out");
        assertGt(out.amount1(), 0, "and the remaining PNTS");
        assertEq(countPointsEvents(vm.getRecordedLogs()), 0);
    }

    function test_rehearsal_windowClosesSevenDaysAfterInitialise() public {
        uint256 t0 = block.timestamp;
        launch(REHEARSAL_SQRT_PRICE_X96);
        vm.warp(t0 + 7 days - 1);
        buyExactIn(0.001 ether, hd(alice));
        assertEq(hook.pointsOf(poolId, alice), 20 ether);
        vm.warp(t0 + 7 days);
        buyExactIn(0.001 ether, hd(alice));
        assertEq(hook.pointsOf(poolId, alice), 30 ether, "second buy earned 10, not 20");
    }

    function test_rehearsal_deployerSuppliesTheWholeSeed() public view {
        // What the factory checks before it launches: the token minted everything to it.
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(address(this)), 1_000_000_000e18);
        assertEq(token.decimals(), 18);
    }

    /// @dev The rehearsal is not price-specific: a spread of launch prices from 1 ETH = 100 PNTS to
    /// 1 ETH = 10^9 PNTS all initialise, seed and take a first buy.
    function testFuzz_otherPrices(uint8 exponent) public {
        exponent = uint8(bound(exponent, 1, 9));
        // sqrt(10^exponent) * 2^96 computed via ticks to stay in range.
        int24 approxTick = int24(int256(uint256(exponent) * 23_026)); // ln(10)/ln(1.0001)
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(approxTick);

        launch(sqrtPrice);
        BalanceDelta first = buyExactIn(0.01 ether, hd(alice));
        assertEq(ethPaid(first), 0.01 ether);
        assertGt(first.amount1(), 0);
        assertEq(hook.pointsOf(poolId, alice), 200 ether);
    }
}
