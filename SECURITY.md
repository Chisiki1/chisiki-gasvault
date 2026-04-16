# Security

## Reporting Vulnerabilities

If you discover a security vulnerability, please report it responsibly:

1. **Do NOT** open a public GitHub issue
2. Email details to the repository maintainers
3. Include steps to reproduce, potential impact, and suggested fix if available

## Security Model

### Contract Architecture

- **GasVault**: Deposit-only vault. No withdraw function exists. CKT can only be consumed by the authorized Router.
- **GasVaultRouter**: Autonomous refund engine. Cannot transfer LP tokens, cannot remove liquidity, limited to 10 CKT per refund and 100 CKT per day per user.

### Access Controls

| Action | Who Can Call | Protection |
|---|---|---|
| `deposit()` | Anyone | — |
| `executeWithRefund()` | Anyone | Whitelisted targets only |
| `consumeForRefund()` | Router only | Enforced by Vault |
| `setInitialRouter()` | Owner | One-time only, before any router is set |
| `proposeRouterChange()` | Owner | 48-hour timelock |
| `pause()` / `unpause()` | Owner | Ownable2Step |
| `rescueTokens()` | Owner | Cannot touch reserved funds |

### Attack Mitigations

| Attack Vector | Mitigation |
|---|---|
| Reentrancy | `ReentrancyGuard` on all external functions |
| Flash loan drain | No `withdraw()` function exists |
| Sandwich attack | amountOutMinimum with 1% slippage protection |
| TWAP manipulation | 300-second TWAP with 20% deviation threshold |
| Return Bomb | Assembly-based ETH transfer + WETH fallback |
| Donation griefing | Internal accounting (`reserveUSDC`/`reserveCKT`), not `balanceOf` |
| Gas griefing | `MAX_GAS_PER_ACTION = 1,000,000` cap |
| Paymaster drain | Attacker consumes own CKT (self-punishing) |

### Audit Status

This code has not been audited by a third-party security firm. Use at your own risk.
