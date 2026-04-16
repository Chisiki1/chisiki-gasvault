const { ethers } = require("ethers");
const fs = require("fs");

const MASTER_KEY = process.env.MASTER_KEY; // Set via: $env:MASTER_KEY="0x..."
const RPC = "https://base-mainnet.public.blastapi.io";

const VAULT_ADDR = "0x09E22b6a1937FbA0194c101E541E086C7711114e";
const ROUTER_ADDR = "0xdCdB81B7BA194AD5F4440559afE0267C8cDBC4eD";

const CKT = "0x5ccdf98d0b48bf8d51e9196d738c5bbf6b33c274";
const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const POSITION_MANAGER = "0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1";
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

// Load ABIs from compiled artifacts
const vaultABI = JSON.parse(fs.readFileSync("out/GasVault.sol/GasVault.json", "utf8")).abi;
const routerABI = JSON.parse(fs.readFileSync("out/GasVaultRouter.sol/GasVaultRouter.json", "utf8")).abi;

const ERC20_ABI = ["function approve(address,uint256) returns (bool)", "function balanceOf(address) view returns (uint256)"];
const PM_ABI = ["function approve(address,uint256)"];

async function sendAndWait(label, contract, method, args) {
    console.log(`\n>>> ${label}`);
    const tx = await contract[method](...args);
    console.log(`  tx: ${tx.hash}`);
    const receipt = await tx.wait();
    console.log(`  confirmed block: ${receipt.blockNumber}, gas: ${receipt.gasUsed.toString()}`);
    return receipt;
}

async function main() {
    const provider = new ethers.JsonRpcProvider(RPC);
    const master = new ethers.Wallet(MASTER_KEY, provider);
    console.log("Master:", master.address);
    console.log("ETH:", ethers.formatEther(await provider.getBalance(master.address)));

    const vault = new ethers.Contract(VAULT_ADDR, vaultABI, master);
    const router = new ethers.Contract(ROUTER_ADDR, routerABI, master);

    // Step 1: setInitialRouter
    const currentRouter = await vault.router();
    if (currentRouter === ethers.ZeroAddress) {
        await sendAndWait("vault.setInitialRouter", vault, "setInitialRouter", [ROUTER_ADDR]);
    } else {
        console.log("Router already set:", currentRouter);
    }

    // Step 2: Approve Router as LP NFT operator
    const pm = new ethers.Contract(POSITION_MANAGER, PM_ABI, master);
    await sendAndWait("positionManager.approve(router, LP)", pm, "approve", [ROUTER_ADDR, LP_TOKEN_ID]);

    // Step 3: Set LP token ID
    await sendAndWait("router.setLpTokenId", router, "setLpTokenId", [LP_TOKEN_ID]);

    // Step 4: Whitelist Chisiki contracts
    for (let i = 0; i < CHISIKI_CONTRACTS.length; i++) {
        const addr = CHISIKI_CONTRACTS[i];
        const isWhitelisted = await router.isChisikiContract(addr);
        if (!isWhitelisted) {
            await sendAndWait(`addChisikiContract[${i}]`, router, "addChisikiContract", [addr]);
        } else {
            console.log(`  Already whitelisted: ${addr}`);
        }
    }

    // Step 5: Donate USDC
    const usdc = new ethers.Contract(USDC, ERC20_ABI, master);
    const usdcBal = await usdc.balanceOf(master.address);
    console.log("\nUSDC balance:", ethers.formatUnits(usdcBal, 6));

    if (usdcBal >= BigInt(DONATE_USDC)) {
        await sendAndWait("USDC.approve", usdc, "approve", [ROUTER_ADDR, DONATE_USDC]);
        await sendAndWait("router.donateUSDC", router, "donateUSDC", [DONATE_USDC]);
    } else {
        console.log("WARN: Insufficient USDC for donation");
    }

    // Verify final state
    console.log("\n=== VERIFICATION ===");
    console.log("vault.router:", await vault.router());
    console.log("router.lpTokenId:", (await router.lpTokenId()).toString());
    console.log("router.reserveUSDC:", ethers.formatUnits(await router.reserveUSDC(), 6));
    for (const addr of CHISIKI_CONTRACTS) {
        console.log(`  isChisiki[${addr.slice(0, 8)}]: ${await router.isChisikiContract(addr)}`);
    }

    // Save deployment info
    const deployment = {
        network: "base-mainnet", chainId: 8453,
        deployer: master.address,
        deployedAt: new Date().toISOString(),
        contracts: { GasVault: VAULT_ADDR, GasVaultRouter: ROUTER_ADDR },
        pools: {
            "CKT-USDC": "0xb434318910ed11a15fa86b38aa398efCf3C83df0",
            "USDC-WETH": "0xd0b53D9277642d899DF5C87A3966A349A798F224",
        },
        lpTokenId: LP_TOKEN_ID,
        whitelistedContracts: CHISIKI_CONTRACTS,
        usdcDonated: DONATE_USDC,
    };
    fs.writeFileSync("deployments/base-mainnet.json", JSON.stringify(deployment, null, 2));
    console.log("\n=== DEPLOYMENT COMPLETE ===");
    console.log(JSON.stringify(deployment, null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
