// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    
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

        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            lp,
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function testLpCannotWithdrawBeforeUnlockButCanRebalance() public {
        // LP a une position active (créée dans setUp)
        // Essaye de retirer immédiatement -> revert attendu
        vm.expectRevert("position locked");
        vm.prank(lp);
        positionManager.decreaseLiquidity(tokenId, 1e18, 0, 0, lp, block.timestamp, Constants.ZERO_BYTES);

        // LP rebalancing = ajoute encore de la liquidité
        uint128 addLiquidity = 50e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            addLiquidity
        );

        positionManager.increaseLiquidity(
            tokenId, addLiquidity, amount0Expected + 1, amount1Expected + 1, block.timestamp, Constants.ZERO_BYTES
        );

        // On pourrait ici checker dans hook.lpPositions que unlockTimestamp est +1 day
    }

    function testBorrowAndRepayFlow() public {
        // Borrower swap pour emprunter
        uint256 amountIn = 100e18;
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: abi.encode(
                Unibow.BorrowData({borrower:borrower, isBorrow: true, tokenIndex: 0, durationSeconds: 0, expectedOut: amountIn})
            ),
            receiver: borrower,
            deadline: block.timestamp + 1
        });

        assertEq(hook.nextLoanId(poolId), 1);

        // Remboursement dans la fenêtre
        vm.prank(borrower);
        hook.repayLoan(poolKey, 1);

        (,,,,,,, bool repaid,) = hook.loans(poolId, 1);
        assertTrue(repaid);
    }

    function testLoanDefaultAfterExpiration() public {
        uint256 amountIn = 50e18;
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: abi.encode(
                Unibow.BorrowData({borrower:borrower, isBorrow: true, tokenIndex: 0, durationSeconds: 0, expectedOut: amountIn})
            ),
            receiver: borrower,
            deadline: block.timestamp + 1
        });

        // Avancer le temps > 60 jours
        vm.warp(block.timestamp + 61 days);

        // Repay doit échouer
        vm.expectRevert("repay window closed");
        vm.prank(borrower);
        hook.repayLoan(poolKey, 1);
    }
}
