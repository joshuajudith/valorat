# Valorat Vault Contract

A Clarity smart contract for managing STX deposits and shares with yield generation and enhanced risk management. Users can deposit STX to receive shares, earn yield, and withdraw assets subject to safety controls.

---

## New Features

### Yield Generation
- **Annual Yield:** Configurable yield rate (default 5%, max 20%)
- **Yield Compounding:** Automatic yield calculation and distribution
- **Yield Tracking:** Monitor accumulated and pending yield

### Risk Management
- **Circuit Breaker:** Automatic pause on significant price drops
- **Withdrawal Limits:**
  - Daily withdrawal caps
  - Single withdrawal percentage limits
  - Withdrawal tracking
- **Cooldown Period:** Required waiting time after circuit breaker triggers

---

## Core Features

- **Deposit STX:** Users deposit STX and receive vault shares
- **Withdraw STX:** Redeem shares for STX, minus management fee
- **Management Fee:** Configurable fee (default 1%, max 10%)
- **Admin Controls:** Pause/unpause vault, emergency functions

---

## Usage

### Yield Management

```clarity
(set-yield-rate new-rate)
(update-yield)
(compound-yield)
```

### Risk Management

```clarity
(set-withdrawal-limits daily-limit single-withdrawal-pct)
(reset-circuit-breaker)
```

### Core Operations

```clarity
(deposit amount)
(withdraw share-amount)
```

### Admin Controls

```clarity
(pause-vault)
(unpause-vault)
(set-management-fee new-fee-bps)
(transfer-management new-manager)
```

---

## New Error Codes

- `u200`: Withdrawal too large
- `u201`: Daily limit exceeded
- `u202`: Circuit breaker triggered
- `u203`: Cooldown not expired
- `u204`: Invalid yield rate

## New Read-only Functions

- `get-yield-info`: Yield rates and accumulation stats
- `get-risk-metrics`: Circuit breaker and withdrawal limit info
- `get-withdrawal-limits-info`: Check withdrawal constraints

---

## Security Enhancements

- Circuit breaker for price protection
- Configurable withdrawal limits
- Daily withdrawal tracking
- Cooldown periods after circuit breaker triggers
- Yield rate limits

---

## Constants

```clarity
MAX-YIELD-RATE: u2000 (20% annual max)
BLOCKS-PER-YEAR: u52560
BASIS-POINTS: u10000
```

---

## License

MIT License (add your license details here)

---

## Author

[judith joshua]
