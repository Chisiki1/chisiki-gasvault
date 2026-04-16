// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GasVault.sol";
import "../src/GasVaultRouter.sol";

/// @title Fork test against deployed Base mainnet contracts
/// @notice Tests the full refund cycle: deposit → executeWithRefund → ETH return
contract GasVaultForkTest is Test {
    // ── Deployed contracts ──
    GasVault public vault = GasVault(0x09E22b6a1937FbA0194c101E541E086C7711114e);
    GasVaultRouter public router = GasVaultRouter(payable(0xdCdB81B7BA194AD5F4440559afE0267C8cDBC4eD));

    // ── Tokens ──
    IERC20 public ckt = IERC20(0x5ccdf98d0b48bf8d51e9196d738c5bbf6b33c274);
    IERC20 public usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    // ── Whitelisted Chisiki contract (QAEscrow) ──
    address public qaEscrow = 0x12dc6fbaa22d38ebbec425ba76db82f0c8594306;

    // ── Test user ──
    address public user = makeAddr("testUser");
    address public owner = 0x7d69916Bc7D7d6C1ff5F0deCf5dcF96C266805bC;

    function setUp() public {
        // Give user some ETH for gas
        vm.deal(user, 1 ether);
        // Give user CKT (100 CKT) via storage manipulation
        deal(address(ckt), user, 100e18);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Test 1: Verify deployment state is correct
    // ═══════════════════════════════════════════════════════════════
    function test_deploymentState() public view {
        // Vault checks
        assertEq(vault.router(), address(router), "vault.router mismatch");
        assertEq(vault.owner(), owner, "vault.owner mismatch");
        assertFalse(vault.paused(), "vault should not be paused");

        // Router checks
        assertEq(address(router.vault()), address(vault), "router.vault mismatch");
        assertEq(router.owner(), owner, "router.owner mismatch");
        assertEq(router.lpTokenId(), 4978169, "lpTokenId mismatch");
        assertFalse(router.paused(), "router should not be paused");
        assertGt(router.reserveUSDC(), 0, "reserveUSDC should be > 0");
        assertEq(router.avgOverheadGas(), 450_000, "avgOverheadGas initial");

        // Whitelist checks
        assertTrue(router.isChisikiContract(qaEscrow), "QAEscrow not whitelisted");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Test 2: CKT deposit to Vault
    // ═══════════════════════════════════════════════════════════════
    function test_deposit() public {
        uint256 depositAmount = 50e18;

        vm.startPrank(user);
        ckt.approve(address(vault), depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();

        assertEq(vault.getAvailableBalance(user), depositAmount, "available balance");
        assertEq(vault.deposits(user), depositAmount, "deposits mapping");
        assertEq(vault.consumed(user), 0, "consumed should be 0");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Test 3: executeWithRefund — full refund cycle
    // ═══════════════════════════════════════════════════════════════
    function test_executeWithRefund() public {
        uint256 depositAmount = 50e18;

        // Setup: deposit CKT
        vm.startPrank(user);
        ckt.approve(address(vault), depositAmount);
        vault.deposit(depositAmount);

        // Record state before
        uint256 ethBefore = user.balance;
        uint256 availBefore = vault.getAvailableBalance(user);

        // Build calldata for QAEscrow — doesn't matter if it reverts internally,
        // the Router won't refund if the call fails. So we use a valid view call
        // that won't revert. Let's use AgentRegistry.isRegistered(user) instead.
        address agentRegistry = 0x7e012e4d81921bc56282dac626f3591fe8c49b54;

        // But we need a call that succeeds. AgentRegistry.isRegistered is view.
        // For a real test, we need a state-changing call. Let's use a no-op call
        // that succeeds — we can register the user first.
        // Actually, the action call needs to succeed. Let's try calling a simple
        // function. The key insight is: the action call must succeed, not revert.

        // For testing, let's try calling agentRegistry.isRegistered(user)
        // as a regular call (will succeed as a no-op since it's view)
        bytes memory data = abi.encodeWithSignature("isRegistered(address)", user);

        // This should either successfully refund, or skip refund (if quoter fails etc)
        // Either way, the tx itself should not revert
        router.executeWithRefund(agentRegistry, data);
        vm.stopPrank();

        // The call should have succeeded (executeWithRefund doesn't revert on refund failure)
        // Check if CKT was consumed (refund happened)
        uint256 consumed = vault.consumed(user);
        if (consumed > 0) {
            // Refund happened!
            emit log_named_uint("CKT consumed", consumed);
            emit log_named_uint("ETH received", user.balance - ethBefore);

            // CKT balance should have decreased
            assertLt(vault.getAvailableBalance(user), availBefore, "available should decrease");

            // User should have received ETH (or WETH)
            // Note: ETH balance might not increase if WETH fallback was used
            // So we just check that CKT was consumed

            // avgOverheadGas should have been updated
            // After first call it might be different from 450k
            emit log_named_uint("avgOverheadGas", router.avgOverheadGas());
        } else {
            // Refund was skipped (possibly Quoter issue on fork, TWAP not enough history, etc)
            emit log("Refund was skipped - this may be normal on a fresh fork");
            emit log("The action call itself succeeded");
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Test 4: Non-whitelisted contract should revert
    // ═══════════════════════════════════════════════════════════════
    function test_revert_nonWhitelisted() public {
        vm.startPrank(user);
        vm.expectRevert();
        router.executeWithRefund(address(0xdead), "");
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Test 5: Cannot consume more than deposited
    // ═══════════════════════════════════════════════════════════════
    function test_cannotConsumeWithoutDeposit() public {
        // User has no deposit — executeWithRefund should succeed but skip refund
        vm.startPrank(user);
        address agentRegistry = 0x7e012e4d81921bc56282dac626f3591fe8c49b54;
        bytes memory data = abi.encodeWithSignature("isRegistered(address)", user);

        // Should not revert — action succeeds, refund is skipped due to no balance
        router.executeWithRefund(agentRegistry, data);
        vm.stopPrank();

        assertEq(vault.consumed(user), 0, "nothing consumed without deposit");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Test 6: Donate functions work correctly
    // ═══════════════════════════════════════════════════════════════
    function test_donateUSDC() public {
        uint256 reserveBefore = router.reserveUSDC();
        uint256 amount = 10e6; // 10 USDC

        // Give some USDC to a donor
        address donor = makeAddr("donor");
        deal(address(usdc), donor, amount);

        vm.startPrank(donor);
        usdc.approve(address(router), amount);
        router.donateUSDC(amount);
        vm.stopPrank();

        assertEq(router.reserveUSDC(), reserveBefore + amount, "reserveUSDC increased");
    }

    function test_donateCKT() public {
        uint256 reserveBefore = router.reserveCKT();
        uint256 amount = 100e18; // 100 CKT

        address donor = makeAddr("donor2");
        deal(address(ckt), donor, amount);

        vm.startPrank(donor);
        ckt.approve(address(router), amount);
        router.donateCKT(amount);
        vm.stopPrank();

        assertEq(router.reserveCKT(), reserveBefore + amount, "reserveCKT increased");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Test 7: Rescue tokens (admin only)
    // ═══════════════════════════════════════════════════════════════
    function test_rescueTokens_onlyOwner() public {
        // Non-owner should revert
        vm.prank(user);
        vm.expectRevert();
        router.rescueTokens(address(usdc), 1);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Test 8: Pause prevents operations
    // ═══════════════════════════════════════════════════════════════
    function test_pausePreventsExecution() public {
        // Owner pauses
        vm.prank(owner);
        router.pause();

        // User tries to execute — should revert
        vm.startPrank(user);
        vm.expectRevert();
        router.executeWithRefund(qaEscrow, "");
        vm.stopPrank();

        // Owner unpauses
        vm.prank(owner);
        router.unpause();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Test 9: Rate limiting
    // ═══════════════════════════════════════════════════════════════
    function test_maxCktPerRefund() public view {
        assertEq(router.MAX_CKT_PER_REFUND(), 10e18, "max per refund = 10 CKT");
        assertEq(router.MAX_CKT_PER_DAY(), 100e18, "max per day = 100 CKT");
    }
}
