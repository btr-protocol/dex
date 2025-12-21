//! Common types for AMM simulation

const std = @import("std");

/// Swap result
pub const SwapResult = struct {
    amount_out: f64,
    fee_paid: f64,
    price_before: f64,
    price_after: f64,
};

/// Quote result (no state change)
pub const QuoteResult = struct {
    amount_out: f64,
    fee: f64,
    effective_price: f64,
    price_impact: f64,
};

/// Common AMM errors
pub const AmmError = error{
    InsufficientLiquidity,
    InvalidToken,
    SlippageExceeded,
    InvalidAmount,
    InvariantViolation,
    InvalidPair,
    OutOfMemory,
};

/// Fee configuration
pub const FeeConfig = struct {
    /// Base fee in basis points (1 = 0.01%)
    base_fee_bps: u32,
    /// Protocol fee share (0-10000, where 10000 = 100%)
    protocol_share_bps: u32 = 0,

    pub fn swapFee(self: FeeConfig) f64 {
        return @as(f64, @floatFromInt(self.base_fee_bps)) / 10000.0;
    }

    pub fn lpFeeBps(self: FeeConfig) u32 {
        const protocol_fee = (self.base_fee_bps * self.protocol_share_bps) / 10000;
        return self.base_fee_bps - protocol_fee;
    }
};

/// Interface that all AMMs must implement
/// For 2-asset AMMs: manages multiple pools in hub-spoke topology
/// For N-asset AMMs: manages single pool with all tokens
pub const AmmInterface = struct {
    /// Get quote for swapping token_in → token_out
    /// For 2-asset: routes through hub if needed
    /// For N-asset: direct quote from pool
    getQuoteFn: *const fn (self: *anyopaque, token_in: []const u8, token_out: []const u8, amount_in: f64) AmmError!QuoteResult,

    /// Execute swap token_in → token_out
    swapFn: *const fn (self: *anyopaque, token_in: []const u8, token_out: []const u8, amount_in: f64, min_out: f64) AmmError!SwapResult,

    /// Get current spot price of token_in in terms of token_out
    getSpotPriceFn: *const fn (self: *anyopaque, token_in: []const u8, token_out: []const u8) AmmError!f64,

    /// Calculate max profitable arb size to bring pool price to external_price
    /// Returns amount_in that maximizes: amount_out * external_price - amount_in
    getArbSizeFn: *const fn (self: *anyopaque, token_in: []const u8, token_out: []const u8, external_price: f64) AmmError!f64,

    /// Get total value locked in USD terms (assuming token prices)
    getTvlFn: *const fn (self: *anyopaque, token_prices: std.StringHashMap(f64)) AmmError!f64,
};
