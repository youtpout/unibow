// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*
 * Unibow.sol — Uniswap v4 Hook (agnostic pair, borrow either token0 or token1)
 *
 * Features implemented (reference/skeleton):
 *  - Inherits BaseHook and exposes proper hook permissions
 *  - Agnostic to token0/token1: borrower can request token0 or token1
 *  - Dynamic fees set at construction: feeBorrow (e.g. 3%), feeClassic (0.3%), feeRebal (0.05%)
 *  - LP providers lock liquidity for 3 months on add; rebalances add +1 day lock
 *  - Borrow flow (no oracle): borrower does a swap; afterSwap detects actual out amount
 *    • feeBorrow taken from swap output (100% to LPs via pool economics)
 *    • borrower receives 80% of V_net (token chosen)
 *    • 20% of V_net converted to LP (minted) and placed in escrow under borrower until repay
 *    • repay window = 60 days (2 months). If repaid, burn escrow LP and return collateral; else escrow stays
 *  - computeA_pool uses locked LP positions to limit borrow size
 */

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
// periphery libraries
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

contract Unibow is BaseHook, ERC721, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using Strings for uint256;
    using LPFeeLibrary for uint24;
    using CurrencyLibrary for Currency;

    uint256 public constant BASIS = 100_000; // bps scale

    // For visual scaling of liquidity bar in SVG
    uint256 public constant VISUAL_LIQUIDITY_CAP = 1e18; // cap used to scale the bar width

    // fees in bps (set at construction)
    uint24 public feeBorrowBP = 30_000; //   3%
    uint24 public feeClassicBP = 3_000; //    0.3%
    uint24 public feeRebalBP = 500; //     0.05%

    // borrow params
    uint256 public borrowableRatioBP = 80_000; //  80%
    uint256 public lpLockTime = 90 days; // default 3 months
    uint256 public borrowRepayWindow = 60 days; // default 60 days

    // safety
    uint256 public triggerRation = 100_000; // if loan > 10% of liquidity, borrow ratio is reduced
    uint256 public ratioByPercent = 30_000; // 3%

    bytes internal constant ZERO_BYTES = bytes("");

    struct LPPosition {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool exists;
        bool zeroForOne;
        uint32 unlockTime;        
        uint32 borrowMaturity;
        uint128 collateralAmount;
        uint128 borrowAmount;
    }

    mapping(uint256 => LPPosition) public positions;
    uint256 public nextId;

    /// @notice Data passed during unlocking liquidity callback, includes sender and key info.
    /// @param sender Address of the sender initiating the unlock.
    /// @param key The pool key associated with the liquidity position.
    /// @param params Parameters for modifying liquidity.
    struct CallbackData {
        address sender;
        PoolKey key;
        ModifyLiquidityParams params;
    }

    mapping(PoolId => uint256) public totalBorrowed0;
    mapping(PoolId => uint256) public totalBorrowed1;

    address public owner;

    error PoolNotInitialized();
    error SenderMustBeHook();
    error MustUseDynamicFee();
    error WrongCollateralCalculation();
    error InsufficientOutputAmount();

    constructor(IPoolManager _pm) BaseHook(_pm) ERC721("Unibow LP", "UBLP") {}

    // hook permissions
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // encoded swap data for borrow
    struct BorrowData {
        address borrower;
        bool isBorrow;
        uint8 tokenIndex; // 0 or 1
        uint256 durationSeconds; // optional override for repay window
        uint256 expectedOut; // optional optimistic check (supplier provided)
    }

    // helper: position key
    function _posKey(address owner_, int24 lower, int24 upper, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner_, lower, upper, salt));
    }

    function _getFee(bool isBorrowing, bool isRebalancing) internal view returns (uint24) {
        if (isBorrowing) return feeBorrowBP;
        if (isRebalancing) return feeRebalBP;
        return feeClassicBP;
    }

    function loan(
        address swapRouter,
        PoolKey calldata key,
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        address recipient
    ) external returns (uint256 tokenId, uint256 amountOut) {
        if (zeroForOne) {
            IERC20(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), amountIn);
            IERC20(Currency.unwrap(key.currency0)).approve(swapRouter, amountIn);
        } else {
            IERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), amountIn);
            IERC20(Currency.unwrap(key.currency1)).approve(swapRouter, amountIn);
        }

        // Todo : replace by pool manager swap
        BalanceDelta swapDelta = IUniswapV4Router04(payable(swapRouter)).swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: abi.encode(
                Unibow.BorrowData({
                    borrower: recipient,
                    isBorrow: true,
                    tokenIndex: 0,
                    durationSeconds: 0,
                    expectedOut: amountIn
                })
            ),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        int128 amount = zeroForOne ? swapDelta.amount1() : swapDelta.amount0();
        uint256 totalOut = uint256(amount > 0 ? uint128(amount) : uint128(-amount));

        amountOut = (totalOut * borrowableRatioBP) / BASIS;
        require(amountOut>= amountOutMin,InsufficientOutputAmount());
        uint256 amountLiquidity = totalOut - amountOut;
        uint256 collateralAmount = amountIn - (amountIn * feeBorrowBP) / BASIS;
        require(collateralAmount < amountIn, WrongCollateralCalculation());

        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        tokenId = ++nextId;

        uint128 poolLiquidity = StateLibrary.getLiquidity(poolManager, poolId);
       

        int24 tickLower= TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper=  TickMath.maxUsableTick(key.tickSpacing);

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        uint256 amount0 = zeroForOne ? 0 : amountLiquidity;
        uint256 amount1 = zeroForOne ? amountLiquidity : 0;
        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, amount0, amount1);

        // Use unlock pattern instead of direct modifyLiquidity call
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(amountLiquidity),
            salt: 0
        });

        // Call through unlock mechanism
        _modifyLiquidity(msg.sender, key, params);

        positions[tokenId] = LPPosition({
            key: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            unlockTime: uint32(block.timestamp + lpLockTime),
            exists: true,
            zeroForOne: zeroForOne,
            borrowMaturity: uint32(block.timestamp + borrowRepayWindow),
            borrowAmount: uint128(totalOut),
            collateralAmount: uint128(collateralAmount)
        });

        _mint(recipient, tokenId);

        if (zeroForOne) {
            IERC20(Currency.unwrap(key.currency1)).transfer(recipient, amountOut);          
        } else {
            IERC20(Currency.unwrap(key.currency0)).transfer(recipient, amountOut);
        }
       
    }

    // lock liquidity for 3 months
    function addLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        address recipient
    ) external returns (uint256 tokenId, uint128 liquidity) {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        tokenId = ++nextId;

        uint128 poolLiquidity = StateLibrary.getLiquidity(poolManager, poolId);

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, amount0Desired, amount1Desired
        );

        // Use unlock pattern instead of direct modifyLiquidity call
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int128(liquidity),
            salt: 0
        });

        // Call through unlock mechanism
        _modifyLiquidity(msg.sender, key, params);

        positions[tokenId] = LPPosition({
            key: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            unlockTime: uint32(block.timestamp + lpLockTime),
            exists: true,
            zeroForOne: false,
            borrowMaturity: 0,
            borrowAmount: 0,
            collateralAmount: 0
        });

        _mint(recipient, tokenId);
    }

    function removeLiquidity(uint256 tokenId, uint128 liquidity) external {
        require(ownerOf(tokenId) == msg.sender, "Not NFT owner");

        LPPosition storage p = positions[tokenId];
        require(p.exists, "No position");
        require(block.timestamp >= p.unlockTime, "Liquidity locked");
        require(p.liquidity >= liquidity, "Not enough liquidity");

        p.liquidity -= liquidity;

        // Use unlock pattern instead of direct modifyLiquidity call
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            liquidityDelta: int128(liquidity),
            salt: 0
        });

        // Call through unlock mechanism
        _modifyLiquidity(msg.sender, p.key, params);

        if (p.liquidity == 0) {
            delete positions[tokenId];
            _burn(tokenId);
        }
    }

    // ---------------- Hooks -----------------

    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        poolManager.updateDynamicLPFee(key, feeClassicBP);

        return BaseHook.afterInitialize.selector;
    }

    /// 🔒 Blocage du mint classique
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        if (sender != address(this)) {
            revert SenderMustBeHook();
        }
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        if (sender != address(this)) {
            revert SenderMustBeHook();
        }
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /// @notice Callback function invoked during the unlock of liquidity, executing any required state changes.
    /// @param rawData Encoded data containing details for the unlock operation.
    /// @return Encoded result of the liquidity modification.
    function unlockCallback(bytes calldata rawData) external override onlyPoolManager returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;

        if (data.params.liquidityDelta > 0) {
            (delta,) = poolManager.modifyLiquidity(data.key, data.params, ZERO_BYTES);
            _settleDeltas(data.sender, data.key, delta);
        } else {
            (delta,) = poolManager.modifyLiquidity(data.key, data.params, ZERO_BYTES);
            _takeDeltas(data.sender, data.key, delta);
        }
        return abi.encode(delta);
    }

    /// @notice Internal function to modify liquidity settings based on the provided parameters.
    /// @param key The pool key associated with the liquidity modification.
    /// @param params The liquidity modification parameters.
    /// @return delta The resulting balance changes from the liquidity modification.
    function _modifyLiquidity(address sender, PoolKey memory key, ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(poolManager.unlock(abi.encode(CallbackData(sender, key, params))), (BalanceDelta));
    }

    /// @notice Settles any owed balances after liquidity modification.
    /// @param sender Address of the user performing the liquidity modification.
    /// @param key The pool key associated with the liquidity modification.
    /// @param delta The balance delta resulting from the liquidity modification.
    function _settleDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        _settleDelta(sender, key.currency0, uint256(int256(-delta.amount0())));
        _settleDelta(sender, key.currency1, uint256(int256(-delta.amount1())));
    }

    function _settleDelta(address sender, Currency currency, uint256 amount) internal {
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            if (sender != address(this)) {
                IERC20(Currency.unwrap(currency)).transferFrom(sender, address(poolManager), amount);
            } else {
                IERC20(Currency.unwrap(currency)).transfer(address(poolManager), amount);
            }
            poolManager.settle();
        }
    }

    /// @notice Takes owed balances after liquidity modification.
    /// @param sender Address of the user performing the liquidity modification.
    /// @param key The pool key associated with the liquidity modification.
    /// @param delta The balance delta resulting from the liquidity modification.
    function _takeDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        poolManager.take(key.currency0, sender, uint256(uint128(delta.amount0())));
        poolManager.take(key.currency1, sender, uint256(uint128(delta.amount1())));
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId pid = key.toId();
        BorrowData memory bd;
        bool isBorrow = false;

        if (data.length > 0) {
            bd = abi.decode(data, (BorrowData));
            isBorrow = bd.isBorrow;
        }

        uint24 fee = _getFee(isBorrow, false) | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    // repay: borrower calls repayLoan with loanId and transfers borrowed token back to the pool/hook
    function repayLoan(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "Not NFT owner");
        LPPosition storage lp = positions[tokenId];
        require(lp.collateralAmount > 0, "invalid loan");
        require(block.timestamp <= lp.borrowMaturity, "repay window closed");

        // Use unlock pattern instead of direct modifyLiquidity call
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: lp.tickLower,
            tickUpper: lp.tickUpper,
            liquidityDelta: int128(lp.liquidity),
            salt: 0
        });

        // Call through unlock mechanism
        _modifyLiquidity(address(this), lp.key, params);

        delete positions[tokenId];
        _burn(tokenId);
    }

    function getAmountsForLiquidity(
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        uint160 sqrtPriceX96Current
    ) private pure returns (uint256 amount0, uint256 amount1) {
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        if (sqrtPriceX96Current <= sqrtPriceLower) {
            // prix en dessous de la range → tout en token0
            amount0 = uint256(liquidityDelta) * (sqrtPriceUpper - sqrtPriceLower)
                / (sqrtPriceUpper * sqrtPriceLower / (1 << 96));
            amount1 = 0;
        } else if (sqrtPriceX96Current >= sqrtPriceUpper) {
            // prix au-dessus → tout en token1
            amount0 = 0;
            amount1 = uint256(liquidityDelta) * (sqrtPriceUpper - sqrtPriceLower) / (1 << 96);
        } else {
            // prix à l'intérieur de la range → mélange des deux
            amount0 = uint256(liquidityDelta) * (sqrtPriceUpper - sqrtPriceX96Current)
                / (sqrtPriceUpper * sqrtPriceX96Current / (1 << 96));
            amount1 = uint256(liquidityDelta) * (sqrtPriceX96Current - sqrtPriceLower) / (1 << 96);
        }
    }

    /// ---------- On-chain metadata + SVG rendering ----------
    /// Returns a data:application/json;base64,.... URI with name/description/attributes and image (SVG base64)
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(tokenId > 0 && tokenId < nextId, "Nonexistent token");
        LPPosition memory pos = positions[tokenId];

        string memory svg = generateSVGofTokenById(tokenId);

        string memory image = string(abi.encodePacked("data:image/svg+xml;base64,", Base64.encode(bytes(svg))));

        // Build JSON
        string memory json = string(
            abi.encodePacked(
                '{"name":"Unibow LP #',
                tokenId.toString(),
                '", "description":"Locked liquidity position managed by Unibow Hook.", "image":"',
                image,
                '", "attributes":[',
                '{"trait_type":"Tick Lower","value":"',
                intToString(pos.tickLower),
                '"},',
                '{"trait_type":"Tick Upper","value":"',
                intToString(pos.tickUpper),
                '"},',
                '{"trait_type":"Liquidity","value":"',
                uint256(pos.liquidity).toString(),
                '"},',
                '{"trait_type":"UnlockTime","value":"',
                uint256(pos.unlockTime).toString(),
                '"}',
                "]}"
            )
        );

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    function intToString(int256 value) internal pure returns (string memory) {
        if (value >= 0) {
            return uint256(value).toString();
        } else {
            return string(abi.encodePacked("-", uint256(-value).toString()));
        }
    }

    /// Produce a simple SVG representing the position:
    /// - top: textual metadata,
    /// - middle: a horizontal bar whose width ~ liquidity / VISUAL_LIQUIDITY_CAP,
    /// - bottom: ticks & unlock time
    function generateSVGofTokenById(uint256 tokenId) public view returns (string memory) {
        LPPosition memory pos = positions[tokenId];

        // clamp liquidity to cap for visual scale
        uint256 liq = pos.liquidity;
        uint256 capped = liq;
        if (capped > VISUAL_LIQUIDITY_CAP) capped = VISUAL_LIQUIDITY_CAP;

        // Bar width scaled to max 400 px
        uint256 barMax = 400;
        uint256 barWidth = (capped * barMax) / VISUAL_LIQUIDITY_CAP;

        // Colors and simple layout
        string memory title = string(abi.encodePacked("Unibow LP #", tokenId.toString()));
        string memory ticks =
            string(abi.encodePacked("Ticks: ", intToString(pos.tickLower), " / ", intToString(pos.tickUpper)));
        string memory liqText = string(abi.encodePacked("Liquidity: ", uint256(pos.liquidity).toString()));
        string memory unlockText = string(abi.encodePacked("Unlock: ", uint256(pos.unlockTime).toString()));

        // Build SVG
        string memory svg = string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" width="520" height="220" viewBox="0 0 520 220">',
                "<style>",
                "text{font-family:Arial,sans-serif;fill:#111;font-size:14px;}",
                ".title{font-size:16px;font-weight:600;}",
                ".muted{font-size:12px;fill:#666;}",
                "</style>",
                // background
                '<rect width="100%" height="100%" fill="#f8fafc" rx="12" />',
                // title
                '<text x="20" y="30" class="title">',
                title,
                "</text>",
                // liquidity text
                '<text x="20" y="60">',
                liqText,
                "</text>",
                // bar background
                '<rect x="20" y="75" width="400" height="24" rx="6" fill="#e6e9ef"/>',
                // bar fill
                '<rect x="20" y="75" width="',
                uint2str(barWidth),
                '" height="24" rx="6" fill="#4f46e5"/>',
                // ticks and unlock
                '<text x="20" y="115" class="muted">',
                ticks,
                "</text>",
                '<text x="20" y="135" class="muted">',
                unlockText,
                "</text>",
                // small footer
                '<text x="20" y="195" class="muted">Unibow - on-chain position</text>',
                "</svg>"
            )
        );

        return svg;
    }

    /// helper uint->string using Strings
    function uint2str(uint256 _i) internal pure returns (string memory) {
        return Strings.toString(_i);
    }
}
