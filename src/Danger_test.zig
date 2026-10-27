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
    \\pub const math = @import("math.zig");
    \\pub fn ArrayList(comptime T: type) type { return array_list.Aligned(T, null); }
    \\pub const AutoHashMapUnmanaged = hash_map.AutoHashMapUnmanaged;
    },
    .{ .name = "std/Io.zig", .bytes =
    \\pub const File = @import("Io/File.zig");
    \\pub const Reader = @import("Io/Reader.zig");
    \\pub const Dir = struct { handle: i32, pub fn openFile(dir: Dir, io: anytype, sub_path: []const u8, options: anytype) !void { _ = dir; _ = io; _ = sub_path; _ = options; } pub fn readFileAlloc(dir: Dir, io: anytype, sub_path: []const u8, gpa: anytype, limit: usize) ![]u8 { _ = dir; _ = io; _ = sub_path; _ = gpa; _ = limit; return &.{}; } pub fn statFile(dir: Dir, io: anytype, sub_path: []const u8) !u64 { _ = dir; _ = io; _ = sub_path; return 0; } };
    \\pub const Writer = struct { end: usize = 0, pub fn print(w: *Writer, comptime format: []const u8, args: anytype) !void { _ = w; _ = format; _ = args; } };
    \\pub fn protocolWriter(buffer: []u8) Writer { _ = buffer; return .{}; }
    \\pub const net = struct { pub const Stream = struct { handle: i32, pub fn writer(s: Stream, buffer: []u8) Writer { _ = s; _ = buffer; return .{}; } }; pub const Server = struct { stream: Stream }; };
    \\pub fn checkCancel(io: @This()) error{Canceled}!void { _ = io; }
    \\pub const Mutex = extern struct { state: u32 = 0, pub const init: Mutex = .{}; pub fn lock(m: *Mutex) void { _ = m; } };
    \\pub const RwLock = struct { state: u32 = 0 };
    \\pub const Handle = @import("root").Handle;
    \\pub const VTable = struct { close: *const fn (?*anyopaque, Handle) void, write: *const fn (?*anyopaque, Handle, []const u8) void };
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
    .{ .name = "std/Io/File.zig", .bytes = "handle: i32,\npub fn close(f: @This()) void { _ = f; }\npub const Reader = struct { interface: @import(\"Reader.zig\") };\npub fn reader(f: @This(), io: anytype, buffer: []u8) Reader { _ = f; _ = io; _ = buffer; return .{ .interface = .{} }; }" },
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
    .{ .name = "std/mem.zig", .bytes = "pub fn findScalar(comptime T: type, s: []const T, v: T) ?usize { _ = s; _ = v; return null; }\npub const Allocator = struct { ptr: *anyopaque, pub fn alloc(self: Allocator, comptime T: type, n: usize) ![]T { _ = self; _ = n; return &.{}; } };" },
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
    .{ .name = "std/math.zig", .bytes =
    \\pub inline fn maxInt(comptime T: type) comptime_int { const info = @typeInfo(T); const bit_count = info.int.bits; if (bit_count == 0) return 0; return (1 << (bit_count - @intFromBool(info.int.signedness == .signed))) - 1; }
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
    .{ .from = 0, .spelling = "math.zig", .target = 15 },
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

test "A019 finds the unchecked operations, the escape covering one, never an address read or an interface field's parent" {
    try expect(pack.unsafe_set,
        \\extern fn write(fd: c_int) c_int;
        \\const Sink = struct { interface: u64, n: u32 };
        \\fn of(w: *u64) *Sink {
        \\    return @alignCast(@fieldParentPtr("interface", w));
        \\}
        \\pub fn f(p: *const u8, a: usize) usize {
        \\    @setRuntimeSafety(false);
        \\    const q: *u8 = @constCast(p);
        \\    const r: *u32 = @ptrCast(@alignCast(q));
        \\    _ = r;
        \\    const s: *u8 = @ptrFromInt(a); // aegis: boundary: an address the kernel hands back
        \\    _ = s;
        \\    return @intFromPtr(p);
        \\}
    , 5);
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

test "A009's input is a child's output and a file's contents, aegis's whole-file read's too, never the path or allocator a read is given, nor a read the program declares its own" {
    const program =
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\pub fn load(dir: std.Io.Dir, gpa: std.mem.Allocator, table: []const u8, name: []const u8) !u8 {
        \\    const whole = try aegis.own.readFile(null, dir, name, gpa, .fromRaw(100));
        \\    _ = whole[whole[0]];
        \\    const bytes = try dir.readFileAlloc(null, name, gpa, 100);
        \\    const mine = try dir.readFileAlloc(null, "receipt", gpa, 100); // aegis: internal: the receipt this program wrote
        \\    const out = try std.process.run(gpa, null, .{});
        \\    _ = table[name[0]];
        \\    _ = mine[mine[0]];
        \\    _ = bytes[bytes[0]];
        \\    return out.stdout[out.stdout[0]];
        \\}
    ;
    try expect(pack.untrusted_input, program, 3);
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
        \\    total += n;
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
        \\    const secs = try r.takeInt(i64, 0);
        \\    const days = @divFloor(secs, 86400);
        \\    _ = secs - days * 86400;
        \\    const size = try r.takeInt(u64, 0);
        \\    _ = bytes.len - at;
        \\    _ = size - n;
        \\    var left = size;
        \\    if (left < 4) return error.Short;
        \\    left = n;
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

test "an aegis owner or loan holds what it is given: input wrapped is input" {
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\fn free(_: *[]const u8) void {}
        \\const Held = aegis.own.Owned([]const u8, free);
        \\pub fn f(dir: std.Io.Dir, gpa: std.mem.Allocator, table: []const u8, name: []const u8) !u8 {
        \\    const bytes = try dir.readFileAlloc(null, name, gpa, 100);
        \\    var held = Held.init(bytes);
        \\    defer held.deinit();
        \\    const lent = held.lend().get();
        \\    const borrowed = held.borrow().*;
        \\    return lent[lent[0]] +% borrowed[borrowed[0]] +% table[name.len];
        \\}
    , 2);
}

test "A019 reads @setRuntimeSafety on the build mode in each mode: off where the build keeps the checks, undecided on anything else" {
    // fiat-crypto's form: checked only in debug, so off in safe builds.
    try expect(pack.unsafe_set,
        \\const mode = @import("builtin").mode;
        \\pub fn f(a: u64, b: u64) u64 {
        \\    @setRuntimeSafety(mode == .debug);
        \\    return a +% b;
        \\}
    , 1);
    // Through the builtin import and a constant: off nowhere the build keeps checks.
    try expect(pack.unsafe_set,
        \\const builtin = @import("builtin");
        \\const checked = builtin.mode == .debug or builtin.mode == .safe;
        \\pub fn f(a: u64, b: u64) u64 {
        \\    @setRuntimeSafety(checked);
        \\    return a +% b;
        \\}
        \\pub fn g(a: u64, b: u64) u64 {
        \\    @setRuntimeSafety(!(builtin.mode == .fast) and .small != builtin.mode);
        \\    return a +% b;
        \\}
    , 0);
    // Off in both checked modes, and a condition on something else.
    try expect(pack.unsafe_set,
        \\const builtin = @import("builtin");
        \\pub fn f(a: u64, b: u64) u64 {
        \\    @setRuntimeSafety(builtin.mode == .fast);
        \\    return a +% b;
        \\}
    , 1);
    const other = try run(pack.unsafe_set,
        \\const flags = struct { var checked: bool = true; };
        \\pub fn f(a: u64, b: u64) u64 {
        \\    @setRuntimeSafety(flags.checked);
        \\    return a +% b;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), other.undecided);
}

test "A010 reads a signed value held at zero or above, a digit checked against character literals, a variable by every value it is given, a fallback that leaves, a bit cleared under its loop's condition and a magnitude" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, bytes: []const u8) !u64 {
        \\    const secs = try r.takeInt(i64, 0);
        \\    if (secs < 0) return error.Negative;
        \\    const time: u64 = @intCast(secs);
        \\    const max = try r.takeInt(i64, 0);
        \\    const limit: ?u64 = if (max > 0) @intCast(max) else null;
        \\    _ = limit;
        \\    const digit = try r.takeInt(u32, 0);
        \\    if (digit < '0' or digit > '9') return error.NotADigit;
        \\    _ = digit - '0';
        \\    var found: ?usize = null;
        \\    for (0..4) |i| {
        \\        const offset = try r.takeInt(u64, 0);
        \\        if (offset > bytes.len) return error.Short;
        \\        const at: usize = @intCast(offset);
        \\        if (i == 2) found = at;
        \\    }
        \\    const fanout = found orelse return error.Missing;
        \\    _ = fanout + 1024;
        \\    var word = try r.takeInt(u64, 0);
        \\    while (word != 0) {
        \\        word &= word - 1;
        \\    }
        \\    const zone = try r.takeInt(i32, 0);
        \\    _ = @as(i32, @intCast(@abs(zone)));
        \\    const raw = try r.takeInt(i64, 0);
        \\    _ = @as(u64, @intCast(raw));
        \\    return time;
        \\}
    , 1);
}

test "A009 reads a constant added to a checked position, a start held at most its slice's end, a clamp and a name for a checked value" {
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, bytes: []const u8) !void {
        \\    const fanout: usize = @intCast(try r.takeInt(u32, 0));
        \\    if (fanout + 1024 > bytes.len) return error.Short;
        \\    _ = bytes[fanout + 255 * 4 ..][0..4];
        \\    const at = try r.takeInt(u64, 0);
        \\    const size: usize = 4096;
        \\    if (at >= size) return error.Past;
        \\    const off: usize = @intCast(at);
        \\    _ = bytes[off..size];
        \\    const count = try r.takeInt(u32, 0);
        \\    const taken = @as(usize, count) * 4;
        \\    const end = bytes.len;
        \\    if (taken > end - 8) return error.Short;
        \\    _ = bytes[end - taken .. end];
        \\    const lines = bytes.len;
        \\    var start: usize = @intCast(try r.takeInt(u32, 0));
        \\    if (start > lines) start = lines;
        \\    _ = bytes[0..start];
        \\    const far: usize = @intCast(try r.takeInt(u32, 0));
        \\    _ = bytes[far..];
        \\}
    , 1);
}

test "A010 reads std.math.maxInt of an integer type as the constant it is, in a guard joined by or and and" {
    const result = try run(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !u32 {
        \\    const wide: i64 = try r.takeInt(i64, 0);
        \\    if (wide < 1 or wide > std.math.maxInt(u32)) return error.Range;
        \\    const narrow: u32 = @intCast(wide);
        \\    const width: i64 = try r.takeInt(i64, 0);
        \\    const kept: u16 = if (width > 0 and width <= std.math.maxInt(u16)) @intCast(width) else 0;
        \\    const signed: i64 = try r.takeInt(i64, 0);
        \\    if (signed < 0 or signed > std.math.maxInt(i16)) return error.Range;
        \\    const small: i16 = @intCast(signed);
        \\    const loose: i64 = try r.takeInt(i64, 0);
        \\    if (loose > std.math.maxInt(u32)) return error.Range;
        \\    const unsure: u16 = @intCast(loose);
        \\    _ = .{ narrow, kept, small, unsure };
        \\    return 0;
        \\}
    );
    // Only the conversion its guard does not hold: at most a u32, read into a u16.
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{13}, result.lines[0..result.findings]);
}

test "A010 reads the left side of an or as holding where its right side is read: an index past the length leaves before the length less it" {
    const result = try run(pack.integers,
        \\const std = @import("std");
        \\const Bytes = struct { index: u32, len: u32 };
        \\pub fn f(r: *std.Io.Reader, extra: []const u32) !void {
        \\    const v: Bytes = .{ .index = try r.takeInt(u32, 0), .len = try r.takeInt(u32, 0) };
        \\    if (v.index > extra.len or v.len > extra.len - v.index) return error.Short;
        \\    const i = try r.takeInt(u32, 0);
        \\    if (i > extra.len or 4 > extra.len - i) return error.Short;
        \\    const j = try r.takeInt(u32, 0);
        \\    if (4 > extra.len - j) return error.Short;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{9}, result.lines[0..result.findings]);
}

test "A002 reads a type std computes from root, as std's VTable's handles are, as std's own: copying it copies no aegis owner" {
    const result = try run(pack.copies,
        \\const std = @import("std");
        \\fn keep(args: anytype) @TypeOf(args) {
        \\    var local = args;
        \\    _ = &local;
        \\    return local;
        \\}
        \\pub fn slot(comptime name: []const u8) @FieldType(std.Io.VTable, name) {
        \\    const params = @typeInfo(@typeInfo(@FieldType(std.Io.VTable, name)).pointer.child).@"fn".param_types;
        \\    return switch (params.len) {
        \\        3 => &struct {
        \\            fn f(u: ?*anyopaque, a: params[1].?, b: params[2].?) void {
        \\                _ = u;
        \\                _ = keep(.{ a, b });
        \\            }
        \\        }.f,
        \\        else => unreachable,
        \\    };
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqual(@as(usize, 0), result.findings);
}

test "A009 reads a parser handed to input.Untrusted.parse as reading input, and readForParse's value as input; only the parse's refined result is clean" {
    const result = try run(pack.untrusted_input,
        \\const aegis = @import("aegis");
        \\const Reading = struct { limit: usize };
        \\const Header = struct { count: u32 };
        \\fn parseFormat(reading: Reading, bytes: []const u8) error{Short}!Header {
        \\    if (bytes.len < reading.limit) return error.Short;
        \\    const at = @as(usize, bytes[0]) << 8 | bytes[1];
        \\    const probe = bytes[at];
        \\    return .{ .count = probe };
        \\}
        \\pub fn parse(bytes: []const u8, table: []const u8) !u8 {
        \\    const header = try aegis.input.Untrusted([]const u8).init(bytes).parse(Reading{ .limit = 4 }, parseFormat);
        \\    if (header.count >= table.len) return error.Short;
        \\    return table[header.count];
        \\}
        \\pub fn direct(text: aegis.input.Untrusted([]const u8)) u8 {
        \\    const b = text.readForParse();
        \\    const at = @as(usize, b[0]) << 8 | b[1];
        \\    return b[at];
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    // The parser's own index and the direct reader's; never the refined result's use.
    try std.testing.expectEqualSlices(u32, &.{ 7, 18 }, result.lines[0..result.findings]);
}

test "A010 leaves float arithmetic, which gives an infinity where an integer's stops: a division by a sample, a sum of them" {
    const result = try run(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !f64 {
        \\    const raw = try r.takeInt(u64, 0);
        \\    const s: f64 = @floatFromInt(raw);
        \\    const rate = 1e9 / s;
        \\    const total = s + rate * 2.5;
        \\    const count = try r.takeInt(u64, 0);
        \\    _ = 1000 / count;
        \\    return total - s;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{8}, result.lines[0..result.findings]);
}

test "a flow finding names the read its input came from: through a caller's argument, a callee's return and a local" {
    var project = try sources.projectWithSources(std.testing.allocator,
        \\const std = @import("std");
        \\fn header(r: *std.Io.Reader) !u32 {
        \\    const raw = try r.takeInt(u32, 0);
        \\    return raw;
        \\}
        \\fn use(count: u32, table: []const u8) u8 {
        \\    return table[count];
        \\}
        \\pub fn f(r: *std.Io.Reader, table: []const u8) !u8 {
        \\    const count = try header(r);
        \\    return use(count, table);
        \\}
    , &std_files, &std_imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.untrusted_input, .level = .report }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var named: usize = 0;
    for (report.diagnostics) |d| if (d.rule == pack.untrusted_input) {
        try std.testing.expectEqual(@as(u32, 7), d.span.line);
        try std.testing.expect(std.mem.endsWith(u8, d.message, "(input from consumer:3 `r.takeInt`)"));
        named += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), named);
}

test "a flow finding names the read that filled the field its input is held in, wherever the program stored it" {
    var project = try sources.projectWithSources(std.testing.allocator,
        \\const std = @import("std");
        \\const Graph = struct { count: u32 = 0 };
        \\fn load(graph: *Graph, r: *std.Io.Reader) !void {
        \\    graph.count = try r.takeInt(u32, 0);
        \\}
        \\fn lookup(graph: *const Graph, table: []const u8) u8 {
        \\    return table[graph.count];
        \\}
        \\pub fn f(r: *std.Io.Reader, table: []const u8) !u8 {
        \\    var graph: Graph = .{};
        \\    try load(&graph, r);
        \\    return lookup(&graph, table);
        \\}
    , &std_files, &std_imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.untrusted_input, .level = .report }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var named: usize = 0;
    for (report.diagnostics) |d| if (d.rule == pack.untrusted_input) {
        try std.testing.expectEqual(@as(u32, 7), d.span.line);
        try std.testing.expect(std.mem.endsWith(u8, d.message, "(input from consumer:4 `r.takeInt`)"));
        named += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), named);
}

test "A009 leaves a loop each pass of which consumes input, advances past what it took, checks for cancelation or clears a bit of its count" {
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, io: std.Io, bytes: []const u8) !usize {
        \\    const count = try r.takeInt(u32, 0);
        \\    var i: u32 = 0;
        \\    while (i < count) : (i += 1) {
        \\        try io.checkCancel();
        \\    }
        \\    const entries = try r.takeInt(u32, 0);
        \\    for (0..entries) |_| _ = try r.takeByte();
        \\    var cp: []const u8 = bytes;
        \\    var n = try r.takeInt(u32, 0);
        \\    while (n > 0) : (n -= 1) {
        \\        const slash = std.mem.findScalar(u8, cp, '/') orelse return error.Short;
        \\        cp = cp[slash + 1 ..];
        \\    }
        \\    var word = try r.takeInt(u64, 0);
        \\    var bits: usize = 0;
        \\    while (word != 0) {
        \\        bits += 1;
        \\        word &= word - 1;
        \\    }
        \\    const steps = try r.takeInt(u32, 0);
        \\    for (0..steps) |_| bits += 1;
        \\    return bits;
        \\}
    , 1);
}

fn runWidths(rule: glint.Rule, program: []const u8, widths: []const u16) !Run {
    var project = try sources.projectWithSources(std.testing.allocator, program, &std_files, &std_imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .report }}, .pointer_widths = widths }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var result: Run = .{ .findings = 0, .undecided = 0 };
    for (report.diagnostics) |d| if (d.rule == rule) {
        result.findings += 1;
    };
    return result;
}

test "A010 reads a range at the pointer widths of the package's targets: a u32 count times a small constant overflows only a 32-bit usize" {
    const program =
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !usize {
        \\    const count = try r.takeInt(u32, 0);
        \\    return @as(usize, count) * 20;
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 1), (try runWidths(pack.integers, program, &.{})).findings);
    try std.testing.expectEqual(@as(usize, 1), (try runWidths(pack.integers, program, &.{ 32, 64 })).findings);
    try std.testing.expectEqual(@as(usize, 0), (try runWidths(pack.integers, program, &.{64})).findings);
    try std.testing.expectError(error.InvalidSelection, (glint.Config{ .pointer_widths = &.{48} }).validate());
}

test "A010 leaves what a file or directory handle answers of itself, though input made the handle" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, io: std.Io) !i64 {
        \\    const dir: std.Io.Dir = .{ .handle = @truncate(try r.takeInt(u64, 0)) };
        \\    const size = try dir.statFile(io, "HEAD");
        \\    _ = @as(i64, @intCast(size));
        \\    const inode = try r.takeInt(u64, 0);
        \\    return @intCast(inode);
        \\}
    , 1);
}

test "A012 reads a size an aegis Limit checked as bounded by it" {
    try expect(pack.bounded_work,
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !void {
        \\    const blobs: aegis.bounded.Limit(u64) = .init(1 << 20);
        \\    const a = try r.takeInt(u64, 0);
        \\    try blobs.check(a);
        \\    _ = try gpa.alloc(u8, a);
        \\    const b = try r.takeInt(u64, 0);
        \\    if (blobs.exceeds(b)) return error.TooLarge;
        \\    _ = try gpa.alloc(u8, b);
        \\    const n = try r.takeInt(u64, 0);
        \\    _ = try gpa.alloc(u8, n);
        \\}
    , 1);
}

test "A010 reads a plain struct's field by every value the program stores in it, never one a reflection may fill or one that changes in place, and a value made at zero or above" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\const Index = struct { fanout_at: usize, count: u32, total: usize = 0, seen: usize = 0 };
        \\const Header = extern struct { at: u64 };
        \\const Parsed = struct { at: usize };
        \\fn open(r: *std.Io.Reader, bytes: []const u8) !Index {
        \\    const raw = try r.takeInt(u64, 0);
        \\    if (raw > bytes.len) return error.Short;
        \\    const fanout: usize = @intCast(raw);
        \\    if (fanout + 1024 > bytes.len) return error.Short;
        \\    var index: Index = .{ .fanout_at = fanout, .count = try r.takeInt(u32, 0) };
        \\    index.total += try r.takeInt(u32, 0);
        \\    return index;
        \\}
        \\fn fill(comptime T: type, r: *std.Io.Reader) !T {
        \\    var out: T = undefined;
        \\    out.at = @intCast(try r.takeInt(u32, 0));
        \\    return out;
        \\}
        \\pub fn f(r: *std.Io.Reader, bytes: []const u8) !usize {
        \\    const index = try open(r, bytes);
        \\    _ = index.fanout_at + @as(usize, 255) * 4;
        \\    _ = index.total + 1;
        \\    const header: Header = .{ .at = try r.takeInt(u64, 0) };
        \\    _ = header.at + 1;
        \\    const parsed = try fill(Parsed, r);
        \\    _ = parsed.at + 1;
        \\    const year = try r.takeInt(i64, 0);
        \\    _ = @as(u64, @intCast(@max(year, 0)));
        \\    _ = @as(u64, @intCast(@mod(year, 12)));
        \\    _ = @as(u64, @intCast(year & 0o7777));
        \\    return index.seen;
        \\}
    , 4);
}

test "A020 counts a refill through a reader made from the function's Io as a cancellation point, never one passed in or over the program's own bytes" {
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\pub fn drain(io: std.Io, file: std.Io.File, buffer: []u8) void {
        \\    var reader = file.reader(io, buffer);
        \\    const r = &reader.interface;
        \\    while (true) _ = r.takeByte() catch return;
        \\}
        \\pub fn spin(io: std.Io, bytes: []const u8) void {
        \\    _ = io;
        \\    var fixed: std.Io.Reader = .fixed(bytes);
        \\    while (true) _ = fixed.takeByte() catch return;
        \\}
    , 1);
}
