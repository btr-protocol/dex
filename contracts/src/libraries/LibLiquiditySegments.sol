// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title LibLiquiditySegments - Packed segment storage for Makima cubic spline
/// @notice Packs (weight, endOffset, slope) into 48 bits per segment
/// @dev 5 segments per uint256 slot, 7 slots total = 32 segment capacity
library LibLiquiditySegments {
    // ========== CONSTANTS ==========

    uint256 internal constant BITS_PER_SEGMENT = 48;
    uint256 internal constant SEGMENTS_PER_SLOT = 5;
    uint256 internal constant SEGMENT_MASK = (1 << 48) - 1;
    uint256 internal constant MAX_SEGMENTS = 32;

    // Bit layout within 48-bit segment:
    // [0..7]   : weight    (uint8,  0-255, sum must = 255)
    // [8..15]  : endOffset (int8,   -100 to +100, % of breadth)
    // [16..47] : slope     (int32,  Makima pre-computed slope, fixed-point)

    uint256 private constant WEIGHT_BITS = 8;
    uint256 private constant OFFSET_BITS = 8;
    uint256 private constant SLOPE_BITS = 32;

    uint256 private constant OFFSET_SHIFT = WEIGHT_BITS;
    uint256 private constant SLOPE_SHIFT = WEIGHT_BITS + OFFSET_BITS;

    // ========== ERRORS ==========

    error SegmentIndexOutOfBounds(uint256 index, uint256 maxSegments);
    error InvalidSegmentData();

    // ========== STRUCT ==========

    /// @dev Storage for up to 32 packed segments across 7 slots
    struct PackedSegments {
        uint256[7] data; // 7 slots × 5 segments/slot = 35 capacity, use 32
    }

    // ========== SEGMENT ACCESS ==========

    /// @notice Load segment i from packed storage
    /// @param self Packed segments storage
    /// @param i Segment index (0 <= i < segmentCount)
    /// @return weight Liquidity weight (0-255)
    /// @return endOffset TWAP offset as % of breadth (-100 to +100)
    /// @return slope Pre-computed Makima slope (int32 fixed-point)
    function get(
        PackedSegments storage self,
        uint256 i
    )
        internal
        view
        returns (uint8 weight, int8 endOffset, int32 slope)
    {
        unchecked {
            if (i >= MAX_SEGMENTS) revert SegmentIndexOutOfBounds(i, MAX_SEGMENTS);

            uint256 slotIndex = i / SEGMENTS_PER_SLOT;
            uint256 offset = (i % SEGMENTS_PER_SLOT) * BITS_PER_SEGMENT;
            uint256 word = self.data[slotIndex];
            uint256 chunk = (word >> offset) & SEGMENT_MASK;

            weight = uint8(chunk);
            endOffset = int8(uint8(chunk >> OFFSET_SHIFT));
            slope = int32(uint32(chunk >> SLOPE_SHIFT));
        }
    }

    /// @notice Store segment i to packed storage
    /// @param self Packed segments storage
    /// @param i Segment index (0 <= i < MAX_SEGMENTS)
    /// @param weight Liquidity weight (0-255)
    /// @param endOffset TWAP offset as % of breadth (-100 to +100)
    /// @param slope Pre-computed Makima slope (int32 fixed-point)
    function set(
        PackedSegments storage self,
        uint256 i,
        uint8 weight,
        int8 endOffset,
        int32 slope
    )
        internal
    {
        unchecked {
            if (i >= MAX_SEGMENTS) revert SegmentIndexOutOfBounds(i, MAX_SEGMENTS);

            uint256 slotIndex = i / SEGMENTS_PER_SLOT;
            uint256 offset = (i % SEGMENTS_PER_SLOT) * BITS_PER_SEGMENT;

            // Pack segment data
            uint256 packed =
                uint256(weight)
                | (uint256(uint8(endOffset)) << OFFSET_SHIFT)
                | (uint256(uint32(slope)) << SLOPE_SHIFT);

            // Update slot
            uint256 mask = SEGMENT_MASK << offset;
            uint256 word = self.data[slotIndex];
            word = (word & ~mask) | (packed << offset);
            self.data[slotIndex] = word;
        }
    }

    /// @notice Load multiple segments in single call (gas optimization)
    /// @dev Useful for batch processing during swap
    /// @param self Packed segments storage
    /// @param startIdx Starting segment index
    /// @param count Number of segments to load
    /// @return weights Array of weights
    /// @return endOffsets Array of end offsets
    /// @return slopes Array of slopes
    function getBatch(
        PackedSegments storage self,
        uint256 startIdx,
        uint256 count
    )
        internal
        view
        returns (
            uint8[] memory weights,
            int8[] memory endOffsets,
            int32[] memory slopes
        )
    {
        weights = new uint8[](count);
        endOffsets = new int8[](count);
        slopes = new int32[](count);

        unchecked {
            for (uint256 i = 0; i < count; ++i) {
                (weights[i], endOffsets[i], slopes[i]) = get(self, startIdx + i);
            }
        }
    }

    /// @notice Clear all segment data (set to zero)
    /// @param self Packed segments storage
    function clear(PackedSegments storage self) internal {
        unchecked {
            for (uint256 i = 0; i < 7; ++i) {
                self.data[i] = 0;
            }
        }
    }
}
