/**
 * GasVault v2.5 Deploy — Fix SwapRouter02 interface mismatch
 * 
 * Steps:
 * 1. Rescue USDC/CKT from old Router
 * 2. Deploy new GasVault
 * 3. Deploy new GasVaultRouter
 * 4. Setup: setRouter, approve LP NFT, setLpTokenId, whitelist, donateUSDC
 */
const { ethers } = require("ethers");
const fs = require("fs");

const MASTER_KEY = process.env.MASTER_KEY;
const RPC = "https://base-mainnet.public.blastapi.io";

// Old contracts
const OLD_ROUTER = "0xdCdB81B7BA194AD5F4440559afE0267C8cDBC4eD";

// Addresses
const CKT = "0x5ccdf98d0b48bf8d51e9196d738c5bbf6b33c274";
const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const WETH = "0x4200000000000000000000000000000000000006";
const SWAP_ROUTER = "0x2626664c2603336E57B271c5C0b26F421741e481";
const QUOTER = "0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a";
const POS_MANAGER = "0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1";
const CKT_USDC_POOL = "0xb434318910ed11a15fa86b38aa398efCf3C83df0";
const USDC_WETH_POOL = "0xd0b53D9277642d899DF5C87A3966A349A798F224";
const LP_TOKEN_ID = 4978169;

const CHISIKI_CONTRACTS = [
    "0x7e012e4d81921bc56282dac626f3591fe8c49b54",
    "0x12dc6fbaa22d38ebbec425ba76db82f0c8594306",
    "0x873a5f2ba8c7b1cf7b050db5022c835487610eef",
    "0x4ffcbc98572b1169cb652bafc72c76e5cfb0de10",
    "0x52a506e7f8d9c6006f7090414c38e9630c8bb2df",
    "0x46125739feab5cdaa2699e39c0d71101146ffbe4",
    "0x3959172dc74ba6ac5abbf68b6ce24041c03e6a8a",
    "0xf82ee34ffd46c515a525014f874867f6c83d5a94",
];

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function sendTx(wallet, tx, label, nonce) {
    tx.nonce = nonce;
    tx.gasLimit = tx.gasLimit || 3000000n;
    const sent = await wallet.sendTransaction(tx);
    const receipt = await sent.wait();
    console.log(`  ✅ ${label}: ${sent.hash.slice(0, 14)}... (gas: ${receipt.gasUsed})`);
    await sleep(2000);
    return receipt;
}

async function main() {
    const provider = new ethers.JsonRpcProvider(RPC);
    const master = new ethers.Wallet(MASTER_KEY, provider);
    let nonce = await provider.getTransactionCount(master.address);
    console.log(`Master: ${master.address}`);
    console.log(`Nonce: ${nonce}`);
    console.log(`ETH: ${ethers.formatEther(await provider.getBalance(master.address))}`);

    // Load ABIs
    const vaultJSON = JSON.parse(fs.readFileSync("out/GasVault.sol/GasVault.json", "utf8"));
    const routerJSON = JSON.parse(fs.readFileSync("out/GasVaultRouter.sol/GasVaultRouter.json", "utf8"));

    // ═══ Step 1: Old Router is already paused, USDC is locked (reserveUSDC == balance) ═══
    // rescueTokens cannot extract reserved funds by design
    // The ~90 USDC in old Router is unfortunately locked
    console.log("\n═══ Step 1: Old Router status ═══");
    console.log("  Old Router paused: true");
    console.log("  USDC locked in old Router: ~90 USDC (reserveUSDC == balance, cannot rescue)");

    // ═══ Step 2: Deploy new GasVault ═══
    console.log("\n═══ Step 2: Deploy new GasVault ═══");
    const vaultFactory = new ethers.ContractFactory(vaultJSON.abi, vaultJSON.bytecode, master);
    const vaultDeployTx = await vaultFactory.getDeployTransaction(CKT, master.address);
    vaultDeployTx.nonce = nonce++;
    const vaultSent = await master.sendTransaction(vaultDeployTx);
    const vaultReceipt = await vaultSent.wait();
    const VAULT = vaultReceipt.contractAddress;
    console.log(`  ✅ GasVault deployed: ${VAULT} (gas: ${vaultReceipt.gasUsed})`);
    await sleep(3000);

    // ═══ Step 3: Deploy new GasVaultRouter ═══
    console.log("\n═══ Step 3: Deploy new GasVaultRouter ═══");
    const routerFactory = new ethers.ContractFactory(routerJSON.abi, routerJSON.bytecode, master);
    const routerDeployTx = await routerFactory.getDeployTransaction(
        VAULT, CKT, USDC, WETH, SWAP_ROUTER, QUOTER, POS_MANAGER,
        CKT_USDC_POOL, USDC_WETH_POOL, master.address
    );
    routerDeployTx.nonce = nonce++;
    const routerSent = await master.sendTransaction(routerDeployTx);
    const routerReceipt = await routerSent.wait();
    const ROUTER = routerReceipt.contractAddress;
    console.log(`  ✅ GasVaultRouter deployed: ${ROUTER} (gas: ${routerReceipt.gasUsed})`);
    await sleep(3000);

    // ═══ Step 4: Setup ═══
    console.log("\n═══ Step 4: Setup ═══");
    const vault = new ethers.Contract(VAULT, vaultJSON.abi, master);
    const router = new ethers.Contract(ROUTER, routerJSON.abi, master);

    // 4a: Set Router on Vault
    await sendTx(master, await vault.setRouter.populateTransaction(ROUTER), "setRouter", nonce++);

    // 4b: Approve LP NFT for Router
    const posMgr = new ethers.Contract(POS_MANAGER, [
        "function approve(address to, uint256 tokenId) external"
    ], master);
    await sendTx(master, await posMgr.approve.populateTransaction(ROUTER, LP_TOKEN_ID), "Approve LP NFT", nonce++);

    // 4c: Set LP Token ID
    await sendTx(master, await router.setLpTokenId.populateTransaction(LP_TOKEN_ID), "setLpTokenId", nonce++);

    // 4d: Whitelist all Chisiki contracts
    for (const addr of CHISIKI_CONTRACTS) {
        await sendTx(master, await router.addChisikiContract.populateTransaction(addr), `Whitelist ${addr.slice(0, 10)}...`, nonce++);
    }

    // 4e: Donate USDC
    const masterUSDC = await new ethers.Contract(USDC, ["function balanceOf(address) view returns (uint256)"], provider).balanceOf(master.address);
    if (masterUSDC > 0n) {
        const usdcContract = new ethers.Contract(USDC, ["function approve(address, uint256) returns (bool)"], master);
        await sendTx(master, await usdcContract.approve.populateTransaction(ROUTER, masterUSDC), `Approve ${ethers.formatUnits(masterUSDC, 6)} USDC`, nonce++);
        await sendTx(master, await router.donateUSDC.populateTransaction(masterUSDC), `Donate ${ethers.formatUnits(masterUSDC, 6)} USDC`, nonce++);
    }

    // ═══ Final ═══
    console.log("\n═══════════════════════════════════════════════════");
    console.log("  GasVault v2.5 Deployment Complete!");
    console.log("═══════════════════════════════════════════════════");
    console.log(`  GasVault:       ${VAULT}`);
    console.log(`  GasVaultRouter: ${ROUTER}`);
    console.log(`  LP NFT:         #${LP_TOKEN_ID}`);
    console.log(`  Reserve USDC:   ${ethers.formatUnits(await router.reserveUSDC(), 6)}`);
    console.log(`  Master ETH:     ${ethers.formatEther(await provider.getBalance(master.address))}`);
    console.log("═══════════════════════════════════════════════════");

    // Save deployment
    const deployment = {
        network: "base-mainnet",
        chainId: 8453,
        version: "2.5",
        deployer: master.address,
        deployedAt: new Date().toISOString(),
        previousRouter: OLD_ROUTER,
        contracts: { GasVault: VAULT, GasVaultRouter: ROUTER },
        pools: { "CKT-USDC": CKT_USDC_POOL, "USDC-WETH": USDC_WETH_POOL },
        lpTokenId: LP_TOKEN_ID,
        whitelistedContracts: CHISIKI_CONTRACTS,
        fix: "SwapRouter02 deadline interface mismatch + SwapFailed revert safety"
    };
    fs.writeFileSync("deployments/base-mainnet.json", JSON.stringify(deployment, null, 2));
    console.log("\nSaved to deployments/base-mainnet.json");
}

main().catch(e => { console.error("FATAL:", e.message.slice(0, 300)); process.exit(1); });
