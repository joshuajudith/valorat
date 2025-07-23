# Valorat Vault Contract

A Clarity smart contract for managing STX deposits and shares in a secure vault system. Users deposit STX to receive shares, which can later be redeemed for STX minus a management fee. The contract includes administrative controls, emergency functions, and read-only queries for transparency.

---

## Features

- **Deposit STX:** Users deposit STX and receive vault shares.
- **Withdraw STX:** Redeem shares for STX, minus a management fee.
- **Management Fee:** Configurable fee (default 1%, max 10%).
- **Pause/Unpause Vault:** Admins can pause or resume vault operations.
- **Emergency Withdraw:** Vault manager can withdraw all assets in emergencies.
- **Transparent Queries:** View vault and user info, share price, and withdrawal calculations.

---

## Key Concepts

- **Shares:** Represent user’s claim on vault assets.
- **Vault Manager & Owner:** Principals with admin rights.
- **Fee:** Deducted on withdrawals, sent to vault manager.

---

## Usage

### Initialization

```clarity
(initialize manager fee-bps)
```
- Set vault manager and management fee (only once, by contract owner).

### Depositing

```clarity
(deposit amount)
```
- Deposit STX and receive shares proportional to vault assets.

### Withdrawing

```clarity
(withdraw share-amount)
```
- Redeem shares for STX, minus management fee.

### Admin Controls

```clarity
(pause-vault)
(unpause-vault)
(set-management-fee new-fee-bps)
(transfer-management new-manager)
```
- Pause/unpause vault, update fee, or transfer manager role.

### Emergency

```clarity
(emergency-withdraw)
```
- Manager can withdraw all STX from the vault.

---

## Read-only Functions

- `get-vault-info`: Vault stats and balances.
- `get-user-info user`: User’s shares, deposits, and withdrawable assets.
- `get-share-price`: Current share price (fixed point).
- `calculate-deposit-shares amount`: Shares for a deposit.
- `calculate-withdrawal-amount shares`: Withdrawal amount and fee.
- `get-contract-balance`: Vault’s STX balance.

---

## Error Codes

- `u100`: Not authorized
- `u101`: Vault paused
- `u102`: Zero amount
- `u103`: Insufficient shares
- `u104`: Insufficient balance
- `u105`: Already initialized
- `u106`: Invalid fee
- `u107`: Transfer failed

---

## Security

- Only authorized principals can perform admin actions.
- Vault can be paused for safety.
- Emergency withdrawal for asset protection.

---

## License

MIT License (add your license details here).

---

## Author

[Your Name or Organization]
