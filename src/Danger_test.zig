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
    \\pub const zig = @import("zig.zig");
    \\pub const fmt = @import("fmt.zig");
    \\pub const DoublyLinkedList = @import("DoublyLinkedList.zig");
    \\pub const ascii = @import("ascii.zig");
    \\pub const base64 = @import("base64.zig");
    \\pub const Random = @import("Random.zig");
    \\pub fn ArrayList(comptime T: type) type { return array_list.Aligned(T, null); }
    \\pub const AutoHashMapUnmanaged = hash_map.AutoHashMapUnmanaged;
    \\pub const c = @import("c.zig");
    \\pub const os = @import("os.zig");
    },
    .{ .name = "std/Io.zig", .bytes =
    \\pub const File = @import("Io/File.zig");
    \\pub const Reader = @import("Io/Reader.zig");
    \\pub const Dir = struct { handle: i32, pub fn openFile(dir: Dir, io: anytype, sub_path: []const u8, options: anytype) !void { _ = dir; _ = io; _ = sub_path; _ = options; } pub fn readFileAlloc(dir: Dir, io: anytype, sub_path: []const u8, gpa: anytype, limit: usize) ![]u8 { _ = dir; _ = io; _ = sub_path; _ = gpa; _ = limit; return &.{}; } pub fn statFile(dir: Dir, io: anytype, sub_path: []const u8) !u64 { _ = dir; _ = io; _ = sub_path; return 0; } pub fn readLink(dir: Dir, io: anytype, sub_path: []const u8, buffer: []u8) !usize { _ = dir; _ = io; _ = sub_path; _ = buffer; return 0; } };
    \\pub const Writer = struct { end: usize = 0, vtable: *const Writer.VTable = undefined, pub const VTable = struct { drain: *const fn (*Writer, []const []const u8, usize) anyerror!usize }; pub fn writeAll(w: *Writer, bytes: []const u8) !void { _ = w; _ = bytes; } pub fn print(w: *Writer, comptime format: []const u8, args: anytype) !void { _ = w; _ = format; _ = args; } pub fn fixed(buffer: []u8) Writer { _ = buffer; return .{}; } };
    \\pub fn random(io: @This(), buffer: []u8) void { _ = io; _ = buffer; }
    \\pub fn protocolWriter(buffer: []u8) Writer { _ = buffer; return .{}; }
    \\pub const net = struct { pub const Stream = struct { handle: i32, pub fn writer(s: Stream, buffer: []u8) Writer { _ = s; _ = buffer; return .{}; } }; pub const Server = struct { stream: Stream }; };
    \\pub const Cancelable = error{Canceled};
    \\pub fn checkCancel(io: @This()) error{Canceled}!void { _ = io; }
    \\pub fn recancel(io: @This()) void { _ = io; }
    \\pub fn futexWait(io: @This(), comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T) error{Canceled}!void { _ = io; _ = ptr; _ = expected; }
    \\pub fn futexWaitTimeout(io: @This(), comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T, timeout: u64) error{Canceled}!void { _ = io; _ = ptr; _ = expected; _ = timeout; }
    \\pub fn futexWaitUncancelable(io: @This(), comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T) void { _ = io; _ = ptr; _ = expected; }
    \\pub fn futexWake(io: @This(), comptime T: type, ptr: *align(@alignOf(u32)) const T, max_waiters: u32) void { _ = io; _ = ptr; _ = max_waiters; }
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
    \\pub const hash = struct { pub const sha2 = @import("crypto/sha2.zig"); };
    \\pub const auth = struct { pub const hmac = @import("crypto/hmac.zig"); };
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
    .{ .name = "std/debug.zig", .bytes = "pub fn assert(ok: bool) void { if (!ok) unreachable; }\npub fn lockStderr(buffer: []u8) void { _ = buffer; }" },
    .{ .name = "std/Io/File.zig", .bytes = "handle: i32,\npub const Handle = i32;\npub fn stdin() @This() { return .{ .handle = 0 }; }\npub fn stdout() @This() { return .{ .handle = 1 }; }\npub fn stderr() @This() { return .{ .handle = 2 }; }\npub fn close(f: @This()) void { _ = f; }\npub const Reader = struct { io: ?*anyopaque = null, interface: @import(\"Reader.zig\") };\npub fn reader(f: @This(), io: anytype, buffer: []u8) Reader { _ = f; _ = io; _ = buffer; return .{ .interface = .{} }; }\npub fn writer(f: @This(), io: anytype, buffer: []u8) void { _ = f; _ = io; _ = buffer; }\npub fn readStreaming(f: @This(), io: anytype, buffer: []const []u8) !usize { _ = f; _ = io; _ = buffer; return 0; }\npub fn readPositional(f: @This(), io: anytype, buffer: []const []u8, offset: u64) !usize { _ = f; _ = io; _ = buffer; _ = offset; return 0; }" },
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
    \\pub fn limited(r: *@This(), limit: Limit, buffer: []u8) @This() { _ = r; _ = limit; _ = buffer; return .{}; }
    \\pub fn allocRemaining(r: *@This(), gpa: anytype, limit: Limit) ![]u8 { _ = gpa; _ = limit; return r.buffer; }
    \\pub fn readAlloc(r: *@This(), gpa: anytype, len: usize) ![]u8 { _ = r; return gpa.alloc(u8, len); }
    \\pub fn readArena(r: *@This(), arena: @import("../mem.zig").Allocator, len: usize) ![]u8 { _ = r; return arena.alloc(u8, len); }
    },
    .{ .name = "std/mem.zig", .bytes = "pub fn asBytes(ptr: anytype) []u8 { _ = ptr; return &.{}; }\npub fn eql(comptime T: type, a: []const T, b: []const T) bool { _ = a; _ = b; return false; }\npub fn writeInt(comptime T: type, buffer: *[4]u8, value: T, endian: anytype) void { _ = buffer; _ = value; _ = endian; }\npub fn readInt(comptime T: type, buffer: anytype, endian: anytype) T { _ = buffer; _ = endian; return 0; }\npub fn findScalar(comptime T: type, s: []const T, v: T) ?usize { _ = s; _ = v; return null; }\npub fn total(items: anytype) usize { return items.count(); }\npub fn findScalarPos(comptime T: type, s: []const T, start: usize, v: T) ?usize { for (s[start..], start..) |x, i| if (x == v) return i; return null; }\npub const Allocator = struct { ptr: *anyopaque, pub fn alloc(self: Allocator, comptime T: type, n: usize) ![]T { _ = self.rawAlloc(n * @sizeOf(T)); return &.{}; } pub fn create(self: Allocator, comptime T: type) !*T { _ = self.rawAlloc(@sizeOf(T)); return undefined; } pub fn destroy(self: Allocator, ptr: anytype) void { const bytes: [*]u8 = @ptrCast(@constCast(ptr)); _ = self; _ = bytes; } pub fn rawAlloc(self: Allocator, len: usize) ?[*]u8 { _ = self; _ = len; return null; } };" },
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
    .{ .name = "std/zig.zig", .bytes =
    \\pub const Ast = struct {
    \\    source: []const u8,
    \\    nodes: []const u32,
    \\    pub fn parse(gpa: anytype, source: []const u8, mode: anytype) error{OutOfMemory}!Ast { _ = gpa; _ = mode; return .{ .source = source, .nodes = &.{} }; }
    \\    pub fn nodeData(tree: Ast, node: u32) u32 { return tree.nodes[node]; }
    \\    pub fn tokenSlice(tree: Ast, token: u32) []const u8 { return tree.source[token..]; }
    \\};
    },
    .{ .name = "std/crypto/sha2.zig", .bytes =
    \\pub const Sha256 = Sha2x32(256);
    \\pub const Sha384 = Sha2x64(384);
    \\pub const Sha512 = Sha2x64(512);
    \\fn Sha2x32(comptime bits: comptime_int) type { return struct { const Self = @This(); pub const digest_length = bits / 8; pub fn init() Self { return .{}; } pub fn final(d: *Self, out: *[digest_length]u8) void { _ = d; _ = out; } pub fn hash(b: []const u8, out: *[digest_length]u8) void { _ = b; _ = out; } }; }
    \\fn Sha2x64(comptime bits: comptime_int) type { return struct { const Self = @This(); pub const digest_length = bits / 8; pub fn init() Self { return .{}; } pub fn update(d: *Self, b: []const u8) void { _ = d; _ = b; } pub fn final(d: *Self, out: *[digest_length]u8) void { _ = d; _ = out; } pub fn hash(b: []const u8, out: *[digest_length]u8) void { _ = b; _ = out; } }; }
    },
    .{ .name = "std/fmt.zig", .bytes = "pub fn bufPrint(buf: []u8, comptime format: []const u8, args: anytype) ![]u8 { _ = format; _ = args; return buf[0..0]; }\npub fn hexToBytes(out: []u8, input: []const u8) ![]u8 { if (input.len & 1 != 0) return error.InvalidLength; if (out.len * 2 < input.len) return error.NoSpaceLeft; return out[0 .. input.len / 2]; }\npub fn printInt(buffer: []u8, value: anytype, base: u8, case: u1, options: struct {}) usize { _ = value; _ = base; _ = case; _ = options; return buffer.len; }" },
    .{ .name = "std/DoublyLinkedList.zig", .bytes =
    \\const DoublyLinkedList = @This();
    \\first: ?*Node = null,
    \\last: ?*Node = null,
    \\pub const Node = struct { prev: ?*Node = null, next: ?*Node = null };
    \\pub fn append(list: *DoublyLinkedList, new_node: *Node) void { list.last = new_node; }
    \\pub fn prepend(list: *DoublyLinkedList, new_node: *Node) void { list.first = new_node; }
    \\pub fn popFirst(list: *DoublyLinkedList) ?*Node { return list.first; }
    \\pub fn concatByMoving(list1: *DoublyLinkedList, list2: *DoublyLinkedList) void { list1.last = list2.last; list2.* = .{}; }
    },
    .{ .name = "std/ascii.zig", .bytes =
    \\pub fn lowerString(output: []u8, ascii_string: []const u8) []u8 { for (ascii_string, 0..) |c, i| output[i] = c; return output[0..ascii_string.len]; }
    \\pub fn upperString(output: []u8, ascii_string: []const u8) []u8 { for (ascii_string, 0..) |c, i| output[i] = c; return output[0..ascii_string.len]; }
    },
    .{ .name = "std/base64.zig", .bytes =
    \\pub const Base64Encoder = struct { pad: u8, pub fn encode(encoder: *const Base64Encoder, dest: []u8, source: []const u8) []const u8 { _ = encoder; return dest[0..source.len]; } };
    \\pub const Base64Decoder = struct { pad: u8, pub fn decode(decoder: *const Base64Decoder, dest: []u8, source: []const u8) !void { _ = decoder; _ = dest; _ = source; } };
    \\pub const Codecs = struct { Encoder: Base64Encoder, Decoder: Base64Decoder };
    \\pub const standard: Codecs = .{ .Encoder = .{ .pad = 0 }, .Decoder = .{ .pad = 0 } };
    },
    .{ .name = "std/crypto/hmac.zig", .bytes =
    \\pub const sha2 = struct { pub const HmacSha256 = Hmac(32); };
    \\fn Hmac(comptime len: comptime_int) type { return struct { const Self = @This(); pub const mac_length = len; pub fn init(key: []const u8) Self { _ = key; return .{}; } pub fn update(d: *Self, b: []const u8) void { _ = d; _ = b; } pub fn final(d: *Self, out: *[mac_length]u8) void { _ = d; _ = out; } pub fn create(out: *[mac_length]u8, msg: []const u8, key: []const u8) void { _ = out; _ = msg; _ = key; } }; }
    },
    .{ .name = "std/Random.zig", .bytes =
    \\ptr: *anyopaque,
    \\pub const ChaCha = struct { state: [8]u32, pub fn fill(self: *ChaCha, buf: []u8) void { _ = self; for (buf) |*b| b.* = 0; } };
    \\pub fn bytes(r: @This(), buf: []u8) void { _ = r; for (buf) |*b| b.* = 0; }
    },
    .{ .name = "std/c.zig", .bytes =
    \\pub const pid_t = c_int;
    \\pub const E = enum(u16) { SUCCESS = 0, AGAIN = 35, _ };
    \\pub fn errno(rc: anytype) E { return if (rc == -1) .AGAIN else .SUCCESS; }
    \\pub const posix_spawnattr_t = *anyopaque;
    \\pub extern "c" fn posix_spawn(pid: *pid_t, path: [*:0]const u8, actions: ?*const anyopaque, attr: ?*const posix_spawnattr_t, argv: [*:null]const ?[*:0]const u8, env: [*:null]const ?[*:0]const u8) c_int;
    \\pub extern "c" fn posix_spawnattr_init(attr: *posix_spawnattr_t) c_int;
    \\pub const rlimit = extern struct { cur: u64, max: u64 };
    \\pub const Stat = extern struct { dev: i32, ino: u64, size: i64 };
    },
    .{ .name = "std/os.zig", .bytes =
    \\pub const windows = struct {
    \\    pub const DWORD = u32;
    \\    pub const HANDLE = *anyopaque;
    \\    pub const IO_STATUS_BLOCK = extern struct { status: usize, information: usize };
    \\};
    },
};
const std_imports = [_]sources.ExtraImport{
    .{ .from = 0, .spelling = "c.zig", .target = 24 },
    .{ .from = 0, .spelling = "os.zig", .target = 25 },
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
    .{ .from = 0, .spelling = "zig.zig", .target = 16 },
    .{ .from = 3, .spelling = "crypto/sha2.zig", .target = 17 },
    .{ .from = 0, .spelling = "fmt.zig", .target = 18 },
    .{ .from = 0, .spelling = "DoublyLinkedList.zig", .target = 19 },
    .{ .from = 0, .spelling = "ascii.zig", .target = 20 },
    .{ .from = 0, .spelling = "base64.zig", .target = 21 },
    .{ .from = 3, .spelling = "crypto/hmac.zig", .target = 22 },
    .{ .from = 0, .spelling = "Random.zig", .target = 23 },
};

/// `program`'s findings of `rule` at report level, and its undecided sites of it.
const Run = struct { findings: usize, undecided: usize, lines: [32]u32 = @splat(0) };
fn run(rule: glint.Rule, program: []const u8) !Run {
    return runWith(rule, program, &std_files, &std_imports);
}
fn runWith(rule: glint.Rule, program: []const u8, extra: []const sources.Extra, imports: []const sources.ExtraImport) !Run {
    var project = try sources.projectWithSources(std.testing.allocator, program, extra, imports);
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

test "A008 finds a use through an alias another name gives in a file the run did not select, where the alias itself is no site this run reports" {
    // `other.zig` names std's wipe `zero` and the secret key `Key`: the call (3) and the key
    // held by value (5) are the sites. A comparison of the key's type is still no site (6).
    const found = try runWithFile(pack.secrets,
        \\const other = @import("other.zig");
        \\pub fn f(buffer: []u8) void {
        \\    other.zero(u8, buffer);
        \\}
        \\pub fn g(k: other.Key) usize { return k.bytes.len; }
        \\pub const same = other.Key == other.Key;
    ,
        \\const std = @import("std");
        \\pub const zero = std.crypto.secureZero;
        \\pub const Key = std.crypto.sign.Ed25519.SecretKey;
    );
    try std.testing.expectEqualSlices(u32, &.{ 3, 5 }, found.lines[0..found.findings]);
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

test "A011 finds time crossing as a raw integer and units converted by hand wherever a constant goes and as the program compiles, not raw nanoseconds compared or subtracted" {
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
    // A factor handed on raw, one computed as the program compiles, and one through a local's
    // name: each a conversion by hand, at the constant.
    try expect(pack.units,
        \\const std = @import("std");
        \\const timeout_ns = 5 * std.time.ns_per_s;
        \\pub fn f() u64 { return std.time.ns_per_ms; }
        \\pub fn g(ms: u64) u64 {
        \\    const per = std.time.ns_per_ms;
        \\    return ms * per + timeout_ns;
        \\}
    , 3);
    try expect(pack.units,
        \\const std = @import("std");
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

test "A019 finds the unchecked operations, an interface field's parent and its alignment among them, the escape covering one, never an address read" {
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
        \\    const s: *u8 = @ptrFromInt(a); // aegis: boundary(A019): an address the kernel hands back
        \\    _ = s;
        \\    return @intFromPtr(p);
        \\}
    , 7);
}

test "A014 finds a pointer into the frame carried out of the call" {
    try expect(pack.lifetimes, "pub fn f(n: usize) []u8 { var buf: [16]u8 = undefined; buf[0] = 1; return buf[0..n]; }", 1);
    try expect(pack.lifetimes, "pub fn f() *u32 { var x: u32 = 1; x += 1; const out = &x; return out; }", 1);
    try expect(pack.lifetimes, "const R = struct { s: []u8 }; pub fn f(n: usize) R { var buf: [8]u8 = undefined; buf[0] = 1; return .{ .s = buf[0..n] }; }", 1);
    try expect(pack.lifetimes, "const S = struct { a: u32 = 0 }; const T = struct { p: *u32 }; pub fn f(t: *T) void { var s: S = .{}; s.a = 1; t.p = &s.a; }", 1);
    try expect(pack.lifetimes, "var last: ?*u32 = null; pub fn f() void { var x: u32 = 1; x += 1; last = &x; }", 1);
    // A const of a run-time value, a local whose type only its value gives, a var alias, an
    // alias of an alias, and a store a defer clears only on one branch.
    try expect(pack.lifetimes, "pub fn f(x: u8) []const u8 { const buf = [_]u8{ x, 1 }; return buf[0..]; }", 1);
    try expect(pack.lifetimes, "pub fn f(n: usize) []u8 { var buf = [_]u8{ 0, 0, 0, 0 }; buf[0] = 1; return buf[0..n]; }", 1);
    try expect(pack.lifetimes, "const S = struct { a: u32 = 0 }; const T = struct { p: *u32 }; pub fn f(t: *T) void { var s = S{}; s.a = 1; t.p = &s.a; }", 1);
    try expect(pack.lifetimes, "pub fn f() *u32 { var x: u32 = 1; x += 1; var p: *u32 = undefined; p = &x; return p; }", 1);
    try expect(pack.lifetimes, "pub fn f() *u32 { var x: u32 = 1; x += 1; const a = &x; const b = a; return b; }", 1);
    try expect(pack.lifetimes, "const T = struct { cur: ?*u32 = null }; pub fn f(t: *T, ok: bool) void { var x: u32 = 1; x += 1; t.cur = &x; defer if (ok) { t.cur = null; }; }", 1);
    // An intrusive waiter a deferred loop unlinks: what the loop removes is not read.
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
    , 1);
}

test "A014 leaves static storage, pointers, copies and a store a defer clears on every exit alone" {
    try expect(pack.lifetimes, "pub fn f() []const u8 { const table = [_]u8{ 1, 2 }; return table[0..]; }", 0);
    try expect(pack.lifetimes, "pub fn f() []const u8 { comptime { var buf: [2]u8 = .{ 1, 2 }; buf[0] = 3; const out = buf; return &out; } }", 0);
    try expect(pack.lifetimes, "pub fn Make(comptime n: usize) type { var x: [n]u8 = undefined; x[0] = 1; _ = &x; return struct {}; }", 0);
    try expect(pack.lifetimes, "const N = struct { v: u32 }; pub fn f(head: *N) *u32 { var node: *N = head; node.v += 1; return &node.v; }", 0);
    try expect(pack.lifetimes, "pub fn f(items: []u8) []u8 { var s: []u8 = items; s = s[1..]; return s[0..1]; }", 0);
    try expect(pack.lifetimes, "pub fn f() [4]u8 { var buf: [4]u8 = undefined; buf[0] = 1; return buf; }", 0);
    try expect(pack.lifetimes, "const T = struct { cur: ?*u32 = null }; pub fn f(t: *T) void { var x: u32 = 1; x += 1; t.cur = &x; defer t.cur = null; }", 0);
    try expect(pack.lifetimes, "pub fn f() u32 { var x: u32 = 1; var p: *u32 = undefined; p = &x; p.* += 1; return x; }", 0);
    try expect(pack.lifetimes, "const T = struct { cur: ?*u32 = null }; pub fn f(t: *T) void { var x: u32 = 1; x += 1; t.cur = &x; defer { t.cur = null; } }", 0);
}

test "the aegis escape covers the pack's findings on its line, is listed with them, and refuses glint-ignore" {
    var project = try sources.projectWithSources(std.testing.allocator,
        \\const std = @import("std");
        \\// aegis: internal(A007): the counter aegis's own Atomic would wrap; measured in bench/count.zig
        \\var hits: u32 = 0;
        \\pub fn f(r: *std.Io.Reader) !u4 {
        \\    const b = try r.takeByte();
        \\    return @intCast(b); // aegis: no-danger(A010): the peer's protocol sends a nibble here
        \\}
        \\pub fn g() void {} // aegis: design(A010): nothing here
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
    try std.testing.expect(report.complete);
    // An escape covers only the rules it names; one naming none hides nothing: its line's pack
    // findings stay findings, recorded as what it covers for the fix to name, and the run that
    // reads it is incomplete.
    var other = try sources.projectWithSources(std.testing.allocator,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !u4 {
        \\    const b = try r.takeByte();
        \\    return @intCast(b); // aegis: no-danger(A009): another rule's
        \\}
        \\pub fn g(r: *std.Io.Reader) !u4 {
        \\    const b = try r.takeByte();
        \\    return @intCast(b); // aegis: no-danger: every rule's
        \\}
    , &std_files, &std_imports);
    defer other.deinit();
    var named = try glint.runConfigured(std.testing.allocator, &other, .{ .enabled = @splat(false), .selections = &.{ .{ .rule = pack.untrusted_input, .level = .gate }, .{ .rule = pack.integers, .level = .gate } } }, .{ .project_rules = &pack.rules });
    defer named.deinit();
    try std.testing.expectEqual(@as(usize, 2), named.diagnostics.len); // safe: fixture counts are representable.
    try std.testing.expectEqual(@as(u32, 4), named.diagnostics[0].span.line);
    try std.testing.expectEqual(@as(u32, 8), named.diagnostics[1].span.line);
    try std.testing.expectEqual(@as(usize, 1), named.escapes.len); // safe: fixture counts are representable.
    try std.testing.expectEqualStrings("A010", named.escapes[0].covered[0].name);
    try std.testing.expect(!named.complete);
    try std.testing.expectEqual(@as(usize, 1), named.malformed.len); // safe: fixture counts are representable.
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

test "A015 finds std resources held by value in a field, released or not, or returned by value, not borrowed by pointer, owned or lent" {
    // Options' `cwd` and `out` are released nowhere: an owner that leaks or a borrow, which
    // own.Lent names; either way a finding.
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
    , 7);
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
    , 3); // Fields held by value and released nowhere (Slot.file, Process.cwd, Context.cwd): no function.
    // Only std's own stdio and a std handle's literal: a method of the program's that is named
    // `stdout` but returns what it opened (and its callers, and the open itself), and a literal
    // of the program's type with a `handle` field, are owners handed over.
    try expect(pack.ownership,
        \\const std = @import("std");
        \\const Proc = struct {
        \\    dir: std.Io.Dir,
        \\    fn opened(p: *Proc) std.Io.File {
        \\        _ = p;
        \\        return undefined;
        \\    }
        \\    pub fn stdout(p: *Proc) std.Io.File {
        \\        return p.opened();
        \\    }
        \\};
        \\const Wrapped = struct { handle: std.Io.File };
        \\pub fn take(p: *Proc) std.Io.File {
        \\    return p.stdout();
        \\}
        \\pub fn unwrap(f: *Proc) std.Io.File {
        \\    const w: Wrapped = .{ .handle = f.opened() };
        \\    return w.handle;
        \\}
    , 6); // And the fields Proc.dir and Wrapped.handle.
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
    , 4); // And the field Conn.stream.
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

test "A017 leaves a kind set where its value is built, and finds a state each record a loop walks is moved through" {
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
    // Classes rules refine on their own value, record by record, from outside the record: each
    // record's state moved by hand, which nothing here tells from a connection's.
    try expect(pack.state_machines,
        \\const Class = enum { mark, letter, number, neutral };
        \\const Slot = struct { class: Class };
        \\fn marks(slots: []Slot, before: Class) void { for (slots) |*s| if (s.class == .mark) { s.class = before; }; }
        \\fn numbers(slots: []Slot) void { var p: ?usize = 0; while (p) |at| : (p = if (at + 1 < slots.len) at + 1 else null) { const s = &slots[at]; switch (s.class) { .number => s.class = .neutral, else => {} } } }
        \\pub fn run(slots: []Slot) usize { marks(slots, .letter); numbers(slots); var n: usize = 0; for (slots) |s| switch (s.class) { .letter => n += 1, else => {} }; return n; }
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

test "A019 finds a local read while still undefined, one written on some paths only or in part among them, and leaves written and branch-written ones and an array's length" {
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
    , 10); // 4 reads (`some`'s when `c` is false); `filled`, `sliced` and `length`, each
    // written in part only (`fill` sets one element; `named` sets its one field); `tied`'s
    // input read before its output is written; and each `asm` itself.
    // Every branch that reaches the read writes it, the others leave; a range of literals runs,
    // and one that sets elements one by one writes them in part only (`ranged`).
    try expect(pack.unsafe_set,
        \\pub fn left(c: bool) u8 { var x: u8 = undefined; if (c) { x = 1; } else return 0; return x; }
        \\pub fn ranged() u8 { var b: [2]u8 = undefined; for (0..2) |i| b[i] = 1; return b[0]; }
        \\pub fn loopLeft(n: usize) u8 { var x: u8 = undefined; for (0..n) |_| { x = 1; } return x; }
        \\pub fn once() u8 { var x: u8 = undefined; for (0..2) |_| { x = 1; } return x; }
    , 2);
}

test "A019 reads a local handed to a call as written only where the call writes all of it: std's fills by name, the program's function whose body writes the whole parameter on every path that returns, and only where a failure leaves" {
    // Written whole (no finding): fillAll (line 13), fillTry under `try` (16), fillSet (18),
    // @memset (21), a `for` setting each element (23, 24), a field read once set and every
    // field set (26, 28), readSliceAll under `try` and under `catch return` (29, 30), a file's
    // writer and a fixed writer keep the buffer (31, 32), io.random (34) and writeInt (35).
    // Findings: fillOne sets a part (14), fillSome returns first (15), fillTry's failure caught
    // (17, the read), fillCatch returns from a `catch` (19), readsFirst reads first (20),
    // @memset of a part (22, the read), a `for` that reads the element (25), a field never set
    // read (27), std's fixed reader reads its bytes (33), a `defer` reads before the write
    // (36), and a pointer kept in a local (37).
    const found = try run(pack.unsafe_set,
        \\const std = @import("std");
        \\const P = struct { a: u8, b: u8 };
        \\fn fillAll(out: *[4]u8) void { out.* = .{ 1, 2, 3, 4 }; }
        \\fn fillOne(out: []u8) void { out[0] = 1; }
        \\fn fillSome(out: *[4]u8, c: bool) void { if (c) return; out.* = @splat(0); }
        \\fn fillTry(r: *std.Io.Reader, out: []u8) !void { try r.readSliceAll(out); }
        \\fn fillSet(out: []u8) void { @memset(out, 0); }
        \\fn fillCatch(out: *[4]u8) void { const v = get() catch return; out.* = v; }
        \\fn get() ![4]u8 { return @splat(1); }
        \\fn readsFirst(out: *[4]u8) void { const k = out[0]; out.* = @splat(k); }
        \\fn print(x: u8) void { _ = x; }
        \\
        \\pub fn a1() u8 { var b: [4]u8 = undefined; fillAll(&b); return b[0]; }
        \\pub fn a2() u8 { var b: [4]u8 = undefined; fillOne(&b); return b[0]; }
        \\pub fn a3(c: bool) u8 { var b: [4]u8 = undefined; fillSome(&b, c); return b[0]; }
        \\pub fn a4(r: *std.Io.Reader) !u8 { var b: [4]u8 = undefined; try fillTry(r, &b); return b[0]; }
        \\pub fn a5(r: *std.Io.Reader) u8 { var b: [4]u8 = undefined; fillTry(r, &b) catch {}; return b[0]; }
        \\pub fn a6() u8 { var b: [4]u8 = undefined; fillSet(&b); return b[0]; }
        \\pub fn a7() u8 { var b: [4]u8 = undefined; fillCatch(&b); return b[0]; }
        \\pub fn a8() u8 { var b: [4]u8 = undefined; readsFirst(&b); return b[0]; }
        \\pub fn b1() u8 { var b: [4]u8 = undefined; @memset(&b, 0); return b[0]; }
        \\pub fn b2(n: usize) u8 { var b: [4]u8 = undefined; @memset(b[0..n], 0); return b[0]; }
        \\pub fn b3() u8 { var b: [4]u8 = undefined; for (&b) |*e| e.* = 0; return b[0]; }
        \\pub fn b4() u8 { var b: [4]u8 = undefined; for (&b, 0..) |*e, i| e.* = @intCast(i); return b[0]; }
        \\pub fn b5() u8 { var b: [4]u8 = undefined; for (&b) |*e| e.* +%= 1; return b[0]; }
        \\pub fn c1() u8 { var p: P = undefined; p.a = 1; return p.a; }
        \\pub fn c2() u8 { var p: P = undefined; p.a = 1; return p.b; }
        \\pub fn c3() P { var p: P = undefined; p.a = 1; p.b = 2; return p; }
        \\pub fn d1(r: *std.Io.Reader) !u8 { var b: [4]u8 = undefined; try r.readSliceAll(&b); return b[0]; }
        \\pub fn d2(r: *std.Io.Reader) u8 { var b: [4]u8 = undefined; r.readSliceAll(&b) catch return 0; return b[0]; }
        \\pub fn d3(f: std.Io.File, io: std.Io) void { var buf: [64]u8 = undefined; const w = f.writer(io, &buf); _ = w; }
        \\pub fn d4() usize { var buf: [64]u8 = undefined; const w: std.Io.Writer = .fixed(&buf); return w.end; }
        \\pub fn d5() u8 { var buf: [8]u8 = undefined; var r: std.Io.Reader = .fixed(&buf); return r.takeByte() catch 0; }
        \\pub fn d6(io: std.Io) u8 { var b: [4]u8 = undefined; io.random(&b); return b[0]; }
        \\pub fn d7() u8 { var b: [4]u8 = undefined; std.mem.writeInt(u32, &b, 7, .little); return b[0]; }
        \\pub fn e1() u8 { var x: u8 = undefined; defer print(x); x = 1; return x; }
        \\pub fn e2() u8 { var b: [4]u8 = undefined; const p = &b; p.* = @splat(0); return b[0]; }
    );
    try std.testing.expectEqualSlices(u32, &.{ 14, 15, 17, 19, 20, 22, 25, 27, 33, 36, 37 }, found.lines[0..found.findings]);
}

test "A019 reads the program's function that only hands a buffer to std's keeps as keeping it, a declaration literal by its result location, and a `for` over several inputs that sets each element first" {
    // Kept (no finding): writerOver returns `.fixed(buf)` by its result type (line 11), hold
    // sets a field's `.fixed(buf)` (12), passOn hands it to writerOver (13), and a `for` sets
    // each element from another input (15). Findings: peeks reads it first (14), and a `for`
    // that may leave a pass before setting it (16, the read). The contract: each writer handed by
    // value to the generic `use`, whose body is not read for it (11, 13, 14).
    const found = try run(pack.unsafe_set,
        \\const std = @import("std");
        \\const Holder = struct { w: std.Io.Writer };
        \\fn writerOver(buf: []u8) std.Io.Writer { return .fixed(buf); }
        \\fn hold(buf: []u8) Holder { return .{ .w = .fixed(buf) }; }
        \\fn passOn(buf: []u8) std.Io.Writer { return writerOver(buf); }
        \\fn peeks(buf: []u8) std.Io.Writer { _ = buf[0]; return .fixed(buf); }
        \\fn use(w: anytype) void { _ = w; }
        \\
        \\
        \\
        \\pub fn k1() void { var b: [8]u8 = undefined; use(writerOver(&b)); }
        \\pub fn k2() void { var b: [8]u8 = undefined; use(hold(&b)); }
        \\pub fn k3() void { var b: [8]u8 = undefined; use(passOn(&b)); }
        \\pub fn k4() void { var b: [8]u8 = undefined; use(peeks(&b)); }
        \\pub fn f1(src: [4]u8) u8 { var dst: [4]u8 = undefined; for (src, &dst) |v, *d| d.* = v; return dst[0]; }
        \\pub fn f2(src: [4]u8) u8 { var dst: [4]u8 = undefined; for (src, &dst) |v, *d| { if (v == 0) continue; d.* = v; } return dst[0]; }
    );
    try std.testing.expectEqualSlices(u32, &.{ 11, 13, 14, 14, 16 }, found.lines[0..found.findings]);
}

test "A019 reads std's hashers as filling their output by declaration, and keeps as neither a fill nor a read: a buffer kept is still undefined to a direct read" {
    // Filled (no finding): Sha512's init/update/final (line 9), Sha384's one-shot hash (10),
    // Sha256's final (11), and a read through what bufPrint returns (16). Findings: a fixed
    // writer's buffer read directly (12), a wrapper that keeps the buffer and also reads it (13),
    // a same-named `fixed` that is not std's (14), a read past what bufPrint printed (15), and a
    // program hasher's same-named `final` (17). The contract: each writer handed by value to the
    // generic `use` (12, 13).
    const found = try run(pack.unsafe_set,
        \\const std = @import("std");
        \\const W = struct { n: usize = 0 };
        \\var stash: []u8 = &.{};
        \\fn fixed(buffer: []u8) W { stash = buffer; return .{}; }
        \\fn keepsAndReads(buf: []u8) std.Io.Writer { const w: std.Io.Writer = .fixed(buf); _ = buf[0]; return w; }
        \\fn use(x: anytype) void { _ = x; }
        \\const Sha = struct { pub fn init() Sha { return .{}; } pub fn final(d: *Sha, out: *[32]u8) void { _ = d; _ = out; } };
        \\
        \\pub fn h1() u8 { var out: [64]u8 = undefined; var d = std.crypto.hash.sha2.Sha512.init(); d.update("x"); d.final(&out); return out[0]; }
        \\pub fn h2() u8 { var out: [48]u8 = undefined; std.crypto.hash.sha2.Sha384.hash("x", &out); return out[0]; }
        \\pub fn h3() u8 { var out: [32]u8 = undefined; var d = std.crypto.hash.sha2.Sha256.init(); d.final(&out); return out[0]; }
        \\pub fn p1() u8 { var buf: [8]u8 = undefined; const w: std.Io.Writer = .fixed(&buf); use(w); return buf[0]; }
        \\pub fn p2() void { var buf: [8]u8 = undefined; use(keepsAndReads(&buf)); }
        \\pub fn p3() void { var buf: [8]u8 = undefined; use(fixed(&buf)); }
        \\pub fn p4(n: u8) !u8 { var buf: [8]u8 = undefined; const s = try std.fmt.bufPrint(&buf, "{d}", .{n}); return buf[s.len]; }
        \\pub fn p5(n: u8) !u8 { var buf: [8]u8 = undefined; const s = try std.fmt.bufPrint(&buf, "{d}", .{n}); return s[0]; }
        \\pub fn p6() u8 { var out: [32]u8 = undefined; var d = Sha.init(); d.final(&out); return out[0]; }
    );
    try std.testing.expectEqualSlices(u32, &.{ 12, 12, 13, 13, 14, 15, 17 }, found.lines[0..found.findings]);
}

test "A019 keeps nothing it read past its depth: a keeper first reached at the end of a long chain is still one where it is called directly" {
    // k0 hands the buffer through nine of the program's keepers, past how deep they are read
    // (line 13: handed on); a call of the last of them reads it as a keeper (14). The contract:
    // each writer handed by value to the generic `use` (13, 14).
    const found = try run(pack.unsafe_set,
        \\const std = @import("std");
        \\fn k8(buf: []u8) std.Io.Writer { return .fixed(buf); }
        \\fn k7(buf: []u8) std.Io.Writer { return k8(buf); }
        \\fn k6(buf: []u8) std.Io.Writer { return k7(buf); }
        \\fn k5(buf: []u8) std.Io.Writer { return k6(buf); }
        \\fn k4(buf: []u8) std.Io.Writer { return k5(buf); }
        \\fn k3(buf: []u8) std.Io.Writer { return k4(buf); }
        \\fn k2(buf: []u8) std.Io.Writer { return k3(buf); }
        \\fn k1(buf: []u8) std.Io.Writer { return k2(buf); }
        \\fn k0(buf: []u8) std.Io.Writer { return k1(buf); }
        \\fn use(w: anytype) void { _ = w; }
        \\
        \\pub fn deep() void { var b: [8]u8 = undefined; use(k0(&b)); }
        \\pub fn direct() void { var b: [8]u8 = undefined; use(k8(&b)); }
    );
    try std.testing.expectEqualSlices(u32, &.{ 13, 13, 14 }, found.lines[0..found.findings]);
}

test "A019 takes what a break or continue holds to where it goes, and a write on some paths through an expression writes nothing" {
    // Unsafe: a jump past the write to a `for`'s end (2, 3), a labeled block's (4) or a
    // labeled switch's (5) and an outer loop's (6); a write in a branch of an expression (7)
    // or past `orelse` (8); a `continue` to a while's continue expression (9); a while's
    // `else` (10). Safe: each jump after the write (11-13), a labeled block that does not
    // hold the local (14), a continue expression after the body wrote it (15).
    const found = try run(pack.unsafe_set,
        \\fn work() void {}
        \\pub fn a(c: bool) u32 { var x: u32 = undefined; for (0..1) |_| { if (c) continue; x = 1; } return x; }
        \\pub fn b(c: bool) u32 { var x: u32 = undefined; for (0..1) |_| { if (c) break; x = 1; } return x; }
        \\pub fn d(c: bool) u32 { var x: u32 = undefined; blk: { if (c) break :blk; x = 1; } return x; }
        \\pub fn e(c: bool) u32 { var x: u32 = undefined; sw: switch (@as(u8, 0)) { 0 => { if (c) break :sw; x = 1; }, else => x = 2 } return x; }
        \\pub fn f(c: bool) u32 { var x: u32 = undefined; outer: for (0..2) |_| { for (0..2) |_| { if (c) break :outer; } x = 1; } return x; }
        \\pub fn g(c: bool) u32 { var x: u32 = undefined; const v: u32 = if (c) blk: { x = 1; break :blk 1; } else 2; return x + v; }
        \\pub fn h(c: ?u32) u32 { var x: u32 = undefined; const v = c orelse blk: { x = 1; break :blk 0; }; return x + v; }
        \\pub fn i(c: bool, q: bool) u32 { var x: u32 = undefined; var y: u32 = 0; while (c) : (y += x) { if (q) continue; x = 1; } return y; }
        \\pub fn j(c: bool) u32 { var x: u32 = undefined; while (c) { x = 1; break; } else { return x; } return 0; }
        \\pub fn k(c: bool) u32 { var x: u32 = undefined; blk: { x = 1; if (c) break :blk; work(); } return x; }
        \\pub fn l(c: bool) u32 { var x: u32 = undefined; for (0..2) |at| { x = @intCast(at); if (c) continue; work(); } return x; }
        \\pub fn m(c: bool) u32 { var x: u32 = undefined; outer: for (0..2) |_| { x = 1; for (0..2) |_| { if (c) break :outer; } } return x; }
        \\pub fn n() u32 { var x: u32 = undefined; const v: u32 = blk: { break :blk 1; }; x = v; return x; }
        \\pub fn o(c: bool) u32 { var x: u32 = undefined; var y: u32 = 0; while (c) : (y += x) { x = 1; } return y; }
    );
    try std.testing.expectEqualSlices(u32, &.{ 2, 3, 4, 5, 6, 7, 8, 9, 10 }, found.lines[0..found.findings]);
}

test "A019 writes a local whole by its parts: every field or element set on every path, by itself, its own init or an inline for over its type's fields" {
    // Safe: its init setting each field (4), each set (6), a set field read (8), each set on
    // both branches (11), each element (12), each by @field's spelled name (14), every field by
    // an inline for, also through a constant and a comptime test of the name (16, 18, 19, 21),
    // a parameter's (23), a comptime for (25). Unsafe: an init that sets one (5), one set (7),
    // a field never set (9), a field set on one branch only (10), an element never set (13), a
    // field read before its set (15), an inline for over part of the fields (17), a test that
    // sets another field (20), a pass skipped (22), over another type's fields (24), a comptime
    // for over part of it (26).
    const found = try run(pack.unsafe_set,
        \\const std = @import("std");
        \\const Pair = struct { a: u32, b: u32, fn init(p: *Pair) void { p.a = 1; p.b = 2; } fn half(p: *Pair) void { p.a = 1; } };
        \\fn take(p: Pair) u32 { return p.a; } fn sum(x: [2]u8) u32 { return x[0]; } fn get(comptime S: type) ?S { return null; }
        \\pub fn case_a() u32 { var p: Pair = undefined; p.init(); return take(p); }
        \\pub fn case_b() u32 { var p: Pair = undefined; p.half(); return take(p); }
        \\pub fn case_c() u32 { var p: Pair = undefined; p.a = 1; p.b = 2; return take(p); }
        \\pub fn case_d() u32 { var p: Pair = undefined; p.a = 1; return take(p); }
        \\pub fn case_e() u32 { var p: Pair = undefined; p.a = 1; return p.a; }
        \\pub fn case_f() u32 { var p: Pair = undefined; p.a = 1; return p.b; }
        \\pub fn case_g(k: bool) u32 { var p: Pair = undefined; if (k) p.a = 1 else p.b = 2; p.b = 3; return take(p); }
        \\pub fn case_h(k: bool) u32 { var p: Pair = undefined; if (k) p.a = 1 else p.a = 2; p.b = 3; return take(p); }
        \\pub fn case_i() u32 { var x: [2]u8 = undefined; x[0] = 1; x[1] = 2; return sum(x); }
        \\pub fn case_j() u32 { var x: [3]u8 = undefined; x[0] = 1; x[1] = 2; return x[0] + x[2]; }
        \\pub fn case_k() u32 { var p: Pair = undefined; @field(p, "a") = 1; @field(p, "b") = 1; return take(p); }
        \\pub fn case_l() u32 { var p: Pair = undefined; p.a = p.a; return 0; }
        \\pub fn case_m(comptime T: type, v: u32) T { var out: T = undefined; inline for (@typeInfo(T).@"struct".fields) |field| @field(out, field.name) = v; return out; }
        \\pub fn case_n(comptime T: type, v: u32) T { var out: T = undefined; inline for (@typeInfo(T).@"struct".fields[1..]) |field| @field(out, field.name) = v; return out; }
        \\pub fn case_o() !Pair { var out: Pair = undefined; const info = @typeInfo(Pair).@"struct"; inline for (info.field_names, info.field_types) |name, F| { @field(out, name) = get(F) orelse return error.Missing; } return out; }
        \\pub fn case_q(comptime T: type, from: T, v: u32) T { var to: T = undefined; inline for (@typeInfo(T).@"struct".field_names) |name| { if (comptime std.mem.eql(u8, name, "a")) to.a = v else @field(to, name) = @field(from, name); } return to; }
        \\pub fn case_r(comptime T: type, from: T, v: u32) T { var to: T = undefined; inline for (@typeInfo(T).@"struct".field_names) |name| { if (comptime std.mem.eql(u8, name, "a")) to.b = v else @field(to, name) = @field(from, name); } return to; }
        \\pub fn case_s() !Pair { var out: Pair = undefined; inline for (@typeInfo(Pair).@"struct".field_names) |name| { @field(out, name) = get(u32) orelse return error.Missing; } return out; }
        \\pub fn case_t() !Pair { var out: Pair = undefined; inline for (@typeInfo(Pair).@"struct".field_names) |name| { @field(out, name) = get(u32) orelse continue; } return out; }
        \\fn fill(out: *Pair) void { inline for (@typeInfo(Pair).@"struct".fields) |field| @field(out, field.name) = 0; } pub fn case_u() u32 { var p: Pair = undefined; fill(&p); return take(p); }
        \\pub fn case_v(comptime T: type, comptime U: type, x: u32) T { var out: T = undefined; inline for (@typeInfo(U).@"struct".fields) |field| @field(out, field.name) = x; return out; }
        \\pub fn case_w(comptime p: []const u8) []const u8 { comptime var buffer: [p.len]u8 = undefined; comptime for (p, &buffer) |ch, *slot| { slot.* = ch; }; const final = buffer; return &final; }
        \\pub fn case_x(comptime p: []const u8) []const u8 { comptime var buffer: [p.len + 1]u8 = undefined; comptime for (p, buffer[0..p.len]) |ch, *slot| { slot.* = ch; }; const final = buffer; return &final; }
    );
    try std.testing.expectEqualSlices(u32, &.{ 5, 7, 9, 10, 13, 15, 17, 20, 22, 24, 26 }, found.lines[0..found.findings]);
}

test "A019 reads hexToBytes as writing all of its output where it succeeds on an input every path shows twice as long, and a flag as what its being true showed" {
    // Safe: a flag of a length test and the call's success, tested before the read (3), also
    // in a loop's `or` guard that continues (4); a guard that leaves on another length (5); an
    // output declared half the input (6). Unsafe: a test of the wrong length (7), a flag of
    // `or` (8), a guard of only an upper bound (9), a failure caught and gone on from (10), an
    // input assigned after its test (11).
    const found = try run(pack.unsafe_set,
        \\const std = @import("std");
        \\fn use(bytes: [32]u8) usize { return bytes[0]; }
        \\pub fn a(text: []const u8) ?[32]u8 { var sha: [32]u8 = undefined; const hex = text.len == 64 and if (std.fmt.hexToBytes(&sha, text)) |_| true else |_| false; if (!hex) { return null; } return sha; }
        \\pub fn b(items: []const []const u8, u: []const u8) usize { var n: usize = 0; for (items) |text| { var sha: [32]u8 = undefined; const hex = text.len == 64 and if (std.fmt.hexToBytes(&sha, text)) |_| true else |_| false; if (u.len == 0 or !hex) { n += 1; continue; } n += use(sha); } return n; }
        \\pub fn c(sha: []const u8) ![32]u8 { var digest: [32]u8 = undefined; if (sha.len != 2 * digest.len) return error.Bad; _ = std.fmt.hexToBytes(&digest, sha) catch return error.Bad; return digest; }
        \\pub fn d(digits: []const u8) usize { var out: [digits.len / 2]u8 = undefined; _ = std.fmt.hexToBytes(&out, digits) catch unreachable; return use(out[0..32].*); }
        \\pub fn e(text: []const u8) ?[32]u8 { var sha: [32]u8 = undefined; const hex = text.len == 62 and if (std.fmt.hexToBytes(&sha, text)) |_| true else |_| false; if (!hex) return null; return sha; }
        \\pub fn f(text: []const u8) ?[32]u8 { var sha: [32]u8 = undefined; const hex = text.len == 64 or if (std.fmt.hexToBytes(&sha, text)) |_| true else |_| false; if (!hex) return null; return sha; }
        \\pub fn g(sha: []const u8) ![32]u8 { var digest: [32]u8 = undefined; if (sha.len > 2 * digest.len) return error.Bad; _ = try std.fmt.hexToBytes(&digest, sha); return digest; }
        \\pub fn h(sha: []const u8) [32]u8 { var digest: [32]u8 = undefined; if (sha.len != 64) return @splat(0); _ = std.fmt.hexToBytes(&digest, sha) catch {}; return digest; }
        \\pub fn i(t: []const u8) ![32]u8 { var text = t; var digest: [32]u8 = undefined; if (text.len != 64) return error.Bad; text = text[1..]; _ = try std.fmt.hexToBytes(&digest, text); return digest; }
    );
    try std.testing.expectEqualSlices(u32, &.{ 7, 8, 9, 10, 11 }, found.lines[0..found.findings]);
}

test "A019 takes no input as twice as long as an output whose doubled length a u64 cannot count" {
    // Twice 2^63 is no 0: the output stays unwritten past a test of an empty input (2).
    const found = try run(pack.unsafe_set,
        \\const std = @import("std");
        \\pub fn j(text: []const u8) u8 { var big: [9223372036854775808]u8 = undefined; const hex = text.len == 0 and if (std.fmt.hexToBytes(&big, text)) |_| true else |_| false; if (!hex) return 0; return big[0]; }
    );
    try std.testing.expectEqualSlices(u32, &.{2}, found.lines[0..found.findings]);
}

test "A019 reads a field used in place as written once it is set, unless something converts a pointer to that field of that struct back to its parent" {
    // Safe: a field set, then a method called on it (5), where the only conversion of a field
    // so named gives another struct (2). Unsafe: the same where a conversion gives this struct
    // (8), or one whose name is a function's parameter, called with that name (11).
    const found = try run(pack.unsafe_set,
        \\const List = struct { n: u32 = 0, fn clear(l: *List) void { l.n = 0; } };
        \\const Other = struct { list: List }; fn other(l: *List) *Other { return @fieldParentPtr("list", l); }
        \\const Q = struct { a: u32, list: List };
        \\const R = struct { a: u32, items: List }; const T = struct { a: u32, held: List };
        \\pub fn a() void { var q: Q = undefined; q.list = .{}; q.list.clear(); }
        \\fn back(l: *List) *R { return @fieldParentPtr("items", l); }
        \\fn helper(comptime member: []const u8, l: *List) *T { return @fieldParentPtr(member, l); }
        \\pub fn b() void { var r: R = undefined; r.items = .{}; r.items.clear(); }
        \\pub fn c(l: *List) *T { return helper("held", l); }
        \\
        \\pub fn d() void { var t: T = undefined; t.held = .{}; t.held.clear(); }
    );
    // The conversions themselves are A019's too (2, 6, 7).
    try std.testing.expectEqualSlices(u32, &.{ 2, 6, 7, 8, 11 }, found.lines[0..found.findings]);
}

test "A019 hands a local to the program's function that reads only parts of it, through a pointer to its type, as a read of those parts" {
    // Safe: a method reading set fields through a helper (3), one setting a field before it
    // reads it (6), a function called by its type (8). Unsafe: one reading a field never set
    // (4), one keeping the pointer (5), one copying all of it (7), by its type (9).
    const found = try run(pack.unsafe_set,
        \\const W = struct { id: u32, root: []const u8, other: u64, fn rootLen(w: *const W) usize { return w.root.len; } fn touches(w: *W) u64 { return w.other; } fn via(w: *W) usize { return w.rootLen() + w.id; } fn keeps(w: *W, list: *[1]*W) void { list[0] = w; } fn first(w: *W) u64 { w.other = 5; return w.other + w.id; } fn copy(w: *W) W { return w.*; } };
        \\var kept: [1]*W = undefined;
        \\pub fn a() usize { var w: W = undefined; w.id = 1; w.root = "x"; return w.via(); }
        \\pub fn b() u64 { var w: W = undefined; w.id = 1; w.root = "x"; return w.touches(); }
        \\pub fn c() void { var w: W = undefined; w.id = 1; w.keeps(&kept); }
        \\pub fn d() u64 { var w: W = undefined; w.id = 1; return w.first(); }
        \\pub fn e() W { var w: W = undefined; w.id = 1; return w.copy(); }
        \\pub fn f() usize { var w: W = undefined; w.root = "x"; return W.rootLen(&w); }
        \\pub fn g() usize { var w: W = undefined; w.id = 1; return W.rootLen(&w); }
    );
    try std.testing.expectEqualSlices(u32, &.{ 4, 5, 7, 9 }, found.lines[0..found.findings]);
}

/// The findings of `rule` on `program` with `edit` applied: each (old, new) replaced once.
fn runEdited(rule: glint.Rule, comptime program: []const u8, comptime old: []const u8, comptime new: []const u8) !Run {
    return run(rule, comptime edited(program, old, new));
}

/// `program` with its first `old` replaced by `new`.
fn edited(comptime program: []const u8, comptime old: []const u8, comptime new: []const u8) []const u8 {
    @setEvalBranchQuota(100_000);
    const at = std.mem.find(u8, program, old).?;
    return program[0..at] ++ new ++ program[at + old.len ..];
}

const interface_program =
    \\const std = @import("std");
    \\const Sink = struct {
    \\    count: usize = 0,
    \\    interface: std.Io.Writer,
    \\    other: std.Io.Writer = .{},
    \\    const vtable: std.Io.Writer.VTable = .{ .drain = drain };
    \\    pub fn init() Sink {
    \\        return .{ .interface = .{ .vtable = &vtable } };
    \\    }
    \\    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) anyerror!usize {
    \\        const self: *Sink = @alignCast(@fieldParentPtr("interface", w));
    \\        self.count += splat;
    \\        return data.len;
    \\    }
    \\};
    \\pub fn use() !usize {
    \\    var s: Sink = .init();
    \\    try s.interface.writeAll("x");
    \\    return s.count + s.interface.end;
    \\}
    \\
;

test "A019 clears a parent pointer an interface's own field shows, and its alignment, where nothing copies the field or installs the function anywhere else" {
    try std.testing.expectEqual(@as(usize, 0), (try run(pack.unsafe_set, interface_program)).findings);
    // A copy of the field carries the function to a pointer that is no Sink's field.
    const copied = try runEdited(pack.unsafe_set, interface_program, "    return s.count + s.interface.end;", "    const w = s.interface;\n    return s.count + w.end;");
    try std.testing.expectEqualSlices(u32, &.{ 11, 11, 19 }, copied.lines[0..copied.findings]);
    // A vtable others can name, installed into another field, or a field of another type.
    const public = try runEdited(pack.unsafe_set, interface_program, "    const vtable:", "    pub const vtable:");
    try std.testing.expectEqualSlices(u32, &.{ 11, 11 }, public.lines[0..public.findings]);
    const other = try runEdited(pack.unsafe_set, interface_program, ".{ .interface = .{ .vtable = &vtable } }", ".{ .interface = .{}, .other = .{ .vtable = &vtable } }");
    try std.testing.expectEqualSlices(u32, &.{ 11, 11 }, other.lines[0..other.findings]);
    const typed = try runEdited(pack.unsafe_set, interface_program, "    interface: std.Io.Writer,", "    interface: std.Io.Reader,");
    try std.testing.expectEqualSlices(u32, &.{ 11, 11 }, typed.lines[0..typed.findings]);
    // A field named as the program compiles may be the interface's.
    const computed = try runEdited(pack.unsafe_set, interface_program, "    return s.count + s.interface.end;", "    inline for (.{\"interface\"}) |name| try @field(s, name).writeAll(\"y\");\n    return s.count + s.interface.end;");
    try std.testing.expectEqualSlices(u32, &.{ 11, 11 }, computed.lines[0..computed.findings]);
}

const reflecting_dependency: sources.Extra = .{ .name = "reflect/root.zig", .bytes =
    \\pub fn count(value: anytype) usize {
    \\    var n: usize = 0;
    \\    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |f| n += @field(value, f.name).len;
    \\    return n;
    \\}
    \\pub fn fill(comptime T: type, value: T) T {
    \\    var out: T = undefined;
    \\    inline for (@typeInfo(T).@"struct".field_names) |name| @field(out, name) = @field(value, name);
    \\    return out;
    \\}
    \\pub const Rule = struct { sets: struct { a: ?u8 = null } = .{} };
    \\pub fn describe(comptime rules: []const Rule) usize {
    \\    var n: usize = 0;
    \\    inline for (rules) |rule| inline for (@typeInfo(@TypeOf(rule.sets)).@"struct".field_names) |name| {
    \\        const v = @field(rule.sets, name) orelse continue;
    \\        n += v;
    \\    };
    \\    return n;
    \\}
};

test "A019 leaves to the follows what a dependency's generic reads by a computed name on what it is handed: one never handed the parent is no use of its interface" {
    // Clean: generics reading, writing and testing each field by a computed name, and a function
    // of comptime data doing so, given only what holds no interface; `count` is a name std calls
    // on what it is given (mem.total), so its parameter is not bound by the program's calls.
    const extra = &(std_files ++ [_]sources.Extra{reflecting_dependency});
    const imports = &(std_imports ++ [_]sources.ExtraImport{.{ .spelling = "reflect", .target = std_files.len }});
    const given = comptime edited(interface_program, "pub fn use() !usize {", "const reflect = @import(\"reflect\");\npub fn use() !usize {\n    _ = reflect.count(.{ .a = \"x\" }) + reflect.describe(&.{.{}});\n    _ = reflect.fill(struct { a: u8 }, .{ .a = 1 });");
    const clean = try runWith(pack.unsafe_set, given, extra, imports);
    try std.testing.expectEqual(@as(usize, 0), clean.findings);
    try std.testing.expectEqual(@as(usize, 0), clean.undecided);
    // Findings (11, the conversion and its alignment): the parent handed to one, which the follow
    // takes into its body, where a computed name may be the interface's.
    const parent = try runWith(pack.unsafe_set, comptime edited(given, "    _ = reflect.fill(struct { a: u8 }, .{ .a = 1 });", "    var t: Sink = .init();\n    _ = reflect.count(&t);"), extra, imports);
    try std.testing.expectEqualSlices(u32, &.{ 11, 11 }, parent.lines[0..parent.findings]);
}

test "A019 follows each pointer to an interface field to every place it goes: a copy of what it points at, a place of another type, or its functions read out leave the conversion a finding" {
    // Findings (11, the conversion and its alignment), and where the contract holds the
    // interface (19 or 20): the copy, the address handed to what may copy it.
    const use = "    return s.count + s.interface.end;";
    const deref = try runEdited(pack.unsafe_set, interface_program, use, "    const copy = (&s.interface).*;\n    return s.count + copy.end;");
    try std.testing.expectEqualSlices(u32, &.{ 11, 11, 19 }, deref.lines[0..deref.findings]);
    const local = try runEdited(pack.unsafe_set, interface_program, use, "    const p = &s.interface;\n    const copy = p.*;\n    return s.count + copy.end;");
    try std.testing.expectEqualSlices(u32, &.{ 11, 11, 20 }, local.lines[0..local.findings]);
    const helper = try runEdited(pack.unsafe_set, interface_program, "pub fn use() !usize {", "fn dup(w: *std.Io.Writer) std.Io.Writer { return w.*; }\npub fn use() !usize {\n    var t: Sink = .init();\n    _ = dup(&t.interface);");
    try std.testing.expectEqualSlices(u32, &.{ 11, 11, 16 }, helper.lines[0..helper.findings]);
    const bytes = try runEdited(pack.unsafe_set, interface_program, use, "    _ = std.mem.asBytes(&s.interface);\n    return s.count + s.interface.end;");
    try std.testing.expectEqualSlices(u32, &.{ 11, 11, 19 }, bytes.lines[0..bytes.findings]);
    const array = try runEdited(pack.unsafe_set, interface_program, use, "    const many: *[1]std.Io.Writer = &s.interface;\n    return s.count + many[0].end;");
    try std.testing.expectEqualSlices(u32, &.{ 11, 11 }, array.lines[0..array.findings]);
    const table = try runEdited(pack.unsafe_set, interface_program, use, "    s.other.vtable = s.interface.vtable;\n    return s.count + s.interface.end;");
    try std.testing.expectEqualSlices(u32, &.{ 11, 11, 19 }, table.lines[0..table.findings]);
    const named = try runEdited(pack.unsafe_set, interface_program, use, "    const vt: std.Io.Writer.VTable = .{ .drain = @field(Sink, \"drain\") };\n    _ = vt;\n    return s.count + s.interface.end;");
    try std.testing.expectEqualSlices(u32, &.{ 11, 11 }, named.lines[0..named.findings]);
    const held = try runEdited(pack.unsafe_set, interface_program, use, "    const vt = &@field(Sink, \"vtable\");\n    _ = vt;\n    return s.count + s.interface.end;");
    try std.testing.expectEqualSlices(u32, &.{ 11, 11 }, held.lines[0..held.findings]);
    // Kept a pointer through a local, a field of its own type and a function that returns it.
    const kept = try runEdited(pack.unsafe_set, interface_program, "pub fn use() !usize {", "const Holder = struct { w: *std.Io.Writer };\nfn writer(s: *Sink) *std.Io.Writer { return &s.interface; }\npub fn use() !usize {\n    var t: Sink = .init();\n    const p = writer(&t);\n    const h: Holder = .{ .w = p };\n    try h.w.writeAll(\"z\");");
    try std.testing.expectEqual(@as(usize, 0), kept.findings);
}

test "A019 reads every file a path import joins to the program, selected or not: a copy of an interface field there leaves the conversion a finding" {
    // `other.zig`, outside the selection, copies the field it is handed: 11, the conversion
    // and its alignment.
    const program = comptime edited(interface_program, "pub fn use() !usize {", "const other = @import(\"other.zig\");\npub fn use() !usize {\n    var t: Sink = .init();\n    other.keep(&t);");
    const other: sources.Extra = .{ .name = "other.zig", .bytes = "pub fn keep(s: anytype) void { const copy = s.interface; _ = copy; }" };
    const found = try runWith(pack.unsafe_set, program, &(std_files ++ [_]sources.Extra{other}), &(std_imports ++ [_]sources.ExtraImport{.{ .spelling = "other.zig", .target = std_files.len }}));
    try std.testing.expectEqualSlices(u32, &.{ 11, 11 }, found.lines[0..found.findings]);
}

const generic_dependency: sources.Extra = .{ .name = "dep/root.zig", .bytes =
    \\pub fn grab(x: anytype) usize { const copy = @field(x, "interface"); return copy.end; }
    \\pub fn named(x: anytype, comptime name: []const u8) usize { const copy = @field(x, name); return copy.end; }
    \\pub fn print(args: anytype) usize { inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |f| { const v = @field(args, f.name); _ = v; } return 0; }
    \\pub fn total(x: anytype) usize { return x.count; }
    \\pub fn part(x: anytype) usize { return x.interface.end; }
    \\pub fn through(x: anytype, f: *const fn (@TypeOf(x)) usize) usize { return f(x); }
};

/// Dependencies whose generics read what they are handed and copy no field of it. A generic
/// nothing calls binds no argument, and one that names the field of what it may be handed
/// shows nothing (as in the program's own file), so each holds only what is called.
const total_dependency: sources.Extra = .{ .name = "dep/root.zig", .bytes = "pub fn total(x: anytype) usize { return x.count; }" };
const part_dependency: sources.Extra = .{ .name = "dep/root.zig", .bytes = "pub fn part(x: anytype) usize { return x.interface.end; }" };
/// A dependency whose generic hands what it is given to a function pointer it is given.
const pointer_dependency: sources.Extra = .{ .name = "dep/root.zig", .bytes =
    \\pub fn total(x: anytype) usize { return x.count; }
    \\pub fn through(x: anytype, f: *const fn (@TypeOf(x)) usize) usize { return f(x); }
};

/// `interface_program` returning `value`, with the dependency imported and `extra` declared.
fn handed(comptime value: []const u8, comptime extra: []const u8) !Run {
    return handedTo(generic_dependency, value, extra);
}
fn handedTo(dependency: sources.Extra, comptime value: []const u8, comptime extra: []const u8) !Run {
    const program = comptime edited(edited(interface_program, "    return s.count + s.interface.end;", "    return " ++ value ++ ";"), "pub fn use() !usize {", "const dep = @import(\"dep\");\n" ++ extra ++ "pub fn use() !usize {");
    return runWith(pack.unsafe_set, program, &(std_files ++ [_]sources.Extra{dependency}), &(std_imports ++ [_]sources.ExtraImport{.{ .spelling = "dep", .target = std_files.len }}));
}

test "A019 reads a parent handed to a dependency's generic: its body is the program's, where a copy of the field by its name or a computed one leaves the conversion a finding" {
    // Clean: a dependency's generics that read another field, by pointer and by value, or a
    // part of the interface.
    try std.testing.expectEqual(@as(usize, 0), (try handedTo(total_dependency, "dep.total(&s) + dep.total(s)", "")).findings);
    try std.testing.expectEqual(@as(usize, 0), (try handedTo(part_dependency, "dep.part(&s)", "")).findings);
    // A generic that copies the field, never handed the parent (`grab` beside `total`): what it
    // reads is what it is given, which the follow takes into it.
    try std.testing.expectEqual(@as(usize, 0), (try handed("dep.total(&s)", "")).findings);
    // Findings (11, the conversion and its alignment): the field copied by name, by pointer
    // and by value; by a name the caller gives; each field of a tuple holding a C copied, as
    // std.fmt's `{any}` does, from the program or through a generic of its own.
    for ([_]Run{
        try handed("dep.grab(&s)", ""),
        try handed("dep.grab(s)", ""),
        try handed("dep.named(&s, \"interface\")", ""),
        try handed("dep.print(.{ s.count, s })", ""),
        try handed("log(s)", "fn log(x: anytype) usize { return dep.print(.{x}); }\n"),
    }) |found| try std.testing.expectEqualSlices(u32, &.{ 11, 11 }, found.lines[0..found.findings]);
    // Undecided: a function pointer the C is handed through, whose body is not known.
    const baseline = try handedTo(pointer_dependency, "dep.total(&s)", "");
    const unread = try handedTo(pointer_dependency, "dep.through(&s, show)", "fn show(x: *Sink) usize { return x.count; }\n");
    try std.testing.expectEqual(@as(usize, 0), unread.findings);
    try std.testing.expect(unread.undecided > baseline.undecided);
}

test "A019 holds an interface to its contract where it is used: a pub accessor returning it clears, and a copy, a function read out or a value passed is flagged where it is made" {
    const tail = "    return s.count + s.interface.end;\n}\n";
    // Clean: an accessor returning the interface's address, and its user writing through it.
    const accessor = comptime edited(interface_program, tail, "    return s.count + s.interface.end;\n}\npub fn writer(s: *Sink) *std.Io.Writer {\n    return &s.interface;\n}\npub fn put(s: *Sink) !void {\n    try writer(s).writeAll(\"y\");\n}\n");
    try std.testing.expectEqual(@as(usize, 0), (try run(pack.unsafe_set, accessor)).findings);
    // Findings where they are made: a copy of what the accessor points at (26); the vtable read
    // out into another writer (26, and the conversion: 11); the interface passed by value (26),
    // where the parameter's own copy of it is no further site.
    const copied = try run(pack.unsafe_set, comptime edited(accessor, "    try writer(s).writeAll(\"y\");\n", "    const w = writer(s);\n    const copy = w.*;\n    _ = copy;\n"));
    try std.testing.expectEqualSlices(u32, &.{26}, copied.lines[0..copied.findings]);
    const table = try run(pack.unsafe_set, comptime edited(accessor, "    try writer(s).writeAll(\"y\");\n", "    const w = writer(s);\n    var other: std.Io.Writer = .{ .vtable = w.vtable };\n    _ = &other;\n"));
    try std.testing.expectEqualSlices(u32, &.{ 11, 11, 26 }, table.lines[0..table.findings]);
    const passed = try run(pack.unsafe_set, comptime edited(accessor, "    try writer(s).writeAll(\"y\");\n", "    const w = writer(s);\n    keep(w.*);\n}\nfn keep(w: std.Io.Writer) void {\n    const again = w;\n    _ = again;\n"));
    try std.testing.expectEqualSlices(u32, &.{26}, passed.lines[0..passed.findings]);
    // A function taking its address in a file this run does not check is followed, not taken
    // as checked there: one copying what it is given is the finding at the handing (25).
    const unchecked: sources.Extra = .{ .name = "other.zig", .bytes = "const std = @import(\"std\");\npub fn keep(w: *std.Io.Writer) void { const copy = w.*; _ = copy; }\npub fn put(w: *std.Io.Writer) !void { try w.writeAll(\"z\"); }" };
    const extra = &(std_files ++ [_]sources.Extra{unchecked});
    const imports = &(std_imports ++ [_]sources.ExtraImport{ .{ .spelling = "other.zig", .target = std_files.len }, .{ .from = std_files.len, .spelling = "std", .target = 0 } });
    const given = comptime edited(accessor, "    try writer(s).writeAll(\"y\");\n}\n", "    other.keep(writer(s));\n}\nconst other = @import(\"other.zig\");\n");
    const kept = try runWith(pack.unsafe_set, given, extra, imports);
    try std.testing.expectEqualSlices(u32, &.{25}, kept.lines[0..kept.findings]);
    const writes = try runWith(pack.unsafe_set, comptime edited(given, "other.keep(", "try other.put("), extra, imports);
    try std.testing.expectEqual(@as(usize, 0), writes.findings);
}

const made_program =
    \\const std = @import("std");
    \\const Sink = struct {
    \\    count: usize = 0,
    \\    interface: std.Io.Writer,
    \\    next: *std.Io.Writer,
    \\    fn init(start: usize, next: *std.Io.Writer) Sink { return .{ .count = start, .interface = .{ .vtable = &.{ .drain = drain } }, .next = next }; }
    \\    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) anyerror!usize {
    \\        const s: *Sink = @alignCast(@fieldParentPtr("interface", w));
    \\        s.count += data.len + splat;
    \\        return 0;
    \\    }
    \\};
    \\pub fn onStack(next: *std.Io.Writer) !usize {
    \\    var s: Sink = .init(1, next);
    \\    try s.interface.writeAll("x");
    \\    return s.count;
    \\}
    \\pub fn allocated(gpa: std.mem.Allocator, next: *std.Io.Writer) !usize {
    \\    const s = try gpa.create(Sink);
    \\    defer gpa.destroy(s);
    \\    s.* = .init(2, next);
    \\    try s.interface.writeAll("y");
    \\    return s.count;
    \\}
    \\
;

test "A019 clears a parent pointer whose parent is made in place by a declaration literal, on the stack or in memory std's allocator gives and frees, and not one a function of the program reads as bytes" {
    // Clean: `.init(...)` read by its result location as Sink.init, which keeps the interface
    // pointer it is given in place, and std's `mem.Allocator` freeing the parent whole, by its
    // contract.
    try std.testing.expectEqual(@as(usize, 0), (try run(pack.unsafe_set, made_program)).findings);
    // Findings (8, the conversion and its alignment): the parent handed to the program's own
    // function that casts it to bytes (13, its casts, are sites of their own).
    const released = comptime edited(made_program, "pub fn onStack(", "fn release(ptr: anytype) void { const raw: [*]u8 = @ptrCast(@constCast(ptr)); _ = raw; }\npub fn onStack(");
    const bytes = try runEdited(pack.unsafe_set, released, "    defer gpa.destroy(s);", "    defer release(s);");
    try std.testing.expectEqualSlices(u32, &.{ 8, 8, 13, 13 }, bytes.lines[0..bytes.findings]);
}

const observer_program =
    \\const Observer = struct {
    \\    vtable: *const VTable,
    \\    pub const VTable = struct { see: *const fn (*Observer, u32) void };
    \\    pub fn see(o: *Observer, n: u32) void { o.vtable.see(o, n); }
    \\};
    \\const Counter = struct {
    \\    total: u32 = 0,
    \\    observer: Observer = .{ .vtable = &vtable },
    \\    const vtable: Observer.VTable = .{ .see = see };
    \\    fn see(o: *Observer, n: u32) void {
    \\        const self: *Counter = @alignCast(@fieldParentPtr("observer", o));
    \\        self.total += n;
    \\    }
    \\};
    \\pub fn run() u32 {
    \\    var c: Counter = .{};
    \\    c.observer.see(3);
    \\    return c.total;
    \\}
    \\
;

test "A019 clears a parent pointer the program's own interface field shows, installed by the field's default, until a copy of the field" {
    try std.testing.expectEqual(@as(usize, 0), (try run(pack.unsafe_set, observer_program)).findings);
    const copied = try runEdited(pack.unsafe_set, observer_program, "    c.observer.see(3);", "    c.total = 1;\n    var copy = c.observer;\n    copy.see(3);");
    try std.testing.expectEqualSlices(u32, &.{ 11, 11, 18 }, copied.lines[0..copied.findings]);
}

const helper_program =
    \\const Host = struct { issue_fn: *const fn (*Host) u32, check_fn: ?*const fn (*Host) bool = null };
    \\const enabled = true;
    \\const W = struct {
    \\    n: u32 = 0,
    \\    host: Host = Hooks.answers,
    \\    const Hooks = struct {
    \\        const answers: Host = .{ .issue_fn = Hooks.issue, .check_fn = if (enabled) Hooks.check else null };
    \\        fn of(h: *Host) *W {
    \\            return @alignCast(@fieldParentPtr("host", h));
    \\        }
    \\        fn issue(h: *Host) u32 { return of(h).n; }
    \\        fn check(h: *Host) bool { return twice(h).n == 0; }
    \\        fn twice(h: *Host) *W { return of(h); }
    \\    };
    \\};
    \\pub fn use(w: *W) u32 { return w.host.issue_fn(&w.host); }
    \\
;

test "A019 clears a parent pointer a helper converts for the installed functions, each handing it its own interface parameter, and one installed by a choice of it or null" {
    // Clear: `of`, called from `issue` and from `twice`, itself called from `check`, which an
    // `if` installs. Findings (9, the conversion and its alignment): `of` given another
    // pointer, `of` public, a helper called on a value, a choice whose value goes elsewhere.
    try std.testing.expectEqual(@as(usize, 0), (try run(pack.unsafe_set, helper_program)).findings);
    const other = try runEdited(pack.unsafe_set, helper_program, "fn issue(h: *Host) u32 { return of(h).n; }", "fn issue(h: *Host) u32 { var copy = h.*; copy.issue_fn = issue; return of(&copy).n; }");
    try std.testing.expectEqualSlices(u32, &.{ 9, 9, 11 }, other.lines[0..other.findings]);
    const public = try runEdited(pack.unsafe_set, helper_program, "        fn of(h: *Host) *W {", "        pub fn of(h: *Host) *W {");
    try std.testing.expectEqualSlices(u32, &.{ 9, 9 }, public.lines[0..public.findings]);
    const stray = try runEdited(pack.unsafe_set, helper_program, "pub fn use(w: *W) u32 {", "pub fn stray(h: *Host) *W { return W.Hooks.twice(h); }\npub fn use(w: *W) u32 {");
    try std.testing.expectEqualSlices(u32, &.{ 9, 9 }, stray.lines[0..stray.findings]);
    const chosen = try runEdited(pack.unsafe_set, helper_program, "pub fn use(w: *W) u32 {", "pub fn chosen() ?*const fn (*Host) bool { const f: ?*const fn (*Host) bool = if (enabled) W.Hooks.check else null; return f; }\npub fn use(w: *W) u32 {");
    try std.testing.expectEqualSlices(u32, &.{ 9, 9 }, chosen.lines[0..chosen.findings]);
    // The function read out of C.F and called on another interface converts that one.
    const elsewhere = try runEdited(pack.unsafe_set, helper_program, "pub fn use(w: *W) u32 { return w.host.issue_fn(&w.host); }", "pub fn use(w: *W, other: *Host) u32 { return w.host.issue_fn(other); }");
    try std.testing.expectEqualSlices(u32, &.{ 9, 9, 16 }, elsewhere.lines[0..elsewhere.findings]);
    const direct =
        \\const Host = struct { issue_fn: *const fn (*Host) u32 };
        \\const W = struct {
        \\    n: u32 = 0,
        \\    host: Host = .{ .issue_fn = issue },
        \\    fn issue(h: *Host) u32 {
        \\        const w: *W = @alignCast(@fieldParentPtr("host", h));
        \\        return w.n;
        \\    }
        \\};
        \\pub fn use(w: *W) u32 { return w.host.issue_fn(&w.host); }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 0), (try run(pack.unsafe_set, direct)).findings);
    const read_out = try runEdited(pack.unsafe_set, direct, "pub fn use(w: *W) u32 { return w.host.issue_fn(&w.host); }", "pub fn use(w: *W, other: *Host) u32 { const f = w.host.issue_fn; return f(other); }");
    try std.testing.expectEqualSlices(u32, &.{ 6, 6, 10 }, read_out.lines[0..read_out.findings]);
    const kept = try runEdited(pack.unsafe_set, helper_program, "pub fn use(w: *W) u32 { return w.host.issue_fn(&w.host); }", "pub fn use(w: *W, other: *Host) u32 { const f = w.host.issue_fn; return f(other); }");
    try std.testing.expectEqualSlices(u32, &.{ 9, 9, 16 }, kept.lines[0..kept.findings]);
}

const file_program =
    \\const std = @import("std");
    \\const options = @import("options");
    \\const Data = struct {
    \\    count: usize = 0,
    \\    spare: ?*const fn (*std.Io.Writer, []const []const u8, usize) std.Io.Writer.Error!usize = null,
    \\    interface: std.Io.Writer,
    \\    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    \\        const d: *Data = @alignCast(@fieldParentPtr("interface", w));
    \\        d.count += splat;
    \\        return data.len;
    \\    }
    \\};
    \\const Body = union(enum) { none, data: Data };
    \\const Out = struct { body: Body };
    \\const Other = struct { interface: std.Io.Writer };
    \\const Tables = struct {
    \\    const data: std.Io.Writer.VTable = .{ .drain = Data.drain };
    \\};
    \\const data_vtable = Tables.data;
    \\fn open(buffer: []u8) Out {
    \\    return .{ .body = .{ .data = .{ .interface = .{ .vtable = &.{ .drain = Data.drain }, .buffer = buffer } } } };
    \\}
    \\fn reset(d: *Data, buffer: []u8) void {
    \\    d.* = .{ .interface = .{ .vtable = &data_vtable, .buffer = buffer } };
    \\}
    \\pub fn use(buffer: []u8) !usize {
    \\    var o = open(buffer);
    \\    reset(&o.body.data, buffer);
    \\    try o.body.data.interface.writeAll("x");
    \\    if (options.drain) o.body.data.count += 1;
    \\    return o.body.data.count + o.body.data.interface.end;
    \\}
    \\
;

test "A019 clears a parent pointer whose function its file installs into C.F of a C anywhere, through constants each named only so, and an import's member is no field read" {
    // Clear: a union's payload built in place, a pointer's target assigned whole, through a
    // vtable constant in a struct and a constant naming it. Findings (8, the conversion and
    // its alignment): that vtable installed into another type's field, the function stored
    // into C's other field or another struct's, the constant made `pub`, the interface handed
    // to a generic that reads the vtable's function (and the contract's sites: the read, 26, and
    // the handing, 30). The same generic handed nothing of it is clean: what it reads is what it
    // is given, which the follow takes into it.
    try std.testing.expectEqual(@as(usize, 0), (try run(pack.unsafe_set, file_program)).findings);
    const other = try runEdited(pack.unsafe_set, file_program, "pub fn use(buffer: []u8) !usize {", "fn wrong(buffer: []u8) Other { return .{ .interface = .{ .vtable = &data_vtable, .buffer = buffer } }; }\npub fn use(buffer: []u8) !usize {");
    try std.testing.expectEqualSlices(u32, &.{ 8, 8 }, other.lines[0..other.findings]);
    const spare = try runEdited(pack.unsafe_set, file_program, "    reset(&o.body.data, buffer);", "    reset(&o.body.data, buffer);\n    o.body.data.spare = Data.drain;");
    try std.testing.expectEqualSlices(u32, &.{ 8, 8 }, spare.lines[0..spare.findings]);
    const held = try runEdited(pack.unsafe_set, file_program, "const Other = struct { interface: std.Io.Writer };", "const Other = struct { interface: std.Io.Writer };\nconst Hold = struct { f: *const fn (*std.Io.Writer, []const []const u8, usize) std.Io.Writer.Error!usize };\nfn hold() Hold { return .{ .f = Data.drain }; }");
    try std.testing.expectEqualSlices(u32, &.{ 8, 8 }, held.lines[0..held.findings]);
    const public = try runEdited(pack.unsafe_set, file_program, "const data_vtable = Tables.data;", "pub const data_vtable = Tables.data;");
    try std.testing.expectEqualSlices(u32, &.{ 8, 8 }, public.lines[0..public.findings]);
    const nested = try runEdited(pack.unsafe_set, file_program, "    const data: std.Io.Writer.VTable", "    pub const data: std.Io.Writer.VTable");
    try std.testing.expectEqualSlices(u32, &.{ 8, 8 }, nested.lines[0..nested.findings]);
    const peek = comptime edited(file_program, "pub fn use(buffer: []u8) !usize {", "pub fn peek(t: anytype) void { _ = t.vtable.drain; }\npub fn use(buffer: []u8) !usize {");
    try std.testing.expectEqual(@as(usize, 0), (try run(pack.unsafe_set, peek)).findings);
    const peeked = try runEdited(pack.unsafe_set, peek, "    reset(&o.body.data, buffer);", "    reset(&o.body.data, buffer);\n    peek(&o.body.data.interface);");
    try std.testing.expectEqualSlices(u32, &.{ 8, 8, 26, 30 }, peeked.lines[0..peeked.findings]);
}

const lookup_program =
    \\const Lookup = struct { lookup_fn: ?*const fn (u32, *Lookup) u32 = null };
    \\const Static = struct {
    \\    n: u32 = 0,
    \\    resolving: Lookup = .{ .lookup_fn = find },
    \\    fn find(port: u32, l: *Lookup) u32 {
    \\        const s: *Static = @alignCast(@fieldParentPtr("resolving", l));
    \\        return s.n + port;
    \\    }
    \\};
    \\pub fn use(s: *Static) u32 {
    \\    const l = &s.resolving;
    \\    return l.lookup_fn.?(1, l);
    \\}
    \\
;

test "A019 clears a parent pointer whose interface is any parameter of the installed function, called through an optional, until it is handed another one" {
    // Findings (6, the conversion and its alignment): another interface at the parameter, the
    // function read out of its optional and called on another.
    try std.testing.expectEqual(@as(usize, 0), (try run(pack.unsafe_set, lookup_program)).findings);
    const other = try runEdited(pack.unsafe_set, lookup_program, "pub fn use(s: *Static) u32 {", "pub fn use(s: *Static, x: *Lookup) u32 {\n    _ = s.resolving.lookup_fn.?(2, x);");
    try std.testing.expectEqualSlices(u32, &.{ 6, 6, 11 }, other.lines[0..other.findings]);
    const read_out = try runEdited(pack.unsafe_set, lookup_program, "pub fn use(s: *Static) u32 {", "pub fn use(s: *Static, x: *Lookup) u32 {\n    const f = s.resolving.lookup_fn.?;\n    _ = f(2, x);");
    try std.testing.expectEqualSlices(u32, &.{ 6, 6, 11 }, read_out.lines[0..read_out.findings]);
    // Captured from its optional and called only on the interface it was read from: clean. On
    // another, or on a `var` pointed elsewhere in between: findings (6, and the read at 12).
    const body = "pub fn use(s: *Static) u32 {\n    const l = &s.resolving;\n    return l.lookup_fn.?(1, l);";
    const captured = try runEdited(pack.unsafe_set, lookup_program, body, "pub fn use(s: *Static) u32 {\n    const l = &s.resolving;\n    if (l.lookup_fn) |f| return f(1, l);\n    return 0;");
    try std.testing.expectEqual(@as(usize, 0), captured.findings);
    const captured_other = try runEdited(pack.unsafe_set, lookup_program, body, "pub fn use(s: *Static, x: *Lookup) u32 {\n    const l = &s.resolving;\n    if (l.lookup_fn) |f| return f(1, x);\n    return 0;");
    try std.testing.expectEqualSlices(u32, &.{ 6, 6, 12 }, captured_other.lines[0..captured_other.findings]);
    const moved = try runEdited(pack.unsafe_set, lookup_program, body, "pub fn use(s: *Static, x: *Lookup) u32 {\n    var l = &s.resolving;\n    if (l.lookup_fn) |f| {\n        l = x;\n        return f(1, l);\n    }\n    return 0;");
    try std.testing.expectEqualSlices(u32, &.{ 6, 6, 12 }, moved.lines[0..moved.findings]);
}

const list_program =
    \\const std = @import("std");
    \\const Conn = struct { id: u32, node: std.DoublyLinkedList.Node = .{} };
    \\const Other = struct { tag: u32, node: std.DoublyLinkedList.Node = .{} };
    \\const Pool = struct {
    \\    free: std.DoublyLinkedList = .{},
    \\    fn put(p: *Pool, c: *Conn) void { p.free.append(&c.node); }
    \\    fn take(p: *Pool) ?*Conn {
    \\        const n = p.free.popFirst() orelse return null;
    \\        return @fieldParentPtr("node", n);
    \\    }
    \\    fn sum(p: *Pool) u32 {
    \\        var total: u32 = 0;
    \\        var it = p.free.first;
    \\        while (it) |n| : (it = n.next) {
    \\            const c: *Conn = @fieldParentPtr("node", n);
    \\            total += c.id;
    \\        }
    \\        return total;
    \\    }
    \\};
    \\pub fn run(p: *Pool, c: *Conn, o: *Other) u32 {
    \\    p.put(c);
    \\    o.tag = 1;
    \\    _ = p.take();
    \\    return p.sum();
    \\}
    \\
;

test "A019 clears a parent pointer an intrusive list's node shows, where every insertion into the list puts that parent's node and nothing copies it" {
    try std.testing.expectEqual(@as(usize, 0), (try run(pack.unsafe_set, list_program)).findings);
    // Another type's node put into the list; a copied node; the list's nodes read as another type.
    const other = try runEdited(pack.unsafe_set, list_program, "    o.tag = 1;", "    p.free.append(&o.node);");
    try std.testing.expectEqualSlices(u32, &.{ 9, 15 }, other.lines[0..other.findings]);
    const copied = try runEdited(pack.unsafe_set, list_program, "    o.tag = 1;", "    o.tag = 1;\n    const node = c.node;\n    _ = node;");
    try std.testing.expectEqualSlices(u32, &.{ 9, 15 }, copied.lines[0..copied.findings]);
    const wrong = try runEdited(pack.unsafe_set, list_program, "            const c: *Conn = @fieldParentPtr(\"node\", n);\n            total += c.id;", "            const c: *Other = @fieldParentPtr(\"node\", n);\n            total += c.tag;");
    try std.testing.expectEqualSlices(u32, &.{15}, wrong.lines[0..wrong.findings]);
}

test "A019 clears a list's nodes walked through an optional's capture, and nothing a list is given another way" {
    // Clean: walked back from `last`, the capture read through `prev`.
    const back = try runEdited(pack.unsafe_set, list_program, "        var it = p.free.first;\n        while (it) |n| : (it = n.next) {", "        var it = p.free.last;\n        while (it) |n| : (it = n.prev) {");
    try std.testing.expectEqual(@as(usize, 0), back.findings);
    // Findings: another type's node put in through `@call`, a function value, a link named by
    // `@field`, a literal, a node literal linked in, a list built elsewhere moved in or
    // concatenated, a link of another list stored in this one's or in a node's.
    const at_call = try runEdited(pack.unsafe_set, list_program, "    o.tag = 1;", "    @call(.auto, std.DoublyLinkedList.append, .{ &p.free, &o.node });");
    try std.testing.expectEqualSlices(u32, &.{ 9, 15 }, at_call.lines[0..at_call.findings]);
    const value = try runEdited(pack.unsafe_set, list_program, "    o.tag = 1;", "    const add = std.DoublyLinkedList.append;\n    add(&p.free, &o.node);");
    try std.testing.expectEqualSlices(u32, &.{ 9, 15 }, value.lines[0..value.findings]);
    const named = try runEdited(pack.unsafe_set, list_program, "    o.tag = 1;", "    @field(p.free, \"first\") = &o.node;");
    try std.testing.expectEqualSlices(u32, &.{ 9, 15 }, named.lines[0..named.findings]);
    const literal = try runEdited(pack.unsafe_set, list_program, "    o.tag = 1;", "    p.free = .{ .first = &o.node, .last = &o.node };");
    try std.testing.expectEqualSlices(u32, &.{ 9, 15 }, literal.lines[0..literal.findings]);
    const node_literal = try runEdited(pack.unsafe_set, list_program, "    o.tag = 1;", "    c.node = .{ .next = &o.node, .prev = null };\n    p.free.last = &c.node;");
    try std.testing.expectEqualSlices(u32, &.{ 9, 15 }, node_literal.lines[0..node_literal.findings]);
    const moved = try runEdited(pack.unsafe_set, list_program, "    o.tag = 1;", "    var b: std.DoublyLinkedList = .{};\n    b.append(&o.node);\n    p.free = b;");
    try std.testing.expectEqualSlices(u32, &.{ 9, 15 }, moved.lines[0..moved.findings]);
    const concatenated = try runEdited(pack.unsafe_set, list_program, "    o.tag = 1;", "    var b: std.DoublyLinkedList = .{};\n    b.append(&o.node);\n    std.DoublyLinkedList.concatByMoving(&p.free, &b);");
    try std.testing.expectEqualSlices(u32, &.{ 9, 15 }, concatenated.lines[0..concatenated.findings]);
    const other_list = try runEdited(pack.unsafe_set, list_program, "    o.tag = 1;", "    var b: std.DoublyLinkedList = .{};\n    b.append(&o.node);\n    p.free.first = b.first;");
    try std.testing.expectEqualSlices(u32, &.{ 9, 15 }, other_list.lines[0..other_list.findings]);
    const other_node = try runEdited(pack.unsafe_set, list_program, "    o.tag = 1;", "    var b: std.DoublyLinkedList = .{};\n    b.append(&o.node);\n    c.node.next = b.first;");
    try std.testing.expectEqualSlices(u32, &.{ 9, 15 }, other_node.lines[0..other_node.findings]);
    // Finding: the walked local written through its address, which no list shows.
    const through = try runEdited(pack.unsafe_set, list_program, "        var it = p.free.first;", "        var it = p.free.first;\n        const alias = &it;\n        alias.* = null;");
    try std.testing.expectEqualSlices(u32, &.{17}, through.lines[0..through.findings]);
}

test "A019 reads a buffer a std count filled where its count is all of it, a limited reader's buffer, and a generator's bytes" {
    // Clean: past a count below the length leaving (3), and equal to it by `.len` (4), a
    // limited reader keeping its buffer (6), a generator filling all of it (8). Findings: the
    // count unchecked (5), checked against less than the length (9), the limited reader's
    // buffer read (7).
    const found = try run(pack.unsafe_set,
        \\const std = @import("std");
        \\fn use(b: []const u8) void { _ = b; }
        \\pub fn c1(r: *std.Io.Reader) !u8 { var sig: [4]u8 = undefined; const n = try r.readSliceShort(&sig); if (n < 4) return error.Short; return sig[0]; }
        \\pub fn c2(r: *std.Io.Reader) !u8 { var sig: [4]u8 = undefined; const n = try r.readSliceShort(&sig); if (n != sig.len) return error.Short; return sig[3]; }
        \\pub fn c3(r: *std.Io.Reader) !u8 { var sig: [4]u8 = undefined; _ = try r.readSliceShort(&sig); return sig[0]; }
        \\pub fn l1(r: *std.Io.Reader) void { var buffer: [64]u8 = undefined; var bounded = r.limited(.unlimited, &buffer); _ = &bounded; }
        \\pub fn l2(r: *std.Io.Reader) u8 { var buffer: [64]u8 = undefined; var bounded = r.limited(.unlimited, &buffer); _ = &bounded; return buffer[0]; }
        \\pub fn g1(drbg: *std.Random.ChaCha) void { var draw: [34]u8 = undefined; drbg.fill(&draw); use(&draw); }
        \\pub fn c4(r: *std.Io.Reader) !u8 { var sig: [4]u8 = undefined; const n = try r.readSliceShort(&sig); if (n < 2) return error.Short; return sig[3]; }
    );
    try std.testing.expectEqualSlices(u32, &.{ 5, 7, 9 }, found.lines[0..found.findings]);
}

test "A019 reads a prefix a counter stepped past each element after setting it, and what a per-build choice of std's hashers fills" {
    // Clean: elements set then counted (7), a hasher a switch of types picks filling the part
    // returned (10, 11). Findings: a count stepped where the set may not run (8), a counter set
    // otherwise (9), past the part the chosen hasher filled (12), a part under its own name
    // returned unwritten (16). Clean too: a part under its own name, filled, returned (15).
    const found = try run(pack.unsafe_set,
        \\const std = @import("std");
        \\fn use(b: []const u32) void { _ = b; }
        \\fn useBytes(b: []const u8) void { _ = b; }
        \\fn Hasher(comptime wide: bool) type { return switch (wide) { false => std.crypto.hash.sha2.Sha256, true => std.crypto.hash.sha2.Sha512 }; }
        \\fn digest(comptime wide: bool, m: []const u8, out: *[64]u8) []const u8 { const H = Hasher(wide); H.hash(m, out[0..H.digest_length]); return out[0..H.digest_length]; }
        \\fn past(comptime wide: bool, m: []const u8, out: *[64]u8) []const u8 { const H = Hasher(wide); H.hash(m, out[0..H.digest_length]); return out[0..64]; }
        \\pub fn a1(src: []const u32) void { var a: [8]u32 = undefined; var n: usize = 0; for (src) |x| { a[n] = x; n += 1; } use(a[0..n]); }
        \\pub fn a2(src: []const u32) void { var a: [8]u32 = undefined; var n: usize = 0; for (src) |x| { if (x > 0) a[n] = x; n += 1; } use(a[0..n]); }
        \\pub fn a3(src: []const u32) void { var a: [8]u32 = undefined; var n: usize = 0; for (src) |x| { a[n] = x; n += 1; } n = 8; use(a[0..n]); }
        \\pub fn d1(m: []const u8, wide: bool) void { var b: [64]u8 = undefined; useBytes(if (wide) digest(true, m, &b) else digest(false, m, &b)); }
        \\pub fn d2(m: []const u8) void { var b: [64]u8 = undefined; useBytes(digest(false, m, &b)); }
        \\pub fn d3(m: []const u8) void { var b: [64]u8 = undefined; useBytes(past(false, m, &b)); }
        \\fn named(out: *[16]u8, v: u32) struct { bytes: []const u8 } { const part = out[0..4]; std.mem.writeInt(u32, part, v, 0); return .{ .bytes = part }; }
        \\fn unnamed(out: *[16]u8) struct { bytes: []const u8 } { const part = out[0..4]; return .{ .bytes = part }; }
        \\pub fn n1(v: u32) void { var b: [16]u8 = undefined; useBytes(named(&b, v).bytes); }
        \\pub fn n2() void { var b: [16]u8 = undefined; useBytes(unnamed(&b).bytes); }
    );
    try std.testing.expectEqualSlices(u32, &.{ 8, 9, 12, 16 }, found.lines[0..found.findings]);
}

test "A019 reads the prefix a cursor writer counts, where its type steps the count only past what it wrote" {
    // Clean: a writer's count over the local (15), a function building into what it is given
    // through a writer it hands on, returning the prefix counted (23). Findings: past the count
    // (16), a writer type that steps past what it wrote (17), a writer that starts at 4 (18), a
    // writer a function points elsewhere (24), the local read with nothing written (25), and
    // the other memory that writer is pointed at, handed on where nothing shows what is read
    // of it (24).
    const found = try run(pack.unsafe_set,
        \\const std = @import("std");
        \\const Writer = struct {
        \\    bytes: []u8,
        \\    pos: usize = 0,
        \\    fn put(self: *Writer, b: []const u8) error{Full}!void { if (b.len > self.bytes.len - self.pos) return error.Full; @memcpy(self.bytes[self.pos..][0..b.len], b); self.pos += b.len; }
        \\    fn byte(self: *Writer, v: u8) error{Full}!void { try self.put(&.{v}); }
        \\    fn written(self: *const Writer) []const u8 { return self.bytes[0..self.pos]; }
        \\};
        \\const Loose = struct {
        \\    bytes: []u8,
        \\    pos: usize = 0,
        \\    fn put(self: *Loose, b: []const u8) void { @memcpy(self.bytes[self.pos..][0..b.len], b); self.pos += b.len + 1; }
        \\};
        \\fn use(b: []const u8) void { _ = b; }
        \\pub fn a1() !void { var buf: [16]u8 = undefined; var w: Writer = .{ .bytes = &buf }; try w.put("ab"); try w.byte(1); use(buf[0..w.pos]); }
        \\pub fn a2() !void { var buf: [16]u8 = undefined; var w: Writer = .{ .bytes = &buf }; try w.put("ab"); use(buf[0 .. w.pos + 2]); }
        \\pub fn a3() void { var buf: [16]u8 = undefined; var w: Loose = .{ .bytes = &buf }; w.put("ab"); use(buf[0..w.pos]); }
        \\pub fn a4() !void { var buf: [16]u8 = undefined; var w: Writer = .{ .bytes = &buf, .pos = 4 }; try w.put("ab"); use(buf[0..w.pos]); }
        \\fn build(out: []u8, v: u8) ![]u8 { var w: Writer = .{ .bytes = out }; try w.byte(v); try more(&w); return out[0..w.pos]; }
        \\fn more(w: *Writer) !void { try w.put("x"); }
        \\fn reset(w: *Writer, other: []u8) void { w.* = .{ .bytes = other }; }
        \\fn swapped(out: []u8, other: []u8) []u8 { var w: Writer = .{ .bytes = out }; reset(&w, other); w.put("x") catch {}; return out[0..w.pos]; }
        \\pub fn b1(v: u8) !void { var buf: [16]u8 = undefined; use(try build(&buf, v)); }
        \\pub fn b2() void { var buf: [16]u8 = undefined; var other: [4]u8 = undefined; use(swapped(&buf, &other)); }
        \\pub fn c1() void { var buf: [16]u8 = undefined; const w: Writer = .{ .bytes = &buf }; _ = w.written(); use(buf[0..1]); }
    );
    try std.testing.expectEqualSlices(u32, &.{ 16, 17, 18, 24, 24, 25 }, found.lines[0..found.findings]);
}

test "A019 reads a function in a file the run did not select as the program's: what it writes of a local, and a cursor writer it keeps" {
    // Clean: `fill` writes all of the local (3); `more` keeps the writer over what it was given
    // (5). Findings: `first` writes one byte of four (4); `elsewhere` points the writer at other
    // memory (6).
    const found = try runWithFile(pack.unsafe_set,
        \\const other = @import("other.zig");
        \\fn use(b: []const u8) void { _ = b; }
        \\pub fn fa() void { var buf: [4]u8 = undefined; other.fill(&buf); use(&buf); }
        \\pub fn fb() void { var buf: [4]u8 = undefined; other.first(&buf); use(&buf); }
        \\pub fn fc() !void { var buf: [16]u8 = undefined; var w: other.Writer = .{ .bytes = &buf }; try w.put("ab"); try other.more(&w); use(buf[0..w.pos]); }
        \\pub fn fd(to: []u8) !void { var buf: [16]u8 = undefined; var w: other.Writer = .{ .bytes = &buf }; try w.put("ab"); other.elsewhere(&w, to); try w.put("y"); use(buf[0..w.pos]); }
    ,
        \\pub fn fill(b: *[4]u8) void { b.* = .{ 1, 2, 3, 4 }; }
        \\pub fn first(b: *[4]u8) void { b[0] = 1; }
        \\pub const Writer = struct {
        \\    bytes: []u8,
        \\    pos: usize = 0,
        \\    pub fn put(self: *Writer, v: []const u8) error{Full}!void { if (v.len > self.bytes.len - self.pos) return error.Full; @memcpy(self.bytes[self.pos..][0..v.len], v); self.pos += v.len; }
        \\};
        \\pub fn more(w: *Writer) !void { try w.put("x"); }
        \\pub fn elsewhere(w: *Writer, to: []u8) void { w.* = .{ .bytes = to }; }
    );
    try std.testing.expectEqualSlices(u32, &.{ 4, 6 }, found.lines[0..found.findings]);
}

test "A019 reads a local a range's passes wrote a stride at a time, all of it" {
    // Clean: four eight-byte strides over 32 bytes, counting up (3) and down (4). Findings: 32
    // of 40 bytes (5), strides of 4 that leave the tail (6), a pass that may skip its write
    // (7), a pass that reads the local it writes (8).
    const found = try run(pack.unsafe_set,
        \\const std = @import("std");
        \\fn use(b: []const u8) void { _ = b; }
        \\pub fn s1(words: [4]u64) void { var out: [32]u8 = undefined; for (0..4) |i| std.mem.writeInt(u64, out[8 * i ..][0..8], words[i], .little); use(&out); }
        \\pub fn s2(words: [4]u64) void { var out: [32]u8 = undefined; inline for (0..4) |i| std.mem.writeInt(u64, out[8 * (4 - 1 - i) ..][0..8], words[i], .big); use(&out); }
        \\pub fn s3(words: [4]u64) void { var out: [40]u8 = undefined; for (0..4) |i| std.mem.writeInt(u64, out[8 * i ..][0..8], words[i], .little); use(&out); }
        \\pub fn s4(words: [4]u64) void { var out: [32]u8 = undefined; for (0..4) |i| std.mem.writeInt(u64, out[4 * i ..][0..8], words[i], .little); use(&out); }
        \\pub fn s5(words: [4]u64) void { var out: [32]u8 = undefined; for (0..4) |i| { if (words[i] == 0) continue; std.mem.writeInt(u64, out[8 * i ..][0..8], words[i], .little); } use(&out); }
        \\pub fn s6() void { var out: [32]u8 = undefined; for (0..4) |i| @memcpy(out[8 * i ..][0..8], out[0..8]); use(&out); }
    );
    try std.testing.expectEqualSlices(u32, &.{ 5, 6, 7, 8 }, found.lines[0..found.findings]);
}

test "A019 reads a local a function outside the program writes only where its result shows it did" {
    // Clean: waitpid's status under `rc > 0` (10), getrlimit's under `== 0` in an `if`
    // expression and past `!= 0` that leaves (12, 13), read's count (15), proc_pidinfo's size
    // returned (17), a BOOL's out never read and read past `== .FALSE` (19, 20), a status's
    // `.SUCCESS` prong (22). Findings: the externs themselves (3-8), status read unchecked (11),
    // past a test whose two sides both go on (14), past a count (16), a size other than the one
    // given (18), read after `and` a failure (21), another prong (23), a test of `and` with the
    // failure on one side (24), a size test that is not the size given (26). Clean too: a size
    // test in a statement of its own, the type read through `@TypeOf` (25); an array of no
    // elements (27); a per-build choice of two symbols alike (32). Findings: their externs (28,
    // 29), read past a test that goes on either way (33).
    const found = try run(pack.unsafe_set,
        \\const Status = enum(u32) { SUCCESS = 0, OTHER = 1, _ };
        \\const BOOL = enum(i32) { FALSE = 0, TRUE = 1 };
        \\extern "c" fn waitpid(pid: i32, status: *c_int, options: c_int) i32;
        \\extern "c" fn getrlimit(resource: c_int, rlim: *std.c.rlimit) c_int;
        \\extern "c" fn read(fd: i32, buf: [*]u8, n: usize) isize;
        \\extern "c" fn proc_pidinfo(pid: i32, flavor: c_int, arg: u64, buffer: *anyopaque, size: c_int) c_int;
        \\extern "kernel32" fn GetConsoleMode(h: std.os.windows.HANDLE, mode: *std.os.windows.DWORD) BOOL;
        \\extern "ntdll" fn NtOpenFile(h: *std.os.windows.HANDLE, access: u32, attributes: usize, io: *std.os.windows.IO_STATUS_BLOCK) Status;
        \\fn use(x: anytype) void { _ = x; }
        \\pub fn w1(pid: i32) ?c_int { var s: c_int = undefined; const rc = waitpid(pid, &s, 1); if (rc == 0) return null; if (rc > 0) return s; return null; }
        \\pub fn w2(pid: i32) c_int { var s: c_int = undefined; _ = waitpid(pid, &s, 1); return s; }
        \\pub fn r1() u64 { var l: std.c.rlimit = undefined; return if (getrlimit(7, &l) == 0) l.cur else 0; }
        \\pub fn r2() u64 { var l: std.c.rlimit = undefined; if (getrlimit(7, &l) != 0) return 0; return l.cur; }
        \\pub fn r3() u64 { var l: std.c.rlimit = undefined; if (getrlimit(7, &l) == 0) {} return l.cur; }
        \\pub fn n1(fd: i32) void { var b: [8]u8 = undefined; const n = read(fd, &b, b.len); if (n <= 0) return; use(b[0..@intCast(n)]); }
        \\pub fn n2(fd: i32) void { var b: [8]u8 = undefined; _ = read(fd, &b, b.len); use(b[0..4]); }
        \\pub fn p1(pid: i32) u64 { var info: [4]u64 = undefined; return if (proc_pidinfo(pid, 1, 0, &info, @sizeOf([4]u64)) == @sizeOf([4]u64)) info[0] else 0; }
        \\pub fn p2(pid: i32) u64 { var info: [4]u64 = undefined; return if (proc_pidinfo(pid, 1, 0, &info, @sizeOf([4]u64)) == 8) info[0] else 0; }
        \\pub fn g1(h: std.os.windows.HANDLE) bool { var m: u32 = undefined; return GetConsoleMode(h, &m) != .FALSE; }
        \\pub fn g2(h: std.os.windows.HANDLE) u32 { var m: u32 = undefined; if (GetConsoleMode(h, &m) == .FALSE) return 0; return m; }
        \\pub fn g3(h: std.os.windows.HANDLE) bool { var m: u32 = undefined; return GetConsoleMode(h, &m) == .FALSE and m == 0; }
        \\pub fn t1() ?std.os.windows.HANDLE { var h: std.os.windows.HANDLE = undefined; var io: std.os.windows.IO_STATUS_BLOCK = undefined; switch (NtOpenFile(&h, 0, 0, &io)) { .SUCCESS => return h, else => return null } }
        \\pub fn t2() ?std.os.windows.HANDLE { var h: std.os.windows.HANDLE = undefined; var io: std.os.windows.IO_STATUS_BLOCK = undefined; switch (NtOpenFile(&h, 0, 0, &io)) { .OTHER => return h, else => return null } }
        \\pub fn e1(pid: i32) u64 { var l: std.c.rlimit = undefined; const rc = getrlimit(pid, &l); if (rc != 0 and pid > 0) return 0; return l.cur; }
        \\pub fn s1(pid: i32) u64 { var info: [4]u64 = undefined; const got = proc_pidinfo(pid, 1, 0, &info, @sizeOf(@TypeOf(info))); if (got != @sizeOf(@TypeOf(info))) return 0; return info[0]; }
        \\pub fn s2(pid: i32) u64 { var info: [4]u64 = undefined; const got = proc_pidinfo(pid, 1, 0, &info, @sizeOf(@TypeOf(info))); if (got == 0) return 0; return info[0]; }
        \\pub fn z1(fd: i32) void { var none: [0]u8 = undefined; _ = read(fd, &none, 0); use(&none); }
        \\extern "c" fn fstat(fd: i32, buf: *std.c.Stat) c_int;
        \\extern "c" fn @"fstat$INODE64"(fd: i32, buf: *std.c.Stat) c_int;
        \\const stat = if (@import("builtin").cpu.arch == .x86_64) @"fstat$INODE64" else fstat;
        \\const either = if (@import("builtin").cpu.arch == .x86_64) fstat else waitpid;
        \\pub fn c1(fd: i32) u64 { var st: std.c.Stat = undefined; if (stat(fd, &st) != 0) return 0; return st.ino; }
        \\pub fn c2(fd: i32) u64 { var st: std.c.Stat = undefined; if (stat(fd, &st) == 0) {} return st.ino; }
        \\const std = @import("std");
    );
    try std.testing.expectEqualSlices(u32, &.{ 3, 4, 5, 6, 7, 8, 11, 14, 16, 18, 21, 23, 24, 26, 28, 29, 33 }, found.lines[0..found.findings]);
}

test "A019 reads what a parts writer wrote only where nothing between changes the part, and a counter only over the buffer it counts" {
    // Clean: a part written before it is handed on (10), bounds a local constant and a
    // container's spell (14), a counter and its buffer in one scope (16). Findings: a part handed
    // on before the deferred write to it runs (9), bounds changed through a pointer (11) or a
    // field (12) between the write and the return, a counter that outlives the buffer it counts,
    // declared afresh each pass (15).
    const found = try run(pack.unsafe_set,
        \\fn sink(s: []const u8) u8 { return s[0]; }
        \\const Cursor = struct { n: usize };
        \\fn deferred(p: *[8]u8) u8 { defer p[0..4].* = .{ 1, 2, 3, 4 }; return sink(p[0..4]); }
        \\fn first(p: *[8]u8) u8 { p[0..4].* = .{ 1, 2, 3, 4 }; return sink(p[0..4]); }
        \\fn pointed(p: []u8, k: *usize, src: []const u8) []u8 { @memcpy(p[0..k.*], src[0..k.*]); k.* += 4; return p[0..k.*]; }
        \\fn fielded(p: []u8, cur: *Cursor, src: []const u8) []u8 { @memcpy(p[0..cur.n], src[0..cur.n]); cur.n += 4; return p[0..cur.n]; }
        \\fn fixed(p: []u8, k: usize, src: []const u8) []u8 { const n = k; @memcpy(p[0..n], src[0..n]); return p[0..n]; }
        \\const Block = struct { pub const length = 4; };
        \\pub fn a1() u8 { var buf: [8]u8 = undefined; return deferred(&buf); }
        \\pub fn a2() u8 { var buf: [8]u8 = undefined; return first(&buf); }
        \\pub fn a3(src: []const u8) u8 { var buf: [16]u8 = undefined; var k: usize = 4; return pointed(&buf, &k, src)[7]; }
        \\pub fn a4(src: []const u8) u8 { var buf: [16]u8 = undefined; var cur: Cursor = .{ .n = 4 }; return fielded(&buf, &cur, src)[7]; }
        \\fn named(p: []u8, src: []const u8) []u8 { @memcpy(p[0..Block.length], src[0..Block.length]); return p[0..Block.length]; }
        \\pub fn a5(src: []const u8) u8 { var buf: [16]u8 = undefined; return fixed(&buf, 4, src)[0] + named(&buf, src)[0]; }
        \\pub fn k1(rounds: usize) u8 { var n: usize = 0; var last: u8 = 0; for (0..rounds) |_| { var buf: [8]u8 = undefined; buf[n] = 7; n += 1; last = sink(buf[0..n]); } return last; }
        \\pub fn k2(rounds: usize) u8 { var buf: [8]u8 = undefined; var n: usize = 0; var last: u8 = 0; for (0..rounds) |_| { if (n == buf.len) break; buf[n] = 7; n += 1; last = sink(buf[0..n]); } return last; }
    );
    try std.testing.expectEqualSlices(u32, &.{ 9, 11, 12, 15 }, found.lines[0..found.findings]);
}

test "A019 reads what a C call writes by its contract: the error number it answers, the size and type it writes, every alternative's failures" {
    // Clean: posix_spawn's pid where its answer is 0 (5), the buffer's own size (9), a status
    // of std's own type (13), a fill whose failure is returned (18). Findings: the externs
    // (2, 10, 12), pid where `errno(rc)`, which reads only -1, says success (3, 4), the spawn
    // attributes alike (6), a size short of the buffer (7), a size reassigned before the test
    // (8), a buffer wider than the status written (11), a per-build choice of fills where the
    // one this build takes can fail, its error dropped (17).
    const found = try run(pack.unsafe_set,
        \\const std = @import("std");
        \\extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
        \\pub fn e1(argv: [*:null]const ?[*:0]const u8) std.c.pid_t { var pid: std.c.pid_t = undefined; const rc = std.c.posix_spawn(&pid, "/bin/true", null, null, argv, argv); if (std.c.errno(rc) != .SUCCESS) return -1; return pid; }
        \\pub fn e2(argv: [*:null]const ?[*:0]const u8) std.c.pid_t { var pid: std.c.pid_t = undefined; const rc = std.c.posix_spawn(&pid, "/bin/true", null, null, argv, argv); switch (std.c.errno(rc)) { .SUCCESS => return pid, else => return -1 } }
        \\pub fn e3(argv: [*:null]const ?[*:0]const u8) std.c.pid_t { var pid: std.c.pid_t = undefined; const rc = std.c.posix_spawn(&pid, "/bin/true", null, null, argv, argv); if (rc != 0) return -1; return pid; }
        \\pub fn e4() ?std.c.posix_spawnattr_t { var a: std.c.posix_spawnattr_t = undefined; if (std.c.errno(std.c.posix_spawnattr_init(&a)) != .SUCCESS) return null; return a; }
        \\pub fn z1(pid: c_int) u8 { var buf: [64]u8 = undefined; const rc = proc_pidinfo(pid, 3, 0, &buf, 8); if (rc != 8) return 0; return buf[63]; }
        \\pub fn z2(pid: c_int) u8 { var buf: [64]u8 = undefined; var size: c_int = 64; const rc = proc_pidinfo(pid, 3, 0, &buf, size); size = 0; if (rc != size) return 0; return buf[63]; }
        \\pub fn z3(pid: c_int) u8 { var buf: [64]u8 = undefined; const rc = proc_pidinfo(pid, 3, 0, &buf, 64); if (rc != 64) return 0; return buf[63]; }
        \\extern "c" fn fstat(fd: c_int, buf: *[4096]u8) c_int;
        \\pub fn t1(fd: c_int) u8 { var buf: [4096]u8 = undefined; if (fstat(fd, &buf) != 0) return 0; return buf[4095]; }
        \\extern "c" fn @"fstat$INODE64"(fd: c_int, buf: *std.c.Stat) c_int;
        \\pub fn t2(fd: c_int) u64 { var st: std.c.Stat = undefined; if (@"fstat$INODE64"(fd, &st) != 0) return 0; return st.ino; }
        \\const builtin = @import("builtin");
        \\const Src = if (builtin.os.tag == .windows) std.Io else *std.Io.Reader;
        \\const fill = if (builtin.os.tag == .windows) std.Io.random else std.Io.Reader.readSliceAll;
        \\pub fn c1(src: Src) u8 { var buf: [16]u8 = undefined; fill(src, &buf) catch {}; return buf[15]; }
        \\pub fn c2(src: *std.Io.Reader) !u8 { var buf: [16]u8 = undefined; try std.Io.Reader.readSliceAll(src, &buf); return buf[15]; }
    );
    try std.testing.expectEqualSlices(u32, &.{ 2, 3, 4, 6, 7, 8, 10, 11, 12, 17 }, found.lines[0..found.findings]);
}

test "A019 clears std's prefix keeps, an HMAC's fills, a count a call returns in place, and the program's functions that return only parts they wrote" {
    // Clean: the program's writers of a part returned as written (9, 10, 11), std's keeps
    // returning what they fill (15, 17), an HMAC's final and create (18, 19), a count a call
    // returns read in place (20). Findings: past the part written (12), a bound assigned
    // between (13), a part written on one path (14), a keep's buffer read (16), past the
    // count (21).
    const found = try run(pack.unsafe_set,
        \\const std = @import("std");
        \\fn use(b: []const u8) void { _ = b; }
        \\fn four(v4: [4]u8, buf: *[16]u8) []const u8 { buf[0..4].* = v4; return buf[0..4]; }
        \\fn whole(v: [16]u8, buf: *[16]u8) []const u8 { buf.* = v; return buf[0..8]; }
        \\fn copied(name: []const u8, out: *[64]u8) []const u8 { if (name.len > out.len) return name; @memcpy(out[0..name.len], name); return out[0..name.len]; }
        \\fn past(v4: [4]u8, buf: *[16]u8) []const u8 { buf[0..4].* = v4; return buf[0..8]; }
        \\fn moved(src: []const u8, out: *[64]u8) []const u8 { var k = src.len; @memcpy(out[0..k], src); k += 1; return out[0..k]; }
        \\fn sometimes(v4: [4]u8, buf: *[16]u8, ok: bool) []const u8 { if (ok) buf[0..4].* = v4; return buf[0..4]; }
        \\pub fn p1(v4: [4]u8) void { var b: [16]u8 = undefined; use(four(v4, &b)); }
        \\pub fn p2(v: [16]u8) void { var b: [16]u8 = undefined; use(whole(v, &b)); }
        \\pub fn p3(s: []const u8) void { var b: [64]u8 = undefined; use(copied(s, &b)); }
        \\pub fn p4(v4: [4]u8) void { var b: [16]u8 = undefined; use(past(v4, &b)); }
        \\pub fn p5(s: []const u8) void { var b: [64]u8 = undefined; use(moved(s, &b)); }
        \\pub fn p6(v4: [4]u8, ok: bool) void { var b: [16]u8 = undefined; use(sometimes(v4, &b, ok)); }
        \\pub fn s1(s: []const u8) void { var b: [64]u8 = undefined; use(std.ascii.lowerString(&b, s)); }
        \\pub fn s2(s: []const u8) u8 { var b: [64]u8 = undefined; _ = std.ascii.lowerString(&b, s); return b[0]; }
        \\pub fn s3(s: []const u8) void { var b: [64]u8 = undefined; use(std.base64.standard.Encoder.encode(&b, s)); }
        \\pub fn h1(m: []const u8) [32]u8 { var out: [32]u8 = undefined; var h = std.crypto.auth.hmac.sha2.HmacSha256.init(m); h.final(&out); return out; }
        \\pub fn h2(m: []const u8) [32]u8 { var out: [32]u8 = undefined; std.crypto.auth.hmac.sha2.HmacSha256.create(&out, m, m); return out; }
        \\pub fn n1() void { var b: [20]u8 = undefined; use(b[0..std.fmt.printInt(&b, 7, 10, 0, .{})]); }
        \\pub fn n2() void { var b: [20]u8 = undefined; use(b[0 .. std.fmt.printInt(&b, 7, 10, 0, .{}) + 1]); }
    );
    try std.testing.expectEqualSlices(u32, &.{ 12, 13, 14, 16, 21 }, found.lines[0..found.findings]);
}

test "A019 reads all of a local through asBytes, a for setting each element after what neither reads it nor leaves, a vector's one buffer, and a prefix read by the count that wrote it" {
    // Clean: asBytes(&h) filled under `catch return` (6), each element set after a statement
    // that does not read it, a member's name like the capture's (8, 9), a buffer kept by a
    // vectored read and read to its count, also with `catch 0` (12, 13), kept and not read
    // (14), std's lockStderr keeping one (16), readLink's count (18). Findings: asBytes(&h)
    // whose failure goes on (7), a pass that may leave first (10), an element read before it
    // is set (11), a count a failure makes 16 (15), past the count (19), lockStderr's buffer
    // read (17), two buffers in the vector (20).
    const found = try run(pack.unsafe_set,
        \\const std = @import("std");
        \\const Header = extern struct { runs: u64, pcs: u64 };
        \\const Definition = struct { id: u32 };
        \\const Rule = struct { definition: Definition };
        \\fn use(bytes: []const u8) void { _ = bytes; }
        \\pub fn a1(r: *std.Io.Reader) u64 { var h: Header = undefined; r.readSliceAll(std.mem.asBytes(&h)) catch return 0; return h.runs; }
        \\pub fn a2(r: *std.Io.Reader) u64 { var h: Header = undefined; r.readSliceAll(std.mem.asBytes(&h)) catch {}; return h.runs; }
        \\pub fn f1(src: [4]Rule) [4]Definition { var out: [4]Definition = undefined; for (src, &out) |rule, *definition| definition.* = rule.definition; return out; }
        \\pub fn f2(src: [4]Rule) [4]Definition { var out: [4]Definition = undefined; for (src, &out) |rule, *slot| { const d = rule.definition; slot.* = d; } return out; }
        \\pub fn f3(src: [4]Rule) [4]Definition { var out: [4]Definition = undefined; for (src, &out) |rule, *slot| { if (rule.definition.id == 0) continue; slot.* = rule.definition; } return out; }
        \\pub fn f4(src: [4]u32) [4]u32 { var out: [4]u32 = undefined; for (src, &out) |v, *slot| { const old = slot.*; slot.* = v + old; } return out; }
        \\pub fn v1(f: std.Io.File, io: std.Io) !void { var buf: [8]u8 = undefined; const n = try f.readStreaming(io, &.{&buf}); use(buf[0..n]); }
        \\pub fn v2(f: std.Io.File, io: std.Io) void { var buf: [8]u8 = undefined; const n = f.readStreaming(io, &.{&buf}) catch 0; use(buf[0..n]); }
        \\pub fn v3(f: std.Io.File, io: std.Io) void { var buf: [8]u8 = undefined; _ = f.readStreaming(io, &.{&buf}) catch {}; }
        \\pub fn v4(f: std.Io.File, io: std.Io) void { var buf: [8]u8 = undefined; const n = f.readStreaming(io, &.{&buf}) catch 16; use(buf[0..n]); }
        \\pub fn k1() void { var buf: [8]u8 = undefined; std.debug.lockStderr(&buf); }
        \\pub fn k2() u8 { var buf: [8]u8 = undefined; std.debug.lockStderr(&buf); return buf[0]; }
        \\pub fn l1(d: std.Io.Dir, io: std.Io) !void { var t: [8]u8 = undefined; const len = try d.readLink(io, "x", &t); use(t[0..len]); }
        \\pub fn l2(d: std.Io.Dir, io: std.Io) !void { var t: [8]u8 = undefined; const len = try d.readLink(io, "x", &t); use(t[0 .. len + 1]); }
        \\pub fn w2(f: std.Io.File, io: std.Io) void { var a: [8]u8 = undefined; var b: [8]u8 = undefined; const n = f.readStreaming(io, &.{ &a, &b }) catch 0; use(a[0..n]); }
    );
    try std.testing.expectEqualSlices(u32, &.{ 7, 10, 11, 15, 17, 19, 20 }, found.lines[0..found.findings]);
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
    \\    _ = table[pick(try r.takeByte())];
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

test "A009 finds input that indexes or slices input, names a path, a byte or number that picks an entry of a table of unknown length, and a number that bounds a loop; it leaves clean, fixed and refined values" {
    // The bytes `table[n]`, `table[0..len]` and `table[pick(n)]` choose: `table`'s length is
    // the caller's, which nothing here shows holds a byte.
    try expect(pack.untrusted_input, input_program, 9);
}

test "A009's input is a child's output and a file's contents, aegis's whole-file read's too, never the path or allocator a read is given; an escape on a read's line makes it no less input" {
    const program =
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\pub fn load(dir: std.Io.Dir, gpa: std.mem.Allocator, table: []const u8, name: []const u8) !u8 {
        \\    const whole = try aegis.own.readFile(null, dir, name, gpa, .fromRaw(100));
        \\    _ = whole[whole[0]];
        \\    const bytes = try dir.readFileAlloc(null, name, gpa, 100);
        \\    const mine = try dir.readFileAlloc(null, "receipt", gpa, 100); // aegis: internal(A009): the receipt this program wrote
        \\    const out = try std.process.run(gpa, null, .{});
        \\    _ = table[name[0]];
        \\    _ = mine[mine[0]];
        \\    _ = bytes[bytes[0]];
        \\    return out.stdout[out.stdout[0]];
        \\}
    ;
    try expect(pack.untrusted_input, program, 4);
    var project = try sources.projectWithSources(std.testing.allocator, program, &std_files, &std_imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.untrusted_input, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    // The escape covers nothing on its own line: it is stale, and the use below is a finding.
    try std.testing.expectEqual(@as(usize, 0), report.escapes.len); // safe: fixture counts are representable.
    try std.testing.expectEqual(@as(usize, 1), report.stale.len); // safe: fixture counts are representable.
}

test "every flow rule reads what an escaped read gives as input in each function it reaches" {
    // The review's probe: one escape on a peer's read, and the index, the conversion, the
    // allocation and the loop it feeds in other functions.
    const program =
        \\const std = @import("std");
        \\fn header(r: *std.Io.Reader) !u32 {
        \\    return r.takeInt(u32, .little); // aegis: no-danger(A009): probe
        \\}
        \\pub fn index(r: *std.Io.Reader, table: []const u8) !u8 {
        \\    const n: usize = try header(r);
        \\    return table[n];
        \\}
        \\pub fn cast(r: *std.Io.Reader) !u8 {
        \\    return @intCast(try header(r));
        \\}
        \\pub fn alloc(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
        \\    return gpa.alloc(u8, try header(r));
        \\}
        \\pub fn spin(r: *std.Io.Reader) !u64 {
        \\    var t: u64 = 0;
        \\    var i: u32 = 0;
        \\    const n = try header(r);
        \\    while (i < n) : (i += 1) t +%= i;
        \\    return t;
        \\}
    ;
    const indexed = try run(pack.untrusted_input, program);
    try std.testing.expectEqualSlices(u32, &.{ 7, 19 }, indexed.lines[0..indexed.findings]);
    const converted = try run(pack.integers, program);
    try std.testing.expectEqualSlices(u32, &.{10}, converted.lines[0..converted.findings]);
    const allocated = try run(pack.bounded_work, program);
    try std.testing.expectEqualSlices(u32, &.{13}, allocated.lines[0..allocated.findings]);
}

test "positions std finds in input, a read's count and a value under a length stay within their memory; a number assembled by hand is a number, and a 16-bit decode is data" {
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

test "A010 finds arithmetic on input that may overflow its type: a byte's sum and product as a number's" {
    // `n + 1` and `len * 2` on a byte stop at 255 and 128; `count + 1` at the u32's top; the
    // return adds `part.len`, a length the peer's byte chose, to a sum past the table's length.
    try expect(pack.integers, input_program, 4);
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
        \\    var total: u64 = try r.takeInt(u64, 0);
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

test "A009 reads a while condition by what decides it, as A020 does: a variable by each value it is given, a payload as a number, in a helper given no Io" {
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn task(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    try io.checkCancel();
        \\    return try laundered(r) +% try payload(r);
        \\}
        \\fn laundered(r: *std.Io.Reader) !u64 {
        \\    const seed = try r.takeInt(u64, .little);
        \\    var total: u64 = 0;
        \\    var more = true;
        \\    while (more) {
        \\        total +%= 1;
        \\        more = total != seed;
        \\    }
        \\    return total;
        \\}
        \\fn payload(r: *std.Io.Reader) !u64 {
        \\    var left: ?u32 = try r.takeInt(u32, .little);
        \\    var total: u64 = 0;
        \\    while (left) |n| {
        \\        total +%= n;
        \\        left = if (n == 0) null else n - 1;
        \\    }
        \\    return total;
        \\}
    , 3);
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn task(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    try io.checkCancel();
        \\    return try laundered(r) +% try payload(r);
        \\}
        \\fn laundered(r: *std.Io.Reader) !u64 {
        \\    const seed = try r.takeInt(u16, .little);
        \\    var total: u64 = 0;
        \\    var more = true;
        \\    while (more) {
        \\        total +%= 1;
        \\        more = total != seed;
        \\    }
        \\    return total;
        \\}
        \\fn payload(r: *std.Io.Reader) !u64 {
        \\    var left: ?u16 = try r.takeInt(u16, .little);
        \\    var total: u64 = 0;
        \\    while (left) |n| {
        \\        total +%= n;
        \\        left = if (n == 0) null else n - 1;
        \\    }
        \\    return total;
        \\}
    , 0);
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

test "A009 reads a fixed array's length check where the position has no numeric bound: an enum's backing integer checked against the array is within; unchecked, or checked against another array, it is not" {
    // `@backingInt` of a non-exhaustive enum gives Range no bound; the check on line 8 is
    // what keeps line 9. Findings: unchecked (12) and checked against `wide` (17).
    const found = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\const Rule = enum(u16) { a, b, _ };
        \\const Config = struct {
        \\    enabled: [64]bool = @splat(false),
        \\    wide: [128]bool = @splat(false),
        \\    fn has(self: Config, rule: Rule) bool {
        \\        const index = @backingInt(rule);
        \\        if (index >= self.enabled.len) return false;
        \\        return self.enabled[index];
        \\    }
        \\    fn raw(self: Config, rule: Rule) bool {
        \\        return self.enabled[@backingInt(rule)];
        \\    }
        \\    fn other(self: Config, rule: Rule) bool {
        \\        const index = @backingInt(rule);
        \\        if (index >= self.wide.len) return false;
        \\        return self.enabled[index];
        \\    }
        \\};
        \\pub fn f(r: *std.Io.Reader) !bool {
        \\    const c: Config = .{};
        \\    const rule: Rule = @enumFromInt(try r.takeInt(u16, .little));
        \\    return c.has(rule) and c.raw(rule) and c.other(rule);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 2), found.findings);
    try std.testing.expectEqualSlices(u32, &.{ 12, 17 }, found.lines[0..2]);
}

test "A009 reads a vectored read's buffers as input: each one the vector names, given in place, held in a local, or a parameter the caller fills" {
    // Input reaches buf (line 5), more through a named part in a local vector (10) and the
    // caller's own (21); clean (13) is never read into, and a value printed in a tuple (12) is
    // a copy the call does not write.
    const found = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(io: std.Io, file: std.Io.File, w: *std.Io.Writer) !u8 {
        \\    var buf: [8]u8 = undefined;
        \\    _ = try file.readStreaming(io, &.{&buf});
        \\    var sum = buf[buf[0]];
        \\    var more: [8]u8 = undefined;
        \\    const part: []u8 = more[0..];
        \\    var vec = [_][]u8{part};
        \\    _ = try file.readPositional(io, &vec, 0);
        \\    sum +%= more[more[1]];
        \\    const clean: [8]u8 = @splat(0);
        \\    try w.print("{d}{d}", .{ clean[0], buf[1] });
        \\    return sum +% clean[clean[0]];
        \\}
        \\fn into(io: std.Io, file: std.Io.File, out: []u8) !void {
        \\    _ = try file.readStreaming(io, &.{ out[0..1], out[1..] });
        \\}
        \\pub fn g(io: std.Io, file: std.Io.File) !u8 {
        \\    var own: [8]u8 = undefined;
        \\    try into(io, file, &own);
        \\    return own[own[0]];
        \\}
    );
    try std.testing.expectEqual(@as(usize, 3), found.findings);
    try std.testing.expectEqualSlices(u32, &.{ 5, 10, 21 }, found.lines[0..3]);
}

test "A009 gives no bound where an integer type's width overflows Range's own arithmetic: a `u65535` beside a signed peer is read, not a panic" {
    // Before the width was added checked, reading `wide + narrow` overflowed a u16 in glint.
    // The type is then unknown, so the position is not shown within: a finding (line 7).
    const found = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !u8 {
        \\    var buf: [8]u8 = undefined;
        \\    _ = try r.readSliceShort(&buf);
        \\    const wide: u65535 = 1;
        \\    const narrow: i8 = @bitCast(buf[1]);
        \\    return buf[wide + narrow];
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), found.findings);
    try std.testing.expectEqual(@as(u32, 7), found.lines[0]);
}

test "A009 trusts a table's own id by its type, and reports each id made from an integer that does not count the table's entries" {
    // A table's own id indexes and slices it (lines 8-10); ids counted over it (13) or its
    // length less one after an append (23) are made. Findings: an id made from input (18), a
    // constant (19), a counter over another table (21), input made another element's id (25)
    // indexing this table (26), an id with a named value (27), an id declared outside its
    // element (28), arithmetic on an id (29), and the length itself, one past the end (31).
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\const Entry = struct { name: u8, pub const Id = enum(u32) { _ }; };
        \\const Other = struct { name: u8, pub const Id = enum(u32) { _ }; };
        \\const Named = struct { name: u8, pub const Id = enum(u32) { first, _ }; };
        \\const LooseId = enum(u32) { _ };
        \\const Table = struct {
        \\    entries: []Entry, others: []Other, named: []Named, list: std.ArrayList(Entry),
        \\    fn at(t: *const Table, id: Entry.Id) u8 { return t.entries[@backingInt(id)].name; }
        \\    fn slice(t: *const Table, id: Entry.Id) []Entry { return t.entries[0..@backingInt(id)]; }
        \\    fn range(t: *const Table, id: Entry.Id) []Entry { return t.entries[@backingInt(id)..]; }
        \\    fn total(t: *const Table) u8 {
        \\        var sum: u8 = 0;
        \\        for (t.entries, 0..) |_, i| sum +%= t.at(@fromBackingInt(@intCast(i)));
        \\        return sum;
        \\    }
        \\};
        \\pub fn f(r: *std.Io.Reader, t: *Table) !u8 {
        \\    const peer: Entry.Id = @fromBackingInt(try r.takeInt(u32, 0));
        \\    const fixed: Entry.Id = @fromBackingInt(7);
        \\    var sum: u8 = t.at(peer) +% t.at(fixed) +% t.total();
        \\    for (t.others, 0..) |_, i| sum +%= t.at(@fromBackingInt(@intCast(i)));
        \\    try t.list.append(.{ .name = 1 });
        \\    const added: Entry.Id = @fromBackingInt(@intCast(t.list.items.len - 1));
        \\    sum +%= t.at(added);
        \\    const other_id: Other.Id = @fromBackingInt(try r.takeInt(u32, 0));
        \\    sum +%= t.entries[@backingInt(other_id)].name;
        \\    sum +%= t.named[@backingInt(@as(Named.Id, @fromBackingInt(try r.takeInt(u32, 0))))].name;
        \\    sum +%= t.entries[@backingInt(@as(LooseId, @fromBackingInt(try r.takeInt(u32, 0))))].name;
        \\    sum +%= t.entries[@backingInt(peer) + 1].name;
        \\    _ = t.slice(peer).len + t.range(peer).len;
        \\    return sum +% t.at(@fromBackingInt(@intCast(t.entries.len)));
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 18, 19, 21, 25, 26, 27, 28, 29, 31 }, result.lines[0..result.findings]);
}

/// `run` with `other.zig`, a file of the program the selection leaves out, imported by path.
fn runWithOther(rule: glint.Rule, program: []const u8, other: []const u8) !Run {
    const file: sources.Extra = .{ .name = "other.zig", .bytes = other };
    return runWith(rule, program, &(std_files ++ [_]sources.Extra{file}), &(std_imports ++ [_]sources.ExtraImport{.{ .spelling = "other.zig", .target = std_files.len }}));
}

test "A009 and A010 read every file of the program, selected or not: a table's own id another file declares, a store another file makes" {
    // A conversion to a type that does not resolve may make a table's own id only where some
    // file of the program declares one: `other.zig` does, outside the selection.
    const made =
        \\const std = @import("std");
        \\const other = @import("other.zig");
        \\const gone = @import("gone");
        \\pub fn f(r: *std.Io.Reader) !u32 {
        \\    const id: gone.Id = @fromBackingInt(try r.takeInt(u32, 0));
        \\    _ = other;
        \\    return @backingInt(id);
        \\}
    ;
    const declared = try runWithOther(pack.untrusted_input, made,
        \\pub const Entry = struct { name: u8, pub const Id = enum(u32) { _ }; };
        \\pub const Table = struct {
        \\    entries: []Entry,
        \\    pub fn at(t: *const Table, id: Entry.Id) u8 { return t.entries[@backingInt(id)].name; }
        \\};
    );
    try std.testing.expectEqual(@as(usize, 1), declared.undecided);
    const none = try runWithOther(pack.untrusted_input, made, "pub const Entry = struct { name: u8 };");
    try std.testing.expectEqual(@as(usize, 0), none.undecided);
    // A field holds at most what every store in the program gives it: 100 in the selected
    // file, so a decoded u32 and it fit a u64, and a u64 from input `other.zig` stores (line 6).
    const stored =
        \\const std = @import("std");
        \\const other = @import("other.zig");
        \\pub const Config = struct { limit: u64 = 0 };
        \\pub fn f(r: *std.Io.Reader, c: *Config) !u64 {
        \\    c.limit = 100;
        \\    other.touch(c);
        \\    const n: u64 = try r.takeInt(u32, 0);
        \\    return n + c.limit;
        \\}
    ;
    const kept = try runWithOther(pack.integers, stored, "pub fn touch(c: anytype) void { c.limit = 7; }");
    try std.testing.expectEqual(@as(usize, 0), kept.findings);
    const widened = try runWithOther(pack.integers, stored, "const std = @import(\"std\");\npub fn touch(c: anytype, r: *std.Io.Reader) void { c.limit = r.takeInt(u64, 0) catch 0; }");
    try std.testing.expectEqualSlices(u32, &.{8}, widened.lines[0..widened.findings]);
}

test "A009 reads a for capture as the input at its own position, a discarded capture counted" {
    // The counter beside the peer's bytes indexes the buffer (line 5); what the peer's bytes
    // give does not, though the capture before it is discarded (line 6): it is no counter, and
    // its value is the peer's.
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
        \\    const peer = try r.take(4);
        \\    var sum: u8 = 0;
        \\    for (0..buf.len, peer) |i, _| sum +%= buf[i];
        \\    for (0..buf.len, peer) |_, v| sum +%= buf[v];
        \\    return sum;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{6}, result.lines[0..result.findings]);
}

test "A009 holds what an aegis function other than a parse gives at the fact it was given: a conversion, a checked sum and an id's integer stay the peer's" {
    // The peer's value through int.cast (line 6), a checked sum (7) and an id made and read
    // back (8) indexes a table no longer than a byte; the program's own value through them
    // (9) does not.
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\const Slot = aegis.id.Id(struct {}, u32);
        \\pub fn f(r: *std.Io.Reader, table: []const u8, own: u32) !u8 {
        \\    const peer = try r.takeInt(u32, .little);
        \\    var sum: u8 = table[try aegis.int.cast(u8, peer)];
        \\    sum +%= table[(try aegis.int.Checked(u32).init(peer).add(1)).raw()];
        \\    sum +%= table[Slot.fromRaw(peer).raw()];
        \\    sum +%= table[Slot.fromRaw(own % @as(u32, @intCast(table.len))).raw()];
        \\    return sum;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 6, 7, 8 }, result.lines[0..result.findings]);
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
        \\    const m = try r.takeInt(u32, 0);
        \\    for (0..m) |_| {}
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

test "A012 reads a length that views a slice std holds as no work: what is done over the view is sized by memory already there" {
    // std's `slice` views its declared slice (clean); `raw` views a many-item pointer, which
    // no length check bounds (6).
    const held: sources.Extra = .{ .name = "std/held.zig", .bytes =
        \\pub const Held = struct {
        \\    extra: []u32,
        \\    many: [*]u32,
        \\    pub fn slice(h: Held, start: usize, len: usize) []u32 { return h.extra[start..][0..len]; }
        \\    pub fn raw(h: Held, len: usize) []u32 { return h.many[0..][0..len]; }
        \\};
    };
    const found = try runWith(pack.bounded_work,
        \\const std = @import("std");
        \\const held = @import("held.zig");
        \\pub fn f(r: *std.Io.Reader, h: held.Held) !usize {
        \\    const n = try r.takeInt(u32, .little);
        \\    const viewed = h.slice(0, n).len;
        \\    return viewed + h.raw(n).len;
        \\}
    , &(std_files ++ [_]sources.Extra{held}), &(std_imports ++ [_]sources.ExtraImport{ .{ .from = 0, .spelling = "held.zig", .target = std_files.len }, .{ .spelling = "held.zig", .target = std_files.len } }));
    try std.testing.expectEqualSlices(u32, &.{6}, found.lines[0..found.findings]);
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

test "A018 reads a peer writer a package declares as one wherever it is declared, its body the program's or not" {
    // Declared in the selected file, and in `wire.zig`, of the package and outside the
    // selection: each is a peer writer when the configuration names it, and nothing else.
    const wire: sources.Extra = .{ .name = "wire.zig", .package = "pkg", .bytes = "const std = @import(\"std\");\npub fn peer(buffer: []u8) std.Io.Writer { return std.Io.protocolWriter(buffer); }" };
    const programs = [_][]const u8{
        \\const std = @import("std");
        \\pub fn peer(buffer: []u8) std.Io.Writer { return std.Io.protocolWriter(buffer); }
        \\pub fn reply(err: anyerror) !void {
        \\    var buf: [64]u8 = undefined;
        \\    var w = peer(&buf);
        \\    try w.print("{s}", .{@errorName(err)});
        \\}
        ,
        \\const wire = @import("wire.zig");
        \\pub fn reply(err: anyerror) !void {
        \\    var buf: [64]u8 = undefined;
        \\    var w = wire.peer(&buf);
        \\    try w.print("{s}", .{@errorName(err)});
        \\}
    };
    for (programs) |program| {
        var project = try sources.projectInPackage(std.testing.allocator, program, "pkg", &(std_files ++ [_]sources.Extra{wire}), &(std_imports ++ [_]sources.ExtraImport{ .{ .spelling = "wire.zig", .target = std_files.len }, .{ .from = std_files.len, .spelling = "std", .target = 0 } }));
        defer project.deinit();
        const declared = [_]glint.Config.PeerWriter{.{ .module = "pkg", .declaration = "peer" }};
        for ([_]usize{ 0, 1 }) |given| {
            var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.diagnostics, .level = .report }}, .peer_writers = declared[0..given] }, .{ .project_rules = &pack.rules });
            defer report.deinit();
            try std.testing.expectEqual(given, report.diagnostics.len);
        }
    }
}

test "A020 finds a loop on input or without bound that gives its Io to nothing, or drops the cancel it checks for" {
    // `quiet` leaves on a cancel but hands its caller no error.Canceled: the task runs on.
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\pub fn serve(io: std.Io, r: *std.Io.Reader) void { _ = io; while (true) { _ = r.takeByte() catch return; } }
        \\pub fn polite(io: std.Io, r: *std.Io.Reader) !void { while (true) { try io.checkCancel(); _ = r.takeByte() catch return; } }
        \\pub fn quiet(io: std.Io, r: *std.Io.Reader) void { while (true) { io.checkCancel() catch return; _ = r.takeByte() catch return; } }
        \\pub fn counted(io: std.Io, r: *std.Io.Reader) void { const n = r.takeInt(u32, 0) catch return; var i: u32 = 0; while (i < n) : (i += 1) {} _ = io; }
        \\pub fn plain(io: std.Io) void { var i: u8 = 0; while (i < 10) : (i += 1) {} _ = io; }
    , 3);
}

/// `program` after the fixes of `rule`'s findings and its stale escapes.
fn fixed(rule: glint.Rule, program: []const u8) ![]u8 {
    var project = try sources.projectWithSources(std.testing.allocator, program, &std_files, &std_imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const changed = try glint.Fix.apply(arena.allocator(), &project, &report, .{});
    if (changed.len == 0) return std.testing.allocator.dupe(u8, program);
    return std.testing.allocator.dupe(u8, changed[0].bytes);
}

/// `program` after the fixes of a run of `rules`, with the escapes a run before reported, and
/// that run's report.
fn fixedBy(rules: []const glint.Rule, program: []const u8, record: []const u8) !struct { bytes: []u8, stale: usize } {
    var project = try sources.projectWithSources(std.testing.allocator, program, &std_files, &std_imports);
    defer project.deinit();
    var selections: [8]glint.Config.Selection = undefined;
    for (rules, 0..) |rule, i| selections[i] = .{ .rule = rule, .level = .gate };
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = selections[0..rules.len] }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = try glint.Fix.escapeRecord(arena.allocator(), record);
    const changed = try glint.Fix.apply(arena.allocator(), &project, &report, .{ .escapes_before = before });
    const bytes = if (changed.len == 0) program else changed[0].bytes;
    return .{ .bytes = try std.testing.allocator.dupe(u8, bytes), .stale = report.stale.len };
}

test "the fix names an escape in the older form only where a run before recorded it at that place with those words, with the rules it covered then that find something now, and keeps an escape whose rules did not run" {
    const older =
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, table: []const u8) !u8 {
        \\    const x = try r.takeInt(i64, .little);
        \\    return table[@intCast(x)]; // aegis: no-danger: probe
        \\}
        \\
    ;
    const both: []const glint.Rule = &.{ pack.untrusted_input, pack.integers };
    // A009 and A010 both find something on the line; the record holds A010 only, so A009, new
    // since, is left to the owner.
    {
        const out = try fixedBy(both, older, "glint: escape: consumer:4:32: no-danger: probe (A010)\nglint: 3 files\n");
        defer std.testing.allocator.free(out.bytes);
        try std.testing.expect(std.mem.find(u8, out.bytes, "// aegis: no-danger(A010): probe") != null);
    }
    {
        const out = try fixedBy(both, older, "escape: consumer:4:32: no-danger: probe (A009 at 4:18, A010 at 4:18, A013 at 4:5)\n");
        defer std.testing.allocator.free(out.bytes);
        try std.testing.expect(std.mem.find(u8, out.bytes, "// aegis: no-danger(A009, A010): probe") != null);
    }
    // No record of the escape, or one of another line, column or words (moved or reworded
    // since), or of rules that find nothing now, or a line in another form that names it:
    // nothing is written, and the escape stays for its owner to name.
    inline for (.{
        "",
        "glint: escape: consumer:9:32: no-danger: probe (A010)\n",
        "glint: escape: consumer:4:30: no-danger: probe (A010)\n",
        "glint: escape: consumer:4:32: design: probe (A010)\n",
        "glint: escape: consumer:4:32: no-danger: probe two (A010)\n",
        "glint: escape: consumer:4:32: no-danger: probe (A013)\n",
        "note: escape: consumer:4:32: no-danger: probe (A010)\n",
        "glint: A010: consumer:4:18: see escape: consumer:4:32: no-danger: probe (A010)\n",
    }) |record| {
        const out = try fixedBy(both, older, record);
        defer std.testing.allocator.free(out.bytes);
        try std.testing.expectEqualStrings(older, out.bytes);
    }
    // A line in the record's form that is no escape's whole record is refused, not guessed at.
    var records = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer records.deinit();
    inline for (.{
        "escape: consumer:4: no-danger: probe (A010)\n",
        "escape: consumer:4:32: no-danger probe (A010)\n",
        "glint: escape: consumer:4:32: no-danger: probe (A010\n",
        "escape: consumer:4:32: no-danger: probe (A010 near 4:18)\n",
        "escape: consumer:x:32: no-danger: probe (A010)\n",
    }) |record| try std.testing.expectError(error.InvalidEscapeRecord, glint.Fix.escapeRecord(records.allocator(), record));
    // An escape is stale only where every rule it names ran: a run of A009 alone keeps an
    // escape naming A010, and one naming A009 and A010.
    inline for (.{ "no-danger(A010)", "no-danger(A009, A013)" }) |escape| {
        const named = "pub fn f() u8 {\n    return 0; // aegis: " ++ escape ++ ": probe\n}\n";
        const out = try fixedBy(&.{pack.untrusted_input}, named, "");
        defer std.testing.allocator.free(out.bytes);
        try std.testing.expectEqual(@as(usize, 0), out.stale);
        try std.testing.expectEqualStrings(named, out.bytes);
    }
    // Where it ran and found nothing, it goes.
    {
        const named = "pub fn f() u8 {\n    return 0; // aegis: no-danger(A010): probe\n}\n";
        const out = try fixedBy(&.{ pack.untrusted_input, pack.integers }, named, "");
        defer std.testing.allocator.free(out.bytes);
        try std.testing.expectEqual(@as(usize, 1), out.stale);
        try std.testing.expect(std.mem.find(u8, out.bytes, "aegis:") == null);
    }
    // A record line that names an escape and is not one is refused.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidEscapeRecord, glint.Fix.escapeRecord(arena.allocator(), "glint: escape: consumer:x:1: no-danger: why (A010)\n"));
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

test "the fix makes the old pack suppression the escape, removes an escape whose rules ran and found nothing, and writes no escape a site did not have" {
    const out = try fixed(pack.unsafe_set,
        \\pub fn f(p: *const u8) *u8 {
        \\    // safe: the caller passes memory it owns
        \\    return @constCast(p);
        \\}
        \\pub fn g() u8 {
        \\    // aegis: no-danger(A019): nothing here any more
        \\    return 1; // aegis: design: nor here
        \\}
        \\pub fn h(p: *const u8) *u8 {
        \\    // glint-ignore: A019 -- c-os-boundary: the kernel's handle
        \\    return @constCast(p);
        \\}
        \\pub fn k(p: *const u8) *u8 {
        \\    return @constCast(p); // aegis: boundary: the kernel's handle
        \\}
    );
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        \\pub fn f(p: *const u8) *u8 {
        \\    // safe: the caller passes memory it owns
        \\    return @constCast(p);
        \\}
        \\pub fn g() u8 {
        \\    return 1; // aegis: design: nor here
        \\}
        \\pub fn h(p: *const u8) *u8 {
        \\    // aegis: boundary(A019): the kernel's handle
        \\    return @constCast(p);
        \\}
        \\pub fn k(p: *const u8) *u8 {
        \\    return @constCast(p); // aegis: boundary: the kernel's handle
        \\}
    , out);
    // An escape in the older form is named only from a record of a run before, and is stale
    // only where the whole pack ran: this run is A019's alone.
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
    // The parsed count (at most 16 bits) picking an entry of a table of unknown length, and
    // the loops the parsed memory's bytes and the direct call's count bound; never the loop the
    // parsed count bounds, through the header it is stored in.
    // Line 10: the bytes the parse counts are 1 or 3 as the peer's first byte picks; the
    // parser's length check is its own, so the slice's start past `in` is the peer's choice here.
    try std.testing.expectEqualSlices(u32, &.{ 10, 16, 21, 26 }, result.lines[0..result.findings]);
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
        \\        in = in[40..];
        \\        return in[ip + 1 ..][0..16][0];
        \\    }
        \\    return 0;
        \\}
        \\pub fn spelled(r: *std.Io.Reader, start: []u8) !u8 {
        \\    var in: []u8 = start;
        \\    const ip: usize = try r.takeInt(u32, 0);
        \\    if (ip <= in.len - 32) {
        \\        in = in[40..];
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

test "A009 reads a truncation and wrapping arithmetic as the peer's number in a wide type, data only where the value is shown small" {
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn wide(r: *std.Io.Reader) !void {
        \\    const big = try r.takeInt(u64, 0);
        \\    var n: u32 = @truncate(big);
        \\    while (n > 0) : (n -= 1) {}
        \\    const a = try r.takeInt(u32, 0);
        \\    var m: u32 = a +% 1;
        \\    while (m > 0) : (m -= 1) {}
        \\}
        \\pub fn small(r: *std.Io.Reader, table: *const [256]u8) !u8 {
        \\    const big = try r.takeInt(u64, 0);
        \\    var n: u8 = @truncate(big);
        \\    while (n > 0) : (n -= 1) {}
        \\    const word = try r.takeInt(u32, 0);
        \\    return table[(word *% 2654435761) >> 24];
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    // The wide truncation's loop and the wrapped sum's; never the byte's, nor the hash shifted to
    // a table's bits.
    try std.testing.expectEqualSlices(u32, &.{ 5, 8 }, result.lines[0..result.findings]);
}

test "A009 reads a parse's number as refined only where its parser compares it or holds it to 16 bits: never for a wider type than its source, nor a tuple's, nor beside another parser" {
    // The review's probes: a `u32` returned as `u64`/`usize` or into a `u64` field, a tuple, and
    // a second parser whose result has no such field.
    const head =
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\const E = error{Short};
        \\
    ;
    inline for (.{
        "fn p(_: void, b: []const u8) E!u64 {\n    if (b.len < 4) return error.Short;\n    return std.mem.readInt(u32, b[0..4], .little);\n}\npub fn f(r: *std.Io.Reader, table: []const u8) !u8 {\n    const n = try aegis.input.Untrusted([]const u8).init(try r.take(4)).parse({}, p);\n    return table[n];\n}\n",
        "const W = struct { count: u64 };\nfn p(_: void, b: []const u8) E!W {\n    if (b.len < 4) return error.Short;\n    return .{ .count = std.mem.readInt(u32, b[0..4], .little) };\n}\npub fn f(r: *std.Io.Reader, table: []const u8) !u8 {\n    const w = try aegis.input.Untrusted([]const u8).init(try r.take(4)).parse({}, p);\n    return table[w.count];\n}\n",
        "const W = struct { count: u64 };\nfn p(_: void, b: []const u8) E!W {\n    if (b.len < 4) return error.Short;\n    const n: u32 = std.mem.readInt(u32, b[0..4], .little);\n    return .{ .count = n };\n}\npub fn f(r: *std.Io.Reader, table: []const u8) !u8 {\n    const w = try aegis.input.Untrusted([]const u8).init(try r.take(4)).parse({}, p);\n    return table[w.count];\n}\n",
        "fn p(_: void, b: []const u8) E!usize {\n    if (b.len < 4) return error.Short;\n    const n: u32 = std.mem.readInt(u32, b[0..4], .little);\n    return n;\n}\npub fn f(r: *std.Io.Reader, table: []const u8) !u8 {\n    const n = try aegis.input.Untrusted([]const u8).init(try r.take(4)).parse({}, p);\n    return table[n];\n}\n",
        "fn p(_: void, b: []const u8) E!struct { u32, u32 } {\n    if (b.len < 8) return error.Short;\n    return .{ std.mem.readInt(u32, b[0..4], .little), std.mem.readInt(u32, b[4..8], .little) };\n}\npub fn f(r: *std.Io.Reader, table: []const u8) !u8 {\n    const t = try aegis.input.Untrusted([]const u8).init(try r.take(8)).parse({}, p);\n    return table[t[0]];\n}\n",
        "const Inner = struct { n: u32 };\nconst Outer = struct { inner: Inner };\nfn p(_: void, b: []const u8) E!Outer {\n    if (b.len < 4) return error.Short;\n    return .{ .inner = .{ .n = std.mem.readInt(u32, b[0..4], .little) } };\n}\nfn q(_: void, b: []const u8) E!?u32 {\n    if (b.len < 4) return error.Short;\n    return std.mem.readInt(u32, b[0..4], .little);\n}\npub fn f(r: *std.Io.Reader, table: []const u8) !u8 {\n    const o = try aegis.input.Untrusted([]const u8).init(try r.take(4)).parse({}, p);\n    return table[o.inner.n];\n}\npub fn other(r: *std.Io.Reader) !?u32 {\n    return try aegis.input.Untrusted([]const u8).init(try r.take(4)).parse({}, q);\n}\n",
    }) |body| expect(pack.untrusted_input, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
    // A count checked below its table, two bytes put together into a wide field, a tuple of
    // bytes: each shown.
    inline for (.{
        "const W = struct { count: u32 };\nfn p(_: void, b: []const u8) E!W {\n    if (b.len < 4) return error.Short;\n    const n = std.mem.readInt(u32, b[0..4], .little);\n    if (n >= 16) return error.Short;\n    return .{ .count = n };\n}\npub fn f(r: *std.Io.Reader, table: *const [16]u8) !u8 {\n    const w = try aegis.input.Untrusted([]const u8).init(try r.take(4)).parse({}, p);\n    return table[w.count];\n}\n",
        "const W = struct { count: u64 };\nfn p(_: void, b: []const u8) E!W {\n    if (b.len < 2) return error.Short;\n    return .{ .count = @as(u16, b[0]) << 8 | b[1] };\n}\npub fn f(r: *std.Io.Reader, table: []const u8) !u8 {\n    const w = try aegis.input.Untrusted([]const u8).init(try r.take(2)).parse({}, p);\n    var n: usize = w.count;\n    while (n > 0) : (n -= 1) {}\n    return table[0];\n}\n",
        "fn p(_: void, b: []const u8) E!struct { u32, u32 } {\n    if (b.len < 2) return error.Short;\n    return .{ b[0], b[1] };\n}\npub fn f(r: *std.Io.Reader) !usize {\n    const t = try aegis.input.Untrusted([]const u8).init(try r.take(2)).parse({}, p);\n    var n: usize = t[0];\n    while (n > 0) : (n -= 1) {}\n    return t[1];\n}\n",
    }) |body| expect(pack.untrusted_input, head ++ body, 0) catch |err| {
        std.debug.print("SAFE<<{s}>>\n", .{body});
        return err;
    };
}

test "A009 clears a pointer moved within its memory only where it is moved forward and read at its first element: what is left past the offset is all the comparison shows" {
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn plus5(r: *std.Io.Reader, out: []u8) !u8 {
        \\    const o: usize = try r.takeInt(u32, .little);
        \\    if (o < out.len) return (out.ptr + o)[5];
        \\    return 0;
        \\}
        \\pub fn copy16(r: *std.Io.Reader, out: []u8, dst: *[16]u8) !void {
        \\    const o: usize = try r.takeInt(u32, .little);
        \\    if (o < out.len) @memcpy(dst, (out.ptr + o)[0..16]);
        \\}
        \\pub fn kept(r: *std.Io.Reader, out: []u8) !u8 {
        \\    const o: usize = try r.takeInt(u32, .little);
        \\    if (o >= out.len) return 0;
        \\    const p = out.ptr + o;
        \\    return p[1];
        \\}
        \\pub fn first(r: *std.Io.Reader, out: []u8) !u8 {
        \\    const o: usize = try r.takeInt(u32, .little);
        \\    if (o < out.len) return (out.ptr + o)[0];
        \\    return 0;
        \\}
        \\pub fn one(r: *std.Io.Reader, out: []u8) ![]u8 {
        \\    const o: usize = try r.takeInt(u32, .little);
        \\    if (o >= out.len) return error.Short;
        \\    return (out.ptr + o)[0..1];
        \\}
        \\pub fn minus(r: *std.Io.Reader, out: []u8) !u8 {
        \\    const o: usize = try r.takeInt(u32, .little);
        \\    if (o < out.len) return (out.ptr - o)[0];
        \\    return 0;
        \\}
        \\pub fn minusWrap(r: *std.Io.Reader, out: []u8) !u8 {
        \\    const o: usize = try r.takeInt(u32, .little);
        \\    if (o < out.len) return (out.ptr -% o)[0];
        \\    return 0;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    // The read five past, the sixteen bytes, the pointer kept, a pointer moved back below the
    // memory whatever its offset is below; never a first element's read past a forward move.
    try std.testing.expectEqualSlices(u32, &.{ 4, 9, 14, 29, 34 }, result.lines[0..result.findings]);
}

test "A009 ends a comparison's fact at a store through another name for its memory: a pointer taken, a method or call given it, a pointer parameter of its type, a value holding it, and memory behind a pointer at any store through one and any call" {
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\const S = struct {
        \\    buf: []u8,
        \\    count: usize = 0,
        \\    other: Inner = .{},
        \\    fn shrink(s: *S) void {
        \\        s.buf = s.buf[16..];
        \\    }
        \\};
        \\const Inner = struct {
        \\    n: usize = 0,
        \\    fn bump(i: *Inner) void {
        \\        i.n += 1;
        \\    }
        \\};
        \\fn cut(s: *S) void {
        \\    s.buf = s.buf[16..];
        \\}
        \\fn look(s: *const S, b: []u8) usize {
        \\    return s.count + b.len;
        \\}
        \\pub fn alias(r: *std.Io.Reader, s0: S) !u8 {
        \\    var s = s0;
        \\    const p = &s;
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < s.buf.len) {
        \\        p.buf = s.buf[16..];
        \\        return s.buf[i];
        \\    }
        \\    return 0;
        \\}
        \\pub fn method(r: *std.Io.Reader, s: *S) !u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < s.buf.len) {
        \\        s.shrink();
        \\        return s.buf[i];
        \\    }
        \\    return 0;
        \\}
        \\pub fn call(r: *std.Io.Reader, s: *S) !u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < s.buf.len) {
        \\        cut(s);
        \\        return s.buf[i];
        \\    }
        \\    return 0;
        \\}
        \\pub fn viaptr(r: *std.Io.Reader, start: []u8) !u8 {
        \\    var in: []u8 = start;
        \\    const pin = &in;
        \\    const ip: usize = try r.takeInt(u32, .little);
        \\    if (ip < in.len) {
        \\        pin.* = in[16..];
        \\        return in[ip];
        \\    }
        \\    return 0;
        \\}
        \\pub fn deref(r: *std.Io.Reader, s: *S) !u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < s.buf.len) {
        \\        s.* = .{ .buf = s.buf[0..1] };
        \\        return s.buf[i];
        \\    }
        \\    return 0;
        \\}
        \\pub fn twin(r: *std.Io.Reader, s: *S, t: *S) !u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < s.buf.len) {
        \\        t.buf = t.buf[1..];
        \\        return s.buf[i];
        \\    }
        \\    return 0;
        \\}
        \\pub fn held(r: *std.Io.Reader, start: []u8) !u8 {
        \\    var in: []u8 = start;
        \\    const h: struct { p: *[]u8 } = .{ .p = &in };
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < in.len) {
        \\        h.p.* = in[0..1];
        \\        return in[i];
        \\    }
        \\    return 0;
        \\}
        \\pub fn apart(r: *std.Io.Reader, s: *S, k: *const S) !u8 {
        \\    const in: []u8 = s.buf;
        \\    const p = &s.count;
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < s.buf.len and i < in.len) {
        \\        p.* += 1;
        \\        s.count = look(k, s.buf) + look(k, in);
        \\        s.other.bump();
        \\        in[0] = 1;
        \\        return s.buf[i] ^ in[i];
        \\    }
        \\    return 0;
        \\}
        \\pub fn after(r: *std.Io.Reader, start: []u8) !u8 {
        \\    var in: []u8 = start;
        \\    const pin = &in;
        \\    const ip: usize = try r.takeInt(u32, .little);
        \\    if (ip < in.len) return in[ip];
        \\    pin.* = in[1..];
        \\    return 0;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    // Each store through another name; and in `apart`, memory behind a pointer is ended by any
    // store through a pointer and any call, while a local slice no other name reaches keeps
    // its fact past both.
    try std.testing.expectEqualSlices(u32, &.{ 28, 36, 44, 54, 62, 70, 80, 93 }, result.lines[0..result.findings]);
}

test "A009 ends a comparison's fact at any call that may write its memory, a store through any pointer that may reach it, and a loop's back edge" {
    // The second probe review's aliases: a call that writes a global, a store through a global
    // pointer, an optional capture, a pointer held in a field set after its declaration, a loop
    // that stores after the use, a pointer reassigned after its initializer.
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\const S = struct { buf: []u8 };
        \\fn cut(s: *S) void {
        \\    s.buf = s.buf[16..];
        \\}
        \\fn cutSlice(b: *[]u8) void {
        \\    b.* = b.*[16..];
        \\}
        \\fn id(p: *S) *S {
        \\    return p;
        \\}
        \\fn idErr(p: *S) !*S {
        \\    return p;
        \\}
        \\var g: []u8 = &.{};
        \\fn shrinkGlobal() void {
        \\    g = g[16..];
        \\}
        \\var gp: *[]u8 = undefined;
        \\// 1. a call given the address of a local
        \\pub fn addrArg(r: *std.Io.Reader, s0: S) !u8 {
        \\    var s = s0;
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < s.buf.len) {
        \\        cut(&s);
        \\        return s.buf[i];
        \\    }
        \\    return 0;
        \\}
        \\// 2. a call given the address of the slice itself
        \\pub fn addrSlice(r: *std.Io.Reader, start: []u8) !u8 {
        \\    var buf = start;
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < buf.len) {
        \\        cutSlice(&buf);
        \\        return buf[i];
        \\    }
        \\    return 0;
        \\}
        \\// 3. a pointer to a pointer
        \\pub fn doublePtr(r: *std.Io.Reader, start: []u8) !u8 {
        \\    var buf = start;
        \\    var p = &buf;
        \\    const pp = &p;
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < buf.len) {
        \\        pp.*.* = buf[16..];
        \\        return buf[i];
        \\    }
        \\    return 0;
        \\}
        \\// 4. a global, written by a call with no arguments
        \\pub fn global(r: *std.Io.Reader) !u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < g.len) {
        \\        shrinkGlobal();
        \\        return g[i];
        \\    }
        \\    return 0;
        \\}
        \\// 5. a global pointer to a local
        \\pub fn globalPtr(r: *std.Io.Reader, start: []u8) !u8 {
        \\    var buf = start;
        \\    gp = &buf;
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < buf.len) {
        \\        gp.* = buf[16..];
        \\        return buf[i];
        \\    }
        \\    return 0;
        \\}
        \\// 6. a pointer returned by a function
        \\pub fn returned(r: *std.Io.Reader, s0: S) !u8 {
        \\    var s = s0;
        \\    const p = id(&s);
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < s.buf.len) {
        \\        p.buf = s.buf[16..];
        \\        return s.buf[i];
        \\    }
        \\    return 0;
        \\}
        \\// 7. a pointer through an error union
        \\pub fn errUnion(r: *std.Io.Reader, s0: S) !u8 {
        \\    var s = s0;
        \\    const p = try idErr(&s);
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < s.buf.len) {
        \\        p.buf = s.buf[16..];
        \\        return s.buf[i];
        \\    }
        \\    return 0;
        \\}
        \\// 8. an optional pointer captured
        \\pub fn optCapture(r: *std.Io.Reader, s0: S) !u8 {
        \\    var s = s0;
        \\    const o: ?*S = &s;
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < s.buf.len) {
        \\        if (o) |p| p.buf = s.buf[16..];
        \\        return s.buf[i];
        \\    }
        \\    return 0;
        \\}
        \\// 9. a struct field holding the pointer, set after its declaration
        \\pub fn fieldHolder(r: *std.Io.Reader, s0: S) !u8 {
        \\    var s = s0;
        \\    var h: struct { p: *S } = undefined;
        \\    h.p = &s;
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < s.buf.len) {
        \\        h.p.buf = s.buf[16..];
        \\        return s.buf[i];
        \\    }
        \\    return 0;
        \\}
        \\// 10. a loop whose store is after the use in the text, before it on the next pass
        \\pub fn loop(r: *std.Io.Reader, start: []u8) !u32 {
        \\    var buf = start;
        \\    var total: u32 = 0;
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < buf.len) {
        \\        var k: u8 = 0;
        \\        while (k < 4) : (k += 1) {
        \\            total += buf[i];
        \\            buf = buf[1..];
        \\        }
        \\    }
        \\    return total;
        \\}
        \\// 11. std.mem.swap given the address
        \\pub fn swapped(r: *std.Io.Reader, start: []u8, other: []u8) !u8 {
        \\    var buf = start;
        \\    var o = other;
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < buf.len) {
        \\        std.mem.swap([]u8, &buf, &o);
        \\        return buf[i];
        \\    }
        \\    return 0;
        \\}
        \\// 12. a pointer variable reassigned after its init
        \\pub fn ptrReassigned(r: *std.Io.Reader, s0: S, t0: S) !u8 {
        \\    var s = s0;
        \\    var t = t0;
        \\    var p = &t;
        \\    p = &s;
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < s.buf.len) {
        \\        p.buf = s.buf[16..];
        \\        return s.buf[i];
        \\    }
        \\    return 0;
        \\}
        \\// 13. a slice of structs, the element's pointer
        \\pub fn element(r: *std.Io.Reader, items: []S) !u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (items.len == 0) return 0;
        \\    if (i < items[0].buf.len) {
        \\        const p = &items[0];
        \\        p.buf = p.buf[16..];
        \\        return items[0].buf[i];
        \\    }
        \\    return 0;
        \\}
        \\// 14. two parameter pointers that may be one
        \\pub fn twoParams(r: *std.Io.Reader, a: *S, b: *S) !u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < a.buf.len) {
        \\        b.buf = b.buf[0..1];
        \\        return a.buf[i];
        \\    }
        \\    return 0;
        \\}
        \\// 15. memcpy over the struct's bytes
        \\pub fn memcpyOver(r: *std.Io.Reader, s0: S, t: S) !u8 {
        \\    var s = s0;
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < s.buf.len) {
        \\        @memcpy(std.mem.asBytes(&s), std.mem.asBytes(&t));
        \\        return s.buf[i];
        \\    }
        \\    return 0;
        \\}
        \\// 16. the safe twins: a store to an unrelated local, a field of one struct apart from the
        \\// compared one, a call that cannot write memory, a local slice no other name reaches
        \\const P = struct { buf: []u8, pos: usize = 0 };
        \\pub fn safeLocal(r: *std.Io.Reader, start: []u8) !u8 {
        \\    var buf = start;
        \\    _ = &buf;
        \\    var n: usize = 0;
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < buf.len) {
        \\        n += 1;
        \\        cut(&S{ .buf = start });
        \\        return buf[i] +% @as(u8, @truncate(n));
        \\    }
        \\    return 0;
        \\}
        \\pub fn safeField(r: *std.Io.Reader, p: *P) !u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < p.buf.len) {
        \\        p.pos += 1;
        \\        _ = std.mem.findScalar(u8, p.buf, 0);
        \\        return p.buf[i];
        \\    }
        \\    return 0;
        \\}
        \\pub fn safeLoop(r: *std.Io.Reader, start: []u8) !u32 {
        \\    const buf = start;
        \\    var total: u32 = 0;
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    if (i < buf.len) {
        \\        var k: u8 = 0;
        \\        while (k < 4) : (k += 1) total += buf[i];
        \\    }
        \\    return total;
        \\}
    );
    // Each of the fifteen; never a store to another local, a field apart from the compared one,
    // std's search given a const view, or a loop that stores nothing it compares.
    try std.testing.expectEqualSlices(u32, &.{ 26, 36, 48, 57, 68, 79, 90, 101, 113, 125, 138, 151, 162, 171, 181 }, result.lines[0..result.findings]);
}

test "A009 trusts a reader as fixed only where std's Reader.fixed made it, by its declaration, and nothing writes it after" {
    // The second probe review's readers: a project function named `fixed` handing back the
    // peer's reader, one given the peer's reader, a fixed reader reassigned or repointed.
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\const ns = struct {
        \\    var peer: *std.Io.Reader = undefined;
        \\    fn fixed(_: []const u8) *std.Io.Reader {
        \\        return peer;
        \\    }
        \\    fn given(r: *std.Io.Reader) *std.Io.Reader {
        \\        return r;
        \\    }
        \\};
        \\pub fn named(r: *std.Io.Reader, out: []u8) !u8 {
        \\    ns.peer = r;
        \\    const rd = ns.fixed("abcd");
        \\    return out[try rd.takeInt(u32, .little)];
        \\}
        \\pub fn param(r: *std.Io.Reader, out: []u8) !u8 {
        \\    const rd = ns.given(r);
        \\    return out[try rd.takeInt(u32, .little)];
        \\}
        \\pub fn reassigned(r: *std.Io.Reader, out: []u8) !u8 {
        \\    var rd: std.Io.Reader = .fixed("abcd");
        \\    rd = r.*;
        \\    return out[try rd.takeInt(u32, .little)];
        \\}
        \\pub fn repointed(r: *std.Io.Reader, out: []u8) !u8 {
        \\    var own: std.Io.Reader = .fixed("abcd");
        \\    var rd = &own;
        \\    rd = r;
        \\    return out[try rd.takeInt(u32, .little)];
        \\}
        \\pub fn handed(r: *std.Io.Reader, out: []u8) !u8 {
        \\    var rd: std.Io.Reader = .fixed("abcd");
        \\    const p = &rd;
        \\    p.* = r.*;
        \\    return out[try rd.takeInt(u32, .little)];
        \\}
        \\pub fn part(r: *std.Io.Reader, out: []u8) !u8 {
        \\    var rd: std.Io.Reader = .fixed("abcd");
        \\    rd.buffer = try r.take(16);
        \\    return out[try rd.takeInt(u32, .little)];
        \\}
        \\pub fn ownBytes(out: []u8) !u8 {
        \\    var rd: std.Io.Reader = .fixed("abcd");
        \\    var spelled = std.Io.Reader.fixed("abcd");
        \\    return out[try rd.takeInt(u32, .little)] ^ out[try spelled.takeInt(u32, .little)];
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    // Each reader but the two std's fixed made over the program's bytes and nothing wrote.
    try std.testing.expectEqualSlices(u32, &.{ 14, 18, 23, 29, 35, 40 }, result.lines[0..result.findings]);
}

test "A010 reads each variable a literal is destructured into by its own element: a constant beside a number from input is no input" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !i32 {
        \\    var x: i32 = 0;
        \\    var y: i32 = 0;
        \\    x, y = .{ 5, try r.takeInt(i32, .little) };
        \\    return -x +% y;
        \\}
    , 0);
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !i32 {
        \\    var x: i32 = 0;
        \\    var y: i32 = 0;
        \\    x, y = .{ try r.takeInt(i32, .little), 5 };
        \\    return -x +% y;
        \\}
    , 1);
}

test "A009 judges an address input moves as an integer (`@ptrFromInt(@intFromPtr(p) + o)`) as it judges a pointer moved by input" {
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn intptr(r: *std.Io.Reader, out: []u8) !u8 {
        \\    const o: usize = try r.takeInt(u32, .little);
        \\    const p: [*]u8 = @ptrFromInt(@intFromPtr(out.ptr) + o);
        \\    return p[0];
        \\}
        \\pub fn fixed(out: []u8) u8 {
        \\    const p: [*]u8 = @ptrFromInt(@intFromPtr(out.ptr) + 4);
        \\    return p[0];
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{4}, result.lines[0..result.findings]);
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

test "a flow finding names every read that fills the field its input is held in, not the first alone" {
    var project = try sources.projectWithSources(std.testing.allocator,
        \\const std = @import("std");
        \\const Graph = struct { count: u32 = 0 };
        \\fn load(graph: *Graph, r: *std.Io.Reader) !void {
        \\    graph.count = try r.takeInt(u32, 0);
        \\}
        \\fn reload(graph: *Graph, r: *std.Io.Reader) !void {
        \\    graph.count = try r.takeByte();
        \\}
        \\fn lookup(graph: *const Graph, table: []const u8) u8 {
        \\    return table[graph.count];
        \\}
        \\pub fn f(r: *std.Io.Reader, table: []const u8) !u8 {
        \\    var graph: Graph = .{};
        \\    try load(&graph, r);
        \\    try reload(&graph, r);
        \\    return lookup(&graph, table);
        \\}
    , &std_files, &std_imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.untrusted_input, .level = .report }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var named: usize = 0;
    for (report.diagnostics) |d| if (d.rule == pack.untrusted_input) {
        try std.testing.expect(std.mem.endsWith(u8, d.message, "(input from consumer:4 `r.takeInt` and consumer:7 `r.takeByte`)"));
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

test "A010 reads a C int at a 16-bit pointer width as 16 bits: a value past it fits elsewhere and not there" {
    const program =
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader) !c_int {
        \\    const v = try r.takeInt(u32, 0);
        \\    return @intCast(v & 0xffff);
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try runWidths(pack.integers, program, &.{ 32, 64 })).findings);
    try std.testing.expectEqual(@as(usize, 1), (try runWidths(pack.integers, program, &.{16})).findings);
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
    // changes after it keep nothing; each in its own function, as a slice a safe build ran
    // keeps its own bound for what follows.
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn branch(r: *std.Io.Reader, flag: bool) !void {
        \\    const in = try r.take(64);
        \\    const ip: usize = try r.takeInt(u8, 0);
        \\    if (flag) _ = in.len - ip;
        \\    _ = in[ip..];
        \\}
        \\pub fn skipped(r: *std.Io.Reader, flag: bool) !void {
        \\    const in = try r.take(64);
        \\    const ip: usize = try r.takeInt(u8, 0);
        \\    if (flag and in.len - ip > 4) {}
        \\    _ = in[ip..];
        \\}
        \\pub fn changed(r: *std.Io.Reader) !void {
        \\    const in = try r.take(64);
        \\    var ip: usize = try r.takeInt(u8, 0);
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
    // A block that may change the clamped value again keeps nothing: the difference, and the
    // sum on a value that may be the byte read or `at.*`'s whole range.
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
    , 2);
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

test "A009 reads a std read's count as at most the one buffer it filled, through a function of the program that retries it" {
    const program =
        \\const std = @import("std");
        \\fn readSome(io: std.Io, from: std.Io.File, buffers: []const []u8) !usize {
        \\    while (true) {
        \\        const n = try from.readStreaming(io, buffers);
        \\        if (n != 0) return n;
        \\    }
        \\}
        \\pub fn f(r: *std.Io.Reader, file: std.Io.File, io: std.Io) !u8 {
        \\    var chunk: [512]u8 = undefined;
        \\    const room: usize = try r.takeInt(u32, .little);
        \\    const n = readSome(io, file, &.{chunk[0..@min(room, chunk.len)]}) catch |err| switch (err) {
        \\        error.Canceled => return error.Canceled,
        \\        else => return 0,
        \\    };
        \\    var buf: [64]u8 = undefined;
        \\    const m = try r.readSliceShort(&buf);
        \\    return chunk[0..n][0] +% buf[0..m][0];
        \\}
    ;
    try expect(pack.untrusted_input, program, 0);
    // A count the wrapper does not return as read, two buffers, and an end past the array.
    try expect(pack.untrusted_input, comptime edited(program, "if (n != 0) return n;", "if (n != 0) return n + 1;"), 1);
    try expect(pack.untrusted_input, comptime edited(program, "&.{chunk[0..@min(room, chunk.len)]}", "&.{ chunk[0..@min(room, chunk.len)], chunk[0..1] }"), 1);
    try expect(pack.untrusted_input, comptime edited(program, "@min(room, chunk.len)", "@max(room, chunk.len)"), 2);
}

test "A009 reads what aegis asserted across another assertion, and a difference or a constant within where what it is made of is" {
    const program =
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\const S = struct { buf: []u8, filled: usize, consumed: usize };
        \\fn touch(s: *S) void {
        \\    s.filled += 1;
        \\}
        \\pub fn f(r: *std.Io.Reader, s: *S) !void {
        \\    s.filled = try r.takeInt(u32, .little);
        \\    s.consumed = try r.takeInt(u32, .little);
        \\    aegis.assert.invariant(s.consumed <= s.filled, "consumed <= filled");
        \\    aegis.assert.invariant(s.filled <= s.buf.len, "filled <= buf.len");
        \\    const rest = s.filled - s.consumed;
        \\    @memmove(s.buf[0..rest], s.buf[s.consumed..s.filled]);
        \\}
    ;
    try expect(pack.untrusted_input, program, 0);
    try expect(pack.untrusted_input, comptime edited(program, "    const rest = s.filled - s.consumed;\n", "    touch(s);\n    const rest = s.filled - s.consumed;\n"), 2);
    try expect(pack.untrusted_input, comptime edited(program, "    aegis.assert.invariant(s.filled <= s.buf.len, \"filled <= buf.len\");\n", ""), 2);
    try expect(pack.untrusted_input, comptime edited(program, "@memmove(s.buf[0..rest]", "s.buf = s.buf[1..];\n    @memmove(s.buf[0..rest]"), 2);
}

test "A009 reads an array's length as its type spells it: a comptime width, a constant naming it, and a capture over addresses of arrays of one length" {
    const program =
        \\const std = @import("std");
        \\const Curve = struct {
        \\    pub const scalar_length = 32;
        \\};
        \\fn rightAligned(comptime width: usize, value: []const u8, out: *[width]u8) error{Long}!void {
        \\    if (value.len > width) return error.Long;
        \\    @memcpy(out[width - value.len ..], value);
        \\}
        \\fn rightAlignedType(comptime curve: type, value: []const u8, out: *[curve.scalar_length]u8) error{Long}!void {
        \\    const width = curve.scalar_length;
        \\    if (value.len > width) return error.Long;
        \\    @memcpy(out[width - value.len ..], value);
        \\}
        \\fn pair(comptime curve: type, input: []const u8) error{Long}![2][curve.scalar_length]u8 {
        \\    const width = curve.scalar_length;
        \\    var r: [width]u8 = @splat(0);
        \\    var s: [width]u8 = @splat(0);
        \\    inline for (.{ &r, &s }, 0..) |out, i| {
        \\        const value = input[i * 4 ..][0..4];
        \\        if (value.len > width) return error.Long;
        \\        @memcpy(out[width - value.len ..], value);
        \\    }
        \\    return .{ r, s };
        \\}
        \\pub fn f(r: *std.Io.Reader) !void {
        \\    const v = try r.take(8);
        \\    var out: [32]u8 = @splat(0);
        \\    try rightAligned(32, v, &out);
        \\    try rightAlignedType(Curve, v, &out);
        \\    _ = try pair(Curve, try r.take(8));
        \\}
    ;
    try expect(pack.untrusted_input, program, 0);
    // Another width than the array's, and a capture over arrays of two lengths.
    try expect(pack.untrusted_input, comptime edited(program, "fn rightAligned(comptime width: usize, value: []const u8, out: *[width]u8)", "fn rightAligned(comptime width: usize, value: []const u8, out: *[width - 1]u8)"), 1);
    try expect(pack.untrusted_input, comptime edited(edited(program, "    var s: [width]u8 = @splat(0);", "    var s: [width + 1]u8 = @splat(0);"), "    return .{ r, s };", "    return .{ r, s[0..width].* };"), 1);
    // Without the check, the start goes under zero: A010's.
    try expect(pack.integers, comptime edited(program, "    if (value.len > width) return error.Long;\n    @memcpy(out[width - value.len ..], value);\n}\nfn rightAlignedType", "    @memcpy(out[width - value.len ..], value);\n}\nfn rightAlignedType"), 1);
}

test "A009 reads a callee's check of its receiver only while the rest of the callee leaves the receiver as checked" {
    const program =
        \\const std = @import("std");
        \\pub const P = struct {
        \\    table: [16]u8 = @splat(0),
        \\    at: usize = 0,
        \\    fn check(self: *P) !void {
        \\        if (self.at >= self.table.len) return error.Range;
        \\        self.at += 1;
        \\    }
        \\    fn peek(self: *P) !u8 {
        \\        return if (self.at < self.table.len) self.table[self.at] else error.Range;
        \\    }
        \\    fn skip(self: *P) !void {
        \\        if (self.at >= self.table.len) return error.Range;
        \\        return self.advance();
        \\    }
        \\    fn advance(self: *P) !void {
        \\        self.at += 1;
        \\    }
        \\    pub fn get(self: *P, reader: *std.Io.Reader) !u8 {
        \\        self.at = try reader.takeByte();
        \\        try self.check();
        \\        return self.table[self.at];
        \\    }
        \\    pub fn next(self: *P, reader: *std.Io.Reader) !u8 {
        \\        self.at = try reader.takeByte();
        \\        try self.skip();
        \\        return self.table[self.at];
        \\    }
        \\    pub fn look(self: *P, reader: *std.Io.Reader) !u8 {
        \\        self.at = try reader.takeByte();
        \\        const first = try self.peek();
        \\        return first +% self.table[self.at];
        \\    }
        \\};
    ;
    // `check` and `skip` move the position past what they checked; `peek` only reads it.
    try expect(pack.untrusted_input, program, 2);
    // The checks with what follows them leaving the position where they saw it: a store to a
    // local of their own.
    const kept = comptime edited(edited(program, "        self.at += 1;\n    }\n    fn peek", "        var seen: usize = 0;\n        seen += 1;\n    }\n    fn peek"), "return self.advance();", "return;");
    try expect(pack.untrusted_input, kept, 0);
    // A guard after the move holds where the call succeeded, unless a statement before it may
    // return without failing, so the call succeeded past it.
    const entered =
        \\const std = @import("std");
        \\pub const P = struct {
        \\    table: [16]u8 = @splat(0),
        \\    at: usize = 0,
        \\    fn enter(self: *P) !void {
        \\        self.at += 1;
        \\        if (self.at >= self.table.len) return error.Range;
        \\    }
        \\    pub fn get(self: *P, reader: *std.Io.Reader) !u8 {
        \\        self.at = try reader.takeByte();
        \\        try self.enter();
        \\        return self.table[self.at];
        \\    }
        \\};
    ;
    try expect(pack.untrusted_input, entered, 0);
    try expect(pack.untrusted_input, comptime edited(entered, "        self.at += 1;\n", "        self.at += 1;\n        if (self.at == 3) return;\n"), 1);
}

test "A009 reads a callee's check only where nothing after it, its defers included, may write what the caller sees, by any name" {
    const program =
        \\const std = @import("std");
        \\pub const P = struct {
        \\    table: [16]u8 = @splat(0),
        \\    at: usize = 0,
        \\    me: *P,
        \\    fn check(self: *P, other: *P) !void {
        \\        if (self.at >= self.table.len) return error.Range;
        \\        _ = other;
        \\    }
        \\    pub fn get(self: *P, reader: *std.Io.Reader) !u8 {
        \\        self.at = try reader.takeByte();
        \\        try self.check(self);
        \\        return self.table[self.at];
        \\    }
        \\};
        \\pub var shared: P = undefined;
    ;
    try expect(pack.untrusted_input, program, 0);
    // The receiver written through another parameter, `@field`, a local naming it, a pointer a
    // field holds, a global it may be, in a `defer`, or by any call.
    try expect(pack.untrusted_input, comptime edited(program, "_ = other;", "other.at = other.table.len;"), 1);
    const writes = [_][]const u8{
        "@field(self, \"at\") = self.table.len;",
        "const q = self;\n        q.at = q.table.len;",
        "const m = self.me;\n        m.at = m.table.len;",
        "shared.at = shared.table.len;",
        "std.log.debug(\"{d}\", .{self.at});",
    };
    inline for (writes) |write| try expect(pack.untrusted_input, comptime edited(program, "_ = other;", "_ = other;\n        " ++ write), 1);
    try expect(pack.untrusted_input, comptime edited(program, "        if (self.at >= self.table.len) return error.Range;\n", "        defer self.at = self.table.len;\n        if (self.at >= self.table.len) return error.Range;\n"), 1);
    // A condition naming a local of the callee says nothing of the caller's value of that name.
    try expect(pack.untrusted_input, comptime edited(program, "        if (self.at >= self.table.len) return error.Range;\n", "        const at = self.at + 0;\n        if (at >= self.table.len) return error.Range;\n"), 1);
}

test "A009 judges a slice's bounds in order: each at most the length leaves the start past the end a peer may choose" {
    // Each slice in its own function: a slice a safe build ran checks its order for what follows.
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f1(r: *std.Io.Reader, buf: []const u8) ![]const u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    const n: usize = try r.takeInt(u32, .little);
        \\    if (i > buf.len) return error.Bad;
        \\    if (n > buf.len) return error.Bad;
        \\    return buf[i..n];
        \\}
        \\pub fn f2(r: *std.Io.Reader, buf: []const u8) ![]const u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    const n: usize = try r.takeInt(u32, .little);
        \\    if (i > buf.len) return error.Bad;
        \\    if (n > buf.len) return error.Bad;
        \\    return buf[i..@min(n, buf.len)];
        \\}
        \\pub fn f3(r: *std.Io.Reader, buf: []const u8) ![]const u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    const n: usize = try r.takeInt(u32, .little);
        \\    if (i > buf.len) return error.Bad;
        \\    if (n > buf.len) return error.Bad;
        \\    return buf[5..n];
        \\}
        \\pub fn f4(r: *std.Io.Reader, buf: []const u8) ![]const u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    const n: usize = try r.takeInt(u32, .little);
        \\    if (i > buf.len) return error.Bad;
        \\    if (n > buf.len) return error.Bad;
        \\    return if (i != n) buf[i..n] else buf;
        \\}
        \\pub fn f5(r: *std.Io.Reader, buf: []const u8) ![]const u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    const n: usize = try r.takeInt(u32, .little);
        \\    if (i > buf.len) return error.Bad;
        \\    if (n > buf.len) return error.Bad;
        \\    return buf[0..n];
        \\}
        \\pub fn f6(r: *std.Io.Reader, buf: []const u8) ![]const u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    const n: usize = try r.takeInt(u32, .little);
        \\    if (i > buf.len) return error.Bad;
        \\    if (n > buf.len) return error.Bad;
        \\    return buf[i..buf.len];
        \\}
        \\pub fn f7(r: *std.Io.Reader, buf: []const u8) ![]const u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    const n: usize = try r.takeInt(u32, .little);
        \\    if (i > buf.len) return error.Bad;
        \\    if (n > buf.len) return error.Bad;
        \\    if (i > n) return error.Bad;
        \\    return buf[i..n];
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 7, 7, 14, 14, 21, 28, 28 }, result.lines[0..result.findings]);
}

test "A009 bounds a constant of each type a peer's choice may give by the widest alternative: a digest's length per suite within memory of the longest, not within shorter" {
    // The peer picks the suite, so the length is its choice among 32 and 48: memory of 48
    // holds either (line 14's `out`), memory of 40 not the second (line 22's `buf`).
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\fn Hasher(comptime digest_bits: comptime_int) type {
        \\    return struct { pub const digest_length = @divCeil(digest_bits, 8); };
        \\}
        \\const Tag = enum { short, long };
        \\fn Type(comptime tag: Tag) type {
        \\    return switch (tag) { .short => Hasher(256), .long => Hasher(384) };
        \\}
        \\pub fn digest(r: *std.Io.Reader, out: *[48]u8) !void {
        \\    const tag: Tag = if (try r.takeByte() == 0) .short else .long;
        \\    var buf: [48]u8 = undefined;
        \\    try r.readSliceAll(&buf);
        \\    switch (tag) {
        \\        inline else => |t| @memcpy(out[0..Type(t).digest_length], buf[0..Type(t).digest_length]),
        \\    }
        \\}
        \\pub fn wider(r: *std.Io.Reader, out: *[48]u8) !void {
        \\    const tag: Tag = if (try r.takeByte() == 0) .short else .long;
        \\    var buf: [40]u8 = undefined;
        \\    try r.readSliceAll(&buf);
        \\    switch (tag) {
        \\        inline else => |t| @memcpy(out[0..Type(t).digest_length], buf[0..Type(t).digest_length]),
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{22}, result.lines[0..result.findings]);
}

test "A009 reads what a branch or a loop a peer decides assigns as the peer's: a counter its number steps and a value its flag picks, within memory only where the program shows it" {
    // Lines 7 and 14: counters stepped up to a number checked against 1000, not the memory.
    // Line 29: a value a peer's flag picks indexes a fixed table that holds it (clean) and a
    // slice that may not (line 35). Line 21: the counter below a number checked against the
    // memory's length. No loop's bound is a finding: each counts at most a short or the memory.
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn counted(r: *std.Io.Reader, buf: []const u8) !u32 {
        \\    const n: usize = try r.takeInt(u32, .little);
        \\    if (n > 1000) return error.Bad;
        \\    var total: u32 = 0;
        \\    var i: usize = 0;
        \\    while (i < n) : (i += 1) total +%= buf[i];
        \\    return total;
        \\}
        \\pub fn ranged(r: *std.Io.Reader, buf: []const u8) !u32 {
        \\    const n: usize = try r.takeInt(u32, .little);
        \\    if (n > 1000) return error.Bad;
        \\    var total: u32 = 0;
        \\    for (0..n) |i| total +%= buf[i];
        \\    return total;
        \\}
        \\pub fn checked(r: *std.Io.Reader, buf: []const u8) !u32 {
        \\    const n: usize = try r.takeInt(u32, .little);
        \\    if (n > buf.len) return error.Bad;
        \\    var total: u32 = 0;
        \\    for (0..n) |i| total +%= buf[i];
        \\    return total;
        \\}
        \\const table: [2000]u8 = @splat(0);
        \\pub fn fixed(r: *std.Io.Reader) !u8 {
        \\    const flag = try r.takeByte();
        \\    var i: usize = 0;
        \\    if (flag == 1) i = 1000;
        \\    return table[i];
        \\}
        \\pub fn sliced(r: *std.Io.Reader, buf: []const u8) !u8 {
        \\    const flag = try r.takeByte();
        \\    var i: usize = 0;
        \\    if (flag == 1) i = 1000;
        \\    return buf[i];
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 7, 14, 35 }, result.lines[0..result.findings]);
}

test "A009 bounds a loop by a number the program checked against the memory it holds, and the counter the loop steps up to it; not one it did not check" {
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn loop(r: *std.Io.Reader, buf: []const u8) !u32 {
        \\    const n: usize = try r.takeInt(u32, .little);
        \\    if (n > buf.len) return error.Bad;
        \\    var total: u32 = 0;
        \\    var i: usize = 0;
        \\    while (i < n) : (i += 1) total +%= buf[i];
        \\    return total;
        \\}
        \\pub fn unchecked(r: *std.Io.Reader, buf: []const u8) !u32 {
        \\    const n: usize = try r.takeInt(u32, .little);
        \\    var total: u32 = 0;
        \\    var i: usize = 0;
        \\    while (i <= n) : (i += 1) total +%= buf[i];
        \\    return total;
        \\}
        \\pub fn down(r: *std.Io.Reader) !void {
        \\    var i: usize = try r.takeInt(u32, .little);
        \\    while (i > 0) : (i -= 1) {}
        \\}
        \\pub fn rounds(r: *std.Io.Reader) !void {
        \\    const m: usize = try r.takeInt(u32, .little);
        \\    var n: usize = 0;
        \\    while (n < 10_000) : (n += 1) {
        \\        if (m == n) break;
        \\    }
        \\}
        \\pub fn stride(r: *std.Io.Reader) !void {
        \\    const step: usize = try r.takeInt(u32, .little);
        \\    var i: usize = 0;
        \\    while (i < 1000) : (i += step) {}
        \\}
        \\pub fn pairs(r: *std.Io.Reader, list: []const u8) !void {
        \\    const m: usize = try r.takeInt(u32, .little);
        \\    var at: usize = 0;
        \\    while (at + 2 <= list.len) : (at += 2) {
        \\        if (m == at) break;
        \\    }
        \\}
    );
    // A counter is judged by what it enters with and steps by: one a peer's number starts
    // (line 19) or strides (line 31), never one a peer's number only stops early (line 24).
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 14, 14, 19, 31 }, result.lines[0..result.findings]);
}

test "Bounds clears an index or a slice the relations along every path keep within its memory: a sum checked against what is left, an index a safe build already checked, a callee's checked result, a counter its loop's checks keep, a reslice" {
    // Each safe case beside its twin: unchecked (line 14), the first read (line 18), a callee
    // that checks nothing (line 34), a loop that reads one past the memory (line 47).
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn sum(r: *std.Io.Reader, buf: []const u8) !u8 {
        \\    const a: usize = try r.takeInt(u32, .little);
        \\    const n: usize = try r.takeInt(u32, .little);
        \\    if (a > buf.len) return error.Bad;
        \\    if (n > buf.len - a) return error.Bad;
        \\    return buf[a..][0..n][0] +% buf[a + n - 1];
        \\}
        \\pub fn sumUnchecked(r: *std.Io.Reader, buf: []const u8) !u8 {
        \\    const a: usize = try r.takeInt(u32, .little);
        \\    const n: usize = try r.takeInt(u32, .little);
        \\    if (a > buf.len) return error.Bad;
        \\    if (n > buf.len) return error.Bad;
        \\    return buf[a + n - 1];
        \\}
        \\pub fn again(r: *std.Io.Reader, buf: []const u8) !u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    const first = buf[i];
        \\    return first +% buf[i];
        \\}
        \\fn fit(n: usize, len: usize) error{Long}!usize {
        \\    if (n > len) return error.Long;
        \\    return n;
        \\}
        \\fn pass(n: usize) usize {
        \\    return n;
        \\}
        \\pub fn summary(r: *std.Io.Reader, buf: []const u8) ![]const u8 {
        \\    const n: usize = try r.takeInt(u32, .little);
        \\    return buf[0..try fit(n, buf.len)];
        \\}
        \\pub fn summaryUnchecked(r: *std.Io.Reader, buf: []const u8) ![]const u8 {
        \\    const n: usize = try r.takeInt(u32, .little);
        \\    return buf[0..pass(n)];
        \\}
        \\pub fn walk(r: *std.Io.Reader, bytes: []const u8) !u32 {
        \\    var at: usize = try r.takeInt(u32, .little);
        \\    if (at >= bytes.len) return error.Bad;
        \\    var total: u32 = 0;
        \\    while (at < bytes.len) : (at += 1) total +%= bytes[at];
        \\    return total;
        \\}
        \\pub fn walkPast(r: *std.Io.Reader, bytes: []const u8) !u32 {
        \\    var at: usize = try r.takeInt(u32, .little);
        \\    if (at >= bytes.len) return error.Bad;
        \\    var total: u32 = 0;
        \\    while (at <= bytes.len) : (at += 1) total +%= bytes[at];
        \\    return total;
        \\}
        \\pub fn reslice(r: *std.Io.Reader, start: []const u8) !u8 {
        \\    var in = start;
        \\    const ip: usize = try r.takeInt(u32, .little);
        \\    if (ip <= in.len - 32) {
        \\        in = in[16..];
        \\        return in[ip + 1];
        \\    }
        \\    return 0;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 14, 18, 34, 47 }, result.lines[0..result.findings]);
}

test "A010 reads one object's length as at most maxInt(isize): two lengths and 1 fit a usize; two lengths and 2, or three lengths, may not" {
    const result = try run(pack.integers,
        \\const std = @import("std");
        \\pub fn two(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
        \\    const a = try r.allocRemaining(gpa, .unlimited);
        \\    const b = try r.allocRemaining(gpa, .unlimited);
        \\    return a.len + b.len + 1;
        \\}
        \\pub fn past(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
        \\    const a = try r.allocRemaining(gpa, .unlimited);
        \\    const b = try r.allocRemaining(gpa, .unlimited);
        \\    return a.len + b.len + 2;
        \\}
        \\pub fn three(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
        \\    const a = try r.allocRemaining(gpa, .unlimited);
        \\    const b = try r.allocRemaining(gpa, .unlimited);
        \\    const c = try r.allocRemaining(gpa, .unlimited);
        \\    return a.len + b.len + c.len;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 10, 16 }, result.lines[0..result.findings]);
}

test "Bounds clears arithmetic and a conversion the relations along every path keep within its type: a difference past its check, a switch prong's range" {
    // Line 5: a sum of a decoded u32 and 2 overflows a 32-bit usize. Each twin's check leaves
    // the operation open: a difference one short (line 12), a prong from zero (line 24), a
    // value one past the destination (line 36), a divisor that may be zero (line 46).
    const result = try run(pack.integers,
        \\const std = @import("std");
        \\pub fn diff(r: *std.Io.Reader) !usize {
        \\    const em_len: usize = try r.takeInt(u32, .little);
        \\    const h_len: usize = try r.takeInt(u32, .little);
        \\    if (em_len < h_len + 2) return error.Bad;
        \\    return em_len - h_len - 1;
        \\}
        \\pub fn diffShort(r: *std.Io.Reader) !usize {
        \\    const em_len: usize = try r.takeInt(u32, .little);
        \\    const h_len: usize = try r.takeInt(u32, .little);
        \\    if (em_len < h_len) return error.Bad;
        \\    return em_len - h_len - 1;
        \\}
        \\pub fn prong(r: *std.Io.Reader) !usize {
        \\    const first = try r.takeByte();
        \\    return switch (first) {
        \\        192...254 => (@as(usize, first - 192) << 8) + try r.takeByte() + 192,
        \\        else => first,
        \\    };
        \\}
        \\pub fn prongWide(r: *std.Io.Reader) !usize {
        \\    const first = try r.takeByte();
        \\    return switch (first) {
        \\        0...254 => (@as(usize, first - 192) << 8) + try r.takeByte() + 192,
        \\        else => first,
        \\    };
        \\}
        \\pub fn narrowed(r: *std.Io.Reader) !u8 {
        \\    const n = try r.takeInt(u32, .little);
        \\    if (n >= 200) return error.Bad;
        \\    return @intCast(n + 50);
        \\}
        \\pub fn narrowedWide(r: *std.Io.Reader) !u8 {
        \\    const n = try r.takeInt(u32, .little);
        \\    if (n >= 250) return error.Bad;
        \\    return @intCast(n + 50);
        \\}
        \\pub fn divisor(r: *std.Io.Reader, total: u32) !u32 {
        \\    const k = try r.takeInt(u32, .little);
        \\    if (k < 1) return error.Bad;
        \\    return total / k;
        \\}
        \\pub fn divisorZero(r: *std.Io.Reader, total: u32) !u32 {
        \\    const k = try r.takeInt(u32, .little);
        \\    if (k > 100) return error.Bad;
        \\    return total / k;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 5, 12, 24, 36, 46 }, result.lines[0..result.findings]);
}

test "Bounds keeps a function's other facts where a loop's are past its budget: an encoder's fixed writes clear beside a loop stepping by input lengths" {
    // The second loop steps `at` by lengths the peer chose (lines 20, 21); every write before
    // and after it at a place the facts bound stays clear, however many facts the loop holds.
    const result = try run(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn encode(r: *std.Io.Reader, gpa: std.mem.Allocator, out: *[400]u8) ![]const u8 {
        \\    try r.readSliceAll(out);
        \\    const secret = try r.allocRemaining(gpa, .unlimited);
        \\    if (secret.len > 48) return error.Long;
        \\    const a = try r.allocRemaining(gpa, .unlimited);
        \\    const b = try r.allocRemaining(gpa, .unlimited);
        \\    if (a.len > 255 or b.len > 255) return error.Long;
        \\    var at: usize = 0;
        \\    out[at..][0..2].* = .{ 0, 7 };
        \\    at += 2;
        \\    out[at] = @intCast(secret.len);
        \\    @memcpy(out[at + 1 ..][0..secret.len], secret);
        \\    at += 1 + secret.len;
        \\    for ([_]u8{ 1, 2 }) |t| {
        \\        out[at..][0..8].* = @splat(t);
        \\        at += 8;
        \\    }
        \\    for ([_][]const u8{ a, b }) |name| {
        \\        out[at] = @intCast(name.len);
        \\        @memcpy(out[at + 1 ..][0..name.len], name);
        \\        at += 1 + name.len;
        \\    }
        \\    return out[0..2];
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 20, 21 }, result.lines[0..result.findings]);
}

test "Bounds bounds what a loop steps by how far each pass steps it and how many passes run: a sum of a table's days, a count of matches" {
    // Each twin's counter can pass its type: a u8 count over a slice of any length (line 21), a
    // u32 count over a slice past 2^32 items on a 64-bit target (line 30), a count whose loop
    // need not step its counter on every pass (line 48). A counter stepped on every pass
    // (`: (i += 1)`) bounds the passes by how far it may go, so a count under it is bounded
    // by the length it walks (`walked`).
    const result = try run(pack.integers,
        \\const std = @import("std");
        \\const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        \\pub fn table(r: *std.Io.Reader) !u64 {
        \\    const n: usize = try r.takeInt(u16, .little);
        \\    var total: u64 = 0;
        \\    for (days[0..@min(n, days.len)]) |d| total += d;
        \\    return total;
        \\}
        \\pub fn count(r: *std.Io.Reader, items: []const u8) !usize {
        \\    const m = try r.takeByte();
        \\    var found: usize = 0;
        \\    for (items) |b| {
        \\        if (b == m) found += 1;
        \\    }
        \\    return found;
        \\}
        \\pub fn twice(r: *std.Io.Reader, items: []const u8) !u8 {
        \\    const m = try r.takeByte();
        \\    var found: u8 = 0;
        \\    for (items) |b| {
        \\        if (b == m) found += 1;
        \\    }
        \\    return found;
        \\}
        \\pub fn walk(r: *std.Io.Reader, items: []const u8) !u32 {
        \\    const m = try r.takeByte();
        \\    var i: usize = 0;
        \\    var seen: u32 = 0;
        \\    while (i < items.len) : (i += 1) {
        \\        if (items[i] == m) seen += 1;
        \\    }
        \\    return seen;
        \\}
        \\pub fn walked(r: *std.Io.Reader, items: []const u8) !usize {
        \\    const m = try r.takeByte();
        \\    var i: usize = 0;
        \\    var seen: usize = 0;
        \\    while (i < items.len) : (i += 1) {
        \\        if (items[i] == m) seen += 1;
        \\    }
        \\    return seen;
        \\}
        \\pub fn lingers(r: *std.Io.Reader, items: []const u8) !usize {
        \\    const m = try r.takeByte();
        \\    var i: usize = 0;
        \\    var seen: usize = 0;
        \\    while (i < items.len) {
        \\        seen += 1;
        \\        if (items[i] == m) i += 1;
        \\    }
        \\    return seen;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 21, 30, 48 }, result.lines[0..result.findings]);
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

test "A020 reads a call of a function or method chosen per target as a cancellation point where every choice is one" {
    // visor's input wait (`wait = if (is_windows) waitWindows else waitPosix`) and conduit's
    // reaper, which waits through a `Cgroup` chosen per target.
    const head =
        \\const std = @import("std");
        \\const windows = @import("builtin").os.tag == .windows;
        \\fn waitWindows(io: std.Io) std.Io.Cancelable!u8 { try io.checkCancel(); return 0; }
        \\fn waitPosix(io: std.Io) (error{EndOfStream} || std.Io.Cancelable)!u8 { try io.checkCancel(); return 1; }
        \\fn spinWindows(io: std.Io) u8 { _ = io; return 0; }
        \\const LinuxCgroup = struct {
        \\    fn waitEmpty(g: *const LinuxCgroup, io: std.Io) std.Io.Cancelable!bool { _ = g; try io.checkCancel(); return true; }
        \\};
        \\const NoCgroup = struct {
        \\    fn waitEmpty(g: *const NoCgroup, io: std.Io) std.Io.Cancelable!bool { _ = g; try io.checkCancel(); return true; }
        \\};
        \\const StubCgroup = struct {
        \\    fn waitEmpty(g: *const StubCgroup, io: std.Io) bool { _ = g; _ = io; return true; }
        \\};
        \\
    ;
    try expect(pack.cancellation, head ++
        \\const wait = if (windows) waitWindows else waitPosix;
        \\pub fn read(io: std.Io) !void {
        \\    while (true) if (try wait(io) == 0) return;
        \\}
    , 0);
    try expect(pack.cancellation, head ++
        \\const Cgroup = if (windows) NoCgroup else LinuxCgroup;
        \\pub fn reap(io: std.Io, group: *const Cgroup) !void {
        \\    while (true) if (try group.waitEmpty(io)) return;
        \\}
    , 0);
    // A choice that cannot return error.Canceled leaves the call no cancellation point.
    inline for (.{
        "const wait = if (windows) spinWindows else waitPosix;\npub fn read(io: std.Io) !void {\n    while (true) if (try wait(io) == 0) return;\n}\n",
        "const Cgroup = if (windows) StubCgroup else LinuxCgroup;\npub fn reap(io: std.Io, group: *const Cgroup) !void {\n    while (true) if (try group.waitEmpty(io)) return;\n}\n",
    }) |body| expect(pack.cancellation, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}

test "A020 reads a project function's body, not its declared error set, and no call whose error.Canceled is caught and dropped" {
    const head =
        \\const std = @import("std");
        \\const windows = @import("builtin").os.tag == .windows;
        \\const Error = error{Bad} || std.Io.Cancelable;
        \\fn step(x: u32) Error!u64 {
        \\    if (x == 0xffff_ffff) return error.Bad;
        \\    return x;
        \\}
        \\fn tick() error{Canceled}!void {}
        \\fn waitPosix(io: std.Io) std.Io.Cancelable!u8 {
        \\    try io.checkCancel();
        \\    return 1;
        \\}
        \\fn waitWindows(io: std.Io) std.Io.Cancelable!u8 {
        \\    _ = io;
        \\    return 1;
        \\}
        \\fn ready(io: std.Io) bool {
        \\    io.checkCancel() catch return false;
        \\    return true;
        \\}
        \\fn passed(io: std.Io) std.Io.Cancelable!void {
        \\    io.checkCancel() catch |err| switch (err) {
        \\        error.Canceled => return err,
        \\    };
        \\}
        \\fn rearmed(io: std.Io) error{Failed}!void {
        \\    io.checkCancel() catch {
        \\        io.recancel();
        \\        return error.Failed;
        \\    };
        \\}
        \\fn renamed(io: std.Io) error{Failed}!void {
        \\    io.checkCancel() catch return error.Failed;
        \\}
        \\fn mapped(io: std.Io) (error{Bad} || std.Io.Cancelable)!void {
        \\    return io.checkCancel() catch |err| switch (err) {
        \\        error.Canceled => error.Canceled,
        \\    };
        \\}
        \\fn captured(io: std.Io) std.Io.Cancelable!void {
        \\    if (io.checkCancel()) |_| {} else |err| switch (err) {
        \\        error.Canceled => |e| return e,
        \\    }
        \\}
        \\fn found(io: std.Io) bool {
        \\    if (io.checkCancel()) |_| return true else |_| return false;
        \\}
        \\
    ;
    // Each loop runs on through a cancel, or loses it: one dropped, a set that only declares it,
    // a choice per target whose body never cancels, a function that turns it into a value or
    // another error, one that re-arms it and returns another error, and a plain return or break
    // that ends the loop but hands the caller no error.Canceled.
    inline for (.{
        "pub fn f(io: std.Io, r: *std.Io.Reader) !u64 {\n    var total: u64 = 0;\n    const n = try r.takeInt(u32, .little);\n    var i: u32 = 0;\n    while (i < n) : (i += 1) {\n        io.checkCancel() catch {};\n        total +%= i;\n    }\n    return total;\n}\n",
        "pub fn f(io: std.Io, r: *std.Io.Reader) !u64 {\n    _ = &io;\n    var total: u64 = 0;\n    const n = try r.takeInt(u32, .little);\n    var i: u32 = 0;\n    while (i < n) : (i += 1) total +%= try step(i);\n    return total;\n}\n",
        "pub fn f(io: std.Io, r: *std.Io.Reader) !u64 {\n    _ = &io;\n    var total: u64 = 0;\n    const n = try r.takeInt(u32, .little);\n    var i: u32 = 0;\n    while (i < n) : (i += 1) {\n        try tick();\n        total +%= i;\n    }\n    return total;\n}\n",
        "pub fn f(io: std.Io, r: *std.Io.Reader) !u64 {\n    var total: u64 = 0;\n    const n = try r.takeInt(u32, .little);\n    var i: u32 = 0;\n    while (i < n) : (i += 1) {\n        io.checkCancel() catch |e| switch (e) {\n            error.Canceled => continue,\n        };\n        total +%= i;\n    }\n    return total;\n}\n",
        "const wait = if (windows) waitWindows else waitPosix;\npub fn f(io: std.Io, r: *std.Io.Reader) !u64 {\n    var total: u64 = 0;\n    const n = try r.takeInt(u32, .little);\n    var i: u32 = 0;\n    while (i < n) : (i += 1) total +%= try wait(io);\n    return total;\n}\n",
        "pub fn f(io: std.Io) void {\n    while (true) if (!ready(io)) return;\n}\n",
        "pub fn f(io: std.Io) !void {\n    while (true) try renamed(io);\n}\n",
        "pub fn f(io: std.Io) void {\n    while (true) if (!found(io)) return;\n}\n",
        "pub fn f(io: std.Io, r: *std.Io.Reader) !u64 {\n    var total: u64 = 0;\n    const n = try r.takeInt(u32, .little);\n    var i: u32 = 0;\n    while (i < n) : (i += 1) {\n        if (i == 0) try io.checkCancel();\n        total +%= i;\n    }\n    return total;\n}\n",
        "pub fn f(io: std.Io) !void {\n    while (true) try rearmed(io);\n}\n",
        "pub fn f(io: std.Io) void {\n    while (true) io.checkCancel() catch return;\n}\n",
        "pub fn f(io: std.Io) void {\n    while (true) io.checkCancel() catch break;\n}\n",
    }) |body| expect(pack.cancellation, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
    // Each passes error.Canceled itself on.
    inline for (.{
        "pub fn f(io: std.Io) !void {\n    while (true) try passed(io);\n}\n",
        "pub fn f(io: std.Io) !void {\n    while (true) io.checkCancel() catch |e| return e;\n}\n",
        "pub fn f(io: std.Io) !void {\n    while (true) try mapped(io);\n}\n",
        "pub fn f(io: std.Io) !void {\n    while (true) try captured(io);\n}\n",
        "pub fn f(io: std.Io, r: *std.Io.Reader) !u64 {\n    var total: u64 = 0;\n    const n = try r.takeInt(u32, .little);\n    var i: u32 = 0;\n    while (i < n) : (i += 1) {\n        if (i % 1024 == 0) try io.checkCancel();\n        total +%= i;\n    }\n    return total;\n}\n",
        "pub fn f(io: std.Io, r: *std.Io.Reader) !u64 {\n    var total: u64 = 0;\n    var left: u32 = 0;\n    const n = try r.takeInt(u32, .little);\n    var i: u32 = 0;\n    while (i < n) : (i += 1) {\n        if (left == 0) {\n            try io.checkCancel();\n            left = 1024;\n        }\n        left -= 1;\n        total +%= i;\n    }\n    return total;\n}\n",
    }) |body| expect(pack.cancellation, head ++ body, 0) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
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

test "A015 finds the vtable slot a function is given in any file of the program, selected or not" {
    // `layer.zig`, outside the selection, gives `routedSpawn` the `processSpawn` slot; `spawn`
    // takes no userdata (7).
    const layer: sources.Extra = .{ .name = "layer.zig", .bytes =
        \\const main = @import("main.zig");
        \\fn Layer(comptime overrides: anytype) type { return struct { const slots = overrides; }; }
        \\pub const Routed = Layer(.{ .processSpawn = &main.routedSpawn });
        \\pub const Plain = Layer(.{ .start = &main.spawn });
    };
    const found = try runWith(pack.ownership,
        \\const std = @import("std");
        \\const State = struct { base: std.Io };
        \\pub fn routedSpawn(userdata: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
        \\    const state: *State = @ptrCast(@alignCast(userdata.?));
        \\    return std.process.spawn(state.base, options);
        \\}
        \\pub fn spawn(io: std.Io, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
        \\    return std.process.spawn(io, options);
        \\}
        \\pub const routed = @import("layer.zig").Routed;
    , &(std_files ++ [_]sources.Extra{layer}), &(std_imports ++ [_]sources.ExtraImport{ .{ .spelling = "layer.zig", .target = std_files.len }, .{ .from = std_files.len, .spelling = "main.zig", .target = sources.consumer_file } }));
    try std.testing.expectEqualSlices(u32, &.{7}, found.lines[0..found.findings]);
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
        \\fn awaitRequest(s: *Socket) std.Io.Cancelable!bool {
        \\    try s.io.checkCancel();
        \\    return true;
        \\}
        \\fn readPacket(s: *Socket) !u8 {
        \\    return s.reader.interface.takeByte();
        \\}
        \\fn send(io: std.Io, s: *Socket) void { _ = io; _ = s; }
        \\pub fn serve(io: std.Io, s: *Socket) !void {
        \\    _ = io;
        \\    while (true) if (!try awaitRequest(s)) return;
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
    // An allocating read is one by the type it takes, whatever its parameter is named.
    try expect(pack.bounded_work,
        \\const std = @import("std");
        \\pub fn f(in: *std.Io.Reader, body: []const u8, gpa: std.mem.Allocator) ![]u8 {
        \\    var r: std.Io.Reader = .fixed(body);
        \\    const size = try in.takeInt(u32, 0);
        \\    return r.readArena(gpa, size);
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
    // minutes negated in place, git's `tz` integer, an offset widened before it is negated. The
    // negations are clean; `tz`'s product and sum are not: its parameter's range is its caller's,
    // and at the i32's whole range `@divTrunc(abs, 60) * 100` passes the top.
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
    , 2);
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
test "A009 reads a parse's number at the bound its parser compared it with a constant on every path to its return, and judges it against the memory it indexes" {
    // The second probe review's caps (N2): a bound past the table, one against another number
    // the peer sent, a return the check does not dominate, a check on another branch, a value
    // read again after it, a bound that leaves nearly the whole range, a lower bound alone.
    const head =
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\const E = error{Short};
        \\
    ;
    try expect(pack.untrusted_input, head ++ "const Cap = struct { count: u64 };\nfn parseCap(_: void, b: []const u8) E!Cap {\n    if (b.len < 4) return error.Short;\n    const n = std.mem.readInt(u32, b[0..4], .little);\n    if (n >= 16) return error.Short;\n    return .{ .count = n };\n}\npub fn capped(r: *std.Io.Reader, table: *const [16]u8) !u8 {\n    const parsed = try aegis.input.Untrusted([]const u8).init(try r.take(4)).parse({}, parseCap);\n    return table[parsed.count];\n}\n", 0);
    inline for (.{
        "const Cap = struct { count: u32 };\nfn parseCap(_: void, b: []const u8) E!Cap {\n    if (b.len < 4) return error.Short;\n    const n = std.mem.readInt(u32, b[0..4], .little);\n    if (n >= 1_000_000) return error.Short;\n    return .{ .count = n };\n}\npub fn capped(r: *std.Io.Reader, table: *const [16]u8) !u8 {\n    const parsed = try aegis.input.Untrusted([]const u8).init(try r.take(4)).parse({}, parseCap);\n    return table[parsed.count];\n}\n",
        "const Cap = struct { count: u64 };\nfn parseCap(_: void, b: []const u8) E!Cap {\n    if (b.len < 8) return error.Short;\n    const n = std.mem.readInt(u32, b[0..4], .little);\n    const m = std.mem.readInt(u32, b[4..8], .little);\n    if (n >= m) return error.Short;\n    return .{ .count = n };\n}\npub fn capped(r: *std.Io.Reader, table: []const u8) !u8 {\n    const parsed = try aegis.input.Untrusted([]const u8).init(try r.take(8)).parse({}, parseCap);\n    return table[parsed.count];\n}\n",
        "const Cap = struct { count: u64 };\nfn parseCap(_: void, b: []const u8) E!Cap {\n    if (b.len < 5) return error.Short;\n    const n = std.mem.readInt(u32, b[0..4], .little);\n    if (b[4] == 1) return .{ .count = n };\n    if (n >= 16) return error.Short;\n    return .{ .count = n };\n}\npub fn capped(r: *std.Io.Reader, table: []const u8) !u8 {\n    const parsed = try aegis.input.Untrusted([]const u8).init(try r.take(5)).parse({}, parseCap);\n    return table[parsed.count];\n}\n",
        "const Cap = struct { count: u64 };\nfn parseCap(_: void, b: []const u8) E!Cap {\n    if (b.len < 5) return error.Short;\n    const n = std.mem.readInt(u32, b[0..4], .little);\n    if (n < 16) return .{ .count = n };\n    if (b[4] == 1) return .{ .count = n };\n    return error.Short;\n}\npub fn capped(r: *std.Io.Reader, table: []const u8) !u8 {\n    const parsed = try aegis.input.Untrusted([]const u8).init(try r.take(5)).parse({}, parseCap);\n    return table[parsed.count];\n}\n",
        "const Cap = struct { count: u64 };\nfn parseCap(_: void, b: []const u8) E!Cap {\n    if (b.len < 4) return error.Short;\n    const n = std.mem.readInt(u32, b[0..4], .little);\n    var small = false;\n    if (n < 16) small = true;\n    std.mem.doNotOptimizeAway(small);\n    return .{ .count = n };\n}\npub fn capped(r: *std.Io.Reader, table: []const u8) !u8 {\n    const parsed = try aegis.input.Untrusted([]const u8).init(try r.take(4)).parse({}, parseCap);\n    return table[parsed.count];\n}\n",
        "const Cap = struct { count: u64 };\nfn parseCap(_: void, b: []const u8) E!Cap {\n    if (b.len < 4) return error.Short;\n    const n = std.mem.readInt(u32, b[0..4], .little);\n    if (n < 16) {\n        std.mem.doNotOptimizeAway(n);\n    } else {\n        return .{ .count = n };\n    }\n    return .{ .count = 0 };\n}\npub fn capped(r: *std.Io.Reader, table: []const u8) !u8 {\n    const parsed = try aegis.input.Untrusted([]const u8).init(try r.take(4)).parse({}, parseCap);\n    return table[parsed.count];\n}\n",
        "const Cap = struct { count: u64 };\nfn parseCap(_: void, b: []const u8) E!Cap {\n    if (b.len < 8) return error.Short;\n    var n: u32 = std.mem.readInt(u32, b[0..4], .little);\n    if (n >= 16) return error.Short;\n    n = std.mem.readInt(u32, b[4..8], .little);\n    return .{ .count = n };\n}\npub fn capped(r: *std.Io.Reader, table: []const u8) !u8 {\n    const parsed = try aegis.input.Untrusted([]const u8).init(try r.take(8)).parse({}, parseCap);\n    return table[parsed.count];\n}\n",
        "const Cap = struct { count: u64 };\nfn parseCap(_: void, b: []const u8) E!Cap {\n    if (b.len < 4) return error.Short;\n    const n = std.mem.readInt(u32, b[0..4], .little);\n    if (n == 0xffff_ffff) return error.Short;\n    return .{ .count = n };\n}\npub fn capped(r: *std.Io.Reader, table: []const u8) !u8 {\n    const parsed = try aegis.input.Untrusted([]const u8).init(try r.take(4)).parse({}, parseCap);\n    return table[parsed.count];\n}\n",
        "const Cap = struct { count: usize };\nfn parseCap(_: void, b: []const u8) E!Cap {\n    if (b.len < 8) return error.Short;\n    const n = std.mem.readInt(u64, b[0..8], .little);\n    if (n > std.math.maxInt(u64) - 1) return error.Short;\n    return .{ .count = n };\n}\npub fn capped(r: *std.Io.Reader, table: []const u8) !u8 {\n    const parsed = try aegis.input.Untrusted([]const u8).init(try r.take(8)).parse({}, parseCap);\n    return table[parsed.count];\n}\n",
        "const Cap = struct { count: u64 };\nfn parseCap(_: void, b: []const u8) E!Cap {\n    if (b.len < 4) return error.Short;\n    const n = std.mem.readInt(u32, b[0..4], .little);\n    if (n < 16) return error.Short;\n    return .{ .count = n };\n}\npub fn capped(r: *std.Io.Reader, table: []const u8) !u8 {\n    const parsed = try aegis.input.Untrusted([]const u8).init(try r.take(4)).parse({}, parseCap);\n    return table[parsed.count];\n}\n",
    }) |body| expect(pack.untrusted_input, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}

test "A009 judges a byte or a short picking an entry of a table shorter than its type's range, through a parse too; a byte picks one of 256" {
    // The second probe review's tables (M-N7): a short's range is past a 256-entry table and a
    // byte's past a 16-entry one; a slice's length is the caller's.
    try expect(pack.untrusted_input, "const std = @import(\"std\");\npub fn look(r: *std.Io.Reader, table: *const [256]u8) !u8 {\n    const i: u32 = try r.takeInt(u8, .little);\n    return table[i];\n}\n", 0);
    inline for (.{
        "const std = @import(\"std\");\npub fn look(r: *std.Io.Reader, table: *const [16]u8) !u8 {\n    const i: u8 = try r.takeByte();\n    return table[i];\n}\n",
        "const std = @import(\"std\");\npub fn look(r: *std.Io.Reader, table: *const [256]u8) !u8 {\n    const i: u32 = try r.takeInt(u16, .little);\n    return table[i];\n}\n",
        "const std = @import(\"std\");\npub fn look(r: *std.Io.Reader, table: *const [256]u8) !u8 {\n    const i: u32 = try r.takeInt(u32, .little);\n    return table[i];\n}\n",
        "const std = @import(\"std\");\npub fn look(r: *std.Io.Reader, table: []const u8) !u8 {\n    const i: u32 = try r.takeInt(u16, .little);\n    return table[i];\n}\n",
        "const std = @import(\"std\");\nconst aegis = @import(\"aegis\");\nconst E = error{Short};\nconst Hdr = struct { index: u32 };\nfn parseHdr(_: void, b: []const u8) E!Hdr {\n    if (b.len < 1) return error.Short;\n    return .{ .index = b[0] };\n}\npub fn look(r: *std.Io.Reader, table: *const [16]u8) !u8 {\n    const h = try aegis.input.Untrusted([]const u8).init(try r.take(1)).parse({}, parseHdr);\n    return table[h.index];\n}\n",
        "const std = @import(\"std\");\nconst aegis = @import(\"aegis\");\nconst E = error{Short};\nconst Hdr = struct { index: u32 };\nfn parseHdr(_: void, b: []const u8) E!Hdr {\n    if (b.len < 2) return error.Short;\n    return .{ .index = std.mem.readInt(u16, b[0..2], .little) };\n}\npub fn look(r: *std.Io.Reader, table: *const [256]u8) !u8 {\n    const h = try aegis.input.Untrusted([]const u8).init(try r.take(2)).parse({}, parseHdr);\n    return table[h.index];\n}\n",
        "const std = @import(\"std\");\nconst aegis = @import(\"aegis\");\nconst E = error{Short};\nconst Hdr = struct { index: u32 };\nfn parseHdr(_: void, b: []const u8) E!Hdr {\n    if (b.len < 2) return error.Short;\n    return .{ .index = std.mem.readInt(u16, b[0..2], .little) };\n}\npub fn look(r: *std.Io.Reader, table: []const u8) !u8 {\n    const h = try aegis.input.Untrusted([]const u8).init(try r.take(2)).parse({}, parseHdr);\n    return table[h.index];\n}\n",
    }) |body| expect(pack.untrusted_input, body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}

test "A020 counts a cancellation point only where the path error.Canceled takes returns it, and a conditioned check only in the two periodic forms" {
    // The second probe review's loops (N5): a handler return Canceled never takes or never reaches,
    // a swallowing else, a helper or catch-all that maps it to another error, a capture of another
    // call, a check once by a flag, a continue, a no-op reset or a compound condition, a function
    // pointer, a per-target choice one of which never cancels, a method declared Cancelable that
    // never cancels, a vtable entry, a check after a continue, a prong that drops it beside one
    // that returns another, a whole assigned, an else that returns another error.
    const result = try run(pack.cancellation,
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\// 1. a return in the handler that Canceled never takes
        \\pub fn condReturn(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        io.checkCancel() catch |e| {
        \\            if (e != error.Canceled) return e;
        \\        };
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// 2. the Canceled prong holds a return it never reaches
        \\pub fn deadReturn(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        io.checkCancel() catch |e| switch (e) {
        \\            error.Canceled => if (total == 0xffff_ffff_ffff) return e,
        \\        };
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// 3. if/else capture that swallows
        \\pub fn elseSwallow(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        if (io.checkCancel()) |_| {} else |err| switch (err) {
        \\            error.Canceled => {},
        \\        }
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// 4. a helper that maps Canceled to another error, returned
        \\const Bad = error{Bad};
        \\fn fail(_: anyerror) Bad {
        \\    return error.Bad;
        \\}
        \\fn step(io: std.Io) Bad!void {
        \\    io.checkCancel() catch |e| return fail(e);
        \\}
        \\pub fn mappedHelper(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        step(io) catch {};
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// 5. a callee whose catch-all maps Canceled away, returned as a whole
        \\fn step2(io: std.Io) error{Timeout}!void {
        \\    return io.checkCancel() catch |e| switch (e) {
        \\        else => error.Timeout,
        \\    };
        \\}
        \\pub fn catchAll(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        try step2(io);
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// 6. a callee that returns the capture's value, but the capture was from another call
        \\fn step3(io: std.Io, r: *std.Io.Reader) !void {
        \\    io.checkCancel() catch {};
        \\    _ = r.takeByte() catch |e| return e;
        \\}
        \\pub fn otherCapture(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        try step3(io, r);
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// 7. once, by a flag
        \\pub fn onceFlag(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    var first = true;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        if (first) {
        \\            first = false;
        \\            try io.checkCancel();
        \\        }
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// 8. once, by continue before the call
        \\pub fn onceContinue(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        total +%= i;
        \\        if (i != 0) continue;
        \\        try io.checkCancel();
        \\    }
        \\    return total;
        \\}
        \\// 9. once, with a no-op reset
        \\pub fn onceNoopReset(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        if (i == 0) {
        \\            i += 0;
        \\            try io.checkCancel();
        \\        }
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// 10. once, compound condition
        \\pub fn onceAnd(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        if (i == 0 and n > 0) try io.checkCancel();
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// 11. a function pointer to a project function that never cancels
        \\fn tick(_: std.Io) std.Io.Cancelable!void {}
        \\const tickPtr: *const fn (std.Io) std.Io.Cancelable!void = &tick;
        \\pub fn fnPtr(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        try tickPtr(io);
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// 12. a switch-chosen callee per target, one choice never cancels
        \\fn waitPosix(io: std.Io) std.Io.Cancelable!void {
        \\    try io.checkCancel();
        \\}
        \\fn waitOther(_: std.Io) std.Io.Cancelable!void {}
        \\const wait = switch (builtin.os.tag) {
        \\    .linux, .macos => waitPosix,
        \\    else => waitOther,
        \\};
        \\pub fn switchChosen(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        try wait(io);
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// 13. a method that never cancels, declared Cancelable
        \\const T = struct {
        \\    io: std.Io,
        \\    fn poll(_: *T) std.Io.Cancelable!void {}
        \\};
        \\pub fn method(io: std.Io, t: *T, r: *std.Io.Reader) !u64 {
        \\    _ = &io;
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        try t.poll();
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// 14. a vtable entry
        \\const VT = struct { poll: *const fn () std.Io.Cancelable!void };
        \\pub fn vtable(io: std.Io, vt: *const VT, r: *std.Io.Reader) !u64 {
        \\    _ = &io;
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        try vt.poll();
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// 15. the cancel point after a break that always runs first
        \\pub fn afterBreak(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        total +%= i;
        \\        if (total != 0xffff_ffff_ffff) continue;
        \\        try io.checkCancel();
        \\    }
        \\    return total;
        \\}
        \\// 16. a catch whose prong names Canceled with another, returns the other only
        \\pub fn multiValue(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        _ = io.sleep(.fromMilliseconds(0), .awake) catch |e| switch (e) {
        \\            error.Canceled => {},
        \\            else => return e,
        \\        };
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// 17. returned-whole form where the prong is the capture but the whole is assigned
        \\fn step4(io: std.Io) !void {
        \\    const res = io.checkCancel() catch |e| switch (e) {
        \\        error.Canceled => e,
        \\    };
        \\    _ = res;
        \\}
        \\pub fn assignedWhole(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        try step4(io);
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// 18. the if/else form where else returns a different error
        \\fn step5(io: std.Io) error{Bad}!void {
        \\    if (io.checkCancel()) |_| {} else |err| switch (err) {
        \\        error.Canceled => return error.Bad,
        \\    }
        \\}
        \\pub fn elseOther(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        step5(io) catch {};
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
    );
    try std.testing.expectEqualSlices(u32, &.{ 8, 21, 34, 54, 70, 85, 97, 111, 123, 137, 150, 169, 185, 198, 209, 221, 241, 257 }, result.lines[0..result.findings]);
}

test "A020 goes where a break or continue goes, by its label or its loop, not by its spelling, and lets a callee leave before its point only by an error that ends the loop" {
    const head =
        \\const std = @import("std");
        \\fn quick(io: std.Io, n: *const usize) std.Io.Cancelable!usize {
        \\    if (n.* == 0) return 0;
        \\    try io.checkCancel();
        \\    return n.*;
        \\}
        \\fn readSome(io: std.Io, n: *const usize) (std.Io.Cancelable || error{Empty})!usize {
        \\    if (n.* == 0) return error.Empty;
        \\    while (true) {
        \\        try io.checkCancel();
        \\        if (n.* != 0) return n.*;
        \\    }
        \\}
        \\fn whileCounted(io: std.Io, n: *usize) std.Io.Cancelable!usize {
        \\    while (n.* < 10) {
        \\        try io.checkCancel();
        \\        n.* += 1;
        \\    }
        \\    return n.*;
        \\}
        \\fn breaksFirst(io: std.Io, n: *const usize) std.Io.Cancelable!usize {
        \\    while (true) {
        \\        if (n.* == 0) break;
        \\        try io.checkCancel();
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
        \\
    ;
    // Each has a pass that goes on without the point: a continue of the loop, a break of a block
    // around the point, the point in a loop that may not run, a callee that returns a value before
    // it, and a handler that goes on with the loop after an error.
    inline for (.{
        "pub fn f(io: std.Io, skip: *const bool) !void {\n    while (true) {\n        if (skip.*) continue;\n        try io.checkCancel();\n    }\n}\n",
        "pub fn f(io: std.Io, skip: *const bool) !void {\n    outer: while (true) {\n        if (skip.*) continue :outer;\n        try io.checkCancel();\n    }\n}\n",
        "pub fn f(io: std.Io, skip: *const bool) !void {\n    while (true) {\n        blk: {\n            if (skip.*) break :blk;\n            try io.checkCancel();\n        }\n    }\n}\n",
        "pub fn f(io: std.Io, skip: *const bool) !void {\n    while (true) body: {\n        if (skip.*) break :body;\n        try io.checkCancel();\n    }\n}\n",
        "pub fn f(io: std.Io, xs: []const u8) !void {\n    while (true) {\n        for (xs) |x| {\n            if (x == 0) break;\n            try io.checkCancel();\n        }\n    }\n}\n",
        "pub fn f(io: std.Io, n: *const usize) !void {\n    while (true) _ = try quick(io, n);\n}\n",
        "pub fn f(io: std.Io, n: *const usize) !void {\n    while (true) {\n        _ = readSome(io, n) catch |err| switch (err) {\n            error.Canceled => return error.Canceled,\n            error.Empty => continue,\n        };\n    }\n}\n",
        "pub fn f(io: std.Io, n: *const usize) !void {\n    while (true) {\n        _ = readSome(io, n) catch |err| switch (err) {\n            error.Canceled => return error.Canceled,\n            error.Empty => {},\n        };\n    }\n}\n",
        "pub fn f(io: std.Io, n: *usize) !void {\n    while (true) _ = try whileCounted(io, n);\n}\n",
        "pub fn f(io: std.Io, n: *const usize) !void {\n    while (true) _ = try breaksFirst(io, n);\n}\n",
        "pub fn f(io: std.Io, done: *const bool) !void {\n    while (true) {\n        while (true) {\n            if (done.*) break;\n            try io.checkCancel();\n        }\n    }\n}\n",
    }) |body| expect(pack.cancellation, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
    // Each reaches the point on every pass that goes on: a break of the loop ends it, a jump
    // inside a statement ends only what it names, a callee leaves before its point only by an
    // error the loop ends on, and a `while (true)` runs its first pass.
    inline for (.{
        "pub fn f(io: std.Io, done: *const bool) !void {\n    while (true) {\n        if (done.*) break;\n        try io.checkCancel();\n    }\n}\n",
        "pub fn f(io: std.Io, done: *const bool) !void {\n    outer: while (true) {\n        if (done.*) break :outer;\n        try io.checkCancel();\n    }\n}\n",
        "pub fn f(io: std.Io, done: *const bool) !void {\n    outer: while (true) {\n        try io.checkCancel();\n        while (true) {\n            if (done.*) continue :outer;\n            try io.checkCancel();\n        }\n    }\n}\n",
        "pub fn f(io: std.Io, xs: []const u8) !void {\n    while (true) {\n        for (xs) |x| {\n            if (x == 0) break;\n            if (x == 1) continue;\n        }\n        try io.checkCancel();\n    }\n}\n",
        "pub fn f(io: std.Io, xs: []const u8) !void {\n    while (true) {\n        const first = blk: {\n            if (xs.len == 0) break :blk 0;\n            break :blk xs[0];\n        };\n        _ = first;\n        try io.checkCancel();\n    }\n}\n",
        "pub fn f(io: std.Io, n: *const usize) !void {\n    while (true) _ = try readSome(io, n);\n}\n",
        "pub fn f(io: std.Io, n: *const usize) !void {\n    while (true) {\n        _ = readSome(io, n) catch |err| switch (err) {\n            error.Canceled => return error.Canceled,\n            error.Empty => return,\n        };\n    }\n}\n",
        "pub fn f(io: std.Io, n: *const usize) !void {\n    while (true) {\n        _ = readSome(io, n) catch |err| switch (err) {\n            error.Canceled => return error.Canceled,\n            else => break,\n        };\n    }\n}\n",
        "pub fn f(io: std.Io, done: *const bool) !void {\n    while (true) {\n        while (true) {\n            try io.checkCancel();\n            if (done.*) break;\n        }\n    }\n}\n",
    }) |body| expect(pack.cancellation, head ++ body, 0) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}

/// `run` with the fixture std and a dependency imported as "dep", not selected.
fn runWithDependency(rule: glint.Rule, program: []const u8, dependency: []const u8) !Run {
    const files = std_files ++ [_]sources.Extra{.{ .name = "dep/dep.zig", .bytes = dependency }};
    const imports = std_imports ++ [_]sources.ExtraImport{ .{ .spelling = "dep", .target = std_files.len }, .{ .from = std_files.len, .spelling = "std", .target = 0 } };
    var project = try sources.projectWithSources(std.testing.allocator, program, &files, &imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .report }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var result: Run = .{ .findings = 0, .undecided = 0 };
    for (report.diagnostics) |d| if (d.rule == rule) {
        result.findings += 1;
    };
    for (report.coverage) |item| if (item.rule != null and item.rule.? == rule) {
        result.undecided += 1;
    };
    return result;
}

test "A020 takes a periodic point's counter only where the function alone writes it: never one written through its address or a container's" {
    // A helper given the counter's address sets it every pass, so `n % 64` never reaches 0; a
    // container's counter any other code may set; each a counting-down form too.
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\fn hold(n: *u32) void {
        \\    n.* = 1;
        \\}
        \\pub fn byAddress(io: std.Io, flag: *bool) !void {
        \\    var n: u32 = 0;
        \\    while (true) {
        \\        n += 1;
        \\        hold(&n);
        \\        if (n % 64 == 0) try io.checkCancel();
        \\        if (flag.*) break;
        \\    }
        \\}
        \\pub fn downByAddress(io: std.Io, flag: *bool) !void {
        \\    var left: u32 = 64;
        \\    while (true) {
        \\        left -= 1;
        \\        hold(&(left));
        \\        if (left == 0) {
        \\            left = 64;
        \\            try io.checkCancel();
        \\        }
        \\        if (flag.*) break;
        \\    }
        \\}
        \\var shared: u32 = 0;
        \\pub fn byContainer(io: std.Io, flag: *bool) !void {
        \\    while (true) {
        \\        shared += 1;
        \\        if (shared % 64 == 0) try io.checkCancel();
        \\        if (flag.*) break;
        \\    }
        \\}
    , 3);
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\pub fn local(io: std.Io, flag: *bool) !void {
        \\    var n: u32 = 0;
        \\    while (true) {
        \\        n += 1;
        \\        if (n % 64 == 0) try io.checkCancel();
        \\        if (flag.*) break;
        \\    }
        \\}
        \\pub fn down(io: std.Io, flag: *bool) !void {
        \\    var left: u32 = 64;
        \\    while (true) {
        \\        left -= 1;
        \\        if (left == 0) {
        \\            left = 64;
        \\            try io.checkCancel();
        \\        }
        \\        if (flag.*) break;
        \\    }
        \\}
    , 0);
}

test "A020 reads a loop bound by input by what bounds it: a for range's end, each comparison a while condition joins" {
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\pub fn ranged(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    _ = io;
        \\    const n = try r.takeInt(u32, .little);
        \\    var total: u64 = 0;
        \\    for (0..n) |i| total +%= i;
        \\    return total;
        \\}
        \\pub fn joined(io: std.Io, r: *std.Io.Reader, stop: *const bool) !u64 {
        \\    _ = io;
        \\    const n = try r.takeInt(u32, .little);
        \\    var total: u64 = 0;
        \\    var i: u32 = 0;
        \\    while (i < n and !stop.*) : (i += 1) total +%= i;
        \\    return total;
        \\}
    , 2);
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\pub fn ranged(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    const n = try r.takeInt(u32, .little);
        \\    var total: u64 = 0;
        \\    for (0..n) |i| {
        \\        try io.checkCancel();
        \\        total +%= i;
        \\    }
        \\    for (0..16) |i| total +%= i;
        \\    return total;
        \\}
        \\pub fn joined(io: std.Io, r: *std.Io.Reader, stop: *const bool) !u64 {
        \\    const n = try r.takeInt(u32, .little);
        \\    var total: u64 = 0;
        \\    var i: u32 = 0;
        \\    while (i < n and !stop.*) : (i += 1) {
        \\        try io.checkCancel();
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
    , 0);
}

test "A020 reads what decides how long a while runs by meaning: a variable by each value it is given, a payload or a call's truth from input, a condition nothing in the loop changes as while (true)" {
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\pub fn churn(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    _ = io;
        \\    var more = (try r.takeByte()) != 0;
        \\    var total: u64 = 0;
        \\    const seed = try r.takeInt(u64, .little);
        \\    while (more) {
        \\        total +%= seed;
        \\        more = total != seed *% 7;
        \\    }
        \\    return total;
        \\}
        \\pub fn count(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    _ = io;
        \\    var left: ?u32 = try r.takeInt(u32, .little);
        \\    var total: u64 = 0;
        \\    while (left) |n| {
        \\        total +%= n;
        \\        left = if (n == 0) null else n - 1;
        \\    }
        \\    return total;
        \\}
        \\pub fn stuck(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    _ = io;
        \\    const go = (try r.takeByte()) & 1 != 0;
        \\    var total: u64 = 0;
        \\    while (go) total +%= 1;
        \\    return total;
        \\}
        \\pub fn asked(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    _ = io;
        \\    const seed = try r.takeInt(u64, .little);
        \\    var total: u64 = 0;
        \\    while (notYet(total, seed)) total +%= 3;
        \\    return total;
        \\}
        \\fn notYet(total: u64, seed: u64) bool {
        \\    return total != seed;
        \\}
    , 4);
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\pub fn churn(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var more = (try r.takeByte()) != 0;
        \\    var total: u64 = 0;
        \\    const seed = try r.takeInt(u64, .little);
        \\    while (more) {
        \\        try io.checkCancel();
        \\        total +%= seed;
        \\        more = total != seed *% 7;
        \\    }
        \\    return total;
        \\}
        \\pub fn varint(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    _ = io;
        \\    var more = true;
        \\    var value: u64 = 0;
        \\    while (more) {
        \\        const b = try r.takeByte();
        \\        value = value << 7 | (b & 0x7f);
        \\        more = b & 0x80 != 0;
        \\    }
        \\    return value;
        \\}
        \\pub fn small(io: std.Io) u64 {
        \\    _ = io;
        \\    var i: u32 = 0;
        \\    var total: u64 = 0;
        \\    while (i != 16) : (i += 1) total +%= i;
        \\    return total;
        \\}
    , 0);
}

test "A020 bounds a while by what decides it where the program checked that against the memory it holds, each value a variable is given; not where it did not" {
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\pub fn drain(io: std.Io, r: *std.Io.Reader, buf: []const u8) !u64 {
        \\    _ = io;
        \\    var n: usize = try r.takeInt(u32, .little);
        \\    var total: u64 = 0;
        \\    var more = n != 0;
        \\    while (more) {
        \\        total +%= n;
        \\        n -= 1;
        \\        more = n != 0;
        \\    }
        \\    return total +% buf.len;
        \\}
    , 1);
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\pub fn drain(io: std.Io, r: *std.Io.Reader, buf: []const u8) !u64 {
        \\    _ = io;
        \\    var n: usize = try r.takeInt(u32, .little);
        \\    if (n > buf.len) return error.TooLong;
        \\    var total: u64 = 0;
        \\    var more = n != 0;
        \\    while (more) {
        \\        total +%= n;
        \\        n -= 1;
        \\        more = n != 0;
        \\    }
        \\    return total;
        \\}
    , 0);
}

test "A020 reads a labeled switch that continues itself as a loop, each prong that goes on as a pass, and a function given an Io by its receiver's field" {
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\pub fn spin(io: std.Io) void {
        \\    _ = io;
        \\    var n: u64 = 0;
        \\    state: switch (@as(u8, 0)) {
        \\        0 => {
        \\            n +%= 1;
        \\            continue :state 1;
        \\        },
        \\        else => continue :state 0,
        \\    }
        \\}
        \\pub fn half(io: std.Io) !void {
        \\    var n: u64 = 0;
        \\    state: switch (@as(u8, 0)) {
        \\        0 => {
        \\            try io.checkCancel();
        \\            continue :state 1;
        \\        },
        \\        1 => {
        \\            n +%= 1;
        \\            continue :state 0;
        \\        },
        \\        else => {},
        \\    }
        \\}
        \\const Worker = struct {
        \\    io: std.Io,
        \\    count: u64 = 0,
        \\    pub fn run(self: *Worker) void {
        \\        while (true) self.count +%= 1;
        \\    }
        \\};
        \\pub fn start(w: *Worker) void {
        \\    w.run();
        \\}
    , 3);
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\pub fn spin(io: std.Io) !void {
        \\    var n: u64 = 0;
        \\    state: switch (@as(u8, 0)) {
        \\        0 => {
        \\            try io.checkCancel();
        \\            n +%= 1;
        \\            continue :state 1;
        \\        },
        \\        1 => {
        \\            try io.checkCancel();
        \\            continue :state 0;
        \\        },
        \\        else => {},
        \\    }
        \\}
        \\pub fn once(io: std.Io, x: u8) u8 {
        \\    _ = io;
        \\    return blk: switch (x) {
        \\        0 => break :blk 1,
        \\        else => break :blk 2,
        \\    };
        \\}
        \\const Worker = struct {
        \\    io: std.Io,
        \\    count: u64 = 0,
        \\    pub fn run(self: *Worker) !void {
        \\        while (true) {
        \\            try self.io.checkCancel();
        \\            self.count +%= 1;
        \\        }
        \\    }
        \\};
        \\pub fn start(w: *Worker) !void {
        \\    try w.run();
        \\}
    , 0);
}

test "A020 reads a dependency's function by its body, as the program's: a declared error.Canceled is no cancellation point outside std" {
    const dependency =
        \\const std = @import("std");
        \\pub fn tick(io: std.Io) std.Io.Cancelable!void {
        \\    _ = io;
        \\}
        \\pub fn real(io: std.Io) std.Io.Cancelable!void {
        \\    try io.checkCancel();
        \\}
    ;
    const head =
        \\const std = @import("std");
        \\const dep = @import("dep");
        \\
    ;
    const declared = try runWithDependency(pack.cancellation, head ++ "pub fn f(io: std.Io) !void {\n    while (true) try dep.tick(io);\n}\n", dependency);
    try std.testing.expectEqual(@as(usize, 0), declared.undecided);
    try std.testing.expectEqual(@as(usize, 1), declared.findings);
    const reached = try runWithDependency(pack.cancellation, head ++ "pub fn f(io: std.Io) !void {\n    while (true) try dep.real(io);\n}\n", dependency);
    try std.testing.expectEqual(@as(usize, 0), reached.undecided);
    try std.testing.expectEqual(@as(usize, 0), reached.findings);
}

test "A020 reads an error returned as a value as no cancellation point: a dropped arm, a swallowing else, a value from the error, a payload that can hold it" {
    // The second probe review's helpers (N5): `case_e` returns the capture from a function whose
    // payload (`?anyerror`) can take it as a value; `case_g`'s helpers pass it on.
    const result = try run(pack.cancellation,
        \\const std = @import("std");
        \\// a) whole returned, the Canceled arm drops it
        \\fn armDrops(io: std.Io) !void {
        \\    return io.checkCancel() catch |e| switch (e) {
        \\        error.Canceled => {},
        \\    };
        \\}
        \\pub fn case_a(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        try armDrops(io);
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// b) if/else capture whose else swallows
        \\fn elseSwallows(io: std.Io) !void {
        \\    if (io.checkCancel()) |_| {} else |err| switch (err) {
        \\        error.Canceled => {},
        \\    }
        \\}
        \\pub fn case_b(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        try elseSwallows(io);
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// c) whole returned, catch-all maps Canceled to a value
        \\fn catchAllValue(io: std.Io) !bool {
        \\    return if (io.checkCancel()) |_| true else |err| switch (err) {
        \\        else => false,
        \\    };
        \\}
        \\pub fn case_c(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        _ = try catchAllValue(io);
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// d) the handler returns a value computed from the error: false on cancel
        \\fn isFatal(e: anyerror) bool {
        \\    return e == error.Unexpected;
        \\}
        \\fn toValue(io: std.Io) !bool {
        \\    io.checkCancel() catch |e| return isFatal(e);
        \\    return true;
        \\}
        \\pub fn case_d(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        _ = try toValue(io);
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// e) the if/else form, the else returns a value naming the capture
        \\fn elseValue(io: std.Io) !?anyerror {
        \\    if (io.checkCancel()) |_| {} else |err| return err;
        \\    return null;
        \\}
        \\pub fn case_e(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        _ = try elseValue(io);
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// f) whole returned, prong value is the error, but the function's type makes it a value
        \\fn asValue(io: std.Io) anyerror {
        \\    return io.checkCancel() catch |err| switch (err) {
        \\        error.Canceled => error.Canceled,
        \\    };
        \\}
        \\pub fn case_f(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        _ = asValue(io);
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\// g) the safe twins
        \\fn passes(io: std.Io) !void {
        \\    return io.checkCancel() catch |err| switch (err) {
        \\        error.Canceled => error.Canceled,
        \\    };
        \\}
        \\fn elsePasses(io: std.Io) !void {
        \\    if (io.checkCancel()) |_| {} else |err| return err;
        \\}
        \\pub fn case_g(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        try passes(io);
        \\        try elsePasses(io);
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
    );
    try std.testing.expectEqualSlices(u32, &.{ 12, 28, 44, 62, 77, 93 }, result.lines[0..result.findings]);
}

test "A020 reads a method by its body, not its declared error set, however it is called" {
    // The second probe review's methods: declared Cancelable through a pointer, by value and called
    // through its type, never cancels; a plain method gives the loop nothing.
    const result = try run(pack.cancellation,
        \\const std = @import("std");
        \\const T = struct {
        \\    io: std.Io,
        \\    // declares Cancelable, never cancels
        \\    fn poll(_: *T) std.Io.Cancelable!void {}
        \\    fn plain(_: *T) void {}
        \\};
        \\pub fn declared(io: std.Io, t: *T, r: *std.Io.Reader) !u64 {
        \\    _ = &io;
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        try t.poll();
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\pub fn plainBase(io: std.Io, t: *T, r: *std.Io.Reader) !u64 {
        \\    _ = &io;
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        t.plain();
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\pub fn valueRecv(io: std.Io, t: T, r: *std.Io.Reader) !u64 {
        \\    var tt = t;
        \\    _ = &io;
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        try tt.poll();
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
        \\pub fn direct(io: std.Io, t: *T, r: *std.Io.Reader) !u64 {
        \\    _ = &io;
        \\    var total: u64 = 0;
        \\    const n = try r.takeInt(u32, .little);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        try T.poll(t);
        \\        total +%= i;
        \\    }
        \\    return total;
        \\}
    );
    try std.testing.expectEqualSlices(u32, &.{ 13, 24, 36, 47 }, result.lines[0..result.findings]);
}

test "A009 reads an array parameter's length from its declared type: a checked byte, a byte into 256 entries" {
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, table: [16]u8) !u8 {
        \\    const b = try r.takeByte();
        \\    if (b >= 16) return 0;
        \\    return table[b];
        \\}
        \\pub fn g(r: *std.Io.Reader, table: *const [256]u8) !u8 {
        \\    return table[try r.takeByte()];
        \\}
    , 0);
    // An unchecked byte past a 16-entry array, a check past its length.
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, table: *const [16]u8) !u8 {
        \\    return table[try r.takeByte()];
        \\}
        \\pub fn g(r: *std.Io.Reader, table: [16]u8) !u8 {
        \\    const b = try r.takeByte();
        \\    if (b > 16) return 0;
        \\    return table[b];
        \\}
    , 2);
}

test "A009 reads a short read's count as at most its buffer's length, and a least of several as at most each" {
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, table: []const u8) !u8 {
        \\    var buf: [8]u8 = undefined;
        \\    const got = try r.readSliceShort(&buf);
        \\    _ = buf[0..got];
        \\    const b = try r.takeByte();
        \\    _ = table[0 .. table.len - @min(b, table.len)];
        \\    return table[@min(b, table.len - 1)];
        \\}
    , 0);
    // A count read into a larger buffer than the one sliced, a least still at the length, and a
    // length less what may be zero.
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, table: []const u8) !u8 {
        \\    var big: [8]u8 = undefined;
        \\    var small: [4]u8 = undefined;
        \\    const many = try r.readSliceShort(&big);
        \\    _ = small[0..many];
        \\    const b = try r.takeByte();
        \\    _ = table[@min(b, table.len)];
        \\    return table[table.len - b];
        \\}
    , 3);
}

test "A010 reads a position a std search found as below a length, a call by what the program's function returns, and one less a value above zero" {
    try expect(pack.integers,
        \\const std = @import("std");
        \\fn twenty() usize {
        \\    return 20;
        \\}
        \\pub fn f(r: *std.Io.Reader) !u128 {
        \\    const line = try r.take(16);
        \\    const space = std.mem.findScalar(u8, line, ' ') orelse return 0;
        \\    const b: usize = try r.takeByte();
        \\    _ = b + twenty();
        \\    const k = try r.takeInt(u8, 0);
        \\    if (k >= 128) return 0;
        \\    return (@as(u128, 1) << @intCast(k)) - 1 + space + 1;
        \\}
    , 0);
    // A function that returns what it is given, a shifted even value that may leave zero, and
    // a number from input plus one.
    try expect(pack.integers,
        \\const std = @import("std");
        \\fn same(v: usize) usize {
        \\    return v;
        \\}
        \\pub fn f(r: *std.Io.Reader, x: usize) !u128 {
        \\    const b: usize = try r.takeByte();
        \\    _ = b + same(x);
        \\    const k = try r.takeInt(u8, 0);
        \\    if (k >= 128) return 0;
        \\    _ = (@as(u128, 2) << @intCast(k)) - 1;
        \\    return try r.takeInt(u64, 0) + 1;
        \\}
    , 3);
}

test "A009 leaves a loop that consumes on every pass a return or try may end, and finds one a continue may skip" {
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, bytes: []const u8) !void {
        \\    var cp: []const u8 = bytes;
        \\    var n = try r.takeInt(u32, 0);
        \\    while (n > 0) : (n -= 1) {
        \\        if (cp.len == 0) return;
        \\        const slash = std.mem.findScalar(u8, cp, '/') orelse return error.Short;
        \\        cp = cp[slash + 1 ..];
        \\    }
        \\}
    , 0);
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, bytes: []const u8) !void {
        \\    var cp: []const u8 = bytes;
        \\    var n = try r.takeInt(u32, 0);
        \\    while (n > 0) : (n -= 1) {
        \\        if (cp.len == 0) continue;
        \\        const slash = std.mem.findScalar(u8, cp, '/') orelse return error.Short;
        \\        cp = cp[slash + 1 ..];
        \\    }
        \\}
    , 1);
}

test "A020 reads a check a function body may return before as no cancellation point of a call, and one a loop's pass may return before as one" {
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\pub fn f(io: std.Io, r: *std.Io.Reader) !void {
        \\    const n = try r.takeInt(u32, 0);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        if (i == 7) return;
        \\        try io.checkCancel();
        \\    }
        \\}
    , 0);
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\fn step(io: std.Io, i: u32) !void {
        \\    if (i != 7) return;
        \\    try io.checkCancel();
        \\}
        \\pub fn f(io: std.Io, r: *std.Io.Reader) !void {
        \\    const n = try r.takeInt(u32, 0);
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) try step(io, i);
        \\}
    , 1);
}

test "A009 reads std's Zig tree as its parse's check where a parser handed to input.Untrusted.parse makes it, and the text it carries as input" {
    const head =
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\const Front = struct { tree: std.zig.Ast };
        \\fn parseZig(_: void, source: []const u8) error{OutOfMemory}!Front {
        \\    return .{ .tree = try std.zig.Ast.parse({}, source, .{}) };
        \\}
        \\
    ;
    try expect(pack.untrusted_input, head ++
        \\pub fn f(r: *std.Io.Reader, table: []const u8) !u8 {
        \\    const front = try aegis.input.Untrusted([]const u8).init(try r.take(16)).parse({}, parseZig);
        \\    return table[front.tree.nodes[front.tree.nodeData(3)]];
        \\}
    , 0);
    // A tree std's parser makes outside a parse, and the tree's text: its source and a token's.
    inline for (.{
        "pub fn f(r: *std.Io.Reader, table: []const u8) !u8 {\n    const tree = try std.zig.Ast.parse({}, try r.take(16), .{});\n    return table[tree.nodeData(3)];\n}\n",
        "pub fn f(r: *std.Io.Reader, table: []const u8) !u8 {\n    const front = try aegis.input.Untrusted([]const u8).init(try r.take(16)).parse({}, parseZig);\n    return table[front.tree.source[0]];\n}\n",
        "pub fn f(r: *std.Io.Reader, table: []const u8) !u8 {\n    const front = try aegis.input.Untrusted([]const u8).init(try r.take(16)).parse({}, parseZig);\n    return table[front.tree.tokenSlice(0)[0]];\n}\n",
    }) |body| expect(pack.untrusted_input, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
}

test "A007 reads only aegis's guards as holding a container var's state, and a sync type's value named through it as held" {
    // An id and a Shared handle guard nothing; a lock's `init` named through its type is one.
    try expect(pack.shared_state,
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\const Tag = struct {};
        \\var next: aegis.id.Id(Tag, u32) = @enumFromInt(0);
        \\pub fn f() void {
        \\    var lock = std.Io.Mutex.init;
        \\    std.Io.Mutex.lock(&lock);
        \\}
    , 2);
    try expect(pack.shared_state,
        \\const aegis = @import("aegis");
        \\var cell: aegis.Atomic(u32) = .init(0);
    , 0);
}

test "A007 finds std's synchronization a dependency names under its own name, held by the program, and a futex on a raw word" {
    const dependency =
        \\const std = @import("std");
        \\pub const Lock = std.Io.Mutex;
        \\pub fn Cell(comptime T: type) type {
        \\    return std.atomic.Value(T);
        \\}
        \\pub const Plain = struct { n: u32 };
        \\pub const Elsewhere = @import("missing.zig").Lock;
    ;
    // A field, an array of optionals, a cell a function makes, the program's alias (its one
    // site), a type argument and a `return`'s value; a futex wake on a plain word.
    const found = try runWithDependency(pack.shared_state,
        \\const std = @import("std");
        \\const dep = @import("dep");
        \\const Shared = struct { lock: dep.Lock = .init, many: [2]?dep.Lock, hits: dep.Cell(u32) };
        \\const Lock = dep.Lock;
        \\const Again = struct { lock: Lock };
        \\pub fn make(a: anytype) !*dep.Lock { return a.create(dep.Lock); }
        \\pub fn Made() type { return dep.Lock; }
        \\pub fn open(io: std.Io, word: *u32) void { io.futexWake(u32, word, 1); }
    , dependency);
    try std.testing.expectEqual(@as(usize, 0), found.undecided); // safe: fixture counts are representable.
    try std.testing.expectEqual(@as(usize, 7), found.findings);
    // Borrowed, a type the dependency makes that holds no lock, test code.
    const clean = try runWithDependency(pack.shared_state,
        \\const dep = @import("dep");
        \\const Borrow = struct { lock: *dep.Lock, cell: ?*const dep.Cell(u32), plain: dep.Plain };
        \\pub fn f(l: *dep.Lock) *dep.Lock { return l; }
        \\test { var lock: dep.Lock = .init; lock.lock(); }
    , dependency);
    try std.testing.expectEqual(@as(usize, 0), clean.undecided); // safe: fixture counts are representable.
    try std.testing.expectEqual(@as(usize, 0), clean.findings);
    // A type the dependency names that does not resolve may be one: undecided, never clean.
    const unknown = try runWithDependency(pack.shared_state,
        \\const dep = @import("dep");
        \\const Held = struct { lock: [2]dep.Elsewhere };
    , dependency);
    try std.testing.expectEqual(@as(usize, 1), unknown.undecided); // safe: fixture counts are representable.
    try std.testing.expectEqual(@as(usize, 0), unknown.findings);
}

test "A013 reads std's assert called through any alias the program declares, public too, and leaves one taken as a value undecided" {
    try expect(pack.contracts,
        \\const std = @import("std");
        \\pub const check = std.debug.assert;
        \\pub fn f(r: *std.Io.Reader) !u8 {
        \\    const b = try r.takeByte();
        \\    check(b < 4);
        \\    return b;
        \\}
    , 1);
    const result = try run(pack.contracts,
        \\const std = @import("std");
        \\fn apply(f: *const fn (bool) void, ok: bool) void {
        \\    f(ok);
        \\}
        \\pub fn g(r: *std.Io.Reader) !void {
        \\    apply(&std.debug.assert, try r.takeByte() < 4);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), result.undecided);
}

test "A015 reads a capture as a view only where what it binds is one" {
    // A file a call opened, unwrapped by a capture and returned, is an owner handed over.
    try expect(pack.ownership,
        \\const std = @import("std");
        \\pub fn open(dir: std.Io.Dir, io: std.Io) ?std.Io.File {
        \\    if (dir.openFile(io, "a", .{})) |f| return f else |_| return null;
        \\}
    , 1);
}

test "A021 holds a guard until a release of its own block runs, and one bound by no declaration to the block's end" {
    const head =
        \\const aegis = @import("aegis");
        \\const A = aegis.Guarded(u32);
        \\
    ;
    inline for (.{
        "pub fn f(a: *A, b: *A, c: bool) void {\n    var g = a.acquire();\n    if (c) g.deinit();\n    var h = b.acquire();\n    h.deinit();\n}\n",
        "pub fn f(a: *A, b: *A) void {\n    a.acquire().data.* += 1;\n    var h = b.acquire();\n    h.deinit();\n}\n",
    }) |body| expect(pack.lock_order, head ++ body, 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{body});
        return err;
    };
    try expect(pack.lock_order, head ++ "pub fn f(a: *A, b: *A) void {\n    var g = a.acquire();\n    g.deinit();\n    var h = b.acquire();\n    h.deinit();\n}\n", 0);
}

test "A010 reads a slice's length as its bounds set it, apart from what it holds: through a local, a parameter, a field, a return and a reassignment" {
    // Each way in its own function, as a difference a safe build ran keeps its operand past it.
    const result = try run(pack.integers,
        \\const std = @import("std");
        \\const Holder = struct { part: []const u8 };
        \\fn take(s: []const u8) usize {
        \\    return s.len - 86;
        \\}
        \\fn prefix(out: *[512]u8, n: usize) []u8 {
        \\    return out[0..n];
        \\}
        \\const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        \\var holder: Holder = .{ .part = "" };
        \\fn read(r: *std.Io.Reader) !usize {
        \\    return try r.takeInt(u16, .little);
        \\}
        \\pub fn local(r: *std.Io.Reader, out: *[512]u8) !usize {
        \\    const bytes = out[0..try read(r)];
        \\    return bytes.len - 86;
        \\}
        \\pub fn tail(r: *std.Io.Reader, out: *[512]u8) !usize {
        \\    const rest = out[try read(r)..];
        \\    return rest.len - 86;
        \\}
        \\pub fn param(r: *std.Io.Reader, out: *[512]u8) !usize {
        \\    return take(out[0..try read(r)]);
        \\}
        \\pub fn reassigned(r: *std.Io.Reader, out: *[512]u8) !usize {
        \\    var moved: []u8 = out[0..0];
        \\    moved = out[0..try read(r)];
        \\    return moved.len - 86;
        \\}
        \\pub fn field(r: *std.Io.Reader, out: *[512]u8) !usize {
        \\    holder.part = out[0..try read(r)];
        \\    return holder.part.len - 86;
        \\}
        \\pub fn returned(r: *std.Io.Reader, out: *[512]u8) !usize {
        \\    return prefix(out, try read(r)).len - 86;
        \\}
        \\pub fn table(r: *std.Io.Reader) !u64 {
        \\    const n = try read(r);
        \\    var total: u64 = 0;
        \\    for (days[0..@min(n, days.len)]) |d| total += d;
        \\    return total;
        \\}
    );
    // Each difference, and no sum of the table's own days: at most 12 passes of a byte each.
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 4, 16, 20, 28, 32, 35 }, result.lines[0..result.findings]);
}

test "A010 reads what a function stores through a parameter in its callers' memory: a value through a pointer, a slice through a pointer to it, and on through a caller that passes its own parameter" {
    const program =
        \\const std = @import("std");
        \\fn setValue(out: *usize, r: *std.Io.Reader) !void {
        \\    out.* = try r.takeInt(u16, .little);
        \\}
        \\fn setSlice(out: *[]u8, memory: *[512]u8, n: usize) void {
        \\    out.* = memory[0..n];
        \\}
        \\fn relay(out: *usize, r: *std.Io.Reader) !void {
        \\    try setValue(out, r);
        \\}
        \\pub fn f(r: *std.Io.Reader) !usize {
        \\    var x: usize = 0;
        \\    try setValue(&x, r);
        \\    var y: usize = 0;
        \\    try relay(&y, r);
        \\    var memory: [512]u8 = @splat(0);
        \\    var s: []u8 = memory[0..0];
        \\    const n: usize = try r.takeInt(u16, .little);
        \\    setSlice(&s, &memory, n);
        \\    var z: usize = 0;
        \\    z = 7;
        \\    return (x - 1) +% (y - 1) +% (s.len - 1) +% (z - 1);
        \\}
    ;
    try expect(pack.integers, program, 3);
}

test "A010 reads a bound past a u128 as past it: a sum or a conversion into a type of 128 bits or more, exact up to 255 bits" {
    const program =
        \\const std = @import("std");
        \\fn grows(r: u128) u128 {
        \\    return r + 1;
        \\}
        \\fn narrows(r: u128) u128 {
        \\    const wide: u136 = r;
        \\    return @intCast(wide + 1);
        \\}
        \\fn widens(r: u128) u136 {
        \\    const wide: u136 = r;
        \\    return wide + std.math.maxInt(u128);
        \\}
        \\pub fn f(r: *std.Io.Reader) !u136 {
        \\    const value = try r.takeInt(u128, .little);
        \\    return grows(value) +% narrows(value) +% widens(value);
        \\}
    ;
    // `r + 1` and the conversion each pass the type's greatest; a u136 holds the sum of two u128s.
    try expect(pack.integers, program, 2);
}

fn runWithFile(rule: glint.Rule, program: []const u8, other: []const u8) !Run {
    var files: [std_files.len + 1]sources.Extra = undefined;
    @memcpy(files[0..std_files.len], &std_files);
    files[std_files.len] = .{ .name = "other.zig", .bytes = other };
    var imports: [std_imports.len + 2]sources.ExtraImport = undefined;
    @memcpy(imports[0..std_imports.len], &std_imports);
    imports[std_imports.len] = .{ .spelling = "other.zig", .target = std_files.len };
    imports[std_imports.len + 1] = .{ .from = std_files.len, .spelling = "std", .target = 0 };
    var project = try sources.projectWithSources(std.testing.allocator, program, &files, &imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .report }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var result: Run = .{ .findings = 0, .undecided = 0 };
    for (report.diagnostics) |d| if (d.rule == rule) {
        if (result.findings < result.lines.len) result.lines[result.findings] = d.span.line;
        result.findings += 1;
    };
    for (report.coverage) |item| if (item.rule != null and item.rule.? == rule) {
        result.undecided += 1;
    };
    return result;
}

test "A009 reads a callee in a file the run did not select as the program's own: what it reads is input" {
    const result = try runWithFile(pack.untrusted_input,
        \\const std = @import("std");
        \\const other = @import("other.zig");
        \\pub fn f(r: *std.Io.Reader, table: []const u8) !u8 {
        \\    const i = try other.get(r);
        \\    return table[i];
        \\}
    ,
        \\const std = @import("std");
        \\pub fn get(r: *std.Io.Reader) !u32 {
        \\    return r.takeInt(u32, .little);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqualSlices(u32, &.{5}, result.lines[0..result.findings]);
}

test "A009 follows input through a chain of calls of any length: the fact's rounds end when nothing changes" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "const std = @import(\"std\");\npub fn sink(r: *std.Io.Reader, table: []const u8) !u8 {\n    return table[try g80(r)];\n}\n");
    // Each function calls the one below it, declared after it: one round reaches one step.
    var i: usize = 80;
    while (i > 0) : (i -= 1) {
        const line = try std.testing.allocator.print("fn g{d}(r: *std.Io.Reader) !u32 {{\n    return g{d}(r);\n}}\n", .{ i, i - 1 });
        defer std.testing.allocator.free(line);
        try text.appendSlice(std.testing.allocator, line);
    }
    try text.appendSlice(std.testing.allocator, "fn g0(r: *std.Io.Reader) !u32 {\n    return r.takeInt(u32, .little);\n}\n");
    try expect(pack.untrusted_input, text.items, 1);
}

test "A010 reads a union's payload through a prong's capture: the field the prong names, every field under else" {
    const program =
        \\const std = @import("std");
        \\const V = union(enum) { num: u32, bytes: []u8, none };
        \\fn decode(r: *std.Io.Reader) !V {
        \\    return .{ .num = try r.takeInt(u32, .little) };
        \\}
        \\pub fn f(r: *std.Io.Reader, memory: *[512]u8) !usize {
        \\    const n: usize = try r.takeInt(u16, .little);
        \\    const v: V = .{ .bytes = memory[0..@min(n, memory.len)] };
        \\    const a: usize = switch (try decode(r)) {
        \\        .num => |x| x + 1,
        \\        else => 0,
        \\    };
        \\    const b: usize = switch (v) {
        \\        .bytes => |s| s.len - 86,
        \\        else => 0,
        \\    };
        \\    const c: usize = switch (v) {
        \\        .none => 0,
        \\        else => |w| switch (w) {
        \\            .bytes => |s| s.len - 1,
        \\            else => 0,
        \\        },
        \\    };
        \\    return a +% b +% c;
        \\}
    ;
    // x + 1 overflows (line 10), s.len - 86 and s.len - 1 underflow (14, 20).
    try expect(pack.integers, program, 3);
}

test "A010 reads a field `@field` names by its declaration, and a value read whole holds each of its fields" {
    const program =
        \\const std = @import("std");
        \\const S = struct { num: u32, other: u32 };
        \\const P = packed struct { lo: u32, hi: u32 };
        \\pub fn f(r: *std.Io.Reader) !u64 {
        \\    const v: S = .{ .num = try r.takeInt(u32, .little), .other = 0 };
        \\    const w: P = .{ .lo = try r.takeInt(u32, .little), .hi = 0 };
        \\    const raw: u64 = @bitCast(w);
        \\    return (@field(v, "num") + 1) +% (raw + 1);
        \\}
    ;
    try expect(pack.integers, program, 2);
}

test "A010 follows a pointer to where it is kept: a store through a struct's field, a literal, a vector, a global or a capture writes what it points at" {
    const program =
        \\const std = @import("std");
        \\const H = struct { p: *u32 };
        \\var target: *u32 = undefined;
        \\fn setValue(out: *u32, r: *std.Io.Reader) !void {
        \\    out.* = try r.takeInt(u32, .little);
        \\}
        \\fn set(h: H, r: *std.Io.Reader) !void {
        \\    h.p.* = try r.takeInt(u32, .little);
        \\}
        \\fn setAll(outs: []const *u32, r: *std.Io.Reader) !void {
        \\    for (outs) |o| o.* = try r.takeInt(u32, .little);
        \\}
        \\fn setTarget(r: *std.Io.Reader) !void {
        \\    target.* = try r.takeInt(u32, .little);
        \\}
        \\pub fn f(r: *std.Io.Reader) !u32 {
        \\    var a: u32 = 0;
        \\    const h: H = .{ .p = &a };
        \\    try setValue(h.p, r);
        \\    var b: u32 = 0;
        \\    try set(.{ .p = &b }, r);
        \\    var c: u32 = 0;
        \\    try setAll(&.{&c}, r);
        \\    var d: u32 = 0;
        \\    target = &d;
        \\    try setTarget(r);
        \\    var e: [4]u32 = @splat(0);
        \\    for (&e) |*slot| slot.* = try r.takeInt(u32, .little);
        \\    return (a + 1) +% (b + 1) +% (c + 1) +% (d + 1) +% (e[0] + 1);
        \\}
    ;
    try expect(pack.integers, program, 5);
}
