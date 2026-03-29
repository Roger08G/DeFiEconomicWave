// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./WaveToken.sol";

/**
 * @title IWaveFlashBorrower
 * @notice Callback interface for flash loan recipients.
 */
interface IWaveFlashBorrower {
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bool);
}

/**
 * @title WaveFlashLender
 * @notice Flash loan facility — lend tokens within a single transaction.
 *
 * VULNERABILITY:
 *   V-01: No repayment verification.
 *         flashLoan() calls the borrower callback and checks that the callback
 *         returned `true`. But it does NOT verify that the actual token balance
 *         is >= (balanceBefore + fee). The borrower controls the return value
 *         and can simply return `true` without repaying. The entire pool
 *         can be drained in a single transaction.
 */
contract WaveFlashLender {
    WaveToken public immutable lendingToken;
    address public owner;

    uint256 public constant FLASH_FEE_BPS = 9; // 0.09%
    uint256 public totalFeesCollected;

    event FlashLoan(address indexed borrower, uint256 amount, uint256 fee);
    event Deposited(address indexed lender, uint256 amount);
    event Withdrawn(address indexed lender, uint256 amount);

    mapping(address => uint256) public deposits;
    uint256 public totalDeposits;

    constructor(address _token) {
        lendingToken = WaveToken(_token);
        owner = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════════
    // LIQUIDITY MANAGEMENT
    // ═══════════════════════════════════════════════════════════════

    function deposit(uint256 amount) external {
        lendingToken.transferFrom(msg.sender, address(this), amount);
        deposits[msg.sender] += amount;
        totalDeposits += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(deposits[msg.sender] >= amount, "FlashLender: insufficient deposit");
        uint256 available = lendingToken.balanceOf(address(this));
        require(available >= amount, "FlashLender: insufficient liquidity");
        deposits[msg.sender] -= amount;
        totalDeposits -= amount;
        lendingToken.transfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════════
    // FLASH LOAN (V-01)
    // ═══════════════════════════════════════════════════════════════

    function maxFlashLoan() external view returns (uint256) {
        return lendingToken.balanceOf(address(this));
    }

    function flashFee(uint256 amount) public pure returns (uint256) {
        return (amount * FLASH_FEE_BPS) / 10000;
    }

    /**
     * @notice Execute a flash loan.
     * @dev V-01: Only checks callback return value, NOT actual token repayment.
     *      A malicious borrower returns `true` from onFlashLoan() without
     *      transferring tokens back. The pool balance drops permanently.
     *
     *      Correct implementation would check:
     *        require(lendingToken.balanceOf(address(this)) >= balanceBefore + fee)
     */
    function flashLoan(address receiver, uint256 amount, bytes calldata data) external {
        uint256 fee = flashFee(amount);

        uint256 balanceBefore = lendingToken.balanceOf(address(this));
        require(balanceBefore >= amount, "FlashLender: insufficient liquidity");

        // Transfer tokens to borrower
        lendingToken.transfer(receiver, amount);

        // Execute callback
        bool success = IWaveFlashBorrower(receiver).onFlashLoan(msg.sender, address(lendingToken), amount, fee, data);

        // V-01: Only checks the boolean return, NOT the balance!
        // Borrower controls this return value — can return true without repaying
        require(success, "FlashLender: callback failed");

        // BUG: Missing balance check!
        // Should have:
        //   uint256 balanceAfter = lendingToken.balanceOf(address(this));
        //   require(balanceAfter >= balanceBefore + fee, "FlashLender: not repaid");

        totalFeesCollected += fee;
        emit FlashLoan(receiver, amount, fee);
    }

    // ═══════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════

    function availableLiquidity() external view returns (uint256) {
        return lendingToken.balanceOf(address(this));
    }
}
