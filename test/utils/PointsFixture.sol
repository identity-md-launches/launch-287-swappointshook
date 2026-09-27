// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Points} from "../../src/Points.sol";
import {SwapPointsHook} from "../../src/SwapPointsHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {HookMiner} from "../../src/HookMiner.sol";

/// @notice Shared scaffolding: a real PoolManager, the v4-core test routers, PNTS, and the hook at
/// a CREATE2 address mined for its flags, exactly as a deployer would place it.
abstract contract PointsFixture is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant BUY_RATE = 10_000;
    uint256 internal constant SELL_RATE = 5_000;
    uint256 internal constant WINDOW = 7 days;
    uint24 internal constant FEE = 3_000;
    int24 internal constant TICK_SPACING = 60;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    Points internal token;
    SwapPointsHook internal hook;
    PoolKey internal key;
    PoolId internal poolId;

    PoolSwapTest.TestSettings internal settings =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    receive() external payable {}

    function setUp() public virtual {
        // Tests start at a realistic timestamp so `block.timestamp < 7 days` cannot pass by accident.
        vm.warp(1_760_000_000);

        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        token = new Points();
        hook = deployHook(manager);

        token.approve(address(lpRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        vm.deal(address(this), 10_000_000 ether);

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
    }

    /// @dev Mines a salt for 0x1040 with this contract as the CREATE2 deployer and deploys there.
    function deployHook(IPoolManager pm) internal returns (SwapPointsHook deployed) {
        bytes memory creationCode = abi.encodePacked(type(SwapPointsHook).creationCode, abi.encode(address(pm)));
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HookFlags.SWAP_POINTS_HOOK, creationCode, 1_000_000);
        deployed = new SwapPointsHook{salt: salt}(pm);
        assertEq(address(deployed), predicted, "hook landed somewhere else");
        assertEq(HookFlags.flagsOf(address(deployed)), 0x1040, "address flags");
    }

    // --- pool setup -----------------------------------------------------------------------------

    function initPool(uint160 sqrtPriceX96) internal returns (int24 tick) {
        tick = manager.initialize(key, sqrtPriceX96);
    }

    /// @dev Two-sided full-range liquidity around the current price, ETH paid from this contract.
    function addFullRangeLiquidity(uint128 liquidity) internal returns (BalanceDelta delta) {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(TICK_SPACING),
            tickUpper: TickMath.maxUsableTick(TICK_SPACING),
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });
        // Over-fund the native leg; the router refunds whatever the position did not need.
        delta = lpRouter.modifyLiquidity{value: uint256(liquidity) * 2}(key, params, "");
    }

    /// @dev Initialises at 1:1 and seeds deep liquidity so exact-input swaps are always fully filled.
    function setUpLiquidPool() internal {
        initPool(SQRT_PRICE_1_1);
        addFullRangeLiquidity(1_000_000 ether);
    }

    // --- swaps (this contract is always the router's caller; identity comes from hookData) ------

    function hd(address user) internal pure returns (bytes memory) {
        return abi.encode(user);
    }

    function buyExactIn(uint256 ethIn, bytes memory hookData) internal returns (BalanceDelta) {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        return swapRouter.swap{value: ethIn}(key, params, settings, hookData);
    }

    function buyExactOut(uint256 pntsOut, uint256 maxEth, bytes memory hookData) internal returns (BalanceDelta) {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: int256(pntsOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        return swapRouter.swap{value: maxEth}(key, params, settings, hookData);
    }

    function sellExactIn(uint256 pntsIn, bytes memory hookData) internal returns (BalanceDelta) {
        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: -int256(pntsIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        return swapRouter.swap(key, params, settings, hookData);
    }

    function sellExactOut(uint256 ethOut, bytes memory hookData) internal returns (BalanceDelta) {
        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: int256(ethOut), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        return swapRouter.swap(key, params, settings, hookData);
    }

    // --- expectations ---------------------------------------------------------------------------

    function ethPaid(BalanceDelta delta) internal pure returns (uint256) {
        int256 a0 = delta.amount0();
        require(a0 < 0, "not a buy");
        return uint256(-a0);
    }

    function ethReceived(BalanceDelta delta) internal pure returns (uint256) {
        int256 a0 = delta.amount0();
        require(a0 > 0, "not a sell");
        return uint256(a0);
    }

    function buyPoints(uint256 eth, bool doubled) internal pure returns (uint256) {
        return eth * BUY_RATE * (doubled ? 2 : 1);
    }

    function sellPoints(uint256 eth, bool doubled) internal pure returns (uint256) {
        return eth * SELL_RATE * (doubled ? 2 : 1);
    }

    /// @dev Number of `Points` events among recorded logs, for "credits nobody" assertions.
    function countPointsEvents(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        bytes32 sig = keccak256("Points(bytes32,address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) ++n;
        }
    }

    function topUsers(PoolId id) internal view returns (address[10] memory users) {
        (users,) = hook.top10(id);
    }

    function topScores(PoolId id) internal view returns (uint256[10] memory scores) {
        (, scores) = hook.top10(id);
    }
}
