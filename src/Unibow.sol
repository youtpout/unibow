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

// periphery libraries
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract Unibow is BaseHook {
    using PoolIdLibrary for PoolKey;

    uint256 public constant BASIS = 10_000; // bps scale

    // fees in bps (set at construction)
    uint256 public feeBorrowBP;   // e.g. 300 = 3%
    uint256 public feeClassicBP;  // e.g. 30  = 0.3%
    uint256 public feeRebalBP;    // e.g. 5   = 0.05%

    // borrow params
    uint256 public borrowableRatioBP; // r (80% = 8000)
    uint256 public lpLockMonths;      // default 3 months
    uint256 public borrowRepayWindow; // default 60 days

    // safety
    uint256 public safetyMarginBP;    // m (25% = 2500)
    uint256 public instantFractionBP; // alpha (50% = 5000)

    // bookkeeping
    struct LPPosition {
        address owner;
        uint256 amount0; // token0 amount at deposit (estimate)
        uint256 amount1; // token1 amount at deposit (estimate)
        uint256 unlockTimestamp;
        bool exists;
    }

    // loan escrow
    struct LoanEscrow {
        address borrower;
        uint8 tokenIndex; // 0 => token0, 1 => token1
        uint256 amountBorrowed; // amount borrower received (80% of V_net)
        uint256 L_add_amount0; // LP minted amounts (token0 side)
        uint256 L_add_amount1; // LP minted amounts (token1 side)
        uint256 start;
        uint256 maturity;
        bool repaid;
        bool exists;
    }

    // pool => positionKey => LPPosition
    mapping(PoolId => mapping(bytes32 => LPPosition)) public lpPositions;
    mapping(PoolId => uint256) public nextLPPositionId; // optional indexing

    // pool => loanId => LoanEscrow
    mapping(PoolId => mapping(uint256 => LoanEscrow)) public loans;
    mapping(PoolId => uint256) public nextLoanId;

    // approximate pool reserves for instant cap
    mapping(PoolId => uint256) public poolReserve0;
    mapping(PoolId => uint256) public poolReserve1;

    address public owner;

    modifier onlyOwner() { require(msg.sender == owner, "owner"); _; }

    constructor(IPoolManager _pm) BaseHook(_pm) {
        owner = msg.sender;
        feeBorrowBP = 30000;
        feeClassicBP = 3000;
        feeRebalBP = 500;

        borrowableRatioBP = 8000; // 80%
        lpLockMonths = 3;
        borrowRepayWindow = 60 days;

        safetyMarginBP = 2500; // 25%
        instantFractionBP = 5000; // 50%
    }

    // hook permissions
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
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
        bool isBorrow;
        uint8 tokenIndex; // 0 or 1
        uint256 durationSeconds; // optional override for repay window
        uint256 expectedOut; // optional optimistic check (supplier provided)
    }

    // helper: position key
    function _posKey(address owner_, int24 lower, int24 upper, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner_, lower, upper, salt));
    }

    // beta seconds for interpolation (25% of lock months)
    function _betaSeconds() internal view returns (uint256) {
        return (lpLockMonths * 30 days) * 25 / 100;
    }

    // compute stable liquidity S(duration) by summing weighted amounts in token index terms
    // we return amounts for both tokens as tuple (s0, s1)
    function _computeStableLiquidity(PoolId pid, uint256 duration) internal view returns (uint256 s0, uint256 s1) {
        uint256 current = block.timestamp;
        uint256 t1 = current + duration;
        uint256 beta = _betaSeconds();
        uint256 n = nextLPPositionId[pid];
        for (uint256 i = 1; i < n; i++) {
            LPPosition storage p = lpPositions[pid][bytes32(i)];
            if (!p.exists) continue;
            uint256 Tj = p.unlockTimestamp;
            uint256 w;
            if (Tj >= t1 + beta) { w = BASIS; }
            else if (Tj <= t1) { w = 0; }
            else { w = ((Tj - t1) * BASIS) / beta; }
            s0 += (p.amount0 * w) / BASIS;
            s1 += (p.amount1 * w) / BASIS;
        }
    }

    // compute outstanding loans (per token) currently active
    function _computeOutstanding(PoolId pid) internal view returns (uint256 out0, uint256 out1) {
        uint256 n = nextLoanId[pid];
        for (uint256 i = 1; i < n; i++) {
            LoanEscrow storage ln = loans[pid][i];
            if (!ln.exists || ln.repaid) continue;
            if (block.timestamp < ln.maturity) {
                if (ln.tokenIndex == 0) out0 += ln.amountBorrowed;
                else out1 += ln.amountBorrowed;
            }
        }
    }

    // compute pool capacity for borrowing tokenIndex (0 or 1) given duration
    function _computeA_pool(PoolId pid, uint8 tokenIndex, uint256 duration) internal view returns (uint256 A_pool) {
        (uint256 s0, uint256 s1) = _computeStableLiquidity(pid, duration);
        (uint256 o0, uint256 o1) = _computeOutstanding(pid);
        uint256 S = tokenIndex == 0 ? s0 : s1;
        uint256 O = tokenIndex == 0 ? o0 : o1;
        uint256 Cpool = 0;
        if (S > 0) {
            Cpool = (S * (BASIS - safetyMarginBP)) / BASIS;
            Cpool = Cpool > O ? (Cpool - O) : 0;
        }
        uint256 reserve = tokenIndex == 0 ? poolReserve0[pid] : poolReserve1[pid];
        uint256 A_instant = (reserve * instantFractionBP) / BASIS;
        A_pool = Cpool < A_instant ? Cpool : A_instant;
    }

    // ---------------- Hooks -----------------
   
    function _beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        internal override returns (bytes4)
    {
        PoolId pid = key.toId();
        require(params.liquidityDelta > 0, "liquidityDelta must be positive for add");

        // read price & bounds
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, pid);

        (uint256 amount0, uint256 amount1) = getAmountsForLiquidity(params.tickLower, params.tickUpper, params.liquidityDelta,sqrtPriceX96);

        bytes32 pKey = _posKey(sender, params.tickLower, params.tickUpper, params.salt);
        LPPosition storage info = lpPositions[pid][pKey];
        uint256 baseLock = lpLockMonths * 30 days;
        if (info.exists) {
            // rebalance: extend lock +1 day and accumulate amounts
            info.unlockTimestamp = info.unlockTimestamp + 1 days;
            info.amount0 += amount0;
            info.amount1 += amount1;
        } else {
            info.exists = true;
            info.owner = sender;
            info.amount0 = amount0;
            info.amount1 = amount1;
            info.unlockTimestamp = block.timestamp + baseLock;
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        internal override returns (bytes4)
    {
        PoolId pid = key.toId();
        bytes32 pKey = _posKey(sender, params.tickLower, params.tickUpper, params.salt);
        LPPosition storage info = lpPositions[pid][pKey];
        require(info.exists, "no locked position");
        require(block.timestamp >= info.unlockTimestamp, "position locked");

        // In a more advanced impl we would decrement amounts by the actual remove amounts computed in afterRemove
        // For simplicity we delete the snapshot here
        delete lpPositions[pid][pKey];
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        internal override returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId pid = key.toId();
        BorrowData memory bd;
        if (data.length > 0) bd = abi.decode(data, (BorrowData));

        if (!bd.isBorrow) {
            // classic swap: no special handling inside hook - pool handles feeClassicBP
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Borrow: perform pre-check capacity
        uint8 tokenIndex = bd.tokenIndex;
        uint256 A_pool = _computeA_pool(pid, tokenIndex, bd.durationSeconds == 0 ? borrowRepayWindow : bd.durationSeconds);
        if (bd.expectedOut != 0) {
            require(bd.expectedOut <= A_pool, "borrow exceeds pool capacity");
        }

        // register loan placeholder; actual amounts will be filled in afterSwap when we know the real out amount
        uint256 loanId = ++nextLoanId[pid];
        loans[pid][loanId] = LoanEscrow({
            borrower: tx.origin,
            tokenIndex: tokenIndex,
            amountBorrowed: 0,
            L_add_amount0: 0,
            L_add_amount1: 0,
            start: block.timestamp,
            maturity: block.timestamp + borrowRepayWindow,
            repaid: false,
            exists: true
        });

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // afterSwap must parse BalanceDelta to discover actual token out amounts and finalize the loan
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata data)
        internal override returns (bytes4, int128)
    {
        PoolId pid = key.toId();
        uint256 loanId = nextLoanId[pid] == 0 ? 0 : nextLoanId[pid] - 1;
        if (loanId == 0) return (BaseHook.afterSwap.selector, 0);
        LoanEscrow storage ln = loans[pid][loanId];
        if (!ln.exists || ln.repaid) return (BaseHook.afterSwap.selector, 0);

        // TODO: parse BalanceDelta to obtain actual token amounts transferred out to borrower.
        // BalanceDelta contains arrays of (tokenId, amount) changes; in this skeleton we assume the caller
        // encodes actualOut in data for simplicity.
        uint256 actualOut = 0;
        if (data.length >= 32) {
            (, , uint256 actualOutEncoded) = abi.decode(data, (bool,uint8,uint256));
            actualOut = actualOutEncoded;
        }
        require(actualOut > 0, "actual out unknown");

        // compute fee, split and L_add
        uint256 fee = (actualOut * feeBorrowBP) / BASIS; // fee goes to LPs via pool
        uint256 V_net = actualOut - fee;
        uint256 borrowerAmount = (V_net * borrowableRatioBP) / BASIS; // 80%
        uint256 L_add_net = V_net - borrowerAmount; // 20%

        // Convert L_add_net into underlying token0/token1 amounts to mint LP
        // Simplest approach: approximate that L_add_net is entirely in borrowed token (swap half for other token),
        // but real implementation should call poolManager.addLiquidity with correct amounts.
        // We'll store L_add in borrowed token side only for record (exact minting handled off-chain/keeper)
        if (ln.tokenIndex == 0) {
            ln.L_add_amount0 = L_add_net;
            ln.L_add_amount1 = 0;
        } else {
            ln.L_add_amount1 = L_add_net;
            ln.L_add_amount0 = 0;
        }

        ln.amountBorrowed = borrowerAmount;

        // update reserves approximation
        if (ln.tokenIndex == 0) poolReserve0[pid] = poolReserve0[pid] + fee + ln.L_add_amount0 - borrowerAmount;
        else poolReserve1[pid] = poolReserve1[pid] + fee + ln.L_add_amount1 - borrowerAmount;

        // Note: actual LP mint and escrow must be handled by interacting with poolManager/addLiquidity
        // and recording the LP token id mapping to this loan. That requires more periphery integration.

        return (BaseHook.afterSwap.selector, 0);
    }

    // repay: borrower calls repayLoan with loanId and transfers borrowed token back to the pool/hook
    function repayLoan(PoolKey calldata key, uint256 loanId) external {
        PoolId pid = key.toId();
        LoanEscrow storage ln = loans[pid][loanId];
        require(ln.exists && !ln.repaid, "invalid loan");
        require(msg.sender == ln.borrower, "only borrower");
        require(block.timestamp <= ln.maturity, "repay window closed");

        // In production: transfer borrowed token from borrower to pool/vault via transferFrom
        // For skeleton we skip ERC20 mechanics and assume transfer done off-chain

        // Burn escrow LP and return assets to borrower (requires poolManager interaction)

        // update reserves
        if (ln.tokenIndex == 0) poolReserve0[pid] = poolReserve0[pid] + ln.amountBorrowed - ln.L_add_amount0;
        else poolReserve1[pid] = poolReserve1[pid] + ln.amountBorrowed - ln.L_add_amount1;

        ln.repaid = true;
    }

    // process default: called by keeper/owner after maturity
    function processDefault(PoolKey calldata key, uint256 loanId) external onlyOwner {
        PoolId pid = key.toId();
        LoanEscrow storage ln = loans[pid][loanId];
        require(ln.exists && !ln.repaid, "bad loan");
        require(block.timestamp > ln.maturity, "not matured");

        // escrow LP remains to pool; nothing else to do (reserves already reflect this)
        ln.repaid = false;
    }

    // admin helpers
    function setPoolReserve(PoolKey calldata key, uint256 r0, uint256 r1) external onlyOwner {
        poolReserve0[key.toId()] = r0;
        poolReserve1[key.toId()] = r1;
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
        amount0 = uint256(liquidityDelta) * (sqrtPriceUpper - sqrtPriceLower) / (sqrtPriceUpper * sqrtPriceLower / (1 << 96));
        amount1 = 0;
    } else if (sqrtPriceX96Current >= sqrtPriceUpper) {
        // prix au-dessus → tout en token1
        amount0 = 0;
        amount1 = uint256(liquidityDelta) * (sqrtPriceUpper - sqrtPriceLower) / (1 << 96);
    } else {
        // prix à l'intérieur de la range → mélange des deux
        amount0 = uint256(liquidityDelta) * (sqrtPriceUpper - sqrtPriceX96Current) / (sqrtPriceUpper * sqrtPriceX96Current / (1 << 96));
        amount1 = uint256(liquidityDelta) * (sqrtPriceX96Current - sqrtPriceLower) / (1 << 96);
    }
}

    function setFees(uint256 borrowBP, uint256 classicBP, uint256 rebalBP) external onlyOwner {
        feeBorrowBP = borrowBP; feeClassicBP = classicBP; feeRebalBP = rebalBP;
    }

    function setParams(uint256 rBP, uint256 lockMonths, uint256 repayWindow, uint256 safetyBP, uint256 instantBP) external onlyOwner {
        borrowableRatioBP = rBP; lpLockMonths = lockMonths; borrowRepayWindow = repayWindow; safetyMarginBP = safetyBP; instantFractionBP = instantBP;
    }
}
