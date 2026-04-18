/**
 * Chisiki Gas Vault — Usage Example
 *
 * This example demonstrates how to:
 * 1. Deposit CKT into the Gas Vault
 * 2. Execute a Chisiki Protocol action with automatic gas refund
 * 3. Check available balance
 *
 * Prerequisites:
 * - ethers.js v6
 * - A wallet with CKT tokens on Base
 */

const { ethers } = require("ethers");

// ── Base Mainnet Addresses ──
const ADDRESSES = {
    GasVault: "0xEFeA7203d86F8517AcF7c9806f5a8Bf25B82D066",
    GasVaultRouter: "0x3a89Ab39Df86989c294E45449d5Bd97ebA191B6A",
    CKT: "0x5ccdf98d0b48bf8d51e9196d738c5bbf6b33c274",
    QAEscrow: "0x12dc6fbaa22d38ebbec425ba76db82f0c8594306",
};

// ── Minimal ABIs ──
const VAULT_ABI = [
    "function deposit(uint256 amount) external",
    "function getAvailableBalance(address user) external view returns (uint256)",
    "function deposits(address user) external view returns (uint256)",
    "function consumed(address user) external view returns (uint256)",
];

const ROUTER_ABI = [
    "function executeWithRefund(address target, bytes calldata data) external",
    "function reserveUSDC() external view returns (uint256)",
    "function reserveCKT() external view returns (uint256)",
];

const ERC20_ABI = [
    "function approve(address spender, uint256 amount) external returns (bool)",
    "function balanceOf(address account) external view returns (uint256)",
];

async function main() {
    // Connect to Base
    const provider = new ethers.JsonRpcProvider("https://mainnet.base.org");
    const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
    console.log("Wallet:", wallet.address);

    const vault = new ethers.Contract(ADDRESSES.GasVault, VAULT_ABI, wallet);
    const router = new ethers.Contract(ADDRESSES.GasVaultRouter, ROUTER_ABI, wallet);
    const ckt = new ethers.Contract(ADDRESSES.CKT, ERC20_ABI, wallet);

    // ── Step 1: Deposit CKT ──
    const depositAmount = ethers.parseEther("10"); // 10 CKT
    console.log("\n[1] Depositing", ethers.formatEther(depositAmount), "CKT...");

    await (await ckt.approve(ADDRESSES.GasVault, depositAmount)).wait();
    await (await vault.deposit(depositAmount)).wait();

    const available = await vault.getAvailableBalance(wallet.address);
    console.log("Available balance:", ethers.formatEther(available), "CKT");

    // ── Step 2: Execute with Gas Refund ──
    console.log("\n[2] Executing Chisiki action with gas refund...");

    // Example: Post a question on QA Escrow
    const qaEscrow = new ethers.Interface([
        "function postQuestion(bytes32 hash, uint256 reward, uint256 deadline) external",
    ]);
    const calldata = qaEscrow.encodeFunctionData("postQuestion", [
        ethers.keccak256(ethers.toUtf8Bytes("What is the meaning of life?")),
        ethers.parseEther("1"), // 1 CKT reward
        Math.floor(Date.now() / 1000) + 86400, // 24h deadline
    ]);

    const ethBefore = await provider.getBalance(wallet.address);
    await (await router.executeWithRefund(ADDRESSES.QAEscrow, calldata)).wait();
    const ethAfter = await provider.getBalance(wallet.address);

    console.log("ETH balance change:", ethers.formatEther(ethAfter - ethBefore), "ETH");
    console.log("(Negative = net gas cost after refund, Positive = refund > gas)");

    // ── Step 3: Check State ──
    console.log("\n[3] Final state:");
    console.log("CKT available:", ethers.formatEther(await vault.getAvailableBalance(wallet.address)));
    console.log("CKT deposited:", ethers.formatEther(await vault.deposits(wallet.address)));
    console.log("CKT consumed:", ethers.formatEther(await vault.consumed(wallet.address)));
}

main().catch(console.error);
