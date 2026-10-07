// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Full precision floor(x * y / denominator), including 512-bit products.
library FullMath {
    error MathOverflow();

    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 low;
            uint256 high;
            assembly ("memory-safe") {
                let mm := mulmod(x, y, not(0))
                low := mul(x, y)
                high := sub(sub(mm, low), lt(mm, low))
            }
            if (denominator == 0 || denominator <= high) revert MathOverflow();
            if (high == 0) return low / denominator;
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(x, y, denominator)
                high := sub(high, gt(remainder, low))
                low := sub(low, remainder)
            }
            uint256 twos = denominator & (0 - denominator);
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
                low := div(low, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            low |= high * twos;
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            result = low * inverse;
        }
    }
}
