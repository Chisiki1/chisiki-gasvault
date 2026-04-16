// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IUniswapV3.sol";
import "./GasVault.sol";

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title GasVaultRouter
 * @notice Autonomous gas refund router for Chisiki Protocol on Base L2.
 *         Piggybacks on user transactions to measure gas, convert CKT→ETH
 *         via Uniswap v3, refund ETH, and manage LP fees.
 *
 * Key features:
 * - Self-learning EMA for gas overhead estimation (no hardcoded constants)
 * - Real-time QuoterV2 pricing with price impact (TWAP as safety valve)
 * - Assembly ETH transfer (Return Bomb safe) with WETH fallback
 * - Internal reserve accounting (Donation Griefing safe)
 * - Rate limiting: per-refund cap + daily per-user cap
 *
 * Security: ReentrancyGuard, Pausable, Ownable2Step, non-upgradeable
 */
contract GasVaultRouter is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    // ── Immutables ──
    GasVault public immutable vault;
    IERC20 public immutable ckt;
    IERC20 public immutable usdc;
    IWETH9 public immutable weth;
    ISwapRouter public immutable swapRouter;
    IQuoterV2 public immutable quoter;
    INonfungiblePositionManager public immutable positionManager;
    address public immutable cktUsdcPool;   // CKT-USDC pool for TWAP
    address public immutable usdcWethPool;  // USDC-WETH pool for TWAP

    uint24 public constant CKT_USDC_FEE = 10000; // 1%
    uint24 public constant USDC_WETH_FEE = 500;   // 0.05%

    // ── Self-Learning EMA ──
    uint256 public avgOverheadGas = 450_000; // Initial conservative estimate

    // ── LP Management ──
    uint256 public lpTokenId;
    uint256 public lastCollectTime;
    uint256 public constant COLLECT_INTERVAL = 24 hours;
    uint256 public constant MIN_REINVEST = 1e4; // Min USDC for reinvest

    // ── Reserves (internal accounting, NOT balanceOf) ──
    uint256 public reserveUSDC;
    uint256 public reserveCKT;

    // ── Rate Limits ──
    uint256 public constant MAX_GAS_PER_ACTION = 1_000_000;
    uint256 public constant MAX_CKT_PER_REFUND = 10e18;   // 10 CKT
    uint256 public constant MAX_CKT_PER_DAY = 100e18;     // 100 CKT / user / day
    uint256 public constant FINALIZE_GAS = 15_000;

    mapping(address => uint256) public dailyCktUsed;
    mapping(address => uint256) public lastResetDay;

    // ── Whitelist ──
    mapping(address => bool) public isChisikiContract;

    // ── TWAP Config ──
    uint32 public constant TWAP_PERIOD = 300; // 5 minutes
    uint256 public constant TWAP_DEVIATION_BPS = 12000; // 120% (20% tolerance)

    // ── Events ──
    event Refunded(address indexed user, uint256 ethAmount, uint256 cktConsumed);
    event RefundSkipped(address indexed user, string reason);
    event Donated(address indexed donor, address indexed token, uint256 amount);
    event FeesAddedToLP(uint256 cktAmount, uint256 usdcAmount, uint256 liquidity);
    event FeesReinvested(uint256 cktCollected, uint256 usdcCollected, uint256 liquidity);
    event OverheadUpdated(uint256 oldValue, uint256 newValue, uint256 actualOverhead);
    event ChisikiContractUpdated(address indexed contractAddr, bool status);
    event LpTokenIdSet(uint256 tokenId);
    event TokensRescued(address indexed token, uint256 amount, address indexed to);

    // ── Errors ──
    error NotChisikiContract(address target);
    error ActionCallFailed(address target);
    error SwapFailed();
    error ExceedsGasLimit(uint256 gasUsed);
    error ExceedsRefundCap(uint256 cktNeeded);
    error ExceedsDailyCap(address user, uint256 dailyUsed);
    error TwapDeviationTooHigh(uint256 quoterPrice, uint256 twapPrice);

    constructor(
        address _vault,
        address _ckt,
        address _usdc,
        address _weth,
        address _swapRouter,
        address _quoter,
        address _positionManager,
        address _cktUsdcPool,
        address _usdcWethPool,
        address _owner
    ) Ownable(_owner) {
        vault = GasVault(_vault);
        ckt = IERC20(_ckt);
        usdc = IERC20(_usdc);
        weth = IWETH9(_weth);
        swapRouter = ISwapRouter(_swapRouter);
        quoter = IQuoterV2(_quoter);
        positionManager = INonfungiblePositionManager(_positionManager);
        cktUsdcPool = _cktUsdcPool;
        usdcWethPool = _usdcWethPool;
    }

    receive() external payable {}

    // ═══════════════════════════════════════════════════════════════
    //  USER-FACING: PROTOCOL ACTION WITH GAS REFUND
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Execute any whitelisted Chisiki contract call with gas refund.
     * @param target The Chisiki contract address to call
     * @param data The calldata to forward
     */
    function executeWithRefund(
        address target,
        bytes calldata data
    ) external nonReentrant whenNotPaused {
        if (!isChisikiContract[target]) revert NotChisikiContract(target);

        uint256 gasStart = gasleft();
        // Forward call to Chisiki contract
        (bool success, ) = target.call(data);
        if (!success) revert ActionCallFailed(target);
        uint256 gasUsed = gasStart - gasleft();

        _processRefund(msg.sender, gasUsed);
    }

    // ═══════════════════════════════════════════════════════════════
    //  DONATE (Reserve Management)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Donate USDC to the reserve. Used as pairing asset for LP additions.
     */
    function donateUSDC(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Router: zero amount");
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        reserveUSDC += amount;
        emit Donated(msg.sender, address(usdc), amount);
    }

    /**
     * @notice Donate CKT to the reserve. Added to LP with fee CKT.
     */
    function donateCKT(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Router: zero amount");
        ckt.safeTransferFrom(msg.sender, address(this), amount);
        reserveCKT += amount;
        emit Donated(msg.sender, address(ckt), amount);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTERNAL: PROCESS REFUND (Core Logic)
    // ═══════════════════════════════════════════════════════════════

    function _processRefund(address user, uint256 gasUsed) internal {
        uint256 overheadStart = gasleft();

        // (a) Gas griefing prevention
        if (gasUsed > MAX_GAS_PER_ACTION) {
            emit RefundSkipped(user, "gas_exceeds_limit");
            return;
        }

        // (b) Calculate ETH cost: (gasUsed + avgOverheadGas) * tx.gasprice
        uint256 totalGas = gasUsed + avgOverheadGas;
        uint256 ethNeeded = totalGas * tx.gasprice;

        if (ethNeeded == 0) {
            emit RefundSkipped(user, "zero_eth_cost");
            return;
        }

        // (c) Quoter: get exact CKT cost via USDC→WETH→CKT path
        uint256 cktNeeded;
        try this._quoteCktForEth(ethNeeded) returns (uint256 result) {
            cktNeeded = result;
        } catch {
            emit RefundSkipped(user, "quoter_failed");
            _updateOverhead(overheadStart);
            return;
        }

        // (d) TWAP safety valve: check 20% deviation
        uint256 twapEstimate = _estimateCktViaTwap(ethNeeded);
        if (twapEstimate > 0 && cktNeeded > (twapEstimate * TWAP_DEVIATION_BPS) / 10000) {
            emit RefundSkipped(user, "twap_deviation");
            _updateOverhead(overheadStart);
            return;
        }

        // (e) Add 5% service fee
        uint256 feeCkt = cktNeeded / 20; // 5%
        uint256 totalCktCost = cktNeeded + feeCkt;

        // (f) Per-refund cap
        if (totalCktCost > MAX_CKT_PER_REFUND) {
            emit RefundSkipped(user, "exceeds_refund_cap");
            _updateOverhead(overheadStart);
            return;
        }

        // (g) Daily cap
        uint256 today = block.timestamp / 1 days;
        if (lastResetDay[user] < today) {
            dailyCktUsed[user] = 0;
            lastResetDay[user] = today;
        }
        if (dailyCktUsed[user] + totalCktCost > MAX_CKT_PER_DAY) {
            emit RefundSkipped(user, "daily_cap_exceeded");
            _updateOverhead(overheadStart);
            return;
        }

        // (h) Check vault balance
        uint256 available = vault.getAvailableBalance(user);
        if (available < totalCktCost) {
            emit RefundSkipped(user, "insufficient_vault");
            _updateOverhead(overheadStart);
            return;
        }

        // (i) Consume CKT from vault
        vault.consumeForRefund(user, totalCktCost);
        dailyCktUsed[user] += totalCktCost;

        // (j) Swap 95% CKT → USDC → WETH
        uint256 refundCkt = totalCktCost - feeCkt;
        uint256 ethReceived = _swapCktToEth(refundCkt, ethNeeded);

        // (k) Send ETH to user (Return Bomb safe)
        if (ethReceived > 0) {
            bool sent = _safeTransferETH(user, ethReceived);
            if (!sent) {
                // Fallback: send as WETH
                weth.deposit{value: ethReceived}();
                weth.transfer(user, ethReceived);
            }
            emit Refunded(user, ethReceived, totalCktCost);
        }

        // (l) Add 5% fee to LP
        if (feeCkt > 0) {
            _addFeeToLP(feeCkt);
        }

        // (m) Piggyback jobs (1% reinvest)
        _piggybackJobs();

        // (n) Update EMA overhead
        _updateOverhead(overheadStart);
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTERNAL: QUOTER & TWAP
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice External wrapper for Quoter call (used with try/catch).
     *         CKT → USDC → WETH path: how much CKT to get `ethAmount` WETH?
     */
    function _quoteCktForEth(uint256 ethAmount) external returns (uint256 cktNeeded) {
        require(msg.sender == address(this), "Router: internal only");

        // Step 1: How much USDC to buy ethAmount of WETH?
        (uint256 usdcNeeded, , , ) = quoter.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(weth),
                amount: ethAmount,
                fee: USDC_WETH_FEE,
                sqrtPriceLimitX96: 0
            })
        );

        // Step 2: How much CKT to buy usdcNeeded of USDC?
        (cktNeeded, , , ) = quoter.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: address(ckt),
                tokenOut: address(usdc),
                amount: usdcNeeded,
                fee: CKT_USDC_FEE,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /**
     * @notice Estimate CKT cost via TWAP (5-minute average). Used as safety check.
     */
    function _estimateCktViaTwap(uint256 ethAmount) internal view returns (uint256) {
        // Get USDC/WETH TWAP — _tickToPrice returns token1/token0 * 1e18
        // USDC-WETH pool: token0=USDC, token1=WETH → returns WETH/USDC * 1e18
        // We need USDC per ETH, so: usdcNeeded = ethAmount * 1e18 / (WETH/USDC)
        uint256 wethPerUsdc = _getTwapPrice(usdcWethPool);
        if (wethPerUsdc == 0) return 0;

        // USDC needed for ethAmount (USDC has 6 decimals, ETH has 18)
        // usdcNeeded = ethAmount / (wethPerUsdc / 1e18) = ethAmount * 1e18 / wethPerUsdc
        // But result needs to be in USDC 6-decimal units:
        // ethAmount is in wei (18 dec), wethPerUsdc is WETH/USDC * 1e18
        // usdcNeeded (6 dec) = ethAmount (18 dec) * 1e6 / wethPerUsdc
        uint256 usdcNeeded = (ethAmount * 1e6) / wethPerUsdc;

        // Get CKT-USDC TWAP — token0=CKT, token1=USDC → returns USDC/CKT * 1e18
        uint256 usdcPerCkt = _getTwapPrice(cktUsdcPool);
        if (usdcPerCkt == 0) return 0;

        // CKT needed = usdcNeeded / (USDC per CKT)
        // usdcNeeded is 6 dec, usdcPerCkt is USDC/CKT * 1e18
        // cktNeeded (18 dec) = usdcNeeded * 1e18 * 1e12 / usdcPerCkt
        //                    = usdcNeeded * 1e30 / usdcPerCkt
        // The 1e12 bridges USDC 6-dec → CKT 18-dec
        return (usdcNeeded * 1e30) / usdcPerCkt;
    }

    /**
     * @notice Get TWAP price from a Uniswap v3 pool (token1/token0 in Q112 format).
     */
    function _getTwapPrice(address pool) internal view returns (uint256) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_PERIOD;
        secondsAgos[1] = 0;

        try IUniswapV3Pool(pool).observe(secondsAgos) returns (
            int56[] memory tickCumulatives,
            uint160[] memory
        ) {
            int56 tickDiff = tickCumulatives[1] - tickCumulatives[0];
            int24 avgTick = int24(tickDiff / int56(int32(TWAP_PERIOD)));

            // Convert tick to price: price = 1.0001^tick
            // Using TickMath-style calculation
            return _tickToPrice(avgTick);
        } catch {
            return 0;
        }
    }

    /**
     * @notice Convert a tick to a price ratio (simplified).
     *         Returns price as token1/token0 * 1e18
     */
    function _tickToPrice(int24 tick) internal pure returns (uint256) {
        // sqrtPriceX96 = sqrt(1.0001^tick) * 2^96
        // price = (sqrtPriceX96)^2 / 2^192
        // Simplified: use the fact that 1.0001^tick ≈ e^(tick * 0.00009999)
        uint256 absTick = tick >= 0 ? uint256(int256(tick)) : uint256(-int256(tick));
        
        // Start with Q128 representation
        uint256 ratio = 0x100000000000000000000000000000000; // 1 in Q128

        if (absTick & 0x1 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        // Convert from Q128 to 1e18 format
        return (ratio * 1e18) >> 128;
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTERNAL: SWAP CKT → ETH
    // ═══════════════════════════════════════════════════════════════

    function _swapCktToEth(uint256 cktAmount, uint256 minEthOut) internal returns (uint256) {
        if (cktAmount == 0) return 0;

        // Approve CKT for swap router
        ckt.safeIncreaseAllowance(address(swapRouter), cktAmount);

        // Multi-hop swap: CKT → USDC → WETH
        bytes memory path = abi.encodePacked(
            address(ckt), CKT_USDC_FEE, address(usdc), USDC_WETH_FEE, address(weth)
        );

        uint256 amountOut;
        try swapRouter.exactInput(
            ISwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                amountIn: cktAmount,
                amountOutMinimum: (minEthOut * 99) / 100 // 1% slippage tolerance (TWAP-based)
            })
        ) returns (uint256 result) {
            amountOut = result;
        } catch {
            // Revert entire tx — CKT consumption is also rolled back
            revert SwapFailed();
        }

        // Unwrap WETH to ETH
        if (amountOut > 0) {
            weth.withdraw(amountOut);
        }

        return amountOut;
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTERNAL: ETH TRANSFER (Return Bomb safe)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Transfer ETH using assembly to prevent Return Bomb attacks.
     *         Does not copy returndata to memory.
     */
    function _safeTransferETH(address to, uint256 value) internal returns (bool success) {
        assembly {
            success := call(gas(), to, value, 0, 0, 0, 0)
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTERNAL: LP MANAGEMENT
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Add 5% fee CKT to LP. Uses reserve USDC if available (no extra swap).
     */
    function _addFeeToLP(uint256 cktAmount) internal {
        if (lpTokenId == 0) return; // LP not configured

        uint256 totalCkt = cktAmount;
        // Include reserve CKT if available
        if (reserveCKT > 0) {
            totalCkt += reserveCKT;
            reserveCKT = 0;
        }

        uint256 usdcAmount;
        if (reserveUSDC > 0) {
            // Use reserve USDC (no swap needed = no sell pressure)
            // Estimate how much USDC pairs with the CKT
            usdcAmount = _estimateUsdcForCkt(totalCkt);
            if (usdcAmount > reserveUSDC) {
                usdcAmount = reserveUSDC;
            }
            reserveUSDC -= usdcAmount;
        } else {
            // No reserve: swap half CKT to USDC
            uint256 halfCkt = totalCkt / 2;
            totalCkt -= halfCkt;
            ckt.safeIncreaseAllowance(address(swapRouter), halfCkt);
            try swapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(ckt),
                    tokenOut: address(usdc),
                    fee: CKT_USDC_FEE,
                    recipient: address(this),
                    amountIn: halfCkt,
                    amountOutMinimum: 0, // Small amounts, MEV unlikely
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 out) {
                usdcAmount = out;
            } catch {
                return;
            }
        }

        if (totalCkt == 0 || usdcAmount == 0) return;

        // Approve tokens for position manager
        ckt.safeIncreaseAllowance(address(positionManager), totalCkt);
        usdc.safeIncreaseAllowance(address(positionManager), usdcAmount);

        // Determine token order
        (uint256 amount0, uint256 amount1) = address(ckt) < address(usdc)
            ? (totalCkt, usdcAmount)
            : (usdcAmount, totalCkt);

        try positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: lpTokenId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        ) returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
            // Recover unused tokens to reserves (zero-leak design)
            (uint256 cktUsed, uint256 usdcUsed) = address(ckt) < address(usdc)
                ? (amount0Used, amount1Used)
                : (amount1Used, amount0Used);
            if (totalCkt > cktUsed) reserveCKT += totalCkt - cktUsed;
            if (usdcAmount > usdcUsed) reserveUSDC += usdcAmount - usdcUsed;
            emit FeesAddedToLP(cktUsed, usdcUsed, liquidity);
        } catch {
            // Return tokens to reserves on failure
            reserveCKT += totalCkt;
            reserveUSDC += usdcAmount;
        }
    }

    /**
     * @notice Piggyback: collect 1% pool fees and reinvest (24h interval).
     */
    function _piggybackJobs() internal {
        if (lpTokenId == 0) return;
        if (block.timestamp - lastCollectTime < COLLECT_INTERVAL) return;

        // Collect all accrued fees
        (uint256 amount0, uint256 amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: lpTokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        lastCollectTime = block.timestamp;

        // Determine CKT and USDC amounts from collected fees
        (uint256 cktCollected, uint256 usdcCollected) = address(ckt) < address(usdc)
            ? (amount0, amount1)
            : (amount1, amount0);

        // Add reserve if available
        if (reserveCKT > 0) {
            cktCollected += reserveCKT;
            reserveCKT = 0;
        }
        if (reserveUSDC > 0) {
            usdcCollected += reserveUSDC;
            reserveUSDC = 0;
        }

        // Check minimum reinvest threshold
        if (usdcCollected < MIN_REINVEST && cktCollected == 0) return;

        if (cktCollected == 0 || usdcCollected == 0) return;

        // Reinvest: increase liquidity
        ckt.safeIncreaseAllowance(address(positionManager), cktCollected);
        usdc.safeIncreaseAllowance(address(positionManager), usdcCollected);

        (uint256 a0, uint256 a1) = address(ckt) < address(usdc)
            ? (cktCollected, usdcCollected)
            : (usdcCollected, cktCollected);

        try positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: lpTokenId,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        ) returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
            // Recover unused tokens to reserves (zero-leak design)
            (uint256 cktUsed, uint256 usdcUsed) = address(ckt) < address(usdc)
                ? (amount0Used, amount1Used)
                : (amount1Used, amount0Used);
            if (cktCollected > cktUsed) reserveCKT += cktCollected - cktUsed;
            if (usdcCollected > usdcUsed) reserveUSDC += usdcCollected - usdcUsed;
            emit FeesReinvested(cktUsed, usdcUsed, liquidity);
        } catch {
            // Return tokens to reserves on failure
            reserveCKT += cktCollected;
            reserveUSDC += usdcCollected;
        }
    }

    /**
     * @notice Estimate USDC needed to pair with a CKT amount for LP addition.
     */
    function _estimateUsdcForCkt(uint256 cktAmount) internal returns (uint256) {
        try quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: address(ckt),
                tokenOut: address(usdc),
                amountIn: cktAmount,
                fee: CKT_USDC_FEE,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 usdcOut, uint160, uint32, uint256) {
            return usdcOut;
        } catch {
            return 0;
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTERNAL: SELF-LEARNING EMA
    // ═══════════════════════════════════════════════════════════════

    function _updateOverhead(uint256 startGas) internal {
        uint256 actualOverhead = startGas - gasleft() + FINALIZE_GAS;
        uint256 oldAvg = avgOverheadGas;
        avgOverheadGas = (oldAvg * 9 + actualOverhead) / 10;
        emit OverheadUpdated(oldAvg, avgOverheadGas, actualOverhead);
    }

    // ═══════════════════════════════════════════════════════════════
    //  ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    function addChisikiContract(address addr) external onlyOwner {
        require(addr != address(0), "Router: zero");
        isChisikiContract[addr] = true;
        emit ChisikiContractUpdated(addr, true);
    }

    function removeChisikiContract(address addr) external onlyOwner {
        isChisikiContract[addr] = false;
        emit ChisikiContractUpdated(addr, false);
    }

    function setLpTokenId(uint256 tokenId) external onlyOwner {
        lpTokenId = tokenId;
        emit LpTokenIdSet(tokenId);
    }

    /**
     * @notice Rescue tokens sent directly to this contract (not via donate).
     *         Cannot rescue amounts tracked by internal accounting.
     */
    function rescueTokens(address token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "Router: zero recipient");

        if (token == address(usdc)) {
            uint256 excess = usdc.balanceOf(address(this)) - reserveUSDC;
            require(amount <= excess, "Router: cannot rescue reserved USDC");
        } else if (token == address(ckt)) {
            uint256 excess = ckt.balanceOf(address(this)) - reserveCKT;
            require(amount <= excess, "Router: cannot rescue reserved CKT");
        }

        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, amount, to);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ═══════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    function getDailyUsage(address user) external view returns (uint256 used, uint256 remaining) {
        uint256 today = block.timestamp / 1 days;
        used = lastResetDay[user] < today ? 0 : dailyCktUsed[user];
        remaining = MAX_CKT_PER_DAY > used ? MAX_CKT_PER_DAY - used : 0;
    }
}
