const { ethers } = require("ethers");
const fs = require("fs");

const PRIVATE_KEY = process.env.PRIVATE_KEY;
if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY env var not set!");
const RPC = "https://mainnet.base.org";

const V3_DATA_PATH = ".deployed_v3.json";
if (!fs.existsSync(V3_DATA_PATH)) {
    console.error("FATAL: .deployed_v3.json not found!");
    process.exit(1);
}
const { GasVaultRouterV3 } = JSON.parse(fs.readFileSync(V3_DATA_PATH));

const LP_TOKEN_ID = 4978169;
const CHISIKI_CONTRACTS = [
    "0x7e012e4d81921bc56282dac626f3591fe8c49b54",
    "0x12dc6fbaa22d38ebbec425ba76db82f0c8594306",
    "0x873a5f2ba8c7b1cf7b050db5022c835487610eef",
    "0x4ffcbc98572b1169cb652bafc72c76e5cfb0de10",
    "0x52a506e7f8d9c6006f7090414c38e9630c8bb2df",
    "0x46125739feab5cdaa2699e39c0d71101146ffbe4",
    "0x3959172dc74ba6ac5abbf68b6ce24041c03e6a8a",
    "0xf82ee34ffd46c515a525014f874867f6c83d5a94"
];

async function main() {
    const provider = new ethers.JsonRpcProvider(RPC);
    const master = new ethers.Wallet(PRIVATE_KEY, provider);
    let nonce = await provider.getTransactionCount(master.address);

    const routerJSON = JSON.parse(fs.readFileSync("out/GasVaultRouter.sol/GasVaultRouter.json", "utf8"));
    const router = new ethers.Contract(GasVaultRouterV3, routerJSON.abi, master);

    console.log(`Master: ${master.address}`);
    console.log(`Setting up GasVaultRouter V3: ${GasVaultRouterV3}`);

    // Set LP Token
    console.log(`Setting LP Token ID to ${LP_TOKEN_ID}...`);
    const txLp = await router.setLpTokenId(LP_TOKEN_ID, { nonce: nonce++ });
    await txLp.wait();

    // Whitelist
    console.log(`Whitelisting ${CHISIKI_CONTRACTS.length} protocol contracts...`);
    for (const addr of CHISIKI_CONTRACTS) {
        const txWl = await router.addChisikiContract(addr, { nonce: nonce++ });
        await txWl.wait();
        console.log(`  └ Whitelisted: ${addr}`);
    }

    console.log("✅ V3 Setup Complete!");
}

main().catch(e => { console.error("FATAL:", e); process.exit(1); });
