# VaultWave Protocol — Flash Lending & Compound Interest

> **Audit ID**: `VW-2024-001`
> **nSLOC**: ~730
> **Contracts**: 5
> **Chain**: Ethereum Mainnet
> **Compiler**: Solidity `0.8.20`
> **Audit Type**: Competitive Security Review

---

## 1. Protocol Overview

**VaultWave** is a flash-loan-enabled lending protocol with compound interest, fee-bearing swaps, and on-chain yield calculation. Users deposit assets into a lending pool, borrow against collateral at variable compound rates, and can execute same-transaction flash loans. A fee-bearing swap module handles token exchanges, and a dedicated yield calculator computes annualized returns.

The protocol is designed so that:
- **Flash lender** (`WaveFlashLender`) provides single-transaction liquidity with callback-based repayment
- **Compound lender** (`WaveCompoundLender`) accrues per-block compound interest via a global `debtIndex`
- **Fee swap** (`WaveFeeSwap`) charges basis-point fees on token swaps
- **Yield calculator** (`WaveYieldCalculator`) estimates APY for depositors
- **Base token** (`WaveToken`) serves as the lending/borrowing unit

The interaction between compound interest accrual, flash loan callbacks, and fee calculations creates multiple exploit surfaces — particularly when temporal ordering invariants are violated.

---

## 2. Architecture

```
                     ┌────────────────────────────────────┐
                     │          User / Frontend            │
                     └───┬──────────┬──────────┬──────────┘
                         │          │          │
            ┌────────────▼──────┐   │   ┌──────▼──────────────┐
            │  WaveFlashLender  │   │   │  WaveCompoundLender  │
            │  (flash loans,    │   │   │  (compound interest, │
            │   callback-based) │   │   │   debtIndex accrual) │
            └────────┬──────────┘   │   └──────┬──────────────┘
                     │              │           │
            ┌────────▼──────────┐   │   ┌──────▼──────────────┐
            │   WaveFeeSwap     │   │   │ WaveYieldCalculator  │
            │  (fee-bearing     │   │   │  (APY computation,   │
            │   token swaps)    │   │   │   rounding issues)   │
            └────────┬──────────┘   │   └──────────────────────┘
                     │              │
                     └──────┬───────┘
                     ┌──────▼──────────────┐
                     │    WaveToken         │
                     │  (ERC20 base asset)  │
                     └─────────────────────┘
```

### Interest Accrual Flow
```
accrueInterest() ──► debtIndex *= (1 + rate * elapsed)
                            │
           borrow()/repay() │ ← NO call to accrueInterest()!
                            │   (stale index used for accounting)
                            ▼
                    User debt = shares × debtIndex
                    (stale index → wrong debt calculation)
```

---

## 3. Contracts

| Contract | File | nSLOC | Description |
|----------|------|-------|-------------|
| `WaveToken` | `WaveToken.sol` | ~80 | ERC20 base token with mint/burn capabilities |
| `WaveFlashLender` | `WaveFlashLender.sol` | ~150 | Flash loan with callback, missing balance verification |
| `WaveCompoundLender` | `WaveCompoundLender.sol` | ~240 | Compound-interest lending with per-block debtIndex |
| `WaveFeeSwap` | `WaveFeeSwap.sol` | ~160 | Fee-bearing swap with basis-point fee calculation |
| `WaveYieldCalculator` | `WaveYieldCalculator.sol` | ~100 | Annualized yield computation with arithmetic |

**Total nSLOC**: ~730

---

## 4. Scope & Focus

All 5 contracts are in scope. This review focuses on **lending mechanics and arithmetic correctness**:
- Flash loan repayment verification completeness
- Compound interest temporal invariants (accrue-before-action pattern)
- Fee calculation rounding behavior on small amounts
- Division-before-multiplication precision loss
- State consistency under timing manipulation

Out of scope: Gas optimization, code style, informational findings.

---

## 5. Audit Findings Report

The following 5 vulnerabilities were confirmed during the security review. They are disclosed here as part of the post-audit transparency report.

---

### F-01: Flash Loan Without Repayment Verification — Total Pool Drain

| Field | Value |
|-------|-------|
| **Severity** | Critical |
| **Impact** | Complete Pool Drain (100% of lending pool) |
| **Likelihood** | High (trivially exploitable by any user) |
| **File** | `WaveFlashLender.sol` |
| **Location** | `flashLoan()` — checks callback return value, NOT actual balance |
| **Difficulty** | Easy |

**Description**: The flash loan facility executes a callback to the borrower (`onFlashLoan()`) and checks that the callback returns `true`. However, it does **NOT verify** that the contract's token balance has been restored: `balanceOf(address(this)) >= balanceBefore + fee` is never checked. The boolean return value is entirely controlled by the borrower.

An attacker deploys a malicious receiver contract whose `onFlashLoan()` simply returns `true` without transferring any tokens back. The flash loan succeeds, and the attacker walks away with the entire borrowed amount plus keeps the borrowed funds.

**Exploit Path**:
1. Attacker deploys `MaliciousReceiver` with `onFlashLoan()` returning `true` but no transfer
2. Attacker calls `flashLoan(entirePoolBalance, receiverAddress, data)`
3. `WaveFlashLender` transfers entire pool to attacker's receiver
4. Receiver's `onFlashLoan()` fires — keeps all tokens, returns `true`
5. `flashLoan()` checks return value = `true` → succeeds
6. Pool is now empty; all depositor funds are stolen

**Recommendation**: Add post-callback balance check: `require(token.balanceOf(address(this)) >= balanceBefore + fee, "Flash loan not repaid")`.

---

### F-02: Stale Debt Index — No Interest Accrual Before Borrow/Repay

| Field | Value |
|-------|-------|
| **Severity** | Critical |
| **Impact** | Under-accounting of Debt → Protocol Insolvency |
| **Likelihood** | High (triggers on every borrow/repay when index is stale) |
| **File** | `WaveCompoundLender.sol` |
| **Location** | `borrow()` and `repay()` — use `debtIndex` without calling `accrueInterest()` |
| **Difficulty** | Medium |

**Description**: The lending market uses a compound interest `debtIndex` that grows per-block via `accrueInterest()`. User debt is calculated as `shares × debtIndex`. The critical invariant is that `accrueInterest()` must be called BEFORE any `borrow()` or `repay()` to ensure the index reflects current interest.

Neither `borrow()` nor `repay()` calls `accrueInterest()` first. If the index hasn't been updated for 100 blocks and the interest rate is 10% APY, debt is under-accounted by the 100-block interest gap. Borrowers effectively receive free tokens; the protocol becomes insolvent as recorded debt falls below actual obligation.

**Exploit Path**:
1. `debtIndex` = 1.0 at block 1000 (last `accrueInterest()` call)
2. 500 blocks pass — true index should be 1.05 (5% interest accumulated)
3. Attacker calls `borrow(1,000,000 tokens)` at block 1500
4. Debt recorded as `1,000,000 / 1.0 = 1,000,000 shares` (should be `1,000,000 / 1.05 = 952,381 shares`)
5. Attacker received ~47,619 tokens more than their debt accounts for
6. Attacker immediately calls `accrueInterest()` → index jumps to 1.05
7. Other borrowers' debt increases; attacker's under-accounted position profits

**Recommendation**: Add `accrueInterest()` as the first line in both `borrow()` and `repay()` functions.

---

### F-03: Temporal Interest Gaming — Multi-Call Exploit

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Impact** | Artificial Interest Inflation → Profit Extraction |
| **Likelihood** | Medium (requires specific state conditions) |
| **File** | `WaveCompoundLender.sol` |
| **Location** | `accrueInterest()` — skips `lastAccrueBlock` update when `totalBorrowed == 0` |
| **Difficulty** | Medium |

**Description**: `accrueInterest()` calculates interest as `rate × (block.number - lastAccrueBlock)` and applies it to `totalBorrowed`. When `totalBorrowed == 0`, the function returns early without updating `lastAccrueBlock`. This means the elapsed block counter continues growing even though there is no active debt.

An attacker exploits this by creating a zero-borrow window, letting blocks accumulate, then opening a small position and triggering `accrueInterest()` — which applies the FULL accumulated block gap to the new borrow as if debt had existed the entire time.

**Exploit Path**:
1. Attacker repays all debt → `totalBorrowed = 0`
2. 10,000 blocks pass — `accrueInterest()` is called but returns early, no debt
3. `lastAccrueBlock` is NOT updated → still points to 10,000 blocks ago
4. Attacker deposits a large amount as lender, borrows a tiny amount
5. Attacker calls `accrueInterest()` → elapsed = 10,000 blocks, applies compound interest
6. Enormous interest accrued on `totalBorrowed` in one transaction
7. Attacker earns outsized lender yield from the artificial interest spike

**Recommendation**: Always update `lastAccrueBlock = block.number` regardless of whether `totalBorrowed` is zero.

---

### F-04: Fee Bypass via Rounding — Zero-Fee Micro-Swaps

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Impact** | Complete Fee Revenue Loss for Protocol |
| **Likelihood** | High (trivially automatable) |
| **File** | `WaveFeeSwap.sol` |
| **Location** | `swap()` — `fee = (amountIn * feeBps) / 10000` truncates to 0 for small inputs |
| **Difficulty** | Easy |

**Description**: Swap fees are calculated as `fee = (amountIn * feeBps) / 10000`. With a typical `feeBps = 30` (0.3%), any `amountIn < 334` results in `fee = 0` due to integer truncation: `333 * 30 / 10000 = 0`. An attacker can split a large swap into thousands of sub-334 micro-swaps, each paying zero fee.

The economic impact scales linearly: a 1M token swap split into ~3,000 micro-swaps of 333 tokens each pays **zero total fees** versus the intended 3,000 tokens in fees.

**Exploit Path**:
1. Attacker wants to swap 1,000,000 tokens
2. Normal fee: `1,000,000 * 30 / 10,000 = 3,000 tokens` (0.3%)
3. Attacker splits into 3,003 swaps of 333 tokens each
4. Each swap: `333 * 30 / 10,000 = 0` → zero fee
5. Total fee paid: **0 tokens** (vs intended 3,000)
6. Attacker saves 3,000 tokens; protocol loses all fee revenue
7. Bot repeats on every swap opportunity → protocol fee income = 0

**Recommendation**: Add minimum fee enforcement: `fee = max((amountIn * feeBps) / 10000, minFee)` where `minFee ≥ 1`.

---

### F-05: Division Before Multiplication — Yield Precision Loss

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Impact** | Zero Yield for Small Depositors → Silent Wealth Transfer |
| **Likelihood** | High (affects all sub-pool-size deposits) |
| **File** | `WaveYieldCalculator.sol` |
| **Location** | `calculateYield()` — `(principal / totalPool)` truncates before multiply |
| **Difficulty** | Easy |

**Description**: The yield calculator computes returns as:
```
yield = (principal / totalPool) * rewardAmount * duration / YEAR
```
The `principal / totalPool` division occurs **first**. For any `principal < totalPool`, this truncates to `0`, making the entire expression `0`. The correct formula is:
```
yield = (principal * rewardAmount * duration) / (totalPool * YEAR)
```

This means every depositor whose balance is less than `totalPool` (practically all users) earns **zero yield**. Their rightful share of rewards remains unclaimed or is silently absorbed by the protocol.

**Exploit Path**:
1. Pool has `totalPool = 10,000,000 tokens`, `rewardAmount = 100,000`
2. Alice deposits 1,000 tokens (0.01% of pool)
3. `calculateYield(1000, ...)` → `1000 / 10,000,000 = 0` → yield = **0**
4. Alice's expected yield: `1000 * 100,000 / 10,000,000 = 10 tokens`
5. Alice receives nothing; her 10 tokens remain in the pool
6. Whale with 9,999,000 tokens: `9,999,000 / 10,000,000 = 0` → also 0! (still < totalPool)
7. **ALL users earn zero** until a single depositor exceeds `totalPool` — which never happens in practice

**Recommendation**: Multiply before dividing: `yield = (principal * rewardAmount * duration) / (totalPool * YEAR)`. Guard against overflow with intermediate `uint256` math.

---

## 6. Findings Summary

| ID | Title | Severity | Impact | Difficulty | Contract |
|----|-------|----------|--------|------------|----------|
| F-01 | Flash Loan No Repayment Check | **Critical** | Total pool drain | Easy | `WaveFlashLender` |
| F-02 | Stale Debt Index | **Critical** | Protocol insolvency | Medium | `WaveCompoundLender` |
| F-03 | Temporal Interest Gaming | **High** | Artificial interest inflation | Medium | `WaveCompoundLender` |
| F-04 | Fee Bypass via Rounding | **High** | Zero fee revenue | Easy | `WaveFeeSwap` |
| F-05 | Division Before Multiplication | **High** | Zero yield for all depositors | Easy | `WaveYieldCalculator` |

**Severity Distribution**: 2 Critical · 3 High · 0 Medium · 0 Low

---

## 7. Build & Test

```bash
forge build
forge test -vvv
```
