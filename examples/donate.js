/**
 * Chisiki Gas Vault — Donation Example
 *
 * Demonstrates how to contribute to the Gas Vault reserve.
 * Donated USDC/CKT is used exclusively for LP pairing optimization,
 * NOT for price manipulation or buybacks.
 *
 * How it helps:
 * - Reduces CKT sell pressure during fee-to-LP conversions
 * - Saves swap fees (1% per Uniswap swap)
 * - Improves LP efficiency (both-sided additions are optimal)
 * - Zero-Leak design ensures reserves are never lost
 */

const { ethers } = require("ethers");

const ROUTER = "0xf7E2172C15b2DfD53AAd5628D1e2055bB7640D57";
const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const CKT = "0x5ccdf98d0b48bf8d51e9196d738c5bbf6b33c274";

const ROUTER_ABI = [
    "function donateUSDC(uint256 amount) external",
    "function donateCKT(uint256 amount) external",
    "function reserveUSDC() external view returns (uint256)",
    "function reserveCKT() external view returns (uint256)",
];

const ERC20_ABI = [
    "function approve(address, uint256) external returns (bool)",
    "function balanceOf(address) external view returns (uint256)",
];

async function main() {
    const provider = new ethers.JsonRpcProvider("https://mainnet.base.org");
    const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
    const router = new ethers.Contract(ROUTER, ROUTER_ABI, wallet);

    // Show current reserves
    console.log("=== Current Reserves ===");
    console.log("USDC:", ethers.formatUnits(await router.reserveUSDC(), 6));
    console.log("CKT:", ethers.formatEther(await router.reserveCKT()));

    // ── Donate USDC ──
    const usdcAmount = 10_000000n; // 10 USDC (6 decimals)
    const usdc = new ethers.Contract(USDC, ERC20_ABI, wallet);

    console.log("\nDonating 10 USDC...");
    await (await usdc.approve(ROUTER, usdcAmount)).wait();
    await (await router.donateUSDC(usdcAmount)).wait();
    console.log("Done! Reserve USDC:", ethers.formatUnits(await router.reserveUSDC(), 6));

    // ── Donate CKT ──
    const cktAmount = ethers.parseEther("100"); // 100 CKT
    const ckt = new ethers.Contract(CKT, ERC20_ABI, wallet);

    console.log("\nDonating 100 CKT...");
    await (await ckt.approve(ROUTER, cktAmount)).wait();
    await (await router.donateCKT(cktAmount)).wait();
    console.log("Done! Reserve CKT:", ethers.formatEther(await router.reserveCKT()));
}

main().catch(console.error);
