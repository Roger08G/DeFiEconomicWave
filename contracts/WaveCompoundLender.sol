// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./WaveToken.sol";

/**
 * @title WaveCompoundLender
 * @notice Lending market with compound interest via debtIndex.
 *         Lenders deposit tokens, borrowers post collateral and borrow.
 *         Interest compounds per-block and is tracked via a global index.
 *
 * VULNERABILITIES:
 *   V-02: Stale debt index — borrow() and repay() do NOT call accrueInterest()
 *         before modifying positions. Users interact with a stale debtIndex,
 *         allowing manipulation of effective interest rates.
 *
 *   V-03: Temporal interest gaming — accrueInterest() is public and does NOT
 *         update lastAccrueBlock when totalBorrowed == 0. An attacker can
 *         create a large elapsed-time window, then borrow and accrue to earn
 *         massive retroactive interest as a lender.
 */
contract WaveCompoundLender {
    WaveToken public immutable lendingToken;
    WaveToken public immutable collateralToken;

    address public owner;

    // ─── Interest model ───
    uint256 public debtIndex; // Compound interest index (1e18 = 1.0)
    uint256 public supplyIndex; // Compound supply index (1e18)
    uint256 public lastAccrueBlock;
    uint256 public interestRateBps; // Annual rate in bps (e.g., 1000 = 10%)
    uint256 public constant BLOCKS_PER_YEAR = 2_628_000;
    uint256 public constant BPS = 10000;

    // ─── Pool state ───
    uint256 public totalDeposits;
    uint256 public totalBorrowed;

    // ─── Lender state ───
    struct LenderInfo {
        uint256 principal; // Deposit principal
        uint256 indexSnapshot; // supplyIndex at time of deposit
    }
    mapping(address => LenderInfo) public lenders;

    // ─── Borrower state ───
    struct BorrowerInfo {
        uint256 collateral;
        uint256 borrowPrincipal; // Principal at time of borrow
        uint256 indexSnapshot; // debtIndex at time of borrow
    }
    mapping(address => BorrowerInfo) public borrowers;

    uint256 public constant COLLATERAL_FACTOR = 7500; // 75% LTV

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event InterestAccrued(uint256 newDebtIndex, uint256 newSupplyIndex, uint256 blocks);

    constructor(address _lendingToken, address _collateralToken, uint256 _rateBps) {
        lendingToken = WaveToken(_lendingToken);
        collateralToken = WaveToken(_collateralToken);
        owner = msg.sender;
        debtIndex = 1e18;
        supplyIndex = 1e18;
        lastAccrueBlock = block.number;
        interestRateBps = _rateBps;
    }

    // ═══════════════════════════════════════════════════════════════
    // INTEREST ACCRUAL (V-03)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Accrue compound interest.
     * @dev V-03: When totalBorrowed == 0, lastAccrueBlock is NOT updated.
     *      If someone later borrows, the next accrueInterest() calculates
     *      interest for the ENTIRE gap period, even though there were no
     *      borrows during that time. An attacker exploits this:
     *        1. Wait for totalBorrowed == 0 (all debt repaid)
     *        2. Many blocks pass without accrual
     *        3. Deposit as lender, borrow tiny amount → totalBorrowed > 0
     *        4. Call accrueInterest() → huge interest for entire gap
     *        5. Withdraw lender deposit + inflated interest
     */
    function accrueInterest() public {
        uint256 blockDelta = block.number - lastAccrueBlock;
        if (blockDelta == 0) return;

        if (totalBorrowed == 0) {
            // V-03: BUG — does NOT update lastAccrueBlock!
            // Correct: lastAccrueBlock = block.number;
            return;
        }

        // Compound interest: index *= (1 + rate * blocks / blocksPerYear)
        uint256 interestFactor = (interestRateBps * blockDelta * 1e18) / (BLOCKS_PER_YEAR * BPS);
        uint256 interestAccrued = (totalBorrowed * interestFactor) / 1e18;

        // Update debt index
        debtIndex += (debtIndex * interestFactor) / 1e18;

        // Update supply index (interest goes to lenders)
        if (totalDeposits > 0) {
            supplyIndex += (supplyIndex * interestAccrued) / (totalDeposits * 1e18 / 1e18);
        }

        totalBorrowed += interestAccrued;
        lastAccrueBlock = block.number;

        emit InterestAccrued(debtIndex, supplyIndex, blockDelta);
    }

    // ═══════════════════════════════════════════════════════════════
    // LENDING
    // ═══════════════════════════════════════════════════════════════

    function deposit(uint256 amount) external {
        accrueInterest();
        lendingToken.transferFrom(msg.sender, address(this), amount);

        lenders[msg.sender].principal += amount;
        lenders[msg.sender].indexSnapshot = supplyIndex;
        totalDeposits += amount;

        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        accrueInterest();
        LenderInfo storage info = lenders[msg.sender];
        require(info.principal >= amount, "Lender: insufficient principal");

        uint256 available = lendingToken.balanceOf(address(this));
        require(available >= amount, "Lender: insufficient liquidity");

        info.principal -= amount;
        totalDeposits -= amount;
        lendingToken.transfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════════
    // BORROWING (V-02)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Borrow tokens against posted collateral.
     * @dev V-02: Does NOT call accrueInterest() before borrowing.
     *      The debtIndex used for the borrower's snapshot may be stale.
     *      If debtIndex is stale-low, the borrower's recorded debt is
     *      lower than it should be → borrows more than collateral allows.
     */
    function borrow(uint256 amount, uint256 collateralAmount) external {
        // V-02: Missing accrueInterest() call!

        // Post collateral
        if (collateralAmount > 0) {
            collateralToken.transferFrom(msg.sender, address(this), collateralAmount);
            borrowers[msg.sender].collateral += collateralAmount;
        }

        // Check capacity
        uint256 maxBorrow = (borrowers[msg.sender].collateral * COLLATERAL_FACTOR) / BPS;
        uint256 currentDebt = getCurrentDebt(msg.sender);
        require(currentDebt + amount <= maxBorrow, "Borrower: undercollateralized");

        uint256 available = lendingToken.balanceOf(address(this));
        require(available >= amount, "Borrower: insufficient liquidity");

        // Record at STALE debtIndex
        borrowers[msg.sender].borrowPrincipal += amount;
        borrowers[msg.sender].indexSnapshot = debtIndex; // V-02: Stale!
        totalBorrowed += amount;

        lendingToken.transfer(msg.sender, amount);

        emit Borrowed(msg.sender, amount);
    }

    /**
     * @notice Repay borrowed tokens.
     * @dev V-02: Does NOT call accrueInterest() before repaying.
     *      Repayer uses stale debtIndex → may overpay or underpay.
     */
    function repay(uint256 amount) external {
        // V-02: Missing accrueInterest() call!

        BorrowerInfo storage info = borrowers[msg.sender];
        uint256 debt = getCurrentDebt(msg.sender);
        uint256 repayAmount = amount > debt ? debt : amount;

        lendingToken.transferFrom(msg.sender, address(this), repayAmount);

        // Reduce principal proportionally
        if (debt > 0) {
            uint256 principalRepaid = (info.borrowPrincipal * repayAmount) / debt;
            info.borrowPrincipal -= principalRepaid;
        }
        totalBorrowed -= repayAmount;

        emit Repaid(msg.sender, repayAmount);
    }

    // ═══════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════

    function getCurrentDebt(address user) public view returns (uint256) {
        BorrowerInfo storage info = borrowers[user];
        if (info.borrowPrincipal == 0 || info.indexSnapshot == 0) return 0;
        // Debt grows with the ratio of current index to borrow-time index
        return (info.borrowPrincipal * debtIndex) / info.indexSnapshot;
    }

    function getLenderBalance(address user) external view returns (uint256) {
        LenderInfo storage info = lenders[user];
        if (info.principal == 0 || info.indexSnapshot == 0) return 0;
        return (info.principal * supplyIndex) / info.indexSnapshot;
    }

    function utilizationRate() external view returns (uint256) {
        if (totalDeposits == 0) return 0;
        return (totalBorrowed * BPS) / totalDeposits;
    }
}
