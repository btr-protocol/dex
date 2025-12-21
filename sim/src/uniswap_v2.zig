//! Uniswap V2 - Constant Product Market Maker (x * y = k)
//!
//! 2-asset CPMM with fixed 0.3% fee (configurable)
//! For multi-token: uses hub-spoke topology with USDC as hub

const std = @import("std");
const types = @import("types.zig");
const AmmError = types.AmmError;
const SwapResult = types.SwapResult;
const QuoteResult = types.QuoteResult;

/// Single Uniswap V2 pool (2 assets)
pub const Pool = struct {
    reserve_0: f64,
    reserve_1: f64,
    fee: f64, // e.g., 0.003 for 0.3%

    pub fn init(reserve_0: f64, reserve_1: f64, fee_bps: u32) Pool {
        return Pool{
            .reserve_0 = reserve_0,
            .reserve_1 = reserve_1,
            .fee = @as(f64, @floatFromInt(fee_bps)) / 10000.0,
        };
    }

    /// Get spot price: how much of token 1 per unit of token 0
    pub fn getSpotPrice(self: *const Pool) f64 {
        return self.reserve_1 / self.reserve_0;
    }

    /// Get quote for 0→1 swap
    pub fn getQuote(self: *const Pool, amount_in: f64, zero_for_one: bool) AmmError!QuoteResult {
        if (amount_in <= 0) return AmmError.InvalidAmount;

        const amount_in_with_fee = amount_in * (1.0 - self.fee);
        const r_in = if (zero_for_one) self.reserve_0 else self.reserve_1;
        const r_out = if (zero_for_one) self.reserve_1 else self.reserve_0;

        // x * y = k
        // (x + Δx') * (y - Δy) = k
        // Δy = y * Δx' / (x + Δx')
        const amount_out = (r_out * amount_in_with_fee) / (r_in + amount_in_with_fee);

        if (amount_out >= r_out) return AmmError.InsufficientLiquidity;

        const price_before = if (zero_for_one) r_out / r_in else r_in / r_out;
        const price_after = if (zero_for_one)
            (r_out - amount_out) / (r_in + amount_in)
        else
            (r_in + amount_in) / (r_out - amount_out);

        return QuoteResult{
            .amount_out = amount_out,
            .fee = amount_in * self.fee,
            .effective_price = amount_in / amount_out,
            .price_impact = @abs(price_after - price_before) / price_before,
        };
    }

    /// Execute swap
    pub fn swap(self: *Pool, amount_in: f64, zero_for_one: bool, min_out: f64) AmmError!SwapResult {
        const quote = try self.getQuote(amount_in, zero_for_one);

        if (quote.amount_out < min_out) return AmmError.SlippageExceeded;

        // Update reserves
        if (zero_for_one) {
            self.reserve_0 += amount_in;
            self.reserve_1 -= quote.amount_out;
        } else {
            self.reserve_1 += amount_in;
            self.reserve_0 -= quote.amount_out;
        }

        return SwapResult{
            .amount_out = quote.amount_out,
            .fee_paid = quote.fee,
            .price_before = quote.effective_price / (1.0 + quote.price_impact),
            .price_after = quote.effective_price,
        };
    }

    /// Calculate optimal arb size to match external price
    /// external_price = how much token_out per token_in
    /// For CPMM: solve for Δx that makes (y - Δy)/(x + Δx) = external_price
    pub fn getArbSize(self: *const Pool, external_price: f64, zero_for_one: bool) AmmError!f64 {
        const r_in = if (zero_for_one) self.reserve_0 else self.reserve_1;
        const r_out = if (zero_for_one) self.reserve_1 else self.reserve_0;

        const current_price = r_out / r_in;

        // If pool price already matches external, no arb
        if (@abs(current_price - external_price) / external_price < 0.0001) {
            return 0.0;
        }

        // For CPMM with fee, optimal arb size where marginal price = external_price
        // After swap: (y - Δy) / (x + Δx) = external_price
        // Using x*y = k and fee:
        // Δy = y * Δx * (1-f) / (x + Δx * (1-f))
        // Solve: (y - y*Δx*(1-f)/(x + Δx*(1-f))) / (x + Δx) = p_ext
        //
        // Simplify to: Δx = (√(x*y*p_ext*(1-f)) - x*p_ext) / (p_ext*(1-f))

        const f = self.fee;
        const sqrt_term = @sqrt(r_in * r_out * external_price * (1.0 - f));
        const numerator = sqrt_term - r_in * external_price;
        const denominator = external_price * (1.0 - f);

        if (denominator == 0) return 0.0;

        const arb_size = numerator / denominator;

        // Validate: arb size must be positive and not drain pool
        if (arb_size <= 0 or arb_size > r_in * 0.5) return 0.0;

        return arb_size;
    }

    pub fn getTvl(self: *const Pool, price_0: f64, price_1: f64) f64 {
        return self.reserve_0 * price_0 + self.reserve_1 * price_1;
    }
};

/// Multi-token Uniswap V2 AMM (hub-spoke topology)
pub const UniswapV2 = struct {
    allocator: std.mem.Allocator,
    hub_token: []const u8, // e.g., "USDC"
    pools: std.StringHashMap(Pool), // token → Pool (token/hub)
    tokens: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, hub_token: []const u8) UniswapV2 {
        return UniswapV2{
            .allocator = allocator,
            .hub_token = hub_token,
            .pools = std.StringHashMap(Pool).init(allocator),
            .tokens = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *UniswapV2) void {
        self.pools.deinit();
        self.tokens.deinit();
    }

    /// Add a pool for token/hub pair
    pub fn addPool(self: *UniswapV2, token: []const u8, reserve_token: f64, reserve_hub: f64, fee_bps: u32) !void {
        const pool = Pool.init(reserve_token, reserve_hub, fee_bps);
        try self.pools.put(token, pool);
        try self.tokens.append(token);
    }

    /// Get quote for token_in → token_out
    pub fn getQuote(self: *UniswapV2, token_in: []const u8, token_out: []const u8, amount_in: f64) AmmError!QuoteResult {
        // Direct pair (both are hub)
        if (std.mem.eql(u8, token_in, self.hub_token) and std.mem.eql(u8, token_out, self.hub_token)) {
            return QuoteResult{
                .amount_out = amount_in,
                .fee = 0,
                .effective_price = 1.0,
                .price_impact = 0,
            };
        }

        // token_in is hub, token_out is spoke
        if (std.mem.eql(u8, token_in, self.hub_token)) {
            const pool = self.pools.get(token_out) orelse return AmmError.InvalidPair;
            return pool.getQuote(amount_in, false); // hub → token (1→0)
        }

        // token_out is hub, token_in is spoke
        if (std.mem.eql(u8, token_out, self.hub_token)) {
            const pool = self.pools.get(token_in) orelse return AmmError.InvalidPair;
            return pool.getQuote(amount_in, true); // token → hub (0→1)
        }

        // Both are spokes: route through hub (2-hop)
        const pool_in = self.pools.get(token_in) orelse return AmmError.InvalidPair;
        const pool_out = self.pools.get(token_out) orelse return AmmError.InvalidPair;

        // First hop: token_in → hub
        const quote1 = try pool_in.getQuote(amount_in, true);

        // Second hop: hub → token_out
        const quote2 = try pool_out.getQuote(quote1.amount_out, false);

        return QuoteResult{
            .amount_out = quote2.amount_out,
            .fee = quote1.fee + quote2.fee,
            .effective_price = amount_in / quote2.amount_out,
            .price_impact = quote1.price_impact + quote2.price_impact,
        };
    }

    /// Execute swap
    pub fn swap(self: *UniswapV2, token_in: []const u8, token_out: []const u8, amount_in: f64, min_out: f64) AmmError!SwapResult {
        // Same logic but mutates pools
        if (std.mem.eql(u8, token_in, self.hub_token) and std.mem.eql(u8, token_out, self.hub_token)) {
            return SwapResult{
                .amount_out = amount_in,
                .fee_paid = 0,
                .price_before = 1.0,
                .price_after = 1.0,
            };
        }

        if (std.mem.eql(u8, token_in, self.hub_token)) {
            var pool = self.pools.getPtr(token_out) orelse return AmmError.InvalidPair;
            return pool.swap(amount_in, false, min_out);
        }

        if (std.mem.eql(u8, token_out, self.hub_token)) {
            var pool = self.pools.getPtr(token_in) orelse return AmmError.InvalidPair;
            return pool.swap(amount_in, true, min_out);
        }

        // 2-hop swap
        var pool_in = self.pools.getPtr(token_in) orelse return AmmError.InvalidPair;
        var pool_out = self.pools.getPtr(token_out) orelse return AmmError.InvalidPair;

        const result1 = try pool_in.swap(amount_in, true, 0);
        const result2 = try pool_out.swap(result1.amount_out, false, min_out);

        return SwapResult{
            .amount_out = result2.amount_out,
            .fee_paid = result1.fee_paid + result2.fee_paid,
            .price_before = (result1.price_before + result2.price_before) / 2.0,
            .price_after = (result1.price_after + result2.price_after) / 2.0,
        };
    }

    /// Get spot price
    pub fn getSpotPrice(self: *UniswapV2, token_in: []const u8, token_out: []const u8) AmmError!f64 {
        if (std.mem.eql(u8, token_in, self.hub_token) and std.mem.eql(u8, token_out, self.hub_token)) {
            return 1.0;
        }

        if (std.mem.eql(u8, token_in, self.hub_token)) {
            const pool = self.pools.get(token_out) orelse return AmmError.InvalidPair;
            return pool.reserve_0 / pool.reserve_1; // hub per token
        }

        if (std.mem.eql(u8, token_out, self.hub_token)) {
            const pool = self.pools.get(token_in) orelse return AmmError.InvalidPair;
            return pool.reserve_1 / pool.reserve_0; // hub per token
        }

        // token_in/token_out = (token_in/hub) / (token_out/hub)
        const pool_in = self.pools.get(token_in) orelse return AmmError.InvalidPair;
        const pool_out = self.pools.get(token_out) orelse return AmmError.InvalidPair;

        const price_in_hub = pool_in.reserve_1 / pool_in.reserve_0;
        const price_out_hub = pool_out.reserve_1 / pool_out.reserve_0;

        return price_out_hub / price_in_hub;
    }

    /// Get optimal arb size
    pub fn getArbSize(self: *UniswapV2, token_in: []const u8, token_out: []const u8, external_price: f64) AmmError!f64 {
        // For hub pairs, use pool's arb calculation
        if (std.mem.eql(u8, token_out, self.hub_token)) {
            const pool = self.pools.get(token_in) orelse return AmmError.InvalidPair;
            return pool.getArbSize(external_price, true);
        }

        if (std.mem.eql(u8, token_in, self.hub_token)) {
            const pool = self.pools.get(token_out) orelse return AmmError.InvalidPair;
            return pool.getArbSize(external_price, false);
        }

        // For 2-hop, approximate with hub price
        const pool_in = self.pools.get(token_in) orelse return AmmError.InvalidPair;
        return pool_in.getArbSize(external_price, true);
    }

    pub fn getTvl(self: *UniswapV2, token_prices: std.StringHashMap(f64)) AmmError!f64 {
        var total: f64 = 0;
        var it = self.pools.iterator();
        while (it.next()) |entry| {
            const token = entry.key_ptr.*;
            const pool = entry.value_ptr.*;
            const token_price = token_prices.get(token) orelse 1.0;
            const hub_price = token_prices.get(self.hub_token) orelse 1.0;
            total += pool.getTvl(token_price, hub_price);
        }
        return total;
    }
};
