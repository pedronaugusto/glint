//! The danger rules' predicates (designs/aegis.md §7): the sites each finds, and the sites it
//! leaves alone, over a std laid out as Zig 0.17's.
const std = @import("std");
const glint = @import("glint");
const pack = glint.AegisPack;
const sources = @import("aegis_sources");

/// std as 0.17 lays out what the rules name, and nothing else.
const std_files = [_]sources.Extra{
    .{ .name = "std/std.zig", .bytes =
    \\pub const Io = @import("Io.zig");
    \\pub const atomic = @import("atomic.zig");
    \\pub const crypto = @import("crypto.zig");
    \\pub const debug = @import("debug.zig");
    \\pub const time = @import("time.zig");
    \\pub const process = @import("process.zig");
    \\pub const mem = @import("mem.zig");
    \\pub const array_list = @import("array_list.zig");
    \\pub const hash_map = @import("hash_map.zig");
    \\pub const array_hash_map = @import("array_hash_map.zig");
    \\pub fn ArrayList(comptime T: type) type { return array_list.Aligned(T, null); }
    \\pub const AutoHashMapUnmanaged = hash_map.AutoHashMapUnmanaged;
    },
    .{ .name = "std/Io.zig", .bytes =
    \\pub const File = @import("Io/File.zig");
    \\pub const Reader = @import("Io/Reader.zig");
    \\pub const Dir = struct { handle: i32, pub fn openFile(dir: Dir, io: anytype, sub_path: []const u8, options: anytype) !void { _ = dir; _ = io; _ = sub_path; _ = options; } pub fn readFileAlloc(dir: Dir, io: anytype, sub_path: []const u8, gpa: anytype, limit: usize) ![]u8 { _ = dir; _ = io; _ = sub_path; _ = gpa; _ = limit; return &.{}; } };
    \\pub const Writer = struct { end: usize = 0, pub fn print(w: *Writer, comptime format: []const u8, args: anytype) !void { _ = w; _ = format; _ = args; } };
    \\pub fn protocolWriter(buffer: []u8) Writer { _ = buffer; return .{}; }
    \\pub const net = struct { pub const Stream = struct { handle: i32, pub fn writer(s: Stream, buffer: []u8) Writer { _ = s; _ = buffer; return .{}; } }; pub const Server = struct { stream: Stream }; };
    \\pub fn checkCancel(io: @This()) error{Canceled}!void { _ = io; }
    \\pub const Mutex = extern struct { state: u32 = 0, pub const init: Mutex = .{}; pub fn lock(m: *Mutex) void { _ = m; } };
    \\pub const RwLock = struct { state: u32 = 0 };
    \\pub const Condition = struct { state: u32 = 0 };
    \\pub const Semaphore = struct { permits: usize = 0 };
    \\pub const Event = enum(u32) { unset, set };
    \\pub const Duration = struct {
    \\    nanoseconds: i96,
    \\    pub fn fromNanoseconds(x: i96) Duration { return .{ .nanoseconds = x }; }
    \\    pub fn fromMicroseconds(x: i64) Duration { return .{ .nanoseconds = x }; }
    \\    pub fn fromMilliseconds(x: i64) Duration { return .{ .nanoseconds = x }; }
    \\    pub fn fromSeconds(x: i64) Duration { return .{ .nanoseconds = x }; }
    \\    pub fn toNanoseconds(d: Duration) i96 { return d.nanoseconds; }
    \\    pub fn toMicroseconds(d: Duration) i64 { return @intCast(d.nanoseconds); }
    \\    pub fn toMilliseconds(d: Duration) i64 { return @intCast(d.nanoseconds); }
    \\    pub fn toSeconds(d: Duration) i64 { return @intCast(d.nanoseconds); }
    \\};
    \\pub const Timestamp = struct {
    \\    nanoseconds: i96,
    \\    pub fn fromNanoseconds(x: i96) Timestamp { return .{ .nanoseconds = x }; }
    \\    pub fn toNanoseconds(t: Timestamp) i96 { return t.nanoseconds; }
    \\    pub fn toMicroseconds(t: Timestamp) i64 { return @intCast(t.nanoseconds); }
    \\    pub fn toMilliseconds(t: Timestamp) i64 { return @intCast(t.nanoseconds); }
    \\    pub fn toSeconds(t: Timestamp) i64 { return @intCast(t.nanoseconds); }
    \\};
    },
    .{ .name = "std/atomic.zig", .bytes =
    \\pub fn Value(comptime T: type) type { return struct { raw: T, pub fn init(v: T) @This() { return .{ .raw = v }; } }; }
    \\pub const Mutex = enum(u8) { unlocked, locked };
    },
    .{ .name = "std/crypto.zig", .bytes =
    \\pub const timing_safe = @import("crypto/timing_safe.zig");
    \\pub const sign = struct { pub const Ed25519 = @import("crypto/ed25519.zig").Ed25519; };
    \\pub fn secureZero(comptime T: type, s: []volatile T) void { for (s) |*b| b.* = 0; }
    },
    .{ .name = "std/crypto/timing_safe.zig", .bytes =
    \\pub fn eql(comptime T: type, a: T, b: T) bool { return a == b; }
    \\pub fn compare(comptime T: type, a: []const T, b: []const T) i8 { _ = a; _ = b; return 0; }
    },
    .{ .name = "std/crypto/ed25519.zig", .bytes =
    \\pub const Ed25519 = struct {
    \\    pub const SecretKey = struct { bytes: [64]u8 };
    \\    pub const PublicKey = struct { bytes: [32]u8 };
    \\    pub const KeyPair = struct { secret_key: SecretKey, public_key: PublicKey, pub fn generate() KeyPair { return undefined; } };
    \\};
    },
    .{ .name = "std/debug.zig", .bytes = "pub fn assert(ok: bool) void { if (!ok) unreachable; }" },
    .{ .name = "std/Io/File.zig", .bytes = "handle: i32,\npub fn close(f: @This()) void { _ = f; }" },
    .{ .name = "std/process.zig", .bytes = "pub const Child = struct { id: i32 };\npub const RunResult = struct { stdout: []u8 = &.{}, stderr: []u8 = &.{} };\npub fn run(gpa: anytype, io: anytype, options: anytype) !RunResult { _ = gpa; _ = io; _ = options; return .{}; }" },
    .{ .name = "std/array_list.zig", .bytes = "pub fn Aligned(comptime T: type, comptime a: ?u8) type { _ = a; return struct { items: []T = &.{}, capacity: usize = 0, pub fn append(self: *@This(), x: T) void { _ = self; _ = x; } }; }" },
    .{ .name = "std/hash_map.zig", .bytes = "pub fn AutoHashMapUnmanaged(comptime K: type, comptime V: type) type { return struct { k: K, v: V, pub fn getPtr(self: *@This(), key: K) ?*V { _ = key; return &self.v; } }; }" },
    .{ .name = "std/array_hash_map.zig", .bytes = "pub const Nothing = struct {};" },
    .{ .name = "std/Io/Reader.zig", .bytes =
    \\buffer: []u8 = &.{},
    \\pub const Limit = enum(usize) { unlimited = 0, _ };
    \\pub fn fixed(bytes: []const u8) @This() { _ = bytes; return .{}; }
    \\pub fn takeByte(r: *@This()) !u8 { _ = r; return 0; }
    \\pub fn takeInt(r: *@This(), comptime T: type, endian: u1) !T { _ = r; _ = endian; return 0; }
    \\pub fn take(r: *@This(), n: usize) ![]u8 { _ = n; return r.buffer; }
    \\pub fn readSliceAll(r: *@This(), buffer: []u8) !void { _ = r; _ = buffer; }
    \\pub fn readSliceShort(r: *@This(), buffer: []u8) !usize { _ = r; return buffer.len; }
    \\pub fn allocRemaining(r: *@This(), gpa: anytype, limit: Limit) ![]u8 { _ = gpa; _ = limit; return r.buffer; }
    },
    .{ .name = "std/mem.zig", .bytes = "pub fn findScalar(comptime T: type, s: []const T, v: T) ?usize { _ = s; _ = v; return null; }\npub fn findScalarPos(comptime T: type, s: []const T, start: usize, v: T) ?usize { _ = s; _ = start; _ = v; return null; }\npub const Allocator = struct { ptr: *anyopaque, pub fn alloc(self: Allocator, comptime T: type, n: usize) ![]T { _ = self; _ = n; return &.{}; } };" },
    .{ .name = "std/time.zig", .bytes =
    \\pub const ns_per_us = 1000;
    \\pub const ns_per_ms = 1000 * ns_per_us;
    \\pub const ns_per_s = 1000 * ns_per_ms;
    \\pub const ns_per_min = 60 * ns_per_s;
    \\pub const ns_per_hour = 60 * ns_per_min;
    \\pub const ns_per_day = 24 * ns_per_hour;
    \\pub const ns_per_week = 7 * ns_per_day;
    \\pub const us_per_ms = 1000;
    \\pub const us_per_s = 1000 * us_per_ms;
    \\pub const us_per_min = 60 * us_per_s;
    \\pub const us_per_hour = 60 * us_per_min;
    \\pub const us_per_day = 24 * us_per_hour;
    \\pub const us_per_week = 7 * us_per_day;
    \\pub const ms_per_s = 1000;
    \\pub const ms_per_min = 60 * ms_per_s;
    \\pub const ms_per_hour = 60 * ms_per_min;
    \\pub const ms_per_day = 24 * ms_per_hour;
    \\pub const ms_per_week = 7 * ms_per_day;
    \\pub const s_per_min = 60;
    \\pub const s_per_hour = s_per_min * 60;
    \\pub const s_per_day = s_per_hour * 24;
    \\pub const s_per_week = s_per_day * 7;
    },
};
const std_imports = [_]sources.ExtraImport{
    .{ .spelling = "std", .target = 0 },
    .{ .from = 0, .spelling = "Io.zig", .target = 1 },
    .{ .from = 0, .spelling = "atomic.zig", .target = 2 },
    .{ .from = 0, .spelling = "crypto.zig", .target = 3 },
    .{ .from = 0, .spelling = "debug.zig", .target = 6 },
    .{ .from = 0, .spelling = "time.zig", .target = 14 },
    .{ .from = 1, .spelling = "Io/Reader.zig", .target = 12 },
    .{ .from = 0, .spelling = "mem.zig", .target = 13 },
    .{ .from = 3, .spelling = "crypto/timing_safe.zig", .target = 4 },
    .{ .from = 3, .spelling = "crypto/ed25519.zig", .target = 5 },
    .{ .from = 1, .spelling = "Io/File.zig", .target = 7 },
    .{ .from = 0, .spelling = "process.zig", .target = 8 },
    .{ .from = 0, .spelling = "array_list.zig", .target = 9 },
    .{ .from = 0, .spelling = "hash_map.zig", .target = 10 },
    .{ .from = 0, .spelling = "array_hash_map.zig", .target = 11 },
};

/// `program`'s findings of `rule` at report level, and its undecided sites of it.
const Run = struct { findings: usize, undecided: usize, lines: [32]u32 = @splat(0) };
fn run(rule: glint.Rule, program: []const u8) !Run {
    var project = try sources.projectWithSources(std.testing.allocator, program, &std_files, &std_imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .report }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var result: Run = .{ .findings = 0, .undecided = 0 };
    // A fixture std's AstGen refuses is not checked at all: it would pass any count of none.
    for (report.coverage) |item| try std.testing.expect(item.reason != .invalid_syntax and item.reason != .invalid_lowering);
    for (report.diagnostics) |d| if (d.rule == rule) {
        if (result.findings < result.lines.len) result.lines[result.findings] = d.span.line;
        result.findings += 1;
    };
    for (report.coverage) |item| if (item.rule != null and item.rule.? == rule) {
        result.undecided += 1;
    };
    return result;
}
fn expect(rule: glint.Rule, program: []const u8, findings: usize) !void {
    const result = try run(rule, program);
    try std.testing.expectEqual(@as(usize, 0), result.undecided); // safe: fixture counts are representable.
    try std.testing.expectEqual(findings, result.findings);
}

test "A007 finds std's synchronization, raw atomics and mutable container state" {
    try expect(pack.shared_state,
        \\const std = @import("std");
        \\const S = struct { lock: std.Io.Mutex = .init, count: std.atomic.Value(u32) };
        \\var hits: u32 = 0;
        \\pub fn f(p: *u32) u32 { return @atomicLoad(u32, p, .acquire); }
    , 4);
    try expect(pack.shared_state,
        \\const std = @import("std");
        \\const Io = std.Io;
        \\const T = struct { l: Io.RwLock, c: Io.Condition, s: Io.Semaphore, e: Io.Event, m: std.atomic.Mutex };
        \\var detected: std.atomic.Value(u8) = .init(0);
    , 6);
}

test "A007 leaves constants, thread-local state, aliases' uses, borrows and test code alone" {
    try expect(pack.shared_state,
        \\const std = @import("std");
        \\const Mutex = std.Io.Mutex;
        \\const limit: u32 = 4;
        \\threadlocal var scratch: u32 = 0;
        \\pub fn f(a: *Mutex, b: *Mutex) void { _ = a; _ = b; }
        \\test { var m: std.Io.Mutex = .init; m.lock(); }
        \\const Io = std.Io;
        \\pub fn g(l: *Io.RwLock, e: *const Io.Event, s: ?*std.atomic.Value(bool)) void { _ = l; _ = e; _ = s; }
        \\const Borrow = struct { stop: ?*const std.atomic.Value(bool) };
        \\const aegis = @import("aegis");
        \\const Id = enum(u32) { _ };
        \\var cell: aegis.Atomic(Id) = .init(@fromBackingInt(0));
    , 1);
}

test "A008 finds hand wipes, hand comparisons and std secret keys held by value" {
    try expect(pack.secrets,
        \\const std = @import("std");
        \\const Ed25519 = std.crypto.sign.Ed25519;
        \\const Signer = struct { key: Ed25519.KeyPair };
        \\pub fn f(buffer: []u8, a: [4]u8, b: [4]u8) bool { std.crypto.secureZero(u8, buffer); return std.crypto.timing_safe.eql([4]u8, a, b); }
        \\pub fn g() void { const kp = Ed25519.KeyPair.generate(); _ = kp; }
    , 4);
}

test "A008 leaves borrowed keys, sealed keys, public keys and compared key types alone" {
    try expect(pack.secrets,
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\const Ed25519 = std.crypto.sign.Ed25519;
        \\const Signer = struct { key: aegis.Secret(Ed25519.KeyPair), public: Ed25519.PublicKey };
        \\pub fn f(kp: *const Ed25519.KeyPair) void { _ = kp; }
        \\pub const same = Ed25519.SecretKey == Ed25519.SecretKey;
    , 0);
}

test "A011 finds time crossing as a raw integer and units converted by hand, not raw nanoseconds compared or subtracted" {
    try expect(pack.units,
        \\const std = @import("std");
        \\pub fn f(ms: i64, d: std.Io.Duration) i64 {
        \\    const timeout = std.Io.Duration.fromMilliseconds(ms);
        \\    _ = timeout;
        \\    const ns = ms * std.time.ns_per_ms;
        \\    _ = ns;
        \\    return d.toMilliseconds() + @as(i64, @intCast(d.nanoseconds));
        \\}
    , 4);
    try expect(pack.units,
        \\const std = @import("std");
        \\pub fn f() u64 { return std.time.ns_per_ms; }
        \\pub fn late(now: std.Io.Timestamp, end: std.Io.Timestamp, left: std.Io.Duration) bool {
        \\    if (left.nanoseconds <= 0) return true;
        \\    return now.nanoseconds >= end.nanoseconds or end.nanoseconds - now.nanoseconds < left.nanoseconds;
        \\}
    , 0);
}

test "A013 finds contracts input reaches: an assert on it, an unreachable it chooses, a catch unreachable on a call that reads or takes it; not the program's own invariants" {
    try expect(pack.contracts,
        \\const std = @import("std");
        \\fn decode(b: u8) !u8 { if (b > 3) return error.Bad; return b; }
        \\pub fn f(r: *std.Io.Reader, x: u8) !u8 {
        \\    const b = try r.takeByte();
        \\    std.debug.assert(b < 4);
        \\    std.debug.assert(x < 4);
        \\    _ = decode(b) catch unreachable;
        \\    _ = r.takeByte() catch unreachable;
        \\    _ = decode(x) catch unreachable;
        \\    if (b == 7) unreachable;
        \\    return switch (b) { 0 => 1, else => unreachable };
        \\}
        \\pub fn g(x: u8) u8 { return switch (x) { 0 => 1, else => unreachable }; }
    , 5);
}

test "A013 leaves what runs as the program compiles, and tests, alone" {
    try expect(pack.contracts,
        \\const std = @import("std");
        \\pub fn Make(comptime n: usize) type { if (n == 0) unreachable; return struct { pub fn get() usize { return n; } }; }
        \\const table = blk: { if (false) unreachable; break :blk 1; };
        \\pub fn f() void { comptime std.debug.assert(true); }
        \\test { std.debug.assert(true); }
    , 0);
}

test "A010 finds conversions of input and division by it, not of the program's own values or a truncation" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\const E = enum(u8) { a, b };
        \\pub fn f(r: *std.Io.Reader, x: u64, y: f64) !void {
        \\    const n = try r.takeByte();
        \\    const wide: u64 = n;
        \\    _ = @as(u4, @intCast(n));
        \\    _ = @as(E, @enumFromInt(n));
        \\    _ = x / wide;
        \\    _ = @as(u8, @truncate(wide));
        \\    _ = @as(u8, @intCast(x));
        \\    _ = @as(u8, @intFromFloat(y));
        \\    _ = @as(E, @enumFromInt(x));
        \\    _ = wide / 2;
        \\    _ = wide >> 1;
        \\}
    , 3);
}

test "A019 finds the unchecked operations, the escape covering one" {
    try expect(pack.unsafe_set,
        \\extern fn write(fd: c_int) c_int;
        \\pub fn f(p: *const u8, a: usize) usize {
        \\    @setRuntimeSafety(false);
        \\    const q: *u8 = @constCast(p);
        \\    const r: *u32 = @ptrCast(@alignCast(q));
        \\    _ = r;
        \\    const s: *u8 = @ptrFromInt(a); // aegis: boundary: an address the kernel hands back
        \\    _ = s;
        \\    return @intFromPtr(p);
        \\}
    , 6);
}

test "A014 finds a pointer into the frame carried out of the call" {
    try expect(pack.lifetimes, "pub fn f(n: usize) []u8 { var buf: [16]u8 = undefined; buf[0] = 1; return buf[0..n]; }", 1);
    try expect(pack.lifetimes, "pub fn f() *u32 { var x: u32 = 1; x += 1; const out = &x; return out; }", 1);
    try expect(pack.lifetimes, "const R = struct { s: []u8 }; pub fn f(n: usize) R { var buf: [8]u8 = undefined; buf[0] = 1; return .{ .s = buf[0..n] }; }", 1);
    try expect(pack.lifetimes, "const S = struct { a: u32 = 0 }; const T = struct { p: *u32 }; pub fn f(t: *T) void { var s: S = .{}; s.a = 1; t.p = &s.a; }", 1);
    try expect(pack.lifetimes, "var last: ?*u32 = null; pub fn f() void { var x: u32 = 1; x += 1; last = &x; }", 1);
}

test "A014 leaves static storage, pointers, copies and undone stores alone" {
    try expect(pack.lifetimes, "pub fn f() []const u8 { const table = [_]u8{ 1, 2 }; return table[0..]; }", 0);
    try expect(pack.lifetimes, "pub fn f() []const u8 { comptime { var buf: [2]u8 = .{ 1, 2 }; buf[0] = 3; const out = buf; return &out; } }", 0);
    try expect(pack.lifetimes, "pub fn Make(comptime n: usize) type { var x: [n]u8 = undefined; x[0] = 1; _ = &x; return struct {}; }", 0);
    try expect(pack.lifetimes, "const N = struct { v: u32 }; pub fn f(head: *N) *u32 { var node: *N = head; node.v += 1; return &node.v; }", 0);
    try expect(pack.lifetimes, "pub fn f(items: []u8) []u8 { var s: []u8 = items; s = s[1..]; return s[0..1]; }", 0);
    try expect(pack.lifetimes, "pub fn f() [4]u8 { var buf: [4]u8 = undefined; buf[0] = 1; return buf; }", 0);
    try expect(pack.lifetimes, "const T = struct { cur: ?*u32 = null }; pub fn f(t: *T) void { var x: u32 = 1; x += 1; t.cur = &x; defer t.cur = null; }", 0);
    try expect(pack.lifetimes, "pub fn f() u32 { var x: u32 = 1; var p: *u32 = undefined; p = &x; p.* += 1; return x; }", 0);
    try expect(pack.lifetimes,
        \\const W = struct { next: ?*W = null };
        \\const Q = struct { first: ?*W = null };
        \\pub fn wait(q: *Q) void {
        \\    var waiter: W = .{ .next = q.first };
        \\    q.first = &waiter;
        \\    defer {
        \\        var link = &q.first;
        \\        while (link.* != &waiter) link = &link.*.?.next;
        \\        link.* = waiter.next;
        \\    }
        \\}
    , 0);
}

test "the aegis escape covers the pack's findings on its line, is listed with them, and refuses glint-ignore" {
    var project = try sources.projectWithSources(std.testing.allocator,
        \\const std = @import("std");
        \\// aegis: internal: the counter aegis's own Atomic would wrap; measured in bench/count.zig
        \\var hits: u32 = 0;
        \\pub fn f(r: *std.Io.Reader) !u4 {
        \\    const b = try r.takeByte();
        \\    return @intCast(b); // aegis: no-danger: the peer's protocol sends a nibble here
        \\}
        \\pub fn g() void {} // aegis: design: nothing here
    , &std_files, &std_imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{ .{ .rule = pack.shared_state, .level = .gate }, .{ .rule = pack.integers, .level = .gate } } }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: fixture counts are representable.
    try std.testing.expectEqual(@as(usize, 2), report.escapes.len); // safe: fixture counts are representable.
    try std.testing.expectEqualStrings("internal", report.escapes[0].reason);
    try std.testing.expectEqualStrings("A007", report.escapes[0].covered[0].name);
    try std.testing.expectEqualStrings("A010", report.escapes[1].covered[0].name);
    try std.testing.expectEqual(@as(usize, 1), report.stale.len); // safe: fixture counts are representable.
    var refused = try sources.projectWithSources(std.testing.allocator, "var hits: u32 = 0; // glint-ignore: A007 -- no-danger: one thread\n", &std_files, &std_imports);
    defer refused.deinit();
    var rejected = try glint.runConfigured(std.testing.allocator, &refused, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.shared_state, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer rejected.deinit();
    try std.testing.expect(!rejected.complete);
    try std.testing.expectEqual(@as(usize, 1), rejected.malformed.len); // safe: fixture count is representable.
}

test "a std path a rule names that does not resolve is undecided, never passed" {
    const result = try runWithStd(pack.shared_state, "const std = @import(\"std\");\npub fn f() void {}", "pub const Io = struct {};\npub const atomic = struct {};");
    try std.testing.expect(result.undecided != 0);
}
fn runWithStd(rule: glint.Rule, program: []const u8, root: []const u8) !Run {
    const files = [_]sources.Extra{.{ .name = "std/std.zig", .bytes = root }};
    const imports = [_]sources.ExtraImport{.{ .spelling = "std", .target = 0 }};
    var project = try sources.projectWithSources(std.testing.allocator, program, &files, &imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .report }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var result: Run = .{ .findings = report.diagnostics.len, .undecided = 0 };
    for (report.coverage) |item| if (item.rule != null and item.rule.? == rule) {
        result.undecided += 1;
    };
    return result;
}

test "A015 finds std resources held by value in a field its file releases or returned by value, not borrowed, owned or lent" {
    try expect(pack.ownership,
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\const Conn = struct { stream: std.Io.net.Stream, log: ?std.Io.File, dir: *std.Io.Dir, pub fn deinit(c: *Conn) void { c.stream.close(); if (c.log) |l| l.close(); c.log.?.close(); } };
        \\const Options = struct { cwd: std.Io.Dir, out: std.Io.File, pub fn run(o: Options) void { const cwd = o.cwd; cwd.close(); } };
        \\const Log = struct { file: ?std.Io.File = null, pub fn deinit(l: *Log) void { if (l.file) |f| f.close(); } };
        \\pub fn open() !std.Io.File { return undefined; }
        \\pub fn child() std.process.Child { return undefined; }
        \\pub fn borrowed(f: *std.Io.File) *std.Io.File { return f; }
        \\fn shut(d: *std.Io.Dir) void { _ = d; }
        \\pub fn lent(o: *aegis.own.Owned(std.Io.Dir, shut)) aegis.own.Lent(std.Io.Dir) { return o.lend(); }
    , 5);
}

test "A016 finds identifying integers of one type meeting, not other integers" {
    try expect(pack.identity,
        \\const NodeIndex = u32;
        \\pub fn link(parent_id: u32, child_id: u32) void { _ = parent_id; _ = child_id; }
        \\pub fn move(from: NodeIndex, toIndex: u32) void { _ = from; _ = toIndex; }
        \\pub const Edge = struct { source_index: usize, target_index: usize, weight: usize };
        \\pub fn clamp(x: u32, lo: u32, hi: u32) u32 { _ = lo; _ = hi; return x; }
        \\pub fn pair(node_id: u32, slot_id: u64) void { _ = node_id; _ = slot_id; }
        \\fn private(a_id: u32, b_id: u32) void { _ = a_id; _ = b_id; }
    , 2);
}

test "A017 finds an enum state written in two functions and switched on" {
    try expect(pack.state_machines,
        \\const Phase = enum { idle, running, done };
        \\const Job = struct {
        \\    phase: Phase = .idle,
        \\    kind: Phase = .idle,
        \\    fn start(j: *Job) void { j.phase = .running; j.kind = .done; }
        \\    fn finish(j: *Job) void { j.phase = .done; }
        \\    fn step(j: *Job) void { switch (j.phase) { .idle => j.start(), .running => j.finish(), .done => {} } switch (j.kind) { else => {} } }
        \\};
        \\pub fn run(j: *Job) void { j.step(); }
    , 1);
}

test "A021 finds a second lock taken while a guard is held, unless both are ranked by Order" {
    try expect(pack.lock_order,
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\const L = aegis.sync.BlockingGuarded(u32);
        \\pub fn both(a: *L, b: *L, io: std.Io) void {
        \\    var ga = a.acquireUncancelable(io);
        \\    defer ga.deinit(io);
        \\    var gb = b.acquireUncancelable(io);
        \\    defer gb.deinit(io);
        \\    ga.value().* += gb.value().*;
        \\}
        \\pub fn apart(a: *L, b: *L, io: std.Io) void {
        \\    var ga = a.acquireUncancelable(io);
        \\    ga.value().* += 1;
        \\    ga.deinit(io);
        \\    var gb = b.acquireUncancelable(io);
        \\    gb.value().* += 1;
        \\    gb.deinit(io);
        \\}
        \\const O = aegis.sync.Order(&.{ .{ .name = "a" }, .{ .name = "b", .after = &.{0} } });
        \\const A = O.Ordered(L, 0);
        \\const B = O.Ordered(L, 1);
        \\pub fn ranked(a: *A, b: *B, c: *O.Context, io: std.Io) void {
        \\    var ga = a.acquireOrderedUncancelable(io, c);
        \\    defer ga.deinit(io);
        \\    var gb = b.acquireOrderedUncancelable(io, c);
        \\    defer gb.deinit(io);
        \\    ga.value().* += gb.value().*;
        \\}
    , 1);
}

test "A019 finds a local read while still undefined, and leaves written, filled and branch-written ones, an array's length and a field written by name" {
    try expect(pack.unsafe_set,
        \\fn fill(b: []u8) void { b[0] = 1; }
        \\pub fn bad() u8 { var x: u8 = undefined; const y = x + 1; x = 2; return y; }
        \\pub fn inLoop(n: usize) u32 { var sum: u32 = undefined; for (0..n) |i| { sum += @truncate(i); } return 0; }
        \\pub fn good() u8 { var x: u8 = undefined; x = 3; return x; }
        \\pub fn filled() u8 { var b: [4]u8 = undefined; fill(&b); return b[0]; }
        \\pub fn sliced() u8 { var b: [4]u8 = undefined; fill(b[0..]); return b[0]; }
        \\pub fn both(c: bool) u8 { var x: u8 = undefined; if (c) { x = 1; } else { x = 2; } return x; }
        \\pub fn some(c: bool) u8 { var x: u8 = undefined; if (c) x = 1; return x; }
        \\pub fn selfRead() u8 { var x: u8 = undefined; x = x + 1; return x; }
        \\pub fn length(r: []const u8) u8 { var b: [8]u8 = undefined; const n = @min(r.len, b.len); @memcpy(b[0..n], r[0..n]); return b[0]; }
        \\const P = struct { a: u8 };
        \\pub fn named() u8 { var p: P = undefined; @field(p, "a") = 1; return p.a; }
    , 3);
}

test "A014 finds a borrow of a std container's storage stored in a field" {
    try expect(pack.lifetimes,
        \\const std = @import("std");
        \\const Cache = struct { view: []u32 = &.{}, slot: ?*u32 = null, list: std.ArrayList(u32) = .{}, map: std.AutoHashMapUnmanaged(u32, u32) = undefined };
        \\pub fn keep(c: *Cache) void { c.view = c.list.items; c.slot = &c.list.items[0]; c.slot = c.map.getPtr(1); }
        \\pub fn local(c: *Cache) u32 { const v = c.list.items; return v[0]; }
    , 3);
}

const input_program =
    \\const std = @import("std");
    \\const aegis = @import("aegis");
    \\fn pick(v: usize) usize { return v; }
    \\pub fn handle(r: *std.Io.Reader, table: []const u8, dir: std.Io.Dir, gpa: std.mem.Allocator) !usize {
    \\    const n = try r.takeByte();
    \\    const x = table[n];
    \\    var buf: [16]u8 = undefined;
    \\    try r.readSliceAll(&buf);
    \\    const len = buf[0];
    \\    const part = table[0..len];
    \\    var i: usize = 0;
    \\    while (i < len) : (i += 1) {}
    \\    for (0..n) |_| {}
    \\    const last = table[table.len - 1];
    \\    var fr: std.Io.Reader = .fixed("abc");
    \\    const own = try fr.takeByte();
    \\    _ = table[own];
    \\    _ = table[pick(n)];
    \\    _ = table[pick(3)];
    \\    const wrapped = aegis.input.Untrusted(u8).init(n);
    \\    _ = table[wrapped.readForParse()];
    \\    const name = try r.take(4);
    \\    try dir.openFile(null, name, .{});
    \\    const sum = n + 1;
    \\    const doubled = len * 2;
    \\    const wrapped_sum = n +% 1;
    \\    const size = table.len + 1;
    \\    _ = try gpa.alloc(u8, n);
    \\    _ = try gpa.alloc(u8, 16);
    \\    _ = try r.take(n);
    \\    _ = try r.allocRemaining(gpa, .unlimited);
    \\    const count = try r.takeInt(u32, 0);
    \\    for (0..count) |_| {}
    \\    const wide = @as(usize, buf[1]) << 8 | buf[2];
    \\    _ = table[0..wide];
    \\    _ = try gpa.alloc(u8, count);
    \\    _ = name[n];
    \\    _ = table[count];
    \\    const total = count + 1;
    \\    _ = total;
    \\    _ = sum;
    \\    _ = doubled;
    \\    _ = wrapped_sum;
    \\    return x + part.len + last + size;
    \\}
;

test "A009 finds input that indexes or slices input, names a path, and a number that picks a table entry or bounds a loop; it leaves clean, fixed and refined values and a byte picking a table entry" {
    try expect(pack.untrusted_input, input_program, 6);
}

test "A009's input is a child's output and a file's contents, never the path or allocator a read is given, nor a read the program declares its own" {
    const program =
        \\const std = @import("std");
        \\pub fn load(dir: std.Io.Dir, gpa: std.mem.Allocator, table: []const u8, name: []const u8) !u8 {
        \\    const bytes = try dir.readFileAlloc(null, name, gpa, 100);
        \\    const mine = try dir.readFileAlloc(null, "receipt", gpa, 100); // aegis: internal: the receipt this program wrote
        \\    const out = try std.process.run(gpa, null, .{});
        \\    _ = table[name[0]];
        \\    _ = mine[mine[0]];
        \\    _ = bytes[bytes[0]];
        \\    return out.stdout[out.stdout[0]];
        \\}
    ;
    try expect(pack.untrusted_input, program, 2);
    var project = try sources.projectWithSources(std.testing.allocator, program, &std_files, &std_imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.untrusted_input, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.escapes.len); // safe: fixture counts are representable.
    try std.testing.expectEqualStrings("A009", report.escapes[0].covered[0].name);
    try std.testing.expectEqual(@as(usize, 0), report.stale.len); // safe: fixture counts are representable.
}

test "positions std finds in input, a read's count and a value under a clean bound are clean; a number assembled by hand is a number, and a 16-bit decode is data" {
    const program =
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, table: []const u8) !usize {
        \\    const line = try r.take(16);
        \\    const space = std.mem.findScalar(u8, line, ' ') orelse return 0;
        \\    _ = line[space + 1 ..];
        \\    var buf: [8]u8 = undefined;
        \\    const got = try r.readSliceShort(&buf);
        \\    _ = buf[0..got];
        \\    _ = table[@min(line[0], table.len - 1)];
        \\    var n: usize = 0;
        \\    for (line) |d| n = n * 10 + d;
        \\    const short = try r.takeInt(u16, 0);
        \\    _ = @as(usize, short) + 0x7f00;
        \\    return table.len + n;
        \\}
    ;
    try expect(pack.untrusted_input, program, 0);
    try expect(pack.integers, program, 3);
}

test "A010 finds arithmetic on a number from input, not on its bytes" {
    try expect(pack.integers, input_program, 1);
}

test "A010 leaves what a number's range holds: arithmetic that cannot overflow its type and a conversion its destination holds, from a decode's width, a typed local, @as and a constant" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\const scale = 100;
        \\pub fn f(r: *std.Io.Reader, s: []const u8) !void {
        \\    const n = try r.takeInt(u32, 0);
        \\    _ = @as(u64, n) * scale;
        \\    _ = @as(u64, n) + s.len;
        \\    const top: u8 = @intCast(n >> 24);
        \\    _ = @as(i64, n) - 5;
        \\    const day: u5 = @truncate(n);
        \\    _ = @as(u16, day) * 32 + 1;
        \\    _ = top;
        \\    _ = n + 1;
        \\    const short: u16 = @intCast(n);
        \\    _ = short;
        \\    _ = @as(u64, n) - 5;
        \\    var total: u64 = 0;
        \\    for (0..n) |_| total += n;
        \\}
    , 4);
}

test "A010 reads the comparisons that hold where a number is used: an earlier check that leaves, the branch it is in, a position into memory and a remainder spelled out" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, bytes: []const u8) !u8 {
        \\    const offset = try r.takeInt(u64, 0);
        \\    if (offset > bytes.len) return error.Short;
        \\    const at: usize = @intCast(offset);
        \\    const n = try r.takeInt(u32, 0);
        \\    if (n < 8) return error.Small;
        \\    if (n < 16) return @as(u8, @intCast(n)) - 8 + 90;
        \\    const hour = try r.takeInt(u32, 0);
        \\    const min = try r.takeInt(u32, 0);
        \\    if (min < 60 and hour < 24) {
        \\        const minutes: i32 = @intCast(hour * 60 + min);
        \\        _ = minutes;
        \\    }
        \\    var to: usize = 0;
        \\    var out: [64]u8 = undefined;
        \\    to += try r.takeByte();
        \\    out[to] = 1;
        \\    const secs: i64 = try r.takeInt(i48, 0);
        \\    const days = @divFloor(secs, 86400);
        \\    _ = secs - days * 86400;
        \\    const size = try r.takeInt(u64, 0);
        \\    _ = bytes.len - at;
        \\    _ = size - n;
        \\    var left = size;
        \\    if (left < 4) return error.Short;
        \\    left = try r.takeInt(u64, 0);
        \\    _ = left - 4;
        \\    return bytes[at];
        \\}
    , 2);
}

test "A010 reads a call's bound from what its function returns, a conversion's destination from the parameter or field it is given to, and leaves an address moved by input" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\const Kind = enum { sha1, sha256 };
        \\fn rawLen(k: Kind) usize {
        \\    return switch (k) {
        \\        .sha1 => 20,
        \\        .sha256 => 32,
        \\    };
        \\}
        \\fn consume(n: u3) void {
        \\    _ = n;
        \\}
        \\const Header = struct { low: u8 };
        \\pub fn f(r: *std.Io.Reader, data: []const u8, k: Kind, out: [*]u8) !Header {
        \\    const pos = try r.takeInt(u64, 0);
        \\    const start: usize = @intCast(@min(pos, data.len));
        \\    if (start + 40 + rawLen(k) > data.len) return error.Short;
        \\    const bit = try r.takeInt(u32, 0);
        \\    _ = 8 - bit % 8;
        \\    consume(@intCast(bit & 7));
        \\    _ = out + bit;
        \\    const month = try r.takeInt(i64, 0);
        \\    _ = if (month > 2) month - 3 else month + 9;
        \\    _ = @as(u8, @intCast(bit));
        \\    return .{ .low = @intCast(bit >> 24) };
        \\}
    , 1);
}

test "A010 reads a chain of constants as far as it goes: a civil date from seconds stays in range" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !i64 {
        \\    const secs: i64 = try r.takeInt(i48, 0);
        \\    const days = @divFloor(secs, 86400);
        \\    const rem = secs - days * 86400;
        \\    const z = @divFloor(days, 2) + 719468;
        \\    const era = @divFloor(z, 146097);
        \\    const doe = z - era * 146097;
        \\    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        \\    const y = yoe + era * 400;
        \\    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        \\    const mp = @divFloor(5 * doy + 2, 153);
        \\    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
        \\    const m = if (mp < 10) mp + 3 else mp - 9;
        \\    return y + m + d + @divFloor(rem, 3600);
        \\}
    , 0);
}

test "A010 reads a value's least and greatest and how two values compare: a check on either side of zero, two comparisons together, a contract, a local's stores and a checked divisor" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, out: []u8) !void {
        \\    const size = try r.takeInt(i32, 0);
        \\    if (size > 0) _ = @as(u32, @intCast(size));
        \\    _ = @as(u32, @intCast(size));
        \\    const n = try r.takeInt(i64, 0);
        \\    if (n < -1) return error.Low;
        \\    if (n < 0) return;
        \\    if (n < 8) _ = @as(u8, @intCast(n)) + 30;
        \\    const count = try r.takeInt(u32, 0);
        \\    const i = try r.takeInt(u32, 0);
        \\    if (i < count) _ = count - 1 - i;
        \\    _ = count - i;
        \\    const start = try r.takeInt(u64, 0);
        \\    const end = try r.takeInt(u64, 0);
        \\    if (start > end or end > out.len) return error.Range;
        \\    _ = out.len - start;
        \\    const used = try r.takeInt(u64, 0);
        \\    const cap = try r.takeInt(u64, 0);
        \\    if (used > cap) return error.Over;
        \\    const more = try r.takeInt(u64, 0);
        \\    std.debug.assert(more <= cap - used);
        \\    _ = used + more;
        \\    const a = try r.takeInt(u32, 0);
        \\    var at: u32 = 0;
        \\    if (a < 64) at = a else at = 63;
        \\    _ = at * 1000;
        \\    var b: u32 = 0;
        \\    b = a;
        \\    _ = b * 1000;
        \\    const d = try r.takeInt(u32, 0);
        \\    if (d == 0) return error.Zero;
        \\    _ = 100 / d;
        \\    _ = 100 % (d - 1);
        \\    const s = try r.takeInt(i64, 0);
        \\    const q = @divFloor(s, 60);
        \\    _ = q * 60;
        \\}
    , 5);
}

test "A010 leaves a shift by a bounded amount, an address moved in place and arithmetic its check already evaluated" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, dst: [*]u8, width: u64) !void {
        \\    const nb = try r.takeInt(u32, 0);
        \\    if (nb > 15) return error.Big;
        \\    const bits: u5 = @intCast(nb);
        \\    _ = (@as(i32, 1) << bits) + 1;
        \\    var p = dst;
        \\    p += nb;
        \\    const used = try r.takeInt(u64, 0);
        \\    var name: u64 = 0;
        \\    if (name > width - used) name = width - used;
        \\    _ = width - used;
        \\    const big = try r.takeInt(u32, 0);
        \\    _ = (@as(u64, 1) << @intCast(big & 63)) * 2;
        \\}
    , 1);
}

test "A010 reads a name as what it was given while nothing stores into it: an untyped variable's type, and a check spelled with the name or its initializer" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\const Kind = enum { sha1, sha256,
        \\    pub fn rawLen(kind: Kind) usize { return switch (kind) { .sha1 => 20, .sha256 => 32 }; }
        \\};
        \\pub fn parse(kind: Kind, bytes: []const u8, r: *std.Io.Reader) !void {
        \\    const header_len = 12 + kind.rawLen();
        \\    if (bytes.len < header_len + kind.rawLen()) return error.Short;
        \\    const data_end = bytes.len - kind.rawLen();
        \\    const count = try r.takeInt(u32, 0);
        \\    var end = data_end;
        \\    if (count > 3) {
        \\        const size = @as(u64, count) * 4;
        \\        if (size > end - header_len) return error.Corrupt;
        \\        _ = bytes[end - size .. end];
        \\        end -= size;
        \\    }
        \\    var looped = data_end;
        \\    while (count > 9) {
        \\        _ = looped - header_len;
        \\        looped = count;
        \\    }
        \\}
    , 1);
}

test "A010 reads a store that only lowers a variable or only raises it as keeping it within what it held, on that side" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(in: *std.Io.Reader, at: usize) !void {
        \\    const consumed = try in.takeInt(u32, 0);
        \\    var n: usize = consumed >> 3;
        \\    if (n > at) {
        \\        n = at;
        \\    }
        \\    _ = n * 8;
        \\    var m: usize = consumed >> 3;
        \\    m = at;
        \\    _ = m * 8;
        \\    var k: i64 = try in.takeInt(i32, 0);
        \\    const low = try in.takeInt(i64, 0);
        \\    if (k > low) k = low;
        \\    _ = k + 1;
        \\    _ = k - 1;
        \\}
    , 2);
}

test "A010 reads an index's, a slice bound's and a shift amount's destination, and the latest store before a read where nothing has touched the value since" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\const S = struct { bits: u32 = 0, buf: u64 = 0 };
        \\fn reset(s: *S) void { s.bits = 99; }
        \\pub fn f(r: *std.Io.Reader, items: []u8, s: *S) !void {
        \\    const v = try r.takeInt(i32, 0);
        \\    if (v >= 0) _ = items[@intCast(v)];
        \\    _ = items[@intCast(v)];
        \\    const w = try r.takeInt(u64, 0);
        \\    _ = items[@intCast(w & 15)..@intCast(w & 31)];
        \\    var bits = try r.takeInt(u32, 0);
        \\    bits &= 31;
        \\    _ = w >> @intCast(bits);
        \\    _ = w >> @intCast(bits + 40);
        \\    s.bits = try r.takeInt(u32, 0);
        \\    s.bits &= 7;
        \\    s.buf &= (@as(u64, 1) << @intCast(s.bits)) - 1;
        \\    s.bits &= 7;
        \\    reset(s);
        \\    _ = w >> @intCast(s.bits);
        \\    bits &= 31;
        \\    while (w > 4) {
        \\        _ = w >> @intCast(bits);
        \\        bits = try r.takeInt(u32, 0);
        \\    }
        \\}
    , 4);
}

test "A010 leaves a backing integer's conversion every value of it makes: a packed struct, a non-exhaustive enum, and an exhaustive enum's run of tags the value lies among" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\const Setting = enum(u16) { a = 1, b = 2, c = 3, _ };
        \\const Mode = enum(u8) { stored, fast, best };
        \\const Gapped = enum(u8) { one = 1, three = 3 };
        \\const Flags = packed struct(u32) { read_only: bool, rest: u31 };
        \\fn mode(v: u8) Mode {
        \\    return @fromBackingInt(v);
        \\}
        \\pub fn f(r: *std.Io.Reader) !void {
        \\    const id: Setting = @fromBackingInt(@intCast(try r.takeInt(u16, 0)));
        \\    _ = id;
        \\    const raw = try r.takeInt(u32, 0);
        \\    const flags: Flags = @fromBackingInt(@intCast(raw | 1));
        \\    _ = flags;
        \\    const m = try r.takeInt(u8, 0);
        \\    if (m > 2) return error.Bad;
        \\    const ok: Mode = @fromBackingInt(m);
        \\    _ = ok;
        \\    _ = mode(try r.takeInt(u8, 0));
        \\    const g: Gapped = @fromBackingInt(m);
        \\    _ = g;
        \\    const any: Mode = @fromBackingInt(try r.takeInt(u8, 0));
        \\    _ = any;
        \\}
    , 3);
}

test "A009 judges a loop by its bound, not by a counter it raises toward it on every pass, and A010 a bit count by its operand's width" {
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, bytes: []const u8) !void {
        \\    var i: usize = try r.takeInt(u32, 0);
        \\    while (i < bytes.len) : (i += 1) {}
        \\    var at: usize = try r.takeInt(u32, 0);
        \\    while (at + 8 <= bytes.len) {
        \\        at += 8;
        \\    }
        \\    var n: usize = try r.takeInt(u32, 0);
        \\    while (n > 0) : (n -= 1) {}
        \\    var k: usize = try r.takeInt(u32, 0);
        \\    const step = try r.takeInt(u32, 0);
        \\    while (k < bytes.len) : (k += step) {}
        \\    var j: usize = try r.takeInt(u32, 0);
        \\    while (j < bytes.len) {
        \\        if (bytes[0] == 1) j += 1;
        \\    }
        \\    const count = try r.takeInt(u32, 0);
        \\    var x: usize = 0;
        \\    while (x < count) : (x += 1) {}
        \\}
    , 4);
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\fn nextLf(bytes: []const u8, from: usize) ?usize {
        \\    var i = from;
        \\    while (i + 32 <= bytes.len) : (i += 32) {
        \\        const v: @Vector(32, u8) = bytes[i..][0..32].*;
        \\        const hits: u32 = @bitCast(v == @as(@Vector(32, u8), @splat('\n')));
        \\        if (hits != 0) return i + @ctz(hits);
        \\    }
        \\    while (i < bytes.len) : (i += 1) if (bytes[i] == '\n') return i;
        \\    return null;
        \\}
        \\pub fn f(r: *std.Io.Reader) ![]const u8 {
        \\    const bytes = try r.take(64);
        \\    const from = try r.takeInt(u32, 0);
        \\    if (from > bytes.len) return error.Short;
        \\    const lf = nextLf(bytes, from) orelse return error.None;
        \\    if (lf > from and bytes[lf - 1] == '\r') return bytes[from .. lf - 1];
        \\    return bytes[lf..];
        \\}
    , 0);
}

test "A009 carries a check past a store on every path that advances what it compares, not one in a branch or in a loop the check is outside" {
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, out: []u8) !void {
        \\    var at: usize = try r.takeInt(u32, 0);
        \\    const n = try r.takeInt(u32, 0);
        \\    if (at > out.len) return error.X;
        \\    if (out.len - at < n) return error.Short;
        \\    at += n;
        \\    _ = out[at..];
        \\    if (out.len - at < 4) return error.Short;
        \\    _ = out[at..][0..4];
        \\    at += 4;
        \\    _ = out[at..];
        \\    if (n > 0) at += 1;
        \\    _ = out[at..];
        \\    var p: usize = try r.takeInt(u32, 0);
        \\    while (p + 4 <= out.len) {
        \\        p += 4;
        \\        _ = out[p..];
        \\    }
        \\    var q: usize = try r.takeInt(u32, 0);
        \\    if (q + 4 > out.len) return error.Short;
        \\    while (n > 9) {
        \\        q += 4;
        \\        _ = out[q..];
        \\    }
        \\}
    , 3);
}

test "A010 reads a private function's parameter by what its calls give it, not a public one's, one given away as a value or one only tests call" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\fn seconds(n: i64) u64 {
        \\    return @as(u64, @intCast(n)) * 1000;
        \\}
        \\fn loose(n: i64) u64 {
        \\    return @intCast(n);
        \\}
        \\fn handed(n: i64) u64 {
        \\    return @intCast(n);
        \\}
        \\pub fn exposed(n: i64) u64 {
        \\    return @intCast(n);
        \\}
        \\const S = struct {
        \\    fn step(s: *S, by: u32) u64 {
        \\        _ = s;
        \\        return @as(u32, @intCast(by)) * 2;
        \\    }
        \\};
        \\pub fn f(r: *std.Io.Reader, s: *S) !void {
        \\    const a = try r.takeInt(i64, 0);
        \\    if (a > 0 and a < 1000) {
        \\        _ = seconds(a);
        \\        _ = handed(a);
        \\        _ = exposed(a);
        \\        _ = s.step(@intCast(a));
        \\    }
        \\    _ = seconds(5);
        \\    _ = loose(a);
        \\    const g = &handed;
        \\    _ = g;
        \\}
        \\test {
        \\    _ = seconds(-1);
        \\}
    , 3);
}

test "A010 reads @min as at most each operand and @max as at least each, and an address moved from a name that holds one" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, piece: []const u8, in: []const u8, out: []u8) !void {
        \\    var left = try r.takeInt(u64, 0);
        \\    const taken = piece[0..@intCast(@min(@as(u64, piece.len), left))];
        \\    left -= taken.len;
        \\    const ip = try r.takeInt(u32, 0);
        \\    if (ip > in.len) return error.Short;
        \\    const wanted = try r.takeInt(u32, 0);
        \\    const n = @min(in.len - ip, wanted);
        \\    _ = in.len - ip - n;
        \\    _ = wanted - n;
        \\    const k = @max(wanted, ip);
        \\    _ = k - ip;
        \\    _ = ip - n;
        \\    const m = out.ptr + ip;
        \\    _ = m - wanted;
        \\}
    , 1);
}

test "A009 reads where a call's result lies: std's positions, a function's summary from its returns, and a local that only grows" {
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\fn nextLf(bytes: []const u8, from: usize) ?usize {
        \\    var i = from;
        \\    while (i < bytes.len) : (i += 1) if (bytes[i] == '\n') return i;
        \\    return null;
        \\}
        \\fn lineEnd(bytes: []const u8, from: usize) ?usize {
        \\    return std.mem.findScalarPos(u8, bytes, from, '\n');
        \\}
        \\fn anywhere(bytes: []const u8, from: usize) usize {
        \\    _ = bytes;
        \\    return from + 7;
        \\}
        \\pub fn f(r: *std.Io.Reader) !void {
        \\    const bytes = try r.take(64);
        \\    const from: usize = try r.takeInt(u16, 0);
        \\    if (from > bytes.len) return error.Short;
        \\    const lf = nextLf(bytes, from) orelse return error.NoLine;
        \\    _ = bytes[from..lf];
        \\    const end = lineEnd(bytes, from) orelse return error.NoLine;
        \\    _ = bytes[from..end];
        \\    const far = anywhere(bytes, from);
        \\    _ = bytes[from..far];
        \\}
    , 1);
}

const cursor_program =
    \\const std = @import("std");
    \\const Cursor = struct {
    \\    buf: []const u8,
    \\    pos: usize = 0,
    \\    end: usize = 0,
    \\    fn init(buf: []const u8) Cursor {
    \\        return .{ .buf = buf, .end = buf.len };
    \\    }
    \\    fn advance(c: *Cursor, n: usize) void {
    \\        std.debug.assert(n <= c.end - c.pos);
    \\        c.pos += n;
    \\    }
    \\    fn rest(c: *const Cursor) []const u8 {
    \\        return c.buf[c.pos..c.end];
    \\    }
    \\};
    \\const Loose = struct {
    \\    buf: []const u8,
    \\    pos: usize = 0,
    \\    end: usize = 0,
    \\    fn init(buf: []const u8) Loose {
    \\        return .{ .buf = buf, .end = buf.len };
    \\    }
    \\    fn jump(l: *Loose, to: usize) void {
    \\        l.pos = to;
    \\    }
    \\    fn rest(l: *const Loose) []const u8 {
    \\        return l.buf[l.pos..l.end];
    \\    }
    \\};
    \\const Far = struct {
    \\    buf: []const u8,
    \\    pos: usize = undefined,
    \\    end: usize = undefined,
    \\    fn rest(w: *const Far) []const u8 {
    \\        return w.buf[w.pos..w.end];
    \\    }
    \\};
    \\pub fn f(r: *std.Io.Reader) !void {
    \\    const bytes = try r.take(64);
    \\    const n: usize = try r.takeInt(u32, 0);
    \\    if (n > 4) return error.Big;
    \\    _ = (Far{ .buf = bytes }).rest();
    \\    var cur = Cursor.init(bytes);
    \\    if (n > cur.end - cur.pos) return error.Short;
    \\    cur.advance(n);
    \\    _ = cur.rest();
    \\    var loose = Loose.init(bytes);
    \\    loose.jump(n);
    \\    _ = loose.end - loose.pos;
    \\    _ = loose.rest();
    \\}
;

test "A009 and A010 read a field's relation to its siblings: a cursor at most its end and the end at most its buffer's length, while every store keeps them; a default the reading does not know gives none" {
    try expect(pack.integers, cursor_program, 1);
    try expect(pack.untrusted_input, cursor_program, 1);
}

test "A010 reads a field by its stores: the widest value its default, its literals and its assignments give it, and its type where a store grows it, takes its address, input's bytes or a computed name reach it, or its layout is bytes" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\const Weights = struct { count: u32 = 0 };
        \\const Open = struct { total: u32 };
        \\const Grown = struct { n: u32 = 0 };
        \\const Given = struct { n: u32 = 0 };
        \\const Viewed = struct { n: u32 = 0 };
        \\const Wiped = struct { n: u32 = 0 };
        \\const Named = struct { n: u32 = 0 };
        \\const Wire = extern struct { n: u32 };
        \\fn fill(n: *u32) void {
        \\    n.* = 7;
        \\}
        \\fn wire(x: *const Wire) u32 {
        \\    return x.n * 1000;
        \\}
        \\pub fn f(r: *std.Io.Reader, w: *Weights, g: *Grown, v: *Given, b: *Viewed, k: *Wiped, q: *Named) !void {
        \\    const n = try r.takeInt(u32, 0);
        \\    if (n >= 255) return error.Long;
        \\    w.count = n + 1;
        \\    _ = w.count * 1000;
        \\    const o: Open = .{ .total = n };
        \\    _ = o.total * 1000;
        \\    g.n += n;
        \\    _ = g.n * 1000;
        \\    v.n = n;
        \\    fill(&v.n);
        \\    _ = v.n * 1000;
        \\    b.n = n;
        \\    _ = try r.readSliceAll(std.mem.asBytes(b));
        \\    _ = b.n * 1000;
        \\    var x: Wire = undefined;
        \\    x.n = n;
        \\    _ = wire(&x);
        \\    k.n = n;
        \\    std.crypto.secureZero(u8, std.mem.asBytes(k));
        \\    _ = k.n * 1000;
        \\    inline for (.{"n"}) |name| @field(q, name) = n;
        \\    _ = q.n * 1000;
        \\}
    , 6);
}

test "A009 leaves a position the program checked against the memory's length, and an index a fixed array's length holds" {
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\const table = [_]u8{ 1, 2, 3, 4 };
        \\pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
        \\    const i = try r.takeInt(u32, 0);
        \\    if (i >= buf.len) return error.Short;
        \\    const n = try r.takeInt(u32, 0);
        \\    if (n > buf.len) return error.Short;
        \\    const lim: [16]u8 = @splat(0);
        \\    _ = lim[i & 15];
        \\    _ = table[i & 3];
        \\    _ = buf[0..n];
        \\    _ = buf[i];
        \\    const j = try r.takeInt(u32, 0);
        \\    return buf[j];
        \\}
    , 1);
}

test "A009 reads a parser's checks of a position, and A012 a size checked against the program's limit and a fixed reader's unlimited read" {
    const program =
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, bytes: []const u8, gpa: std.mem.Allocator, max_bytes: u64) !void {
        \\    const at = try r.takeInt(u32, 0);
        \\    if (bytes.len - at < 4) return error.Short;
        \\    _ = bytes[at..][0..2];
        \\    const n = try r.takeInt(u32, 0);
        \\    if (n > bytes.len - at) return error.Short;
        \\    _ = bytes[at..][0..n];
        \\    const want = try r.takeInt(u64, 0);
        \\    if (want > max_bytes) return error.TooLong;
        \\    _ = try gpa.alloc(u8, @intCast(want));
        \\    var fixed: std.Io.Reader = .fixed("abc");
        \\    _ = try fixed.allocRemaining(gpa, .unlimited);
        \\    _ = try r.allocRemaining(gpa, .unlimited);
        \\}
    ;
    try expect(pack.untrusted_input, program, 0);
    try expect(pack.bounded_work, program, 1);
}

test "a number held to 16 bits bounds a loop and sizes work as data does" {
    const program =
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !void {
        \\    const n = try r.takeInt(u32, 0);
        \\    const low: u16 = @intCast(n);
        \\    for (0..@as(u16, @intCast(n))) |_| {}
        \\    _ = try gpa.alloc(u8, low);
        \\    for (0..n) |_| {}
        \\}
    ;
    try expect(pack.untrusted_input, program, 1);
    try expect(pack.bounded_work, program, 0);
}

test "A012 finds work sized by a number from input and reads with no limit" {
    try expect(pack.bounded_work, input_program, 2);
}

test "A018 finds an error's name written to a peer, not to another writer" {
    try expect(pack.diagnostics,
        \\const std = @import("std");
        \\pub fn reply(stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer) !void {
        \\    var buf: [64]u8 = undefined;
        \\    var w = stream.writer(&buf);
        \\    try w.print("{s}", .{@errorName(err)});
        \\    try log.print("{s}", .{@errorName(err)});
        \\}
    , 1);
}

test "A018 reads the peer writers a package declares" {
    var project = try sources.projectWithSources(std.testing.allocator,
        \\const std = @import("std");
        \\pub fn reply(err: anyerror) !void {
        \\    var buf: [64]u8 = undefined;
        \\    var w = std.Io.protocolWriter(&buf);
        \\    try w.print("{s}", .{@errorName(err)});
        \\}
    , &std_files, &std_imports);
    defer project.deinit();
    const declared = [_]glint.Config.PeerWriter{.{ .module = "std", .declaration = "Io.protocolWriter" }};
    for ([_]usize{ 0, 1 }) |given| {
        var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.diagnostics, .level = .report }}, .peer_writers = declared[0..given] }, .{ .project_rules = &pack.rules });
        defer report.deinit();
        try std.testing.expectEqual(given, report.diagnostics.len);
    }
}

test "A020 finds a loop on input or without bound that gives its Io to nothing" {
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\pub fn serve(io: std.Io, r: *std.Io.Reader) void { _ = io; while (true) { _ = r.takeByte() catch return; } }
        \\pub fn polite(io: std.Io, r: *std.Io.Reader) void { while (true) { io.checkCancel() catch return; _ = r.takeByte() catch return; } }
        \\pub fn counted(io: std.Io, r: *std.Io.Reader) void { const n = r.takeInt(u32, 0) catch return; var i: u32 = 0; while (i < n) : (i += 1) {} _ = io; }
        \\pub fn plain(io: std.Io) void { var i: u8 = 0; while (i < 10) : (i += 1) {} _ = io; }
    , 2);
}

/// `program` after the fixes of `rule`'s findings and its stale escapes.
fn fixed(rule: glint.Rule, program: []const u8) ![]u8 {
    var project = try sources.projectWithSources(std.testing.allocator, program, &std_files, &std_imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const changed = try glint.Fix.apply(arena.allocator(), &project, &report);
    if (changed.len == 0) return std.testing.allocator.dupe(u8, program);
    return std.testing.allocator.dupe(u8, changed[0].bytes);
}

test "A013's fix makes std's assert on input aegis's invariant, through a private alias too, and imports aegis" {
    const once = try fixed(pack.contracts,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, y: u8) !void {
        \\    const x = try r.takeByte();
        \\    std.debug.assert(x <
        \\        4);
        \\    std.debug.assert(y < 4);
        \\}
    );
    defer std.testing.allocator.free(once);
    try std.testing.expectEqualStrings(
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\pub fn f(r: *std.Io.Reader, y: u8) !void {
        \\    const x = try r.takeByte();
        \\    aegis.assert.invariant(x <
        \\        4, "x < 4");
        \\    std.debug.assert(y < 4);
        \\}
    , once);
    const alias = try fixed(pack.contracts,
        \\const std = @import("std");
        \\const checks = @import("aegis");
        \\const assert = std.debug.assert;
        \\pub fn f(r: *std.Io.Reader) !void {
        \\    const s = try r.take(2);
        \\    assert(s[0] != '"');
        \\}
    );
    defer std.testing.allocator.free(alias);
    try std.testing.expectEqualStrings(
        \\const std = @import("std");
        \\const checks = @import("aegis");
        \\const assert = std.debug.assert;
        \\pub fn f(r: *std.Io.Reader) !void {
        \\    const s = try r.take(2);
        \\    checks.assert.invariant(s[0] != '"', "s[0] != '\"'");
        \\}
    , alias);
}

test "the fix makes an older written reason or the old pack suppression the escape, and removes an escape that covers nothing" {
    const out = try fixed(pack.unsafe_set,
        \\pub fn f(p: *const u8) *u8 {
        \\    // safe: the caller passes memory it owns
        \\    return @constCast(p);
        \\}
        \\pub fn g() u8 {
        \\    // aegis: no-danger: nothing here any more
        \\    return 1; // aegis: design: nor here
        \\}
        \\pub fn h(p: *const u8) *u8 {
        \\    // glint-ignore: A019 -- c-os-boundary: the kernel's handle
        \\    return @constCast(p);
        \\}
    );
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        \\pub fn f(p: *const u8) *u8 {
        \\    // aegis: no-danger: the caller passes memory it owns
        \\    return @constCast(p);
        \\}
        \\pub fn g() u8 {
        \\    return 1;
        \\}
        \\pub fn h(p: *const u8) *u8 {
        \\    // aegis: boundary: the kernel's handle
        \\    return @constCast(p);
        \\}
    , out);
}
