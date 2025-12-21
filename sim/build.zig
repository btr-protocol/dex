const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create root module
    const root_module = b.addModule("amm_sim", .{
        .root_source_file = .{ .cwd_relative = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Main library (static)
    const lib = b.addLibrary(.{
        .name = "amm_sim",
        .root_module = root_module,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Main CLI executable (disabled for Zig 0.16 experimental - std.io API incompatibility)
    // const exe_module = b.addModule("main", .{
    //     .root_source_file = .{ .cwd_relative = "src/main.zig" },
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const exe = b.addExecutable(.{
    //     .name = "amm-sim",
    //     .root_module = exe_module,
    // });
    // b.installArtifact(exe);

    // Tests
    const test_module = b.addModule("test", .{
        .root_source_file = .{ .cwd_relative = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Benchmark executable (disabled for Zig 0.16 experimental - API incompatibility)
    // const bench_module = b.addModule("bench", .{
    //     .root_source_file = .{ .cwd_relative = "src/bench.zig" },
    //     .target = target,
    //     .optimize = .ReleaseFast,
    // });
    // const bench = b.addExecutable(.{
    //     .name = "bench",
    //     .root_module = bench_module,
    // });
    // b.installArtifact(bench);
    // const run_bench = b.addRunArtifact(bench);
    // const bench_step = b.step("bench", "Run benchmarks");
    // bench_step.dependOn(&run_bench.step);

    // Backtest executable (disabled for Zig 0.16 experimental - API incompatibility)
    // const backtest_module = b.addModule("backtest", .{
    //     .root_source_file = .{ .cwd_relative = "src/backtest.zig" },
    //     .target = target,
    //     .optimize = .ReleaseFast,
    // });
    // const backtest = b.addExecutable(.{
    //     .name = "backtest",
    //     .root_module = backtest_module,
    // });
    // b.installArtifact(backtest);
    // const run_backtest = b.addRunArtifact(backtest);
    // const backtest_step = b.step("backtest", "Run backtest (demo mode)");
    // backtest_step.dependOn(&run_backtest.step);
}
