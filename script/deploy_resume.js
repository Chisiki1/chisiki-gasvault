const { ethers } = require("ethers");
const fs = require("fs");

const MASTER_KEY = process.env.MASTER_KEY; // Set via: $env:MASTER_KEY="0x..."
const RPC = "https://mainnet.base.org";

// Already deployed
const VAULT_ADDR = "0x09E22b6a1937FbA0194c101E541E086C7711114e";

// Addresses
const CKT = "0x5ccdf98d0b48bf8d51e9196d738c5bbf6b33c274";
const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const WETH = "0x4200000000000000000000000000000000000006";
const SWAP_ROUTER = "0x2626664c2603336E57B271c5C0b26F421741e481";
const QUOTER_V2 = "0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a";
const POSITION_MANAGER = "0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1";
const UNISWAP_FACTORY = "0x33128a8fC17869897dcE68Ed026d694621f6FDfD";
const LP_TOKEN_ID = 4978169;
const DONATE_USDC = "89920000";

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

const FACTORY_ABI = ["function getPool(address,address,uint24) view returns (address)"];
const ERC20_ABI = ["function approve(address,uint256) returns (bool)", "function balanceOf(address) view returns (uint256)"];
const PM_ABI = ["function approve(address,uint256)"];
const VAULT_ABI = ["function setInitialRouter(address)", "function router() view returns (address)"];

async function main() {
    const provider = new ethers.JsonRpcProvider(RPC);
    const master = new ethers.Wallet(MASTER_KEY, provider);
    console.log("Master:", master.address);
    console.log("ETH:", ethers.formatEther(await provider.getBalance(master.address)));
    console.log("Nonce:", await provider.getTransactionCount(master.address));

    // Get pool addresses
    const factory = new ethers.Contract(UNISWAP_FACTORY, FACTORY_ABI, provider);
    const cktUsdcPool = await factory.getPool(CKT, USDC, 10000);
    const usdcWethPool = await factory.getPool(USDC, WETH, 500);
    console.log("CKT-USDC pool:", cktUsdcPool);
    console.log("USDC-WETH pool:", usdcWethPool);

    // Verify vault is deployed
    const vaultCode = await provider.getCode(VAULT_ADDR);
    console.log("\nVault code size:", vaultCode.length, "at", VAULT_ADDR);
    if (vaultCode.length <= 2) throw new Error("Vault not deployed!");

    // Check if vault router is already set
    const vault = new ethers.Contract(VAULT_ADDR, VAULT_ABI, master);
    const currentRouter = await vault.router();
    console.log("Current vault router:", currentRouter);

    // Deploy Router
    console.log("\n=== Deploying GasVaultRouter ===");
    const routerArtifact = JSON.parse(
        fs.readFileSync("c:/Users/PC_User/Desktop/aiagentonly/chisiki-gasvault/out/GasVaultRouter.sol/GasVaultRouter.json", "utf8")
    );
    const RouterFactory = new ethers.ContractFactory(routerArtifact.abi, routerArtifact.bytecode.object, master);
    const router = await RouterFactory.deploy(
        VAULT_ADDR, CKT, USDC, WETH, SWAP_ROUTER, QUOTER_V2,
        POSITION_MANAGER, cktUsdcPool, usdcWethPool, master.address
    );
    await router.waitForDeployment();
    const routerAddr = await router.getAddress();
    console.log("GasVaultRouter deployed:", routerAddr);

    // Set Router on Vault
    if (currentRouter === ethers.ZeroAddress) {
        console.log("\n=== vault.setInitialRouter ===");
        let tx = await vault.setInitialRouter(routerAddr);
        await tx.wait();
        console.log("Done:", tx.hash);
    }

    // Approve Router as LP NFT operator
    console.log("\n=== positionManager.approve ===");
    const pm = new ethers.Contract(POSITION_MANAGER, PM_ABI, master);
    let tx = await pm.approve(routerAddr, LP_TOKEN_ID);
    await tx.wait();
    console.log("Done:", tx.hash);

    // Set LP token ID
    console.log("\n=== router.setLpTokenId ===");
    tx = await router.setLpTokenId(LP_TOKEN_ID);
    await tx.wait();
    console.log("Done:", tx.hash);

    // Whitelist Chisiki contracts
    console.log("\n=== Adding Chisiki contracts ===");
    for (const addr of CHISIKI_CONTRACTS) {
        tx = await router.addChisikiContract(addr);
        await tx.wait();
        console.log("  Added:", addr);
    }

    // Donate USDC
    console.log("\n=== Donating USDC ===");
    const usdc = new ethers.Contract(USDC, ERC20_ABI, master);
    const usdcBal = await usdc.balanceOf(master.address);
    console.log("USDC balance:", ethers.formatUnits(usdcBal, 6));

    if (usdcBal >= BigInt(DONATE_USDC)) {
        tx = await usdc.approve(routerAddr, DONATE_USDC);
        await tx.wait();
        tx = await router.donateUSDC(DONATE_USDC);
        await tx.wait();
        console.log("Donated:", DONATE_USDC);
    } else {
        console.log("Insufficient USDC, skipping donation");
    }

    // Save
    const deployment = {
        network: "base-mainnet",
        chainId: 8453,
        deployer: master.address,
        deployedAt: new Date().toISOString(),
        contracts: { GasVault: VAULT_ADDR, GasVaultRouter: routerAddr },
        pools: { "CKT-USDC": cktUsdcPool, "USDC-WETH": usdcWethPool },
        lpTokenId: LP_TOKEN_ID,
        whitelistedContracts: CHISIKI_CONTRACTS,
        usdcDonated: DONATE_USDC,
    };
    fs.writeFileSync("c:/Users/PC_User/Desktop/aiagentonly/chisiki-gasvault/deployments/base-mainnet.json", JSON.stringify(deployment, null, 2));
    console.log("\n=== COMPLETE ===");
    console.log(JSON.stringify(deployment, null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
