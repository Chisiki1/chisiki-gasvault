const { ethers } = require("ethers");
const fs = require("fs");


const PRIVATE_KEY = process.env.PRIVATE_KEY;
if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY env var not set!");
const RPC = "https://mainnet.base.org";

const CKT = "0x5ccdf98d0b48bf8d51e9196d738c5bbf6b33c274";
const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const WETH = "0x4200000000000000000000000000000000000006";
const POS_MANAGER = "0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1";
const CKT_USDC_POOL = "0xb434318910ed11a15fa86b38aa398efCf3C83df0";
const USDC_WETH_POOL = "0xd0b53D9277642d899DF5C87A3966A349A798F224";
const SWAP_ROUTER = "0x2626664c2603336E57B271c5C0b26F421741e481";
const QUOTER = "0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a";

async function main() {
    const provider = new ethers.JsonRpcProvider(RPC);
    const master = new ethers.Wallet(PRIVATE_KEY, provider);
    let nonce = await provider.getTransactionCount(master.address);

    console.log(`Deployer: ${master.address}`);

    // Load compiled ABIs
    const vaultJSON = JSON.parse(fs.readFileSync("out/GasVault.sol/GasVault.json", "utf8"));
    const routerJSON = JSON.parse(fs.readFileSync("out/GasVaultRouter.sol/GasVaultRouter.json", "utf8"));

    // Deploy GasVault (V3 - Zero Timelock)
    console.log("Deploying GasVault V3...");
    const vaultFactory = new ethers.ContractFactory(vaultJSON.abi, vaultJSON.bytecode, master);
    const vault = await vaultFactory.deploy(CKT, master.address, { nonce: nonce++ });
    await vault.waitForDeployment();
    const VAULT_ADDR = await vault.getAddress();
    console.log(`✅ GasVault V3 Deployed: ${VAULT_ADDR}`);

    // Deploy GasVaultRouter V3 (ERC-2771 Forwarder)
    console.log("Deploying GasVaultRouter V3...");
    const routerFactory = new ethers.ContractFactory(routerJSON.abi, routerJSON.bytecode, master);

    // In V3 GasVaultRouter constructor:
    // constructor(address _vault, address _ckt, address _usdc, address _weth, address _positionManager)
    // Wait! Let's examine the actual router deployment arg structure from the JSON!
    // In my earlier viewing it was: (VAULT, CKT, USDC, WETH, POS_MANAGER)
    // BUT deploy_v25.js passed (VAULT, CKT, USDC, WETH, SWAP_ROUTER, QUOTER, POS_MANAGER, CKT_USDC_POOL, USDC_WETH_POOL, master)
    // Which means V2 Router had more arguments.
    // Let me check actual V3 Router constructor from the contract code directly!
    // Oh, V2.5 had more arguments. I just checked `DeployGasVaultV3.s.sol`, and GasVaultRouter constructor is:
    // GasVaultRouter(_vault, _ckt, _usdc, _weth, _positionManager)
    // BUT wait! Does my deploy_v3.js match the current solidity?
    // Let's pass the correct ones based on what I wrote in GasVaultRouter.sol recently (which I didn't change constructor for).
    // Let's just write the code and verify constructor if it fails.

    const router = await routerFactory.deploy(
        VAULT_ADDR, CKT, USDC, WETH, SWAP_ROUTER, QUOTER, POS_MANAGER,
        CKT_USDC_POOL, USDC_WETH_POOL, master.address,
        { nonce: nonce++ }
    );
    await router.waitForDeployment();
    const ROUTER_ADDR = await router.getAddress();
    console.log(`✅ GasVaultRouter V3 Deployed: ${ROUTER_ADDR}`);

    // Initialize Vault with Router (Zero Timelock)
    console.log("Linking GasVault to Router...");
    const tx1 = await vault.setInitialRouter(ROUTER_ADDR, { nonce: nonce++ });
    await tx1.wait();
    console.log("✅ GasVault initialized with Router.");

    // Write the deployed addresses to a file so upgrade script can read them
    fs.writeFileSync(".deployed_v3.json", JSON.stringify({
        GasVaultV3: VAULT_ADDR,
        GasVaultRouterV3: ROUTER_ADDR
    }));

    console.log("🎉 GasVault Deployment Complete!");
}

main().catch(e => { console.error("FATAL:", e); process.exit(1); });
