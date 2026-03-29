// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title WaveYieldCalculator
 * @notice Calculates yield distributions for staking and lending positions.
 *         Used by the protocol to determine how much yield each participant
 *         earns based on their share in the pool.
 *
 * VULNERABILITY:
 *   V-05: Division before multiplication — the share calculation performs
 *         (principal / totalPool) first, which truncates to 0 for any
 *         principal < totalPool. Then multiplies by rewardAmount and
 *         duration. The correct order is: (principal * rewardAmount * duration)
 *         / (totalPool * YEAR).
 *
 *         An attacker with a large totalPool can dilute all small depositors'
 *         yields to exactly 0, collecting 100% of rewards themselves.
 */
contract WaveYieldCalculator {
    uint256 public constant YEAR = 365 days;
    uint256 public constant PRECISION = 1e18;

    // ═══════════════════════════════════════════════════════════════
    // YIELD (V-05)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Calculate proportional yield for a position.
     * @param principal      User's deposited principal
     * @param totalPool      Total deposits in the pool
     * @param rewardAmount   Total reward tokens distributed
     * @param durationSec    Duration in seconds for yield calculation
     * @return yield_        The user's share of rewards
     *
     * @dev V-05: Division before multiplication. For principal < totalPool,
     *      (principal / totalPool) == 0, so the entire expression is 0.
     *
     *      Example: principal = 999, totalPool = 1000, rewardAmount = 1e18
     *        BUG:     (999 / 1000) * 1e18 * duration / YEAR = 0
     *        CORRECT: (999 * 1e18 * duration) / (1000 * YEAR) = ~999e18 * duration / (1000 * YEAR)
     */
    function calculateYield(uint256 principal, uint256 totalPool, uint256 rewardAmount, uint256 durationSec)
        external
        pure
        returns (uint256 yield_)
    {
        if (totalPool == 0 || durationSec == 0) return 0;

        // V-05: BUG — division first truncates share to 0 for small principals
        uint256 share = principal / totalPool;
        yield_ = (share * rewardAmount * durationSec) / YEAR;
    }

    /**
     * @notice Calculate annualized APY for a position.
     * @dev Uses the same flawed division order internally.
     */
    function calculateAPY(uint256 principal, uint256 totalPool, uint256 rewardAmount)
        external
        pure
        returns (uint256 apyBps)
    {
        if (totalPool == 0 || principal == 0) return 0;

        // V-05: Same division-before-multiplication bug
        uint256 share = principal / totalPool;
        uint256 annualYield = share * rewardAmount;
        apyBps = (annualYield * 10000) / principal;
    }

    /**
     * @notice Batch calculate yields for multiple depositors.
     * @dev Utility for off-chain aggregation.
     */
    function batchCalculateYield(
        uint256[] calldata principals,
        uint256 totalPool,
        uint256 rewardAmount,
        uint256 durationSec
    ) external pure returns (uint256[] memory yields) {
        yields = new uint256[](principals.length);
        for (uint256 i = 0; i < principals.length; i++) {
            if (totalPool == 0 || durationSec == 0) {
                yields[i] = 0;
            } else {
                // V-05: Same bug propagated
                uint256 share = principals[i] / totalPool;
                yields[i] = (share * rewardAmount * durationSec) / YEAR;
            }
        }
    }
}
