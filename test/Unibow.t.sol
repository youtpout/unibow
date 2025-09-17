// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {Deployers} from "./utils/Deployers.sol";

import {Unibow} from "../src/Unibow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract UnibowTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    PoolId poolId;

    Unibow hook;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    address borrower = address(0xBEEF);
    address lp = address(0xAAAA);

    function setUp() public {
        // Déploiement de tous les artefacts core/periphery
        deployArtifacts();

        (currency0, currency1) = deployCurrencyPair();

        // Déploiement du hook à une adresse avec flags Uniswap v4
        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144)
        );

        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("Unibow.sol:Unibow", constructorArgs, flags);
        hook = Unibow(flags);

        // Création d'une pool
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Ajout de liquidité full-range
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        (tokenId,) = hook.addLiquidity(poolKey, tickLower, tickUpper, 100e18, 150e18, lp);

        uint256 bal0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 bal1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(hook));

        console.log("bal0 hook 0", bal0);
        console.log("bal1 hook 0", bal1);
    }

    function testMintFails() public {
        vm.expectRevert();
        positionManager.mint(
            poolKey, -120, 120, 1e18, type(uint256).max, type(uint256).max, address(this), block.timestamp, ""
        );
    }

    function testLpCannotWithdrawBeforeUnlockButCanRebalance() public {
        // can't withdraw before 90 days
        vm.expectRevert();
        vm.prank(lp);
        hook.removeLiquidity(tokenId, 1);
    }

    function testBorrowAndRepayFlow() public {
        // Ask to borrow
        uint256 amountIn = 1e18;

        (uint256 loanId, uint256 balOut) = hook.loan(address(swapRouter), poolKey, amountIn, 1, true, borrower);
        console.log("balOut", balOut);

        uint256 bal0 = IERC20(Currency.unwrap(currency0)).balanceOf(borrower);
        uint256 bal1 = IERC20(Currency.unwrap(currency1)).balanceOf(borrower);

        console.log("bal0", bal0);
        console.log("bal1", bal1);

        bal0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        bal1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(hook));

        console.log("bal0 hook", bal0);
        console.log("bal1 hook", bal1);

        // reimbourse on swap
        (,,,,, bool zeroForOne,,, uint128 collateralAmount, uint128 borrowAmount) = hook.positions(loanId);
        deal(Currency.unwrap(currency1), borrower, borrowAmount);
        deal(Currency.unwrap(currency1), borrower, borrowAmount);

        vm.startPrank(borrower);
        bal0 = IERC20(Currency.unwrap(currency0)).balanceOf(borrower);
        bal1 = IERC20(Currency.unwrap(currency1)).balanceOf(borrower);

        console.log("bal0", bal0);
        console.log("bal1", bal1);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        console.log("borrowAmount", borrowAmount);
        console.log("collateralAmount", collateralAmount);
        // swapRouter.swapExactTokensForTokens({
        //     amountIn: borrowAmount,
        //     amountOutMin: collateralAmount,
        //     zeroForOne: !zeroForOne,
        //     poolKey: poolKey,
        //     hookData: abi.encode(Unibow.BorrowData({borrower: borrower, isBorrow: false, tokenId: loanId})),
        //     receiver: borrower,
        //     deadline: block.timestamp + 1
        // });
        hook.reimbourse(tokenId);
        vm.stopPrank();

        bal0 = IERC20(Currency.unwrap(currency0)).balanceOf(borrower);
        bal1 = IERC20(Currency.unwrap(currency1)).balanceOf(borrower);

        console.log("bal0", bal0);
        console.log("bal1", bal1);
    }

    // function testLoanDefaultAfterExpiration() public {
    //     uint256 amountIn = 50e18;
    //     swapRouter.swapExactTokensForTokens({
    //         amountIn: amountIn,
    //         amountOutMin: 1,
    //         zeroForOne: true,
    //         poolKey: poolKey,
    //         hookData: abi.encode(
    //             Unibow.BorrowData({
    //                 borrower: borrower,
    //                 isBorrow: true,
    //                 tokenIndex: 0,
    //                 durationSeconds: 0,
    //                 expectedOut: amountIn
    //             })
    //         ),
    //         receiver: borrower,
    //         deadline: block.timestamp + 1
    //     });

    //     // Avancer le temps > 60 jours
    //     vm.warp(block.timestamp + 61 days);

    //     // Repay doit échouer
    //     vm.expectRevert("repay window closed");
    //     vm.prank(borrower);
    //     hook.repayLoan(2);
    // }
}
