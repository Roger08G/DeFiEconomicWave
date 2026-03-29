// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./WaveToken.sol";

/**
 * @title WaveFeeSwap
 * @notice Minimal constant-product AMM with a configurable swap fee.
 *
 * VULNERABILITY:
 *   V-04: Fee bypass via rounding — fee = (amountIn * feeBps) / 10000.
 *         For feeBps = 30 (0.30%), any amountIn < 334 yields fee = 0.
 *         An attacker can split a large swap into many micro-swaps below
 *         the fee threshold and avoid paying ANY fee, draining LP value.
 */
contract WaveFeeSwap {
    WaveToken public immutable tokenA;
    WaveToken public immutable tokenB;

    uint256 public reserveA;
    uint256 public reserveB;

    uint256 public feeBps; // Fee in basis points (e.g., 30 = 0.30%)
    uint256 public constant BPS = 10000;

    uint256 public totalLP;
    mapping(address => uint256) public lpBalance;

    address public owner;

    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB, uint256 lpMinted);
    event LiquidityRemoved(address indexed provider, uint256 amountA, uint256 amountB, uint256 lpBurned);
    event Swap(address indexed user, address tokenIn, uint256 amountIn, uint256 amountOut, uint256 fee);

    constructor(address _tokenA, address _tokenB, uint256 _feeBps) {
        tokenA = WaveToken(_tokenA);
        tokenB = WaveToken(_tokenB);
        feeBps = _feeBps;
        owner = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════════
    // LIQUIDITY
    // ═══════════════════════════════════════════════════════════════

    function addLiquidity(uint256 amountA, uint256 amountB) external returns (uint256 lpMinted) {
        tokenA.transferFrom(msg.sender, address(this), amountA);
        tokenB.transferFrom(msg.sender, address(this), amountB);

        if (totalLP == 0) {
            lpMinted = _sqrt(amountA * amountB);
        } else {
            uint256 lpA = (amountA * totalLP) / reserveA;
            uint256 lpB = (amountB * totalLP) / reserveB;
            lpMinted = lpA < lpB ? lpA : lpB;
        }

        require(lpMinted > 0, "Swap: zero LP");
        lpBalance[msg.sender] += lpMinted;
        totalLP += lpMinted;
        reserveA += amountA;
        reserveB += amountB;

        emit LiquidityAdded(msg.sender, amountA, amountB, lpMinted);
    }

    function removeLiquidity(uint256 lpAmount) external returns (uint256 amountA, uint256 amountB) {
        require(lpBalance[msg.sender] >= lpAmount, "Swap: insufficient LP");

        amountA = (lpAmount * reserveA) / totalLP;
        amountB = (lpAmount * reserveB) / totalLP;

        lpBalance[msg.sender] -= lpAmount;
        totalLP -= lpAmount;
        reserveA -= amountA;
        reserveB -= amountB;

        tokenA.transfer(msg.sender, amountA);
        tokenB.transfer(msg.sender, amountB);

        emit LiquidityRemoved(msg.sender, amountA, amountB, lpAmount);
    }

    // ═══════════════════════════════════════════════════════════════
    // SWAP (V-04)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Swap tokenA for tokenB or vice versa.
     * @dev V-04: fee = (amountIn * feeBps) / 10000. With feeBps = 30,
     *      amountIn < 334 → fee = 0 → swap is free. No minimum trade or
     *      minimum fee check. Attacker can loop micro-swaps to trade at
     *      zero cost.
     */
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut) {
        require(tokenIn == address(tokenA) || tokenIn == address(tokenB), "Swap: invalid token");
        require(amountIn > 0, "Swap: zero amount");

        bool isAtoB = tokenIn == address(tokenA);

        // V-04: Integer division truncates fee to zero for small amounts
        uint256 fee = (amountIn * feeBps) / BPS;
        uint256 amountInAfterFee = amountIn - fee;

        uint256 reserveIn;
        uint256 reserveOut;

        if (isAtoB) {
            reserveIn = reserveA;
            reserveOut = reserveB;
        } else {
            reserveIn = reserveB;
            reserveOut = reserveA;
        }

        // Constant product: amountOut = reserveOut - (reserveIn * reserveOut) / (reserveIn + amountInAfterFee)
        amountOut = (reserveOut * amountInAfterFee) / (reserveIn + amountInAfterFee);
        require(amountOut >= minAmountOut, "Swap: slippage exceeded");
        require(amountOut > 0, "Swap: zero output");

        // Execute transfers
        if (isAtoB) {
            tokenA.transferFrom(msg.sender, address(this), amountIn);
            tokenB.transfer(msg.sender, amountOut);
            reserveA += amountIn;
            reserveB -= amountOut;
        } else {
            tokenB.transferFrom(msg.sender, address(this), amountIn);
            tokenA.transfer(msg.sender, amountOut);
            reserveB += amountIn;
            reserveA -= amountOut;
        }

        emit Swap(msg.sender, tokenIn, amountIn, amountOut, fee);
    }

    // ═══════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════

    function getPrice(address tokenIn, uint256 amountIn) external view returns (uint256) {
        bool isAtoB = tokenIn == address(tokenA);
        uint256 rIn = isAtoB ? reserveA : reserveB;
        uint256 rOut = isAtoB ? reserveB : reserveA;
        uint256 fee = (amountIn * feeBps) / BPS;
        uint256 netIn = amountIn - fee;
        return (rOut * netIn) / (rIn + netIn);
    }

    function getReserves() external view returns (uint256, uint256) {
        return (reserveA, reserveB);
    }

    // ─── Internal ───

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
