# Zig 0.16 API Migration Guide

This document captures the breaking API changes from Zig 0.13 → 0.16 for reference.

## Major Breaking Changes Summary

### Memory Management
- `std.heap.GeneralPurposeAllocator` → `std.heap.DebugAllocator`
- New `std.heap.smp_allocator` for high-performance multi-threaded code
- `Allocator.VTable` gains `remap` operation
- ArrayList/HashMap now use `initCapacity` instead of `init`
- `deinit()` now requires allocator parameter: `list.deinit(allocator)`

### I/O System (0.15.1)
- Non-generic `std.io.Reader` and `std.io.Writer` replace generic versions
- Old `Reader(T)`/`Writer(T)` patterns deprecated
- `fs.File` helpers restructured around new Reader/Writer interfaces
- `std.io.getStdOut()` for stdout access

### Language Features
- `@export` now takes pointer: `@export(&foo, ...)`
- `@branchHint` replaces `@setCold`
- `@fence` removed
- Calling conventions become tagged union
- Type introspection tags: PascalCase → lowercase (`.Int` → `.int`)
- Tuple destructuring syntax changed: `const (a, b) = tuple` no longer valid

### Standard Library
- `std.io` module (lowercase) doesn't exist in 0.16 dev
- Use `std.Io` (capital I) or direct `std.io.getStdOut()`
- `std.Random.DefaultPrng.init(seed).random()` returns `*const Random`
- ArrayList/containers require explicit allocator in init/deinit

## Code Patterns for 0.16

### Debug Allocator
```zig
var dbg_alloc = std.heap.DebugAllocator(.{}){};
defer _ = dbg_alloc.deinit();
const allocator = dbg_alloc.allocator();
```

### SMP Allocator (Multi-threaded)
```zig
const allocator = std.heap.smp_allocator;
```

### ArrayList
```zig
// Init
var list = std.ArrayList(f64).initCapacity(allocator, 100);
defer list.deinit(allocator);

// Or empty
var list = std.ArrayList(f64){};
defer list.deinit(allocator);
```

### Random Number Generation
```zig
var prng = std.rand.DefaultPrng.init(seed);
const rand = prng.random();
const value = rand.float(f64);
```

### Stdout Access
```zig
const stdout = std.io.getStdOut().writer();
try stdout.print("Hello\n", .{});
```

### Tuple Destructuring
```zig
// Old (doesn't work):
const (a, b, c) = computeValues();

// New:
const result = computeValues();
const a = result[0];
const b = result[1];
const c = result[2];
```

## Common Patterns

### Time Measurement
```zig
const start = std.time.nanoTimestamp();
// ... work ...
const elapsed = std.time.nanoTimestamp() - start;
```

### Thread Pool
```zig
const Thread = std.Thread;
const WaitGroup = Thread.WaitGroup;

var wg = WaitGroup{};
for (&threads, 0..) |*t, i| {
    wg.start();
    t.* = try Thread.spawn(.{}, worker, .{ &wg, i });
}
wg.wait();
```

### Atomic Operations
```zig
_ = @atomicRmw(u64, &counter, .Add, value, .monotonic);
```

## Build System (0.14+)

### Module Creation
```zig
const module = b.addModule("name", .{
    .root_source_file = .{ .cwd_relative = "src/file.zig" },
    .target = target,
    .optimize = optimize,
});
```

### Library Creation
```zig
const lib = b.addLibrary(.{
    .name = "mylib",
    .root_module = module,
    .linkage = .static,  // or .dynamic
});
```

## Reserved Keywords in 0.16
- `volatile` is now a reserved keyword (use `high_vol`, `high_volatility`, etc.)

## References
- [Zig 0.13.0 Release Notes](https://ziglang.org/download/0.13.0/release-notes.html)
- [Zig 0.14.0 Release Notes](https://ziglang.org/download/0.14.0/release-notes.html)
- [Zig 0.15.1 Release Notes](https://ziglang.org/download/0.15.1/release-notes.html)
- [Zig Master Documentation](https://ziglang.org/documentation/master/)
