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
    \\pub const VTable = struct { close: *const fn (?*anyopaque, Handle) void, write: *const fn (?*anyopaque, Handle, []const u8) void, processSpawn: *const fn (?*anyopaque) void };
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
    .{ .name = "std/Io/File.zig", .bytes = "handle: i32,\npub fn close(f: @This()) void { _ = f; }\npub const Reader = struct { io: ?*anyopaque = null, interface: @import(\"Reader.zig\") };\npub fn reader(f: @This(), io: anytype, buffer: []u8) Reader { _ = f; _ = io; _ = buffer; return .{ .interface = .{} }; }" },
    .{ .name = "std/process.zig", .bytes = "pub const Child = struct { id: i32 };\npub const RunResult = struct { stdout: []u8 = &.{}, stderr: []u8 = &.{} };\npub fn run(gpa: anytype, io: anytype, options: anytype) !RunResult { _ = gpa; _ = io; _ = options; return .{}; }" },
    .{ .name = "std/array_list.zig", .bytes = "pub fn Aligned(comptime T: type, comptime a: ?u8) type { _ = a; return struct { items: []T = &.{}, capacity: usize = 0, pub fn append(self: *@This(), x: T) void { _ = self; _ = x; } }; }" },
    .{ .name = "std/hash_map.zig", .bytes = "pub fn AutoHashMapUnmanaged(comptime K: type, comptime V: type) type { return struct { k: K, v: V, pub fn getPtr(self: *@This(), key: K) ?*V { _ = key; return &self.v; } }; }" },
    .{ .name = "std/array_hash_map.zig", .bytes = "pub const Nothing = struct {};" },
    .{ .name = "std/Io/Reader.zig", .bytes =
    \\buffer: []u8 = &.{},
    \\seek: usize = 0,
    \\end: usize = 0,
    \\pub const Limit = enum(usize) { unlimited = 0, _ };
    \\pub fn fixed(bytes: []const u8) @This() { _ = bytes; return .{}; }
    \\pub fn takeByte(r: *@This()) !u8 { _ = r; return 0; }
    \\pub fn takeInt(r: *@This(), comptime T: type, endian: u1) !T { _ = r; _ = endian; return 0; }
    \\pub fn fill(r: *@This(), n: usize) !void { if (r.seek + n > r.end) return error.EndOfStream; }
    \\pub fn take(r: *@This(), n: usize) ![]u8 { try r.fill(n); return r.buffer; }
    \\pub fn toss(r: *@This(), n: usize) void { r.seek += n; assert(r.seek <= r.end); }
    \\fn assert(ok: bool) void { if (!ok) unreachable; }
    \\pub fn readSliceAll(r: *@This(), buffer: []u8) !void { _ = r; _ = buffer; }
    \\pub fn readSliceShort(r: *@This(), buffer: []u8) !usize { _ = r; return buffer.len; }
    \\pub fn allocRemaining(r: *@This(), gpa: anytype, limit: Limit) ![]u8 { _ = gpa; _ = limit; return r.buffer; }
    \\pub fn readAlloc(r: *@This(), gpa: anytype, len: usize) ![]u8 { _ = r; return gpa.alloc(u8, len); }
    },
    .{ .name = "std/mem.zig", .bytes = "pub fn asBytes(ptr: anytype) []u8 { _ = ptr; return &.{}; }\npub fn readInt(comptime T: type, buffer: anytype, endian: anytype) T { _ = buffer; _ = endian; return 0; }\npub fn findScalar(comptime T: type, s: []const T, v: T) ?usize { _ = s; _ = v; return null; }\npub fn findScalarPos(comptime T: type, s: []const T, start: usize, v: T) ?usize { for (s[start..], start..) |x, i| if (x == v) return i; return null; }\npub const Allocator = struct { ptr: *anyopaque, pub fn alloc(self: Allocator, comptime T: type, n: usize) ![]T { _ = self.rawAlloc(n * @sizeOf(T)); return &.{}; } pub fn create(self: Allocator, comptime T: type) !*T { _ = self.rawAlloc(@sizeOf(T)); return undefined; } pub fn rawAlloc(self: Allocator, len: usize) ?[*]u8 { _ = self; _ = len; return null; } };" },
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
    , 5);
}

test "A007 leaves an Io.Event, which guards no data, and a container var a build chooses an aegis cell or void for" {
    // conduit's exit signals and test hooks.
    try expect(pack.shared_state,
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const aegis = @import("aegis");
        \\const Child = struct { exited: std.Io.Event = .unset };
        \\var before_exit_watch: if (builtin.is_test) aegis.Atomic(?*const fn (*Child) void) else void = if (builtin.is_test) .init(null) else {};
    , 0);
    // A branch that is a plain type, or a lock beside the event, stays a finding.
    try expect(pack.shared_state,
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const aegis = @import("aegis");
        \\const Child = struct { exited: std.Io.Event = .unset, lock: std.Io.Mutex = .init };
        \\var hook: if (builtin.is_test) ?*const fn (*Child) void else void = if (builtin.is_test) null else {};
    , 2);
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
        \\fn plain(comptime T: type) void {
        \\    if (T == std.Io.Mutex or T != std.atomic.Value(u32)) @compileError("a lock is no data");
        \\}
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
    // A function each of whose returns reads what is already held hands over no owner:
    // shakedown's simulated working directory and standard streams, std's own stdio, a pipe end
    // named by the handle it is given.
    try expect(pack.ownership,
        \\const std = @import("std");
        \\const Slot = struct { file: std.Io.File, open: bool };
        \\const Process = struct { cwd: ?std.Io.Dir, stdio: [3]Slot };
        \\const Context = struct { process: ?*Process, cwd: ?std.Io.Dir };
        \\const closed: std.Io.File = .{ .handle = 0, .flags = .{ .nonblocking = false } };
        \\pub fn cwdOf(ctx: *const Context) ?std.Io.Dir {
        \\    if (ctx.process) |p| return p.cwd;
        \\    return ctx.cwd;
        \\}
        \\pub fn translate(p: *const Process, file: std.Io.File, i: usize) std.Io.File {
        \\    if (i > 2) return file;
        \\    const s = p.stdio[i];
        \\    return if (s.open) s.file else closed;
        \\}
        \\pub fn standard(i: usize) std.Io.File {
        \\    return switch (i) {
        \\        0 => std.Io.File.stdin(),
        \\        1 => std.Io.File.stdout(),
        \\        else => std.Io.File.stderr(),
        \\    };
        \\}
        \\pub fn pipeFile(handle: std.Io.File.Handle) std.Io.File {
        \\    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
        \\}
    , 0);
    // A field moved out through a variable, a field of what was just opened, and an open are
    // owners handed over.
    try expect(pack.ownership,
        \\const std = @import("std");
        \\const Conn = struct { stream: std.Io.net.Stream };
        \\fn connect() !Conn { return undefined; }
        \\pub fn take(c: *Conn) std.Io.net.Stream {
        \\    const s = c.stream;
        \\    c.stream = undefined;
        \\    var moved = s;
        \\    _ = &moved;
        \\    return moved;
        \\}
        \\pub fn fresh() !std.Io.net.Stream {
        \\    const c = try connect();
        \\    return c.stream;
        \\}
        \\pub fn open(dir: std.Io.Dir, io: std.Io) !std.Io.File {
        \\    return dir.openFile(io, "x", .{});
        \\}
    , 3);
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
    // The holder moves it in the switch itself.
    try expect(pack.state_machines,
        \\const Phase = enum { idle, running, done };
        \\const Job = struct {
        \\    phase: Phase = .idle,
        \\    fn reset(j: *Job) void { j.phase = .idle; }
        \\    fn step(j: *Job) void { switch (j.phase) { .idle => j.phase = .running, .running => j.phase = .done, .done => {} } }
        \\};
        \\pub fn run(j: *Job) void { j.step(); j.reset(); }
    , 1);
    // A parser's frame, a record its decoder moves through the frame on top.
    try expect(pack.state_machines,
        \\const State = enum { start, value, after_value };
        \\const Frame = struct { state: State };
        \\const Decoder = struct {
        \\    frames: [4]Frame = undefined,
        \\    depth: usize = 0,
        \\    fn top(d: *Decoder) *Frame { return &d.frames[d.depth]; }
        \\    fn open(d: *Decoder) void { d.top().state = .start; }
        \\    fn step(d: *Decoder) void { const f = d.top(); switch (f.state) { .start => f.state = .value, .value => f.state = .after_value, .after_value => {} } }
        \\};
        \\pub fn run(d: *Decoder) void { d.open(); d.step(); }
    , 1);
}

test "A017 leaves a kind set where its value is built, and records an algorithm rewrites" {
    // A table's layout, set by whichever builder made it.
    try expect(pack.state_machines,
        \\const Kind = enum { single, double };
        \\const Table = struct {
        \\    kind: Kind = .single,
        \\    fn buildSingle(t: *Table) void { t.kind = .single; }
        \\    fn buildDouble(t: *Table) void { t.kind = .double; }
        \\    fn width(t: *const Table) u8 { return switch (t.kind) { .single => 1, .double => 2 }; }
        \\};
        \\pub fn run(t: *Table, wide: bool) u8 { if (wide) t.buildDouble() else t.buildSingle(); return t.width(); }
    , 0);
    // Classes the rules refine on their own value, record by record, from outside the record.
    try expect(pack.state_machines,
        \\const Class = enum { mark, letter, number, neutral };
        \\const Slot = struct { class: Class };
        \\fn marks(slots: []Slot, before: Class) void { for (slots) |*s| if (s.class == .mark) { s.class = before; }; }
        \\fn numbers(slots: []Slot) void { var p: ?usize = 0; while (p) |at| : (p = if (at + 1 < slots.len) at + 1 else null) { const s = &slots[at]; switch (s.class) { .number => s.class = .neutral, else => {} } } }
        \\pub fn run(slots: []Slot) usize { marks(slots, .letter); numbers(slots); var n: usize = 0; for (slots) |s| switch (s.class) { .letter => n += 1, else => {} }; return n; }
    , 0);
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
        \\pub fn cpuid(leaf: u32) [2]u32 {
        \\    var eax: u32 = undefined;
        \\    var ebx: u32 = undefined;
        \\    asm volatile ("cpuid"
        \\        : [_] "={eax}" (eax),
        \\          [_] "={ebx}" (ebx),
        \\        : [_] "{eax}" (leaf),
        \\    );
        \\    return .{ eax, ebx };
        \\}
        \\pub fn tied() u32 { var v: u32 = undefined; asm volatile ("" : [_] "=r" (v) : [_] "r" (v)); return v; }
    , 6); // 3 reads, `tied`'s input read before its output is written, and each `asm` itself
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

test "A012 leaves a size std only moves a position by, and finds one it passes on" {
    try expect(pack.bounded_work,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !void {
        \\    const n = try r.takeInt(u32, 0);
        \\    r.toss(n);
        \\    _ = try r.take(n);
        \\}
    , 1);
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

test "A009 reads a parser's returned literal as the parse refines it: its numbers clean through the parse, its memory still input, and a direct call's numbers input" {
    const result = try run(pack.untrusted_input,
        \\const aegis = @import("aegis");
        \\const Count = struct { count: u32, bytes: u8, rest: []const u8 };
        \\const Header = struct { count: usize, stream: []const u8 };
        \\fn parseCount(_: void, in: []const u8) error{Short}!Count {
        \\    if (in.len < 3) return error.Short;
        \\    return if (in[0] < 0x80) .{ .count = in[0], .bytes = 1, .rest = in[1..] } else .{ .count = @as(u32, in[1]) << 8 | in[2], .bytes = 3, .rest = in[3..] };
        \\}
        \\fn header(in: []const u8) error{Short}!Header {
        \\    const parsed = try aegis.input.Untrusted([]const u8).init(in).parse({}, parseCount);
        \\    return .{ .count = parsed.count, .stream = in[parsed.bytes..] };
        \\}
        \\pub fn counted(in: []const u8, table: []const u8) !u8 {
        \\    const h = try header(in);
        \\    var n = h.count;
        \\    while (n > 0) : (n -= 1) {}
        \\    return table[h.count];
        \\}
        \\pub fn rest(in: []const u8) !void {
        \\    const parsed = try aegis.input.Untrusted([]const u8).init(in).parse({}, parseCount);
        \\    var n = @as(usize, parsed.rest[0]) << 8 | parsed.rest[1];
        \\    while (n > 0) : (n -= 1) {}
        \\}
        \\pub fn direct(text: aegis.input.Untrusted([]const u8)) !void {
        \\    const raw = try parseCount({}, text.readForParse());
        \\    var n = raw.count;
        \\    while (n > 0) : (n -= 1) {}
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    // The loops the parsed memory's bytes and the direct call's count bound; never the parsed
    // count's, through the header it is stored in.
    try std.testing.expectEqualSlices(u32, &.{ 21, 26 }, result.lines[0..result.findings]);
}

test "A009 judges a pointer moved by input: no length checks the address it reaches, unless the offset is within the memory it came from" {
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn moved(r: *std.Io.Reader, out: []u8) !u8 {
        \\    const o: usize = try r.takeInt(u32, 0);
        \\    const offset: usize = try r.takeInt(u32, 0);
        \\    const m = out.ptr + o;
        \\    const src = m - offset;
        \\    return src[0];
        \\}
        \\pub fn indexed(r: *std.Io.Reader, out: []u8) !u8 {
        \\    const o: usize = try r.takeInt(u32, 0);
        \\    return (out.ptr + o)[0];
        \\}
        \\pub fn stepped(r: *std.Io.Reader, out: []u8) !u8 {
        \\    var p = out.ptr;
        \\    p += try r.takeInt(u32, 0);
        \\    return p[0];
        \\}
        \\pub fn checked(r: *std.Io.Reader, out: []u8) !u8 {
        \\    const o: usize = try r.takeInt(u32, 0);
        \\    if (o >= out.len) return error.Short;
        \\    return (out.ptr + o)[0];
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    // Each offset moved by input; never the one checked against its memory's length.
    try std.testing.expectEqualSlices(u32, &.{ 5, 6, 11, 15 }, result.lines[0..result.findings]);
}

test "A010 reads a conversion into a type that fills its backing integer as safe only for an operand within it: not a wider one, nor a signed one" {
    const result = try run(pack.integers,
        \\const std = @import("std");
        \\const Open = enum(u8) { a, _ };
        \\pub fn wide(r: *std.Io.Reader) !u8 {
        \\    const w: u16 = try r.takeInt(u16, 0);
        \\    const open: Open = @enumFromInt(w);
        \\    return @intFromEnum(open);
        \\}
        \\pub fn signed(r: *std.Io.Reader) !u8 {
        \\    const s: i16 = try r.takeInt(i16, 0);
        \\    const open: Open = @enumFromInt(s);
        \\    return @intFromEnum(open);
        \\}
        \\pub fn narrow(r: *std.Io.Reader) !u8 {
        \\    const b: u8 = try r.takeInt(u8, 0);
        \\    const open: Open = @enumFromInt(b);
        \\    return @intFromEnum(open);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    // The wider and the signed operand; never the byte.
    try std.testing.expectEqualSlices(u32, &.{ 5, 10 }, result.lines[0..result.findings]);
}

test "A009 ends a length's fact where its memory is assigned between the check and the use, through a constant naming the length too" {
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn margin(r: *std.Io.Reader, start: []u8) !u8 {
        \\    var in: []u8 = start;
        \\    const ip: usize = try r.takeInt(u32, 0);
        \\    const in_end = in.len - 32;
        \\    if (ip <= in_end) {
        \\        in = in[16..];
        \\        return in[ip + 1 ..][0..16][0];
        \\    }
        \\    return 0;
        \\}
        \\pub fn spelled(r: *std.Io.Reader, start: []u8) !u8 {
        \\    var in: []u8 = start;
        \\    const ip: usize = try r.takeInt(u32, 0);
        \\    if (ip <= in.len - 32) {
        \\        in = in[16..];
        \\        return in[ip + 1 ..][0..16][0];
        \\    }
        \\    return 0;
        \\}
        \\pub fn plain(r: *std.Io.Reader, start: []u8) !u8 {
        \\    var in: []u8 = start;
        \\    const ip: usize = try r.takeInt(u32, 0);
        \\    if (ip < in.len) {
        \\        in = in[16..];
        \\        return in[ip];
        \\    }
        \\    return 0;
        \\}
        \\pub fn kept(r: *std.Io.Reader, start: []u8) !u8 {
        \\    var in: []u8 = start;
        \\    var at: usize = 0;
        \\    const ip: usize = try r.takeInt(u32, 0);
        \\    if (ip < in.len) {
        \\        at = 1;
        \\        in[0] = @intCast(at);
        \\        return in[ip];
        \\    }
        \\    return 0;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    // Each use after its memory was assigned; never the one whose memory only had an element
    // stored.
    try std.testing.expectEqualSlices(u32, &.{ 8, 17, 26 }, result.lines[0..result.findings]);
}

test "A010 reads a negation's variable as written by every form that writes it: a destructuring, a store through its address, an asm output" {
    const result = try run(pack.integers,
        \\const std = @import("std");
        \\pub fn destructured(r: *std.Io.Reader) !i32 {
        \\    var x: i32 = 0;
        \\    var y: i32 = 0;
        \\    x, y = .{ try r.takeInt(i32, 0), 0 };
        \\    return -x +% y;
        \\}
        \\pub fn pointed(r: *std.Io.Reader) !i32 {
        \\    var x: i32 = 0;
        \\    const p = &x;
        \\    p.* = try r.takeInt(i32, 0);
        \\    return -x;
        \\}
        \\pub fn counted(n: u8) i32 {
        \\    var x: i32 = 0;
        \\    var i: u8 = 0;
        \\    while (i < n) : (i += 1) x += 1;
        \\    return -x;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    // The destructured and the pointed-to input; never the count.
    try std.testing.expectEqualSlices(u32, &.{ 6, 12 }, result.lines[0..result.findings]);
}

test "A009 reads a field through a value whose type is one of several by each one's stores: a parse's result over each parser it is given" {
    const result = try run(pack.untrusted_input,
        \\const aegis = @import("aegis");
        \\const Head = struct { rest: []const u8 };
        \\const Tail = struct { rest: []const u8 };
        \\fn head(_: void, b: []const u8) error{Short}!Head {
        \\    if (b.len < 2) return error.Short;
        \\    return .{ .rest = b[1..] };
        \\}
        \\fn tail(_: void, b: []const u8) error{Short}!Tail {
        \\    if (b.len < 2) return error.Short;
        \\    return .{ .rest = b[0 .. b.len - 1] };
        \\}
        \\pub fn f(bytes: []const u8) !void {
        \\    const h = try aegis.input.Untrusted([]const u8).init(bytes).parse({}, head);
        \\    var n = @as(usize, h.rest[0]) << 8 | h.rest[1];
        \\    while (n > 0) : (n -= 1) {}
        \\    const t = try aegis.input.Untrusted([]const u8).init(bytes).parse({}, tail);
        \\    var m = @as(usize, t.rest[0]) << 8 | t.rest[1];
        \\    while (m > 0) : (m -= 1) {}
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    // Each loop the parsed memory's bytes bound, whichever parser the result is read from.
    try std.testing.expectEqualSlices(u32, &.{ 15, 18 }, result.lines[0..result.findings]);
}

test "A009 reads a parse's result as refined only where its parser shows the value's range: a check, a narrower source; a whole-width read stays input" {
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\const Parsed = struct { count: u32 };
        \\fn unchecked(_: void, b: []const u8) error{Short}!Parsed {
        \\    if (b.len < 4) return error.Short;
        \\    return .{ .count = std.mem.readInt(u32, b[0..4], .little) };
        \\}
        \\fn bare(_: void, b: []const u8) error{Short}!u32 {
        \\    if (b.len < 4) return error.Short;
        \\    return std.mem.readInt(u32, b[0..4], .little);
        \\}
        \\fn checked(_: void, b: []const u8) error{ Short, Big }!u32 {
        \\    if (b.len < 4) return error.Short;
        \\    const n = std.mem.readInt(u32, b[0..4], .little);
        \\    if (n > 4096) return error.Big;
        \\    return n;
        \\}
        \\fn narrow(_: void, b: []const u8) error{Short}!u32 {
        \\    if (b.len < 1) return error.Short;
        \\    return b[0];
        \\}
        \\pub fn f(bytes: []const u8) !void {
        \\    const field = try aegis.input.Untrusted([]const u8).init(bytes).parse({}, unchecked);
        \\    var a: usize = field.count;
        \\    while (a > 0) : (a -= 1) {}
        \\    var b: usize = try aegis.input.Untrusted([]const u8).init(bytes).parse({}, bare);
        \\    while (b > 0) : (b -= 1) {}
        \\    var c: usize = try aegis.input.Untrusted([]const u8).init(bytes).parse({}, checked);
        \\    while (c > 0) : (c -= 1) {}
        \\    var d: usize = try aegis.input.Untrusted([]const u8).init(bytes).parse({}, narrow);
        \\    while (d > 0) : (d -= 1) {}
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    // The unchecked field's loop and the bare read's; never the checked or the narrow one's.
    try std.testing.expectEqualSlices(u32, &.{ 25, 27 }, result.lines[0..result.findings]);
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
        try std.testing.expect(std.mem.endsWith(u8, d.message, "(input from consumer:3 `r.takeInt` via consumer:10 `header`)"));
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

test "A009 reads a position its guards keep within the memory: a strict check a slice's bound passes by one, a check other than the length, a loop's condition past its continue expression, a read before, an aegis invariant and a std search" {
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\pub fn f(r: *std.Io.Reader) !void {
        \\    const bytes = try r.take(64);
        \\    var at: usize = try r.takeInt(u8, 0);
        \\    if (at >= bytes.len or bytes[at] != '"') return error.Bad;
        \\    _ = bytes[at + 1 ..];
        \\    while (at < bytes.len) : (at += 1) switch (bytes[at]) {
        \\        ' ' => {},
        \\        else => break,
        \\    };
        \\    while (at < bytes.len) {
        \\        if (bytes[at] == '\\') {
        \\            if (at + 1 == bytes.len or bytes[at + 1] != 'u') return error.Bad;
        \\            _ = bytes[at + 2 ..];
        \\        }
        \\        at += 1;
        \\    }
        \\    var from: usize = try r.takeInt(u8, 0);
        \\    while (std.mem.findScalarPos(u8, bytes, from, '\\')) |slash| {
        \\        _ = bytes[from..slash];
        \\        from = slash + 1;
        \\    }
        \\    const s: usize = try r.takeInt(u8, 0);
        \\    const e: usize = try r.takeInt(u8, 0);
        \\    aegis.assert.invariant(s <= e and e <= bytes.len, "s <= e and e <= bytes.len");
        \\    _ = bytes[s..e];
        \\    var next: usize = try r.takeInt(u8, 0);
        \\    if (next >= bytes.len) return error.Bad;
        \\    if (bytes[next] == '0') {
        \\        next += 1;
        \\    } else if (bytes[next] >= '1') _ = bytes[next];
        \\}
    , 0);
    // A position only other than the length, one read from other memory, and one at most a
    // value nothing bounds are not kept.
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, other: []const u8) !void {
        \\    const bytes = try r.take(64);
        \\    const at: usize = try r.takeInt(u8, 0);
        \\    const e: usize = try r.takeInt(u8, 0);
        \\    if (at != bytes.len) _ = bytes[at];
        \\    if (at < other.len and other[at] == 'x') _ = bytes[at];
        \\    if (at <= e) _ = bytes[at];
        \\    var next: usize = try r.takeInt(u8, 0);
        \\    if (next >= bytes.len) return;
        \\    while (other.len > 0) {
        \\        if (other[0] == 'x') {
        \\            next += 1;
        \\        } else _ = bytes[next];
        \\    }
        \\}
    , 4);
}

test "A009 reads a difference computed before the use: its subtrahend is at most its minuend past it" {
    // The guard's difference, a local's and a field chain's (warp's marked.zig) each stopped the
    // program had it underflowed, so the start is within the memory past it.
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\const Stream = struct { in: []const u8, ip: usize };
        \\pub fn f(r: *std.Io.Reader, s: *Stream) !void {
        \\    const in = try r.take(64);
        \\    const ip: usize = try r.takeInt(u8, 0);
        \\    const len: usize = try r.takeInt(u8, 0);
        \\    if (len > in.len - ip) return error.Short;
        \\    _ = in[ip..];
        \\    const at: usize = try r.takeInt(u8, 0);
        \\    const left = in.len - at;
        \\    _ = left;
        \\    _ = in[at..];
        \\    s.ip = try r.takeInt(u8, 0);
        \\    s.in = in;
        \\    if (len > s.in.len - s.ip) return error.Short;
        \\    _ = s.in[s.ip..];
        \\}
    , 0);
    // A difference only a branch computes, one an `and` may skip, and one whose operand
    // changes after it keep nothing.
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, flag: bool) !void {
        \\    const in = try r.take(64);
        \\    var ip: usize = try r.takeInt(u8, 0);
        \\    if (flag) _ = in.len - ip;
        \\    _ = in[ip..];
        \\    if (flag and in.len - ip > 4) {}
        \\    _ = in[ip..];
        \\    _ = in.len - ip;
        \\    ip += try r.takeInt(u8, 0);
        \\    _ = in[ip..];
        \\}
    , 3);
}

test "A009 reads a sum the length bounds as bounding each of its parts' sums" {
    // warp's huffman streams: four lengths, their sum and the header checked against the input.
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !void {
        \\    const in = try r.take(64);
        \\    const l1: usize = try r.takeInt(u16, .little);
        \\    const l2: usize = try r.takeInt(u16, .little);
        \\    const l3: usize = try r.takeInt(u16, .little);
        \\    if (l1 + l2 + l3 + 6 > in.len) return error.Bad;
        \\    _ = in[6..][0..l1];
        \\    _ = in[6 + l1 ..][0..l2];
        \\    _ = in[6 + l1 + l2 ..][0..l3];
        \\    _ = in[6 + l1 + l2 + l3 ..];
        \\}
    , 0);
    // A part the sum does not hold, and the whole sum as an index (at most the length, not
    // below it), are not kept.
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !void {
        \\    const in = try r.take(64);
        \\    const l1: usize = try r.takeInt(u16, .little);
        \\    const l2: usize = try r.takeInt(u16, .little);
        \\    const l4: usize = try r.takeInt(u16, .little);
        \\    if (l1 + l2 > in.len) return error.Bad;
        \\    _ = in[l1..][0..l4];
        \\    _ = in[l1 + l2];
        \\}
    , 2);
}

test "A010 reads a clamp among the block's other assignments before a difference" {
    // warp's zstd bit reader: the clamp beside the status it sets.
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, at: *usize) !bool {
        \\    var n: usize = try r.takeInt(u8, .little);
        \\    var short = false;
        \\    if (n > at.*) {
        \\        n = at.*;
        \\        short = true;
        \\    }
        \\    at.* -= n;
        \\    return short;
        \\}
    , 0);
    // A block that may change the clamped value again keeps nothing.
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, at: *usize, more: bool) !void {
        \\    var n: usize = try r.takeInt(u8, .little);
        \\    if (n > at.*) {
        \\        n = at.*;
        \\        if (more) n += 1;
        \\    }
        \\    at.* -= n;
        \\}
    , 1);
}

test "A010 takes no input into a comptime parameter, which the program fixes when it is compiled" {
    // warp's match copy: an inline prong's period, chosen by an input offset, as a comptime
    // divisor; given at run time, the same divisor is input's.
    try expect(pack.integers,
        \\const std = @import("std");
        \\fn spread(comptime period: usize) usize {
        \\    var sum: usize = 0;
        \\    for (0..16) |i| sum +%= i % period;
        \\    return sum;
        \\}
        \\pub fn f(r: *std.Io.Reader) !usize {
        \\    const offset: usize = try r.takeInt(u8, .little);
        \\    return switch (offset) {
        \\        inline 1...7 => |period| spread(period),
        \\        else => 0,
        \\    };
        \\}
    , 0);
    try expect(pack.integers,
        \\const std = @import("std");
        \\fn spread(period: usize) usize {
        \\    var sum: usize = 0;
        \\    for (0..16) |i| sum +%= i % period;
        \\    return sum;
        \\}
        \\pub fn f(r: *std.Io.Reader) !usize {
        \\    return spread(try r.takeInt(u8, .little));
        \\}
    , 1);
}

test "A010 reads a constant minimum as at most each of its arguments, and a difference as at most what it is taken from" {
    // warp's speculative decoder: the history taken back from the output's position.
    try expect(pack.integers,
        \\const std = @import("std");
        \\const max = 64;
        \\pub fn f(r: *std.Io.Reader, op: usize, start: usize, out: []u8) !void {
        \\    _ = try r.takeInt(u8, .little);
        \\    const len: usize = try r.takeInt(u8, .little);
        \\    const n = @min(max, op - start);
        \\    const dict = @min(max - n, len);
        \\    _ = max - n - dict;
        \\    _ = out[op - n .. op];
        \\}
    , 0);
    // A minimum's argument assigned after it is no bound on what it is now.
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, start: usize) !usize {
        \\    var op: usize = try r.takeInt(u8, .little);
        \\    const n = @min(op, start);
        \\    op = try r.takeInt(u8, .little);
        \\    return op - n;
        \\}
    , 1);
}

test "A010 reads a midpoint, a nonnegative negation, a divisor that cannot be zero and a byte a for capture takes" {
    // relic's binary searches and zone parser, warp's zstd and match copy, uplink's hpack nibbles.
    try expect(pack.integers,
        \\const std = @import("std");
        \\fn spread(comptime period: usize, step: usize) usize { return step % period; }
        \\pub fn f(r: *std.Io.Reader) !usize {
        \\    var lo: u32 = try r.takeInt(u32, .little);
        \\    var hi: u32 = try r.takeInt(u32, .little);
        \\    while (lo < hi) {
        \\        const mid = lo + (hi - lo) / 2;
        \\        if (mid > 7) hi = mid else lo = hi;
        \\    }
        \\    const zone: i16 = try r.takeInt(i16, .little);
        \\    const magnitude: i32 = @intCast(@abs(@as(i32, zone)));
        \\    const minutes: i32 = @divTrunc(magnitude, 100) * 60 + @mod(magnitude, 100);
        \\    const signed: i32 = if (zone < 0) -minutes else minutes;
        \\    const n: usize = try r.takeInt(u8, .little);
        \\    var sum: usize = @intCast(signed & 0xff);
        \\    sum +%= 2048 / @max(1, n);
        \\    if (n == 0) return sum;
        \\    sum +%= 4096 / n;
        \\    const offset: usize = try r.takeInt(u8, .little);
        \\    switch (offset) {
        \\        inline 1...7 => |period| sum +%= 16 % period,
        \\        else => {},
        \\    }
        \\    const in = try r.take(16);
        \\    for (in) |byte| sum +%= @as(u4, @intCast(byte >> 4));
        \\    return sum;
        \\}
    , 0);
    // The unsafe forms stay findings, each its own: a plain sum, a negated input, a divisor
    // only read, a prong that holds zero, a signed divisor only other than zero (it may be -1),
    // and a byte grown past a byte.
    const head =
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !i64 {
        \\
    ;
    inline for (.{
        "    const lo: u32 = try r.takeInt(u32, .little);\n    const hi: u32 = try r.takeInt(u32, .little);\n    return lo + hi;\n}\n",
        "    const v: i64 = try r.takeInt(i64, .little);\n    return -v;\n}\n",
        "    const n: usize = try r.takeInt(u8, .little);\n    return @intCast(4096 / n);\n}\n",
        "    const n: usize = try r.takeInt(u8, .little);\n    switch (n) {\n        inline 0...3 => |k| return @intCast(16 % k),\n        else => return 0,\n    }\n}\n",
        "    const v: i64 = try r.takeInt(i64, .little);\n    const d: i64 = try r.takeInt(i64, .little);\n    if (d == 0) return 0;\n    return @divTrunc(v, d) +% @rem(v, 3) +% @divTrunc(v, 1) +% v % d;\n}\n",
        "    const in = try r.take(16);\n    var digits: u8 = 0;\n    for (in) |byte| digits = digits * 10 +% byte;\n    return digits;\n}\n",
    }) |body| expect(pack.integers, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}

test "A009 reads a sum a constant names" {
    // chronicle's stream index: the records' start named, and checked against the input.
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !u32 {
        \\    const rest = try r.take(64);
        \\    const id_end = 1 + @as(usize, rest[0]);
        \\    const records_at = id_end + 4;
        \\    if (rest.len < records_at) return error.Bad;
        \\    _ = rest[1..id_end];
        \\    return std.mem.readInt(u32, rest[id_end..][0..4], .little);
        \\}
    , 0);
    // A guard on a smaller sum keeps no larger one.
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !void {
        \\    const rest = try r.take(64);
        \\    const id_end = 1 + @as(usize, rest[0]);
        \\    if (rest.len < id_end) return error.Bad;
        \\    _ = rest[id_end + 4 ..];
        \\}
    , 1);
}

test "A010 reads a remainder by the length of memory input sized as input's divisor, unless the memory is known not to be empty" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !u8 {
        \\    const ring = try r.take(16);
        \\    const table: [8]u8 = @splat(0);
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (ring.len == 0) return error.Bad;
        \\    return table[i % table.len] +% ring[i % ring.len];
        \\}
    , 0);
    // An empty read divides by zero.
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !u8 {
        \\    const ring = try r.take(16);
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    return ring[i % ring.len];
        \\}
    , 1);
}

test "A009 reads what a method of the file checked of its receiver, where the call succeeded" {
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\const Parser = struct {
        \\    input: []const u8,
        \\    at: usize,
        \\    fn byte(self: *const Parser) error{Bad}!u8 {
        \\        return if (self.at < self.input.len) self.input[self.at] else error.Bad;
        \\    }
        \\    fn more(self: *const Parser) error{Bad}!void {
        \\        if (self.at >= self.input.len) return error.Bad;
        \\    }
        \\    fn step(self: *Parser, other: *const Parser) error{Bad}!void {
        \\        switch (try self.byte()) {
        \\            'a' => _ = self.input[self.at],
        \\            else => {},
        \\        }
        \\        try self.more();
        \\        _ = self.input[self.at];
        \\        try other.more();
        \\        self.at += 1;
        \\        _ = self.input[self.at];
        \\    }
        \\};
        \\pub fn f(r: *std.Io.Reader) !void {
        \\    var p: Parser = .{ .input = try r.take(8), .at = try r.takeInt(u8, 0) };
        \\    const q = p;
        \\    try p.step(&q);
        \\}
    , 1);
}

test "A012 reads a count an aegis Budget reservation charged, itself or as a checked multiple" {
    try expect(pack.bounded_work,
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !void {
        \\    var budget: aegis.bounded.Budget(usize) = .init(1 << 20);
        \\    const n = try r.takeInt(u32, 0);
        \\    const bytes = aegis.int.Checked(usize).init(8).mul(n) catch return error.TooLarge;
        \\    var charge = budget.reserve(bytes.raw()) catch return error.TooLarge;
        \\    _ = &charge;
        \\    _ = try gpa.alloc(u64, n);
        \\    const m = try r.takeInt(u32, 0);
        \\    _ = try gpa.alloc(u64, m);
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

test "A020 counts no read as a cancellation point whose error set holds no error.Canceled: a file reader's refill reports a cancel as ReadFailed" {
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
    , 2);
}

test "A010 reads a type made from its backing integer as holding the operand where each value it can have is one of the type's" {
    // uplink's h2 frame types and DNS codes, warp's xz check and zstd block kind, hold's zip hosts.
    try expect(pack.integers,
        \\const std = @import("std");
        \\const Frame = enum(u8) { data = 0, headers = 1, priority_update = 0x10, _ };
        \\const Check = enum(u4) { none = 0, crc32 = 1, crc64 = 4, sha256 = 0xa, _ };
        \\const Kind = enum(u2) { raw, rle, compressed, reserved };
        \\const Mode = enum(u8) { a, b, c, d };
        \\const Bits = packed struct(u8) { low: u4, high: u4 };
        \\const Header = struct { frame: Frame, check: Check };
        \\fn host(bits: Bits) u8 { return @backingInt(bits); }
        \\pub fn f(r: *std.Io.Reader) !u8 {
        \\    const bytes = try r.take(4);
        \\    const made_by: u16 = try r.takeInt(u16, .little);
        \\    const h: u24 = try r.takeInt(u24, .little);
        \\    const header: Header = .{ .frame = @fromBackingInt(@intCast(bytes[3])), .check = @fromBackingInt(@intCast(@as(u4, @truncate(bytes[2])))) };
        \\    const kind: Kind = @fromBackingInt(@as(u2, @truncate(h >> 1)));
        \\    var mode: Mode = .a;
        \\    mode = @enumFromInt(bytes[1] & 3);
        \\    const frame: ?Frame = @fromBackingInt(@intCast(made_by >> 8));
        \\    return @backingInt(header.frame) +% @backingInt(header.check) +% @backingInt(kind) +% @backingInt(mode) +% @backingInt(frame.?) +% host(@fromBackingInt(bytes[0]));
        \\}
    , 0);
    // An exhaustive enum's unnamed values stay findings, as does an operand wider than the
    // tags named from zero, and a conversion into the backing integer that may not fit.
    const head =
        \\const std = @import("std");
        \\const Gap = enum(u4) { none = 0, crc32 = 1, crc64 = 4 };
        \\const Mode = enum(u8) { a, b, c, d };
        \\const Open = enum(u8) { a, _ };
        \\pub fn f(r: *std.Io.Reader) !u8 {
        \\    const bytes = try r.take(4);
        \\
    ;
    inline for (.{
        "    const check: Gap = @fromBackingInt(@as(u4, @truncate(bytes[0])));\n    return @backingInt(check);\n}\n",
        "    const mode: Mode = @fromBackingInt(bytes[1] & 7);\n    return @backingInt(mode);\n}\n",
        "    const wide: u16 = try r.takeInt(u16, .little);\n    const open: Open = @fromBackingInt(@intCast(wide));\n    return @backingInt(open) +% bytes[0];\n}\n",
    }) |body| expect(pack.integers, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}

test "A010 reads a shift amount's conversion as into the log of the shifted value's width" {
    // glint's own `filled`: a width checked below 128 shifts a u128.
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !u128 {
        \\    const bits: u16 = try r.takeInt(u16, .little);
        \\    var mask: u64 = 1;
        \\    mask <<= @intCast(bits & 63);
        \\    return if (bits >= 128) mask else (@as(u128, 1) << @intCast(bits)) - 1;
        \\}
    , 0);
    // An amount past the width stays a finding.
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !u128 {
        \\    const bits: u16 = try r.takeInt(u16, .little);
        \\    return if (bits > 128) 0 else @as(u128, 1) << @intCast(bits);
        \\}
    , 1);
}

test "A015 reads a function std's Io calls through its vtable as returning what the caller of the operation owns" {
    // conduit's routed spawn, given to a layer as the `processSpawn` slot.
    try expect(pack.ownership,
        \\const std = @import("std");
        \\const State = struct { base: std.Io };
        \\pub fn routedSpawn(userdata: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
        \\    const state: *State = @ptrCast(@alignCast(userdata.?));
        \\    return std.process.spawn(state.base, options);
        \\}
        \\fn Layer(comptime overrides: anytype) type { return struct { const slots = overrides; }; }
        \\pub const Routed = Layer(.{ .processSpawn = &routedSpawn });
    , 0);
    // Named in a slot no vtable declares, or taking no userdata, it hands over an owner.
    try expect(pack.ownership,
        \\const std = @import("std");
        \\const State = struct { base: std.Io };
        \\pub fn routedSpawn(userdata: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
        \\    const state: *State = @ptrCast(@alignCast(userdata.?));
        \\    return std.process.spawn(state.base, options);
        \\}
        \\pub fn spawn(io: std.Io, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
        \\    return std.process.spawn(io, options);
        \\}
        \\fn Layer(comptime overrides: anytype) type { return struct { const slots = overrides; }; }
        \\pub const Routed = Layer(.{ .start = &routedSpawn, .processSpawn = spawn });
    , 2);
}

test "A014 reads a local list nothing grows or frees once its items are stored as no borrow a growth moves" {
    // parley's agreed task ids, collected into a local list and stored once it is full.
    try expect(pack.lifetimes,
        \\const std = @import("std");
        \\const Agreed = struct { ids: []u32 = &.{} };
        \\pub fn agree(agreed: *Agreed, from: []const u32) void {
        \\    var held: std.ArrayList(u32) = .{};
        \\    for (from) |id| held.append(id);
        \\    agreed.ids = held.items;
        \\}
    , 0);
    // Grown after the store, handed on where an alias may grow it, stored in a loop that grows
    // it on the next pass, or a list someone else holds, each stays a finding.
    const head =
        \\const std = @import("std");
        \\const Agreed = struct { ids: []u32 = &.{}, list: std.ArrayList(u32) = .{} };
        \\fn grow(list: *std.ArrayList(u32)) void { list.append(1); }
        \\pub fn agree(agreed: *Agreed, from: []const u32) void {
        \\
    ;
    inline for (.{
        "    var held: std.ArrayList(u32) = .{};\n    agreed.ids = held.items;\n    held.append(from[0]);\n}\n",
        "    var held: std.ArrayList(u32) = .{};\n    grow(&held);\n    agreed.ids = held.items;\n    _ = from;\n}\n",
        "    var held: std.ArrayList(u32) = .{};\n    for (from) |id| {\n        held.append(id);\n        agreed.ids = held.items;\n    }\n}\n",
        "    const list = &agreed.list;\n    list.append(from[0]);\n    agreed.ids = list.items;\n}\n",
        // Freed, by a `defer` written before the store or a `deinit` after it.
        "    var held: std.ArrayList(u32) = .{};\n    defer held.deinit();\n    held.append(from[0]);\n    agreed.ids = held.items;\n}\n",
        "    var held: std.ArrayList(u32) = .{};\n    errdefer held.clearAndFree();\n    held.append(from[0]);\n    agreed.ids = held.items;\n}\n",
    }) |body| expect(pack.lifetimes, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}

test "A020 reads a cancellation point the loop reaches through the project's functions: a call whose error set holds error.Canceled, never one only given an Io" {
    // uplink's connection loop (its socket holds the Io); relic's fetch-pack packets read from
    // a stream reader, which reports a cancel as ReadFailed, and a call only given the Io, are
    // no cancellation point.
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\const Socket = struct { io: std.Io, file: std.Io.File, reader: std.Io.File.Reader };
        \\fn awaitRequest(s: *Socket) bool {
        \\    s.io.checkCancel() catch return false;
        \\    return true;
        \\}
        \\fn readPacket(s: *Socket) !u8 {
        \\    return s.reader.interface.takeByte();
        \\}
        \\fn send(io: std.Io, s: *Socket) void { _ = io; _ = s; }
        \\pub fn serve(io: std.Io, s: *Socket) void {
        \\    _ = io;
        \\    while (true) if (!awaitRequest(s)) return;
        \\}
        \\pub fn fetch(io: std.Io, s: *Socket) !void {
        \\    _ = io;
        \\    while (true) if (try readPacket(s) == 0) break;
        \\}
        \\pub fn pump(io: std.Io, s: *Socket) void {
        \\    _ = io;
        \\    while (true) send(s.io, s);
        \\}
        \\fn now(io: std.Io) u64 {
        \\    _ = io;
        \\    return 0;
        \\}
        \\pub fn clock(io: std.Io) void {
        \\    var total: u64 = 0;
        \\    while (true) total +%= now(io);
        \\}
    , 3);
    // A reader passed in may be a fixed one over the program's bytes, a toss never refills, and
    // a function that reaches no Io is no cancellation point.
    const head =
        \\const std = @import("std");
        \\const Socket = struct { io: std.Io, file: std.Io.File, reader: std.Io.File.Reader };
        \\fn idle(s: *Socket) bool { return s.file.handle != 0; }
        \\
    ;
    inline for (.{
        "pub fn f(io: std.Io, r: *std.Io.Reader) void {\n    _ = io;\n    while (true) _ = r.takeByte() catch return;\n}\n",
        "pub fn f(io: std.Io, s: *Socket) void {\n    _ = io;\n    while (true) s.reader.interface.toss(1);\n}\n",
        "pub fn f(io: std.Io, s: *Socket) void {\n    _ = io;\n    while (true) if (!idle(s)) return;\n}\n",
    }) |body| expect(pack.cancellation, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}

test "A009 reads an unsigned difference as at most what it is taken from less the constant it takes" {
    // relic's resolve undo: a `u2` stage other than zero, less one, picks one of three.
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\const Entry = struct { stage: u2 = 0, mode: u32 = 0 };
        \\const Item = struct { modes: [3]u32 };
        \\fn record(item: *Item, entry: Entry) void {
        \\    if (entry.stage == 0) return;
        \\    item.modes[entry.stage - 1] = entry.mode;
        \\}
        \\pub fn f(r: *std.Io.Reader, items: []Item) !void {
        \\    const b = try r.take(4);
        \\    const flags = std.mem.readInt(u32, b[0..4], .big);
        \\    items[0].modes[0] = flags;
        \\    record(&items[0], .{ .stage = @truncate((flags >> 12) & 3), .mode = flags });
        \\}
    , 0);
    // Less too small a constant, nothing taken, or a value no constant names, it stays a finding.
    const head =
        \\const std = @import("std");
        \\const Entry = struct { stage: u2 = 0, by: u2 = 0, mode: u32 = 0 };
        \\const Item = struct { modes: [3]u32, pair: [2]u32 };
        \\fn record(item: *Item, entry: Entry) void {
        \\    if (entry.stage == 0) return;
        \\
    ;
    const tail =
        \\}
        \\pub fn f(r: *std.Io.Reader, items: []Item) !void {
        \\    const b = try r.take(4);
        \\    const flags = std.mem.readInt(u32, b[0..4], .big);
        \\    items[0].modes[0] = flags;
        \\    items[0].pair[0] = flags;
        \\    record(&items[0], .{ .stage = @truncate((flags >> 12) & 3), .by = @truncate(flags & 3), .mode = flags });
        \\}
    ;
    inline for (.{
        "    item.pair[entry.stage - 1] = entry.mode;\n",
        "    item.modes[entry.stage] = entry.mode;\n",
        "    if (entry.by > entry.stage) return;\n    item.pair[entry.stage - entry.by] = entry.mode;\n",
    }) |body| expect(pack.untrusted_input, head ++ body ++ tail, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}

test "A012 reads a take, peek or discard on a fixed reader as no work a peer sizes, an allocating read as work" {
    // relic's index extensions: each one's size, taken from the file's bytes it already holds.
    try expect(pack.bounded_work,
        \\const std = @import("std");
        \\pub fn f(in: *std.Io.Reader, body: []const u8) ![]u8 {
        \\    var r: std.Io.Reader = .fixed(body);
        \\    const size = try in.takeInt(u32, 0);
        \\    return r.take(size);
        \\}
    , 0);
    // A stream's take is a peer's size, and so is a fixed reader's read that allocates.
    try expect(pack.bounded_work,
        \\const std = @import("std");
        \\pub fn f(in: *std.Io.Reader, body: []const u8, gpa: std.mem.Allocator) ![]u8 {
        \\    var r: std.Io.Reader = .fixed(body);
        \\    const size = try in.takeInt(u32, 0);
        \\    _ = try in.take(size);
        \\    _ = gpa;
        \\    return r.take(0);
        \\}
    , 1);
    try expect(pack.bounded_work,
        \\const std = @import("std");
        \\pub fn f(in: *std.Io.Reader, body: []const u8, gpa: std.mem.Allocator) ![]u8 {
        \\    var r: std.Io.Reader = .fixed(body);
        \\    const size = try in.takeInt(u32, 0);
        \\    return r.readAlloc(gpa, size);
        \\}
    , 1);
}

test "A008 decides a method called through a generic's bound type where the binding names it" {
    // parallax's interner: its context's equality, whatever context a consumer binds.
    try expect(pack.secrets,
        \\const std = @import("std");
        \\pub fn Interner(comptime T: type, comptime Context: type) type {
        \\    return struct {
        \\        context: Context,
        \\        items: []const T,
        \\        pub fn find(s: *const @This(), item: T) ?usize {
        \\            for (s.items, 0..) |x, i| if (s.context.eql(x, item)) return i;
        \\            return null;
        \\        }
        \\    };
        \\}
    , 0);
    // A binding that names std's timing-safe comparison is found where it names it.
    try expect(pack.secrets,
        \\const std = @import("std");
        \\pub fn Interner(comptime T: type, comptime Context: type) type {
        \\    return struct {
        \\        context: Context,
        \\        items: []const T,
        \\        pub fn find(s: *const @This(), item: T) ?usize {
        \\            for (s.items, 0..) |x, i| if (s.context.eql(x, item)) return i;
        \\            return null;
        \\        }
        \\    };
        \\}
        \\const Timed = struct { pub const eql = std.crypto.timing_safe.eql; };
        \\pub const Keys = Interner([4]u8, Timed);
    , 1);
}

test "A008 finds a hand comparison an alias a container declares names, at the alias" {
    try expect(pack.secrets,
        \\const std = @import("std");
        \\const eql = std.crypto.timing_safe.eql;
        \\pub fn f(a: [4]u8, b: [4]u8) bool { return eql([4]u8, a, b); }
        \\pub fn g(a: [4]u8, b: [4]u8) bool { const local = std.crypto.timing_safe.eql; return local([4]u8, a, b); }
    , 2);
}

test "A011 finds a unit converted by hand through an alias a container declares, at the arithmetic" {
    try expect(pack.units,
        \\const std = @import("std");
        \\const ns_per_ms = std.time.ns_per_ms;
        \\pub fn f(ms: u64) u64 { return ms * ns_per_ms; }
        \\pub fn g() u64 { return ns_per_ms; }
    , 1);
}

test "A011 keeps a method a generic's bound type gives undecided, as std's own type may be the binding" {
    const result = try run(pack.units,
        \\const std = @import("std");
        \\pub fn Timer(comptime D: type) type {
        \\    return struct {
        \\        left: D,
        \\        pub fn ms(t: *const @This()) i64 { return t.left.toMilliseconds(); }
        \\    };
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), result.undecided);
}

test "A009 reads a constant margin: a cursor at most the length less a constant, then parts within the constant" {
    // warp's fast loops: lz4's `in_end = in.len - 32` and `op + len <= out.len - 64`, zstd's
    // and inflate's named margins.
    const head =
        \\const std = @import("std");
        \\const margin = 258 + 16;
        \\pub fn f(r: *std.Io.Reader, out: []u8) !void {
        \\    const in = try r.take(4096);
        \\    var ip: usize = try r.takeInt(u32, 0);
        \\    var op: usize = try r.takeInt(u32, 0);
        \\    _ = &ip;
        \\    _ = &op;
        \\
    ;
    inline for (.{
        "    if (in.len < 32) return;\n    const in_end = in.len - 32;\n    if (ip <= in_end) {\n        _ = in[ip];\n        _ = in[ip + 1 ..][0..16];\n        _ = in[ip..][0..32];\n    }\n    _ = out;\n}\n",
        "    if (out.len < 64) return;\n    const out_end = out.len - 64;\n    const len: usize = 8;\n    if (op + len <= out_end) {\n        out[op..][0..8].* = in[0..8].*;\n        out[op + 8 ..][0..8].* = in[0..8].*;\n        out[op + 16 ..][0..2].* = in[0..2].*;\n    }\n}\n",
        "    if (op + margin <= out.len) out[op + 258 ..][0..16].* = in[0..16].*;\n}\n",
    }) |body| expect(pack.untrusted_input, head ++ body, 0) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
    // A part past the margin, a saturating difference (zero where the length is short of the
    // margin, which leaves the cursor anywhere below it), and a margin no constant names stay
    // findings.
    inline for (.{
        "    if (in.len < 32) return;\n    const in_end = in.len - 32;\n    if (ip <= in_end) _ = in[ip + 33 ..];\n    _ = out;\n}\n",
        "    if (op <= out.len -| 32) out[op..][0..16].* = in[0..16].*;\n}\n",
        "    const n = in[0];\n    if (ip + n <= in.len) _ = in[ip + 16 ..];\n    _ = out;\n}\n",
    }) |body| expect(pack.untrusted_input, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}

test "Z034's fix nests the parentheses two findings open at one offset" {
    // warp's lzma range decoder: a difference shifted, the shift in an exclusive or.
    const once = try fixed(.Z034,
        \\pub fn mask(code: u32, range: u32) u32 {
        \\    return 0 -% (code -% range >> 31 ^ 1);
        \\}
    );
    defer std.testing.allocator.free(once);
    try std.testing.expectEqualStrings(
        \\pub fn mask(code: u32, range: u32) u32 {
        \\    return 0 -% (((code -% range) >> 31) ^ 1);
        \\}
    , once);
    const twice = try fixed(.Z034, once);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(once, twice);
}

test "A010 reads C integer types by their narrowest width where a value goes into one, their widest where one is read, and c_char by either sign" {
    // bay's warp frames: a guard against the 32-bit bound clears a conversion into `c_ulong`
    // and `c_int`; a `c_char` held at 0 to 127 fits it on every target.
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !void {
        \\    const v = try r.takeInt(u64, 0);
        \\    if (v > 0xffff_ffff) return;
        \\    const window: c_ulong = @intCast(v);
        \\    const count: c_int = @intCast(v & 0x7fff_ffff);
        \\    const b = try r.takeByte();
        \\    const ch: c_char = @intCast(b & 0x7f);
        \\    _ = .{ window, count, ch };
        \\}
        \\fn narrow(ch: c_char) u8 {
        \\    if (ch < 0) return 0;
        \\    return @intCast(ch);
        \\}
        \\pub fn g(r: *std.Io.Reader) !u8 {
        \\    return narrow(@intCast(try r.takeByte() & 0x7f));
        \\}
    , 0);
    // A guard only a 64-bit `c_ulong` holds, a byte into `c_char` (above 127 on a signed
    // target), a `c_char` that may be negative into `u8`, and a `c_ulong` read into a `u32`
    // (64 bits where it is long), each stays a finding.
    const head =
        \\const std = @import("std");
        \\
    ;
    inline for (.{
        "pub fn f(r: *std.Io.Reader) !c_ulong {\n    const v = try r.takeInt(u64, 0);\n    if (v > 0xffff_ffff_ffff) return 0;\n    return @intCast(v);\n}\n",
        "pub fn f(r: *std.Io.Reader) !c_char {\n    const b = try r.takeByte();\n    return @intCast(b);\n}\n",
        "fn narrow(ch: c_char) u8 {\n    return @intCast(ch);\n}\npub fn f(r: *std.Io.Reader) !u8 {\n    return narrow(@bitCast(try r.takeByte()));\n}\n",
        "fn narrow(n: c_ulong) u32 {\n    return @intCast(n);\n}\npub fn f(r: *std.Io.Reader) !u32 {\n    return narrow(try r.takeInt(u32, 0));\n}\n",
    }) |body| expect(pack.integers, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}

test "A009 reads the length of an array a field points to: a byte indexes 256 entries" {
    // relic's multi-pack index, pack index and commit-graph fanouts: an object name's first byte.
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\const buckets = 256;
        \\const Index = struct { fanout_table: *const [256][4]u8, direct: *const [buckets]u32 };
        \\fn fanout(index: *const Index, bucket: u8) u32 {
        \\    return std.mem.readInt(u32, &index.fanout_table[bucket], .big) +% index.direct[bucket];
        \\}
        \\pub fn f(r: *std.Io.Reader) !u32 {
        \\    const b = try r.take(2048);
        \\    const index: Index = .{ .fanout_table = @ptrCast(b[0..1024]), .direct = @ptrCast(@alignCast(b[1024..2048])) };
        \\    return fanout(&index, b[0]);
        \\}
    , 0);
    // A wider index, or a slice with no declared length, stays a finding.
    const head =
        \\const std = @import("std");
        \\const Index = struct { fanout_table: *const [256][4]u8, rows: []const [4]u8 };
        \\
    ;
    const tail =
        \\pub fn f(r: *std.Io.Reader) !u32 {
        \\    const b = try r.take(2048);
        \\    const index: Index = .{ .fanout_table = @ptrCast(b[0..1024]), .rows = @ptrCast(b[1024..2048]) };
        \\    return fanout(&index, b[0], try r.takeInt(u16, 0));
        \\}
    ;
    inline for (.{
        "fn fanout(index: *const Index, bucket: u8, wide: u16) u32 {\n    _ = bucket;\n    return std.mem.readInt(u32, &index.fanout_table[wide], .big);\n}\n",
        "fn fanout(index: *const Index, bucket: u8, wide: u16) u32 {\n    _ = wide;\n    return std.mem.readInt(u32, &index.rows[bucket], .big);\n}\n",
    }) |body| expect(pack.untrusted_input, head ++ body ++ tail, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}

test "A010 reads a wrapping comparison of a value less one as the value from one to the bound" {
    // warp's lz4 fast loop: an offset from 1 to `at`, as one comparison.
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !usize {
        \\    const at: usize = try r.takeInt(u32, 0);
        \\    const offset: usize = try r.takeInt(u16, 0);
        \\    if (offset -% 1 < at) return at - offset;
        \\    if (at > offset -% 1) return offset - 1;
        \\    return 0;
        \\}
    , 0);
    // Less two, a signed value, or a comparison that may hold at zero stays a finding.
    const head =
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !i64 {
        \\
    ;
    inline for (.{
        "    const at: usize = try r.takeInt(u32, 0);\n    const offset: usize = try r.takeInt(u16, 0);\n    if (offset -% 2 < at) return @intCast(at - offset);\n    return 0;\n}\n",
        "    const at: i64 = try r.takeInt(i64, 0);\n    const offset: i64 = try r.takeInt(i64, 0);\n    if (offset -% 1 < at) return at - offset;\n    return 0;\n}\n",
        "    const at: usize = try r.takeInt(u32, 0);\n    const offset: usize = try r.takeInt(u16, 0);\n    if (offset -% 1 <= at) return @intCast(at - offset);\n    return 0;\n}\n",
    }) |body| expect(pack.integers, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}

test "A009 reads a call that passes its argument through, an empty asm tied to it, as that argument" {
    // warp's lz4 and snappy fast loops: `chainless(ip + 3)`, an optimization barrier.
    const tail =
        \\pub fn f(r: *std.Io.Reader, out: []u8) !void {
        \\    const in = try r.take(4096);
        \\    var ip: usize = try r.takeInt(u32, 0);
        \\    _ = &ip;
        \\    if (in.len < 32) return;
        \\    const in_end = in.len - 32;
        \\    if (ip <= in_end) {
        \\        const past_offset = through(ip + 3);
        \\        out[0..16].* = in[past_offset - 2 ..][0..16].*;
        \\    }
        \\}
    ;
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\inline fn through(x: usize) usize {
        \\    return switch (builtin.cpu.arch) {
        \\        .aarch64, .x86_64 => asm ("" : [out] "=r" (-> usize) : [in] "0" (x)),
        \\        else => x,
        \\    };
        \\}
        \\
    ++ tail, 0);
    // An asm that does something, or a function that moves its argument, is no identity.
    inline for (.{
        "const std = @import(\"std\");\nconst builtin = @import(\"builtin\");\ninline fn through(x: usize) usize {\n    return switch (builtin.cpu.arch) {\n        .x86_64 => asm (\"add %[out], 64\" : [out] \"=r\" (-> usize) : [in] \"0\" (x)),\n        else => x,\n    };\n}\n",
        "const std = @import(\"std\");\ninline fn through(x: usize) usize {\n    return x + 64;\n}\n",
    }) |head| expect(pack.untrusted_input, head ++ tail, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{head});
        return err;
    };
}

test "A009 reads the length a union field's capture or an allocator's create points to: a byte indexes 256 entries" {
    // relic's regular expressions: a bracket's set, made by `create([256]bool)` from the
    // pattern's bytes and read through a prong's capture. The capture's own reading is shown on
    // relic's matchers (ere.zig's backtracker and VM), whose taint no fixture here reaches.
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\const Node = union(enum) { set: *const [256]bool, byte: u8 };
        \\fn matches(node: Node, c: u8) bool {
        \\    return switch (node) {
        \\        .set => |s| s[c],
        \\        .byte => |b| c == b,
        \\    };
        \\}
        \\pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !bool {
        \\    const pattern = try r.take(256);
        \\    const set = try gpa.create([256]bool);
        \\    @memcpy(set[0..64], @as([]const bool, @ptrCast(pattern[0..64])));
        \\    set[pattern[64]] = true;
        \\    var nodes: [2]Node = undefined;
        \\    nodes[0] = .{ .byte = pattern[65] };
        \\    nodes[1] = .{ .set = set };
        \\    return matches(nodes[1], pattern[66]) or matches(nodes[0], pattern[67]);
        \\}
    , 0);
    // A wider index, or a set of fewer entries, stays a finding.
    const head =
        \\const std = @import("std");
        \\const Node = union(enum) { set: *const [256]bool, small: *const [128]bool, byte: u8 };
        \\pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !bool {
        \\    const pattern = try r.take(256);
        \\    const w = std.mem.readInt(u32, pattern[0..4], .big);
        \\
    ;
    inline for (.{
        "    const set = try gpa.create([256]bool);\n    @memcpy(set[0..64], @as([]const bool, @ptrCast(pattern[0..64])));\n    set[w] = true;\n    return set[0];\n}\n",
        "    const set = try gpa.create([128]bool);\n    @memcpy(set[0..64], @as([]const bool, @ptrCast(pattern[0..64])));\n    set[pattern[64]] = true;\n    _ = w;\n    return set[0];\n}\n",
    }) |body| expect(pack.untrusted_input, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}

test "A010 reads a negation's operand by every value its variable is given, a saturating sum of digits, a remainder, and a widened value" {
    // relic's date parsers: a sign applied to digits read with `*|` and `+|`, a zone's
    // minutes negated in place, git's `tz` integer, an offset widened before it is negated.
    try expect(pack.integers,
        \\const std = @import("std");
        \\fn digits(s: []const u8, neg: bool) i64 {
        \\    var v: i64 = 0;
        \\    var i: usize = 0;
        \\    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) v = v *| 10 +| (s[i] - '0');
        \\    return if (neg) -v else v;
        \\}
        \\fn zone(date: []const u8, sign: u8) i32 {
        \\    var ofs: i64 = 0;
        \\    var j: usize = 0;
        \\    while (j < date.len and date[j] >= '0' and date[j] <= '9') : (j += 1) ofs = ofs *| 10 +| (date[j] - '0');
        \\    if (ofs > 9999) return 0;
        \\    var minutes: i32 = @intCast(@divTrunc(ofs, 100) * 60 + @mod(ofs, 100));
        \\    if (sign == '-') minutes = -minutes;
        \\    return minutes;
        \\}
        \\fn tz(offset_minutes: i32) i32 {
        \\    const abs: i32 = @intCast(@abs(offset_minutes));
        \\    const v = @divTrunc(abs, 60) * 100 + @rem(abs, 60);
        \\    return if (offset_minutes < 0) -v else v;
        \\}
        \\fn widened(offset: i32, secs: i64) bool {
        \\    return offset < 0 and -@as(i64, offset) * 60 > secs;
        \\}
        \\pub fn f(r: *std.Io.Reader) !i64 {
        \\    const s = try r.take(16);
        \\    const n = try r.takeInt(i64, 0);
        \\    const o = try r.takeInt(i32, 0);
        \\    _ = widened(o, n);
        \\    return digits(s, s[0] == '-') +| zone(s[2..], s[1]) +| tz(@intCast(o & 0xffff));
        \\}
    , 0);
    // A variable given a negative value elsewhere or through its address, a product that may be
    // the minimum, and a full-width value stay findings.
    const head =
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !i64 {
        \\    const n = try r.takeInt(i64, 0);
        \\
    ;
    inline for (.{
        "    var v: i64 = 0;\n    v = n;\n    return -v;\n}\n",
        "    var v: i64 = @max(n, 0);\n    set(&v, n);\n    return -v;\n}\nfn set(p: *i64, x: i64) void {\n    p.* = x;\n}\n",
        "    const v = @divTrunc(n, 2) * 2;\n    return -v;\n}\n",
        "    const w: i64 = n;\n    return -@as(i64, w);\n}\n",
    }) |body| expect(pack.integers, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}

test "A009 ends a comparison's fact where the compared value's address is handed on, which lets the callee write it" {
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\fn advance(i: *usize, by: usize) void {
        \\    i.* += by;
        \\}
        \\pub fn f(r: *std.Io.Reader) !u8 {
        \\    const buf = try r.take(64);
        \\    var i: usize = try r.takeInt(u32, 0);
        \\    if (i < buf.len) {
        \\        advance(&i, buf[0]);
        \\        return buf[i];
        \\    }
        \\    return 0;
        \\}
    , 1);
    // Its address taken before the comparison, or in another branch, leaves the fact.
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\fn advance(i: *usize, by: usize) void {
        \\    i.* += by;
        \\}
        \\pub fn f(r: *std.Io.Reader) !u8 {
        \\    const buf = try r.take(64);
        \\    var i: usize = try r.takeInt(u32, 0);
        \\    advance(&i, 1);
        \\    if (i < buf.len) return buf[i] else advance(&i, 2);
        \\    return 0;
        \\}
    , 0);
}

test "A010 reads an address moved from a pointer through a constant as an address, A009's where it reaches memory" {
    // warp's zstd sequences: `const m = out.ptr + o_lit;` then `m - offset`.
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, out: []u8) !u8 {
        \\    const o_lit: usize = try r.takeInt(u32, 0);
        \\    const offset: usize = try r.takeInt(u32, 0);
        \\    const m = out.ptr + o_lit;
        \\    const src = m - offset;
        \\    return src[0];
        \\}
    , 0);
    // The same arithmetic on a number stays one.
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !usize {
        \\    const o_lit: usize = try r.takeInt(u32, 0);
        \\    const offset: usize = try r.takeInt(u32, 0);
        \\    const m = o_lit;
        \\    return m - offset;
        \\}
    , 1);
}

test "A010 reads a field by its stores only while nothing writes its struct's bytes unseen: a byte view, a reinterpretation, its address handed outside the program, a store through a computed name" {
    // Stores the program makes, a literal-named `@field` among them, and a struct its own
    // function writes through the address it is given, keep their fields' ranges.
    try expect(pack.integers,
        \\const std = @import("std");
        \\const Weights = struct { count: u32 = 0 };
        \\const Named = struct { n: u32 = 0 };
        \\const Set = struct { n: u32 = 0 };
        \\fn set(s: *Set, v: u32) void {
        \\    s.n = v & 0xff;
        \\}
        \\pub fn f(r: *std.Io.Reader, w: *Weights, q: *Named, t: *Set) !void {
        \\    const n = try r.takeInt(u32, 0);
        \\    if (n >= 255) return error.Long;
        \\    w.count = n + 1;
        \\    _ = w.count * 1000;
        \\    @field(q, "n") = n;
        \\    _ = q.n * 1000;
        \\    set(t, n);
        \\    _ = t.n * 1000;
        \\}
    , 0);
    // Input's bytes written over the struct, its address handed to std, its bytes reinterpreted,
    // a computed name, and a literal-named store of a peer's value each leave a field unbounded.
    const head =
        \\const std = @import("std");
        \\const S = struct { n: u32 = 0 };
        \\
    ;
    inline for (.{
        "pub fn f(r: *std.Io.Reader, b: *S) !u32 {\n    const n = try r.takeInt(u32, 0);\n    if (n >= 255) return error.Long;\n    b.n = n;\n    try r.readSliceAll(std.mem.asBytes(b));\n    return b.n * 1000;\n}\n",
        "pub fn f(r: *std.Io.Reader, b: *S) !u32 {\n    const n = try r.takeInt(u32, 0);\n    if (n >= 255) return error.Long;\n    b.n = n;\n    var x: S = .{};\n    try r.readSliceAll(@ptrCast(&x));\n    return b.n * 1000;\n}\n",
        "pub fn f(r: *std.Io.Reader, bytes: *[4]u8) !u32 {\n    const n = try r.takeInt(u32, 0);\n    if (n >= 255) return error.Long;\n    const b: *S = @ptrCast(@alignCast(bytes));\n    b.n = n;\n    return b.n * 1000;\n}\n",
        "pub fn f(r: *std.Io.Reader, b: *S) !u32 {\n    const n = try r.takeInt(u32, 0);\n    if (n >= 255) return error.Long;\n    b.n = n;\n    inline for (.{\"n\"}) |name| @field(b, name) = try r.takeInt(u32, 0);\n    return b.n * 1000;\n}\n",
        "pub fn f(r: *std.Io.Reader, b: *S) !u32 {\n    const n = try r.takeInt(u32, 0);\n    if (n >= 255) return error.Long;\n    b.n = n;\n    @field(b, \"n\") = try r.takeInt(u32, 0);\n    return b.n * 1000;\n}\n",
    }) |body| expect(pack.integers, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}
