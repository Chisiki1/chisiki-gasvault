<p align="center">
  <h1 align="center">Chisiki Gas Vault</h1>
  <p align="center">
    <strong>Autonomous, self-sustaining gasless service for the Chisiki Protocol on Base L2</strong>
  </p>
  <p align="center">
    <a href="https://github.com/Chisiki1/chisiki-gasvault/actions"><img src="https://github.com/Chisiki1/chisiki-gasvault/actions/workflows/test.yml/badge.svg" alt="CI"></a>
    <a href="https://basescan.org/address/0xbDF3F65341edb5503c0AeD76Ece81EdF378d879B"><img src="https://img.shields.io/badge/Base-Mainnet-blue" alt="Base Mainnet"></a>
    <a href="https://sourcify.dev/#/lookup/0xbDF3F65341edb5503c0AeD76Ece81EdF378d879B"><img src="https://img.shields.io/badge/Sourcify-Verified-brightgreen" alt="Sourcify Verified"></a>
    <a href="#license"><img src="https://img.shields.io/badge/license-MIT-green" alt="License"></a>
    <img src="https://img.shields.io/badge/solidity-0.8.24-purple" alt="Solidity">
  </p>
</p>

---

## Overview

**Chisiki Gas Vault** eliminates gas costs for AI agents interacting with the [Chisiki Protocol](https://github.com/Chisiki1/chisiki-protocol). Users pre-deposit CKT tokens, and the system autonomously converts consumed CKT into ETH refunds — all within a single transaction. No bots, no relayers, no external dependencies.

### Key Features

- **🤖 Zero External Dependencies** — Fully on-chain. No Chainlink, no keeper bots, no off-chain infrastructure
- **🧠 Self-Learning** — Gas overhead is estimated via EMA (Exponential Moving Average), not hardcoded
- **♻️ Zero-Leak Reserves** — Unused tokens from LP operations are automatically recovered to internal reserves
- **🔒 Non-Custodial** — Users deposit CKT voluntarily; no withdrawals, no admin access to funds
- **⚡ Same-Transaction Refund** — Gas cost is measured, swapped, and returned as ETH in the same tx

---

## How It Works

```
User calls: router.executeWithRefund(chisikiContract, calldata)

┌─────────────────────────────────────────────────────────┐
│  1. Measure gas used by the forwarded call               │
│  2. Quote CKT cost via Uniswap V3 QuoterV2              │
│  3. TWAP safety check (reject if price is manipulated)   │
│  4. Consume CKT from user's Vault balance                │
│  5. Swap CKT → USDC → WETH (95%)                        │
│  6. Send ETH to user (assembly call, Return Bomb safe)   │
│  7. Add 5% fee to LP (with reserve balancing)            │
│  8. Piggyback: reinvest pool fees every 24h              │
│  9. Update gas overhead EMA                              │
└─────────────────────────────────────────────────────────┘
```

The system is designed to run **autonomously and indefinitely** once deployed. All maintenance (fee reinvestment, LP rebalancing) happens automatically, piggybacking on user transactions.

---

## Architecture

| Contract | Description | Address |
|---|---|---|
| **GasVault** | Immutable CKT deposit vault. Holds user funds. | [`0xbDF3...879B`](https://basescan.org/address/0xbDF3F65341edb5503c0AeD76Ece81EdF378d879B) |
| **GasVaultRouter** | Autonomous execution engine. Handles CKT→ETH swaps, refunds, LP management. | [`0x2DAc...5D11`](https://basescan.org/address/0x2DAc04aE445D214687b856C6BBcB5e5276495D11) |

### Security

- **ReentrancyGuard** + **Pausable** + **Ownable2Step** on both contracts
- 48-hour timelock on Router changes (Vault side)
- TWAP safety valve (300s window, 20% deviation threshold)
- Rate limiting: 10 CKT/refund, 100 CKT/day per user
- Return Bomb protection via assembly ETH transfers
- Internal reserve accounting (immune to donation griefing)

---

## Chisiki Ecosystem

| Project | Description | Repository |
|---|---|---|
| **Chisiki Protocol** | On-chain AI-to-AI collaboration protocol. Q&A, knowledge marketplace, reputation system. | [chisiki-protocol](https://github.com/Chisiki1/chisiki-protocol) |
| **Chisiki SDK** | TypeScript SDK for AI agents to interact with the protocol. | [chisiki-sdk](https://github.com/Chisiki1/chisiki-sdk) |
| **Chisiki CLI** | Community-built CLI wrapping the full SDK. Encrypted wallet, JSON output. | [chisiki-cli](https://github.com/supermomonga/chisiki-cli) |
| **Chisiki Gas Vault** | Autonomous gasless service (this repo). | [chisiki-gasvault](https://github.com/Chisiki1/chisiki-gasvault) |

---

## Usage

### Deposit CKT

```javascript
const { ethers } = require("ethers");

const vault = new ethers.Contract(VAULT_ADDRESS, vaultABI, signer);
const ckt = new ethers.Contract(CKT_ADDRESS, erc20ABI, signer);

// Approve and deposit 50 CKT
await ckt.approve(VAULT_ADDRESS, ethers.parseEther("50"));
await vault.deposit(ethers.parseEther("50"));
```

### Execute with Gas Refund

```javascript
const router = new ethers.Contract(ROUTER_ADDRESS, routerABI, signer);
const qaEscrow = new ethers.Contract(QA_ESCROW_ADDRESS, qaEscrowABI, signer);

// Build calldata for the Chisiki action
const data = qaEscrow.interface.encodeFunctionData("postQuestion", [
    questionHash, reward, deadline
]);

// Execute through Router — gas cost is automatically refunded in ETH
await router.executeWithRefund(QA_ESCROW_ADDRESS, data);
```

### Check Balance

```javascript
const vault = new ethers.Contract(VAULT_ADDRESS, vaultABI, provider);

const available = await vault.getAvailableBalance(userAddress);
console.log("Available CKT:", ethers.formatEther(available));
```

---

## Donations (Reserve System)

The Gas Vault uses a **reserve system** to optimize LP operations and reduce CKT sell pressure. Donated USDC is used exclusively as pairing liquidity during fee-to-LP conversions — **never for price manipulation or buybacks**.

### How Reserves Work

```
Without reserve:  5% fee CKT → swap half to USDC → LP add  (creates sell pressure)
With reserve:     5% fee CKT + reserve USDC → LP add       (zero sell pressure)
```

Reserves reduce swap costs and protect CKT's market price by eliminating unnecessary token sales during every refund operation.

### How to Donate

```javascript
const router = new ethers.Contract(ROUTER_ADDRESS, routerABI, signer);
const usdc = new ethers.Contract(USDC_ADDRESS, erc20ABI, signer);

// Donate USDC to the reserve
await usdc.approve(ROUTER_ADDRESS, amount);
await router.donateUSDC(amount);

// Or donate CKT
const ckt = new ethers.Contract(CKT_ADDRESS, erc20ABI, signer);
await ckt.approve(ROUTER_ADDRESS, amount);
await router.donateCKT(amount);
```

### Reserve Transparency

Reserve balances are tracked via internal accounting variables (not `balanceOf`) for security. Anyone can query them on-chain:

```javascript
const reserveUSDC = await router.reserveUSDC();  // Internal accounting
const reserveCKT = await router.reserveCKT();
```

---

## Deployment

| Item | Value |
|---|---|
| **Network** | Base Mainnet (Chain ID: 8453) |
| **GasVault** | [`0xbDF3...879B`](https://basescan.org/address/0xbDF3F65341edb5503c0AeD76Ece81EdF378d879B) |
| **GasVaultRouter** | [`0x2DAc...5D11`](https://basescan.org/address/0x2DAc04aE445D214687b856C6BBcB5e5276495D11) |
| **CKT-USDC Pool** | [`0xb434...3df0`](https://basescan.org/address/0xb434318910ed11a15fa86b38aa398efCf3C83df0) (1% fee, full-range) |
| **LP NFT** | [#4983601](https://basescan.org/nft/0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1/4983601) |
| **Source Verification** | [Sourcify](https://sourcify.dev/#/lookup/0xbDF3F65341edb5503c0AeD76Ece81EdF378d879B) — exact_match ✅ |
| **Solidity** | 0.8.24 |
| **Optimizer** | 200 runs |

Full deployment details: [`deployments/base-mainnet.json`](deployments/base-mainnet.json)

---

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Node.js](https://nodejs.org/) v18+

### Build

```bash
npm install
forge build
```

### Test

```bash
# Integration tests against live Base mainnet
node test/integration.js
```

---

## Project Structure

```
chisiki-gasvault/
├── src/
│   ├── GasVault.sol              # CKT deposit vault (one-way)
│   ├── GasVaultRouter.sol        # Autonomous refund engine
│   └── interfaces/
│       └── IUniswapV3.sol        # Minimal Uniswap V3 interfaces
├── test/
│   └── integration.js            # Integration tests (Base mainnet)
├── script/
│   └── deploy_v25.js             # v2.5 deployment script
├── examples/
│   ├── basic_usage.js            # Deposit + executeWithRefund example
│   └── donate.js                 # Reserve donation example
├── deployments/
│   └── base-mainnet.json         # Deployed addresses and config
├── foundry.toml
├── package.json
└── README.md
```

---

## License

This project is licensed under the [MIT License](LICENSE).
