// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title GasVault
 * @notice CKT deposit-only vault for Chisiki Gas Vault system.
 *         Deposits are one-way (no withdraw). Only the authorized Router
 *         can consume CKT on behalf of users for gas refunds.
 *
 * Security: ReentrancyGuard, Pausable, Ownable2Step
 * Design: Non-upgradeable (immutable after deploy)
 */
contract GasVault is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    // ── State ──
    IERC20 public immutable cktToken;
    address public router;
    address public pendingRouter;
    uint256 public routerChangeTime;
    uint256 public constant ROUTER_CHANGE_DELAY = 48 hours;

    mapping(address => uint256) public deposits;
    mapping(address => uint256) public consumed;

    // ── Events ──
    event Deposited(address indexed user, uint256 amount);
    event Consumed(address indexed user, uint256 cktAmount, address indexed router);
    event RouterChangeProposed(address indexed newRouter, uint256 effectiveAt);
    event RouterChanged(address indexed oldRouter, address indexed newRouter);

    // ── Errors ──
    error OnlyRouter();
    error InsufficientBalance(address user, uint256 available, uint256 requested);
    error ZeroAmount();
    error RouterChangeLocked();
    error NoPendingRouter();

    constructor(address _cktToken, address _owner) Ownable(_owner) {
        require(_cktToken != address(0), "GasVault: zero CKT");
        cktToken = IERC20(_cktToken);
    }

    // ── Deposit (anyone) ──

    /**
     * @notice Deposit CKT into the vault. One-way, no withdrawal.
     * @param amount Amount of CKT to deposit (18 decimals)
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        cktToken.safeTransferFrom(msg.sender, address(this), amount);
        deposits[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    // ── Consume (Router only) ──

    /**
     * @notice Consume CKT from a user's vault balance for gas refund.
     *         Only callable by the authorized Router contract.
     * @param user The user whose CKT is consumed
     * @param cktAmount Amount of CKT to consume
     */
    function consumeForRefund(address user, uint256 cktAmount) external nonReentrant whenNotPaused {
        if (msg.sender != router) revert OnlyRouter();
        if (cktAmount == 0) revert ZeroAmount();

        uint256 available = deposits[user] - consumed[user];
        if (available < cktAmount) revert InsufficientBalance(user, available, cktAmount);

        consumed[user] += cktAmount;
        cktToken.safeTransfer(router, cktAmount);
        emit Consumed(user, cktAmount, router);
    }

    // ── View ──

    /**
     * @notice Get available (unconsumed) CKT balance for a user
     */
    function getAvailableBalance(address user) external view returns (uint256) {
        return deposits[user] - consumed[user];
    }

    // ── Admin: Router change (48h timelock) ──

    /**
     * @notice Propose a new Router address. Takes effect after 48h.
     */
    function proposeRouterChange(address newRouter) external onlyOwner {
        require(newRouter != address(0), "GasVault: zero router");
        pendingRouter = newRouter;
        routerChangeTime = block.timestamp + ROUTER_CHANGE_DELAY;
        emit RouterChangeProposed(newRouter, routerChangeTime);
    }

    /**
     * @notice Execute the pending Router change after the timelock.
     */
    function executeRouterChange() external onlyOwner {
        if (pendingRouter == address(0)) revert NoPendingRouter();
        if (block.timestamp < routerChangeTime) revert RouterChangeLocked();

        address oldRouter = router;
        router = pendingRouter;
        pendingRouter = address(0);
        routerChangeTime = 0;
        emit RouterChanged(oldRouter, router);
    }

    /**
     * @notice Set the initial Router address (one-time setup, only if unset).
     */
    function setInitialRouter(address _router) external onlyOwner {
        require(router == address(0), "GasVault: router already set");
        require(_router != address(0), "GasVault: zero router");
        router = _router;
        emit RouterChanged(address(0), _router);
    }

    // ── Pause ──
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
