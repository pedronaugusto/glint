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
    \\pub const meta = @import("meta.zig");
    },
    .{ .name = "std/Io.zig", .bytes =
    \\pub const File = @import("Io/File.zig");
    \\pub const Reader = @import("Io/Reader.zig");
    \\pub const Limit = Reader.Limit;
    \\pub const Dir = struct { handle: i32, pub fn close(dir: Dir) void { _ = dir; } pub fn openFile(dir: Dir, io: anytype, sub_path: []const u8, options: anytype) !void { _ = dir; _ = io; _ = sub_path; _ = options; } pub fn readFileAlloc(dir: Dir, io: anytype, sub_path: []const u8, gpa: anytype, limit: usize) ![]u8 { _ = dir; _ = io; _ = sub_path; _ = gpa; _ = limit; return &.{}; } pub fn statFile(dir: Dir, io: anytype, sub_path: []const u8) !u64 { _ = dir; _ = io; _ = sub_path; return 0; } pub fn readLink(dir: Dir, io: anytype, sub_path: []const u8, buffer: []u8) !usize { _ = dir; _ = io; _ = sub_path; _ = buffer; return 0; } };
    \\pub const Writer = struct { buffer: []u8 = &.{}, end: usize = 0, vtable: *const Writer.VTable = undefined, pub const VTable = struct { drain: *const fn (*Writer, []const []const u8, usize) anyerror!usize }; pub fn writeAll(w: *Writer, bytes: []const u8) !void { _ = w; _ = bytes; } pub fn print(w: *Writer, comptime format: []const u8, args: anytype) !void { _ = w; _ = format; _ = args; } pub fn fixed(buffer: []u8) Writer { return .{ .buffer = buffer }; } pub fn buffered(w: *const Writer) []u8 { return w.buffer[0..w.end]; } pub fn unusedCapacitySlice(w: *const Writer) []u8 { return w.buffer[w.end..]; } };
    \\pub fn random(io: @This(), buffer: []u8) void { _ = io; _ = buffer; }
    \\pub fn protocolWriter(buffer: []u8) Writer { _ = buffer; return .{}; }
    \\pub const net = struct { pub const Stream = struct { handle: i32, pub fn close(s: *const Stream) void { _ = s; } pub fn writer(s: Stream, buffer: []u8) Writer { _ = s; _ = buffer; return .{}; } }; pub const Server = struct { stream: Stream }; };
    \\pub const Cancelable = error{Canceled};
    \\pub fn checkCancel(io: @This()) error{Canceled}!void { _ = io; }
    \\pub fn recancel(io: @This()) void { _ = io; }
    \\pub fn concurrent(io: @This(), function: anytype, args: @import("std").meta.ArgsTuple(@TypeOf(function))) error{ConcurrencyUnavailable}!void { const erased: *const anyopaque = @ptrCast(&args); _ = erased; _ = io; }
    \\pub fn futexWait(io: @This(), comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T) error{Canceled}!void { _ = io; _ = ptr; _ = expected; }
    \\pub fn futexWaitTimeout(io: @This(), comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T, timeout: u64) error{Canceled}!void { _ = io; _ = ptr; _ = expected; _ = timeout; }
    \\pub fn futexWaitUncancelable(io: @This(), comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T) void { _ = io; _ = ptr; _ = expected; }
    \\pub fn futexWake(io: @This(), comptime T: type, ptr: *align(@alignOf(u32)) const T, max_waiters: u32) void { _ = io; _ = ptr; _ = max_waiters; }
    \\pub const Mutex = extern struct { state: u32 = 0, pub const init: Mutex = .{}; pub fn lock(m: *Mutex) void { _ = m; } };
    \\pub const RwLock = struct { state: u32 = 0 };
    \\pub const Handle = @import("root").Handle;
    \\pub const VTable = struct { close: *const fn (?*anyopaque, Handle) void, write: *const fn (?*anyopaque, Handle, []const u8) void, processSpawn: *const fn (?*anyopaque) void, futexWait: *const fn (?*anyopaque, *const u32, u32) error{Canceled}!void, futexWaitUncancelable: *const fn (?*anyopaque, *const u32, u32) void, futexWake: *const fn (?*anyopaque, *const u32, u32) void };
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
    .{ .name = "std/Io/File.zig", .bytes = "handle: i32,\nconst File = @This();\npub const Handle = i32;\npub fn stdin() @This() { return .{ .handle = 0 }; }\npub fn stdout() @This() { return .{ .handle = 1 }; }\npub fn stderr() @This() { return .{ .handle = 2 }; }\npub fn close(f: @This()) void { _ = f; }\npub const Reader = struct { io: ?*anyopaque = null, file: File = undefined, interface: @import(\"Reader.zig\"), err: ?anyerror = null };\npub fn reader(f: @This(), io: anytype, buffer: []u8) Reader { _ = io; _ = buffer; return .{ .file = f, .interface = .{} }; }\npub fn writer(f: @This(), io: anytype, buffer: []u8) void { _ = f; _ = io; _ = buffer; }\npub fn readStreaming(f: @This(), io: anytype, buffer: []const []u8) !usize { _ = f; _ = io; _ = buffer; return 0; }\npub fn readPositional(f: @This(), io: anytype, buffer: []const []u8, offset: u64) !usize { _ = f; _ = io; _ = buffer; _ = offset; return 0; }" },
    .{ .name = "std/process.zig", .bytes = "pub const Child = struct { id: i32, pub fn kill(child: *Child) void { _ = child; } pub fn wait(child: *Child) !void { _ = child; } };\npub const RunResult = struct { stdout: []u8 = &.{}, stderr: []u8 = &.{} };\npub fn run(gpa: anytype, io: anytype, options: anytype) !RunResult { _ = gpa; _ = io; _ = options; return .{}; }" },
    .{ .name = "std/array_list.zig", .bytes = "pub fn Aligned(comptime T: type, comptime a: ?u8) type { _ = a; return struct { items: []T = &.{}, capacity: usize = 0, pub fn append(self: *@This(), x: T) void { _ = self; _ = x; } pub fn deinit(self: *@This(), gpa: anytype) void { _ = gpa; const held = self.capacity; _ = held; self.* = undefined; } }; }" },
    .{ .name = "std/hash_map.zig", .bytes = "pub fn AutoHashMapUnmanaged(comptime K: type, comptime V: type) type { return struct { k: K, v: V, pub fn getPtr(self: *@This(), key: K) ?*V { _ = key; return &self.v; } }; }" },
    .{ .name = "std/array_hash_map.zig", .bytes = "pub const Nothing = struct {};" },
    .{ .name = "std/Io/Reader.zig", .bytes =
    \\buffer: []u8 = &.{},
    \\seek: usize = 0,
    \\end: usize = 0,
    \\pub const Limit = enum(usize) { unlimited = 0, _ };
    \\pub fn fixed(bytes: []const u8) @This() { _ = bytes; return .{}; }
    \\pub fn takeByte(r: *@This()) !u8 { if (r.seek == r.end) return error.EndOfStream; return 0; }
    \\pub fn takeInt(r: *@This(), comptime T: type, endian: u1) !T { _ = endian; if (r.seek == r.end) return error.EndOfStream; return 0; }
    \\pub fn fill(r: *@This(), n: usize) !void { if (r.seek + n > r.end) return error.EndOfStream; }
    \\pub fn takeFresh(r: *@This()) !usize { if (r.seek == r.end) return error.EndOfStream; return 0; }
    \\pub fn take(r: *@This(), n: usize) ![]u8 { try r.fill(n); return r.buffer; }
    \\pub fn toss(r: *@This(), n: usize) void { r.seek += n; assert(r.seek <= r.end); }
    \\fn assert(ok: bool) void { if (!ok) unreachable; }
    \\pub fn readSliceAll(r: *@This(), buffer: []u8) !void { if (buffer.len > r.end - r.seek) return error.EndOfStream; }
    \\pub fn readSliceShort(r: *@This(), buffer: []u8) !usize { if (r.seek == r.end) return error.ReadFailed; return buffer.len; }
    \\pub fn limited(r: *@This(), limit: Limit, buffer: []u8) @This() { _ = r; _ = limit; _ = buffer; return .{}; }
    \\pub fn allocRemaining(r: *@This(), gpa: anytype, limit: Limit) ![]u8 { _ = gpa; _ = limit; if (r.seek == r.end) return error.ReadFailed; return r.buffer; }
    \\pub fn readAlloc(r: *@This(), gpa: @import("../mem.zig").Allocator, len: usize) ![]u8 { _ = r; return gpa.alloc(u8, len); }
    \\pub fn readArena(r: *@This(), arena: @import("../mem.zig").Allocator, len: usize) ![]u8 { _ = r; return arena.alloc(u8, len); }
    },
    .{ .name = "std/mem.zig", .bytes = "pub fn asBytes(ptr: anytype) []u8 { _ = ptr; return &.{}; }\npub fn sort(comptime T: type, items: []T, context: anytype, comptime lessThan: fn (@TypeOf(context), T, T) bool) void { _ = items; _ = lessThan; }\npub fn eql(comptime T: type, a: []const T, b: []const T) bool { _ = a; _ = b; return false; }\npub fn writeInt(comptime T: type, buffer: *[4]u8, value: T, endian: anytype) void { _ = buffer; _ = value; _ = endian; }\npub fn readInt(comptime T: type, buffer: anytype, endian: anytype) T { _ = buffer; _ = endian; return 0; }\npub fn findScalar(comptime T: type, s: []const T, v: T) ?usize { _ = s; _ = v; return null; }\npub fn total(items: anytype) usize { return items.count(); }\npub fn findScalarPos(comptime T: type, s: []const T, start: usize, v: T) ?usize { for (s[start..], start..) |x, i| if (x == v) return i; return null; }\npub const Allocator = struct { ptr: *anyopaque, pub fn alloc(self: Allocator, comptime T: type, n: usize) ![]T { _ = self.rawAlloc(n * @sizeOf(T)); return &.{}; } pub fn create(self: Allocator, comptime T: type) !*T { _ = self.rawAlloc(@sizeOf(T)); return undefined; } pub fn destroy(self: Allocator, ptr: anytype) void { const bytes: [*]u8 = @ptrCast(@constCast(ptr)); _ = self; _ = bytes; } pub fn rawAlloc(self: Allocator, len: usize) ?[*]u8 { _ = self; _ = len; return null; } };" },
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
    \\pub fn minInt(comptime T: type) comptime_int { const info = @typeInfo(T); const bit_count = info.int.bits; if (info.int.signedness == .unsigned) return 0; if (bit_count == 0) return 0; return -(1 << (bit_count - 1)); }
    \\pub fn divCeil(comptime T: type, numerator: T, denominator: T) !T {
    \\    @setRuntimeSafety(false);
    \\    if (denominator == 0) return error.DivisionByZero;
    \\    if (@typeInfo(T) == .int and numerator == minInt(T) and denominator == -1) {
    \\        return error.Overflow;
    \\    }
    \\    return @divCeil(numerator, denominator);
    \\}
    \\pub inline fn maxInt(comptime T: type) comptime_int { const info = @typeInfo(T); const bit_count = info.int.bits; if (bit_count == 0) return 0; return (1 << (bit_count - @intFromBool(info.int.signedness == .signed))) - 1; }
    },
    .{ .name = "std/zig.zig", .bytes =
    \\pub const Ast = struct {
    \\    source: []const u8,
    \\    nodes: []const Node.Index,
    \\    starts: []const u32,
    \\    pub const TokenIndex = u32;
    \\    pub const Node = struct { pub const Index = enum(u32) { root = 0, _ }; };
    \\    pub const Location = struct { line: usize, column: usize };
    \\    pub fn parse(gpa: anytype, source: []const u8, mode: anytype) error{OutOfMemory}!Ast { _ = gpa; _ = mode; return .{ .source = source, .nodes = &.{}, .starts = &.{} }; }
    \\    pub fn nodeData(tree: Ast, node: Node.Index) Node.Index { return tree.nodes[@intFromEnum(node)]; }
    \\    pub fn firstToken(tree: Ast, node: Node.Index) TokenIndex { return @intFromEnum(tree.nodes[@intFromEnum(node)]); }
    \\    pub fn tokenSlice(tree: Ast, token: TokenIndex) []const u8 { return tree.source[token..]; }
    \\    pub fn tokenStart(tree: Ast, token: TokenIndex) u32 { return tree.starts[token]; }
    \\    pub fn tokenLocation(tree: Ast, start: usize, token: TokenIndex) Location { return .{ .line = tree.starts[token] + start, .column = 0 }; }
    \\    pub fn rootDecls(tree: Ast) []const Node.Index { return tree.nodes; }
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
    // `Io.concurrent`'s and `Io.async`'s arguments: the tuple of the function's parameters.
    .{ .name = "std/meta.zig", .bytes =
    \\pub fn ArgsTuple(comptime Function: type) type {
    \\    const info = @typeInfo(Function);
    \\    if (info != .@"fn") @compileError("ArgsTuple expects a function type");
    \\    const function_info = info.@"fn";
    \\    var argument_field_list: [function_info.param_types.len]type = undefined;
    \\    inline for (function_info.param_types, 0..) |arg_type, i| {
    \\        const T = arg_type orelse @compileError("cannot create ArgsTuple for function with an 'anytype' parameter");
    \\        argument_field_list[i] = T;
    \\    }
    \\    return @Tuple(&argument_field_list);
    \\}
    },
};
const std_imports = [_]sources.ExtraImport{
    .{ .from = 0, .spelling = "c.zig", .target = 24 },
    .{ .from = 0, .spelling = "os.zig", .target = 25 },
    .{ .from = 0, .spelling = "meta.zig", .target = 26 },
    // std's own files import std, as `Io.concurrent`'s `@import("std").meta.ArgsTuple` does.
    .{ .from = 1, .spelling = "std", .target = 0 },
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
    // File.Reader's `interface`, the reader it reads through.
    .{ .from = 7, .spelling = "Reader.zig", .target = 12 },
    // The reader's allocating reads take std's Allocator.
    .{ .from = 12, .spelling = "../mem.zig", .target = 13 },
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
/// A run's findings and undecided sites of a rule; `unbound` of the undecided are the pack's
/// note at a public generic nothing the run binds.
const Run = struct {
    findings: usize,
    undecided: usize,
    unbound: usize = 0,
    lines: [32]u32 = @splat(0),
    fn countUndecided(result: *Run, report: glint.Report, rule: glint.Rule) void {
        for (report.coverage) |item| if (item.rule != null and item.rule.? == rule) {
            result.undecided += 1;
            if (std.mem.eql(u8, item.detail, "unbound generic: judged at its consumers' bindings")) result.unbound += 1;
        };
    }
};
fn run(rule: glint.Rule, program: []const u8) !Run {
    return runWith(rule, program, &std_files, &std_imports);
}
fn runWith(rule: glint.Rule, program: []const u8, extra: []const sources.Extra, imports: []const sources.ExtraImport) !Run {
    return runAs(rule, program, .{}, extra, imports);
}
/// `runWith`, the program compiled as `as` says.
fn runAs(rule: glint.Rule, program: []const u8, as: sources.Consumer, extra: []const sources.Extra, imports: []const sources.ExtraImport) !Run {
    var project = try sources.projectAs(std.testing.allocator, program, as, extra, imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = rule, .level = .report }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var result: Run = .{ .findings = 0, .undecided = 0 };
    // A fixture std's AstGen refuses is not checked at all: it would pass any count of none.
    for (report.coverage) |item| try std.testing.expect(item.reason != .invalid_syntax and item.reason != .invalid_lowering);
    for (report.diagnostics) |d| if (d.rule == rule) {
        if (result.findings < result.lines.len) result.lines[result.findings] = d.span.line;
        result.findings += 1;
    };
    result.countUndecided(report, rule);
    return result;
}
/// `expect` for a program whose public generics nothing binds, as the row means them to be:
/// undecided only by `notes` notes at their names.
fn expectNoted(rule: glint.Rule, program: []const u8, notes: usize, findings: usize) !void {
    const result = try run(rule, program);
    try std.testing.expectEqual(notes, result.undecided);
    try std.testing.expectEqual(notes, result.unbound);
    try std.testing.expectEqual(findings, result.findings);
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

test "A007 and A008 read a tuple by its parts, a chain of orelse to its payload, and errors, error sets and imports as holding none" {
    // A tuple holding a lock or a key a call gives is a finding, as the call's result is; an error
    // set, an error capture, an enum literal in a tuple and `a orelse b orelse return` hold none,
    // and a capture of a value a peer with `null` made optional, an element of a choice of a
    // slice and `&.{}` or of a named tuple, holds what the value does; a typeless literal's
    // field names are strings, and `{}` bound to an `anytype` is void.
    try expect(pack.shared_state,
        \\const std = @import("std");
        \\const Error = error{Gone};
        \\const Failure = Error || error{Lost};
        \\fn first(m: *std.Io.Mutex) ?*std.Io.Mutex { return m; }
        \\fn second(m: *std.Io.Mutex) ?*std.Io.Mutex { return m; }
        \\fn make() std.Io.Mutex { return .init; }
        \\fn g() Error!void {}
        \\pub fn f(m: *std.Io.Mutex, n: u32) Failure!u32 {
        \\    const p = first(m) orelse second(m) orelse return error.Gone;
        \\    _ = p;
        \\    g() catch |err| return err;
        \\    const key = .{ n, .tag, "name" };
        \\    const both = .{ n, make() };
        \\    _ = .{ key, both };
        \\    return n;
        \\}
        \\fn cut(s: []const u8) ?struct { []const u8, []const u8 } { return .{ s, s }; }
        \\pub fn h(s: []const u8, found: ?[]const u32) void {
        \\    const name, const place = cut(s) orelse .{ s, null };
        \\    _ = name;
        \\    if (place) |words| _ = words;
        \\    for (if (found) |list| list else &.{}) |each| _ = each;
        \\}
        \\fn apply(v: u32, context: anytype) u32 {
        \\    _ = context;
        \\    return v;
        \\}
        \\pub fn k(v: u32) u32 {
        \\    const record = .{ .a = v };
        \\    inline for (@typeInfo(@TypeOf(record)).@"struct".field_names) |name| _ = name;
        \\    const kinds = .{ .{ "pointer", .pointer }, .{ "optional", .optional } };
        \\    inline for (kinds) |kind| if (kind[0].len == 1) return 0;
        \\    return apply(v, {});
        \\}
    , 2);
    try expect(pack.secrets,
        \\const std = @import("std");
        \\const dep = @import("dep.zig");
        \\const Error = error{Gone};
        \\const Failure = Error || error{Lost};
        \\const Ed25519 = std.crypto.sign.Ed25519;
        \\fn make() Ed25519.KeyPair { return Ed25519.KeyPair.generate(); }
        \\fn g() Error!void {}
        \\pub fn f(n: u32) Failure!u32 {
        \\    g() catch |err| return err;
        \\    const key = .{ n, .tag };
        \\    const both = .{ n, make() };
        \\    _ = .{ key, both };
        \\    return n;
        \\}
    , 2);
    // A ZON file's import is its value, which may be a key: one the run did not load is
    // undecided, never clean.
    const unloaded = try run(pack.secrets,
        \\const data = @import("data.zon");
        \\pub fn f() void { _ = data; }
    );
    try std.testing.expectEqual(@as(usize, 0), unloaded.findings);
    try std.testing.expectEqual(@as(usize, 1), unloaded.undecided);
    // The same import of a manifest the run loads is the value its ZON gives, read as any
    // value is: a build script's `@import("build.zig.zon")` holds strings, a number, enum
    // literals and records of them, no lock and no key.
    const manifest: sources.Extra = .{ .name = "build.zig.zon", .kind = .zon, .bytes =
        \\.{
        \\    .name = .pkg,
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x77d01758a12937de,
        \\    .paths = .{ "build.zig", "build.zig.zon", "src" },
        \\    .dependencies = .{ .dep = .{ .url = "git+https://example.com/dep?ref=v1#00", .hash = "dep-1.0.0-AAAA" } },
        \\}
    };
    const build_script =
        \\const zon = @import("build.zig.zon");
        \\pub fn version() []const u8 {
        \\    return zon.version;
        \\}
    ;
    for ([_]glint.Rule{ pack.shared_state, pack.secrets }) |rule| {
        const loaded = try runWith(rule, build_script, &(std_files ++ [_]sources.Extra{manifest}), &(std_imports ++ [_]sources.ExtraImport{.{ .spelling = "build.zig.zon", .target = std_files.len }}));
        try std.testing.expectEqual(@as(usize, 0), loaded.findings);
        try std.testing.expectEqual(@as(usize, 0), loaded.undecided);
    }
}

/// A dependency's records and type functions: what it holds is the program's, judged where the
/// program holds it, since no run selecting the program judges the dependency's fields.
const held_dependency: sources.Extra = .{ .name = "dep/root.zig", .bytes =
    \\const std = @import("std");
    \\const Ed25519 = std.crypto.sign.Ed25519;
    \\pub const Shared = struct { lock: std.Io.Mutex = .init, count: u32 = 0 };
    \\pub const Plain = struct { count: u32 = 0 };
    \\pub fn Box(comptime T: type) type { return struct { value: T, tag: u8 = 0 }; }
    \\pub const Locked = Box(std.Io.Mutex);
    \\pub const Counted = Box(u32);
    \\pub const Kind = enum { a, init };
    \\pub const types = [_]type{ std.Io.Mutex, Kind };
    \\pub fn Pick(comptime n: usize) type { return types[n]; }
    \\pub fn make() std.Io.Mutex { return .init; }
    \\pub const Wallet = struct { key: Ed25519.SecretKey, label: u8 };
    \\pub const Shown = struct { key: Ed25519.PublicKey, label: u8 };
};

/// The program's import of `held_dependency`, and the dependency's of std.
const held_imports = [_]sources.ExtraImport{ .{ .spelling = "dep", .target = std_files.len }, .{ .from = std_files.len, .spelling = "std", .target = 0 } };

test "A007 and A008 read a value's type by its meaning: a type function's result, a tuple type, a dependency's record, and a decl literal" {
    // Findings: a dependency's record holding a lock by value and one its generic makes over a
    // lock; a tuple type holding one (a parameter); a local typed by the program's type
    // function reading `@typeInfo` (as std.meta.Child does) and one a dependency picks from a
    // table, each given the decl literal `.init`. Clean: the same over a number, a table's
    // enum given its tag `.init`, a record holding none.
    const program =
        \\const std = @import("std");
        \\const dep = @import("dep");
        \\fn Child(comptime T: type) type {
        \\    return switch (@typeInfo(T)) {
        \\        .pointer => |info| info.child,
        \\        .optional => |info| info.child,
        \\        else => @compileError("no child"),
        \\    };
        \\}
        \\pub const Server = struct { a: dep.Shared = .{}, b: dep.Locked = undefined, c: dep.Counted = undefined, d: dep.Plain = .{} };
        \\pub fn run(p: struct { @TypeOf(dep.make()), u32 }, q: struct { u32, u8 }) u32 {
        \\    var m: Child(*const std.Io.Mutex) = .init;
        \\    var n: Child(*const u32) = 0;
        \\    var picked: dep.Pick(0) = .init;
        \\    const kind: dep.Pick(1) = .init;
        \\    _ = .{ &m, &n, &picked, kind, q };
        \\    return p[1];
        \\}
    ;
    const found = try runWith(pack.shared_state, program, &(std_files ++ [_]sources.Extra{held_dependency}), &(std_imports ++ held_imports));
    try std.testing.expectEqual(@as(usize, 0), found.undecided);
    try std.testing.expectEqual(@as(usize, 5), found.findings);
    // Findings: a dependency's record holding a key by value, a tuple type holding one, and a
    // key typed by a type function; clean: the public key in each.
    const keys =
        \\const std = @import("std");
        \\const dep = @import("dep");
        \\const Ed25519 = std.crypto.sign.Ed25519;
        \\fn Child(comptime T: type) type {
        \\    return switch (@typeInfo(T)) {
        \\        .pointer => |info| info.child,
        \\        else => @compileError("no child"),
        \\    };
        \\}
        \\pub fn a(w: dep.Wallet, s: dep.Shown) void { _ = .{ w, s }; }
        \\pub fn b(k: struct { Ed25519.SecretKey, u8 }, p: struct { Ed25519.PublicKey, u8 }) void { _ = .{ k, p }; }
        \\pub fn c(k: Child(*const Ed25519.SecretKey), p: Child(*const Ed25519.PublicKey)) void { _ = .{ k, p }; }
    ;
    const secret = try runWith(pack.secrets, keys, &(std_files ++ [_]sources.Extra{held_dependency}), &(std_imports ++ held_imports));
    try std.testing.expectEqual(@as(usize, 0), secret.undecided);
    try std.testing.expectEqual(@as(usize, 3), secret.findings);
}

test "A007 and A008 judge a local known only as the program compiles at each call's bindings, and read std.meta.Child of an array (sweep 2 class 4)" {
    // Findings: a local typed by Child of an array of locks in a function with a comptime
    // parameter it does not depend on, one bound to an array of locks by a call, and that call's
    // type argument. Clean: the same bound to an array of counters. Undecided: a public function
    // nothing here calls.
    const program =
        \\const std = @import("std");
        \\fn Child(comptime T: type) type {
        \\    return switch (@typeInfo(T)) {
        \\        .array => |info| info.child,
        \\        .vector => |info| info.child,
        \\        else => @compileError("no child"),
        \\    };
        \\}
        \\fn step(comptime by: u32, counter: *u32) void {
        \\    var lock: Child([1]std.Io.Mutex) = undefined;
        \\    _ = &lock;
        \\    counter.* += by;
        \\}
        \\fn hold(comptime T: type, counter: *u32) void {
        \\    var held: Child(T) = undefined;
        \\    _ = &held;
        \\    counter.* += 1;
        \\}
        \\pub fn open(comptime T: type) void {
        \\    var held: Child(T) = undefined;
        \\    _ = &held;
        \\}
        \\pub fn run(counter: *u32) void {
        \\    step(2, counter);
        \\    hold([1]std.Io.Mutex, counter);
        \\    hold([1]u32, counter);
        \\}
    ;
    const found = try runWith(pack.shared_state, program, &std_files, &std_imports);
    try std.testing.expectEqual(@as(usize, 2), found.undecided);
    // One of them the note at a public generic nothing the run binds.
    try std.testing.expectEqual(@as(usize, 1), found.unbound);
    try std.testing.expectEqual(@as(usize, 3), found.findings);
    const keys =
        \\const std = @import("std");
        \\const Ed25519 = std.crypto.sign.Ed25519;
        \\fn Child(comptime T: type) type {
        \\    return switch (@typeInfo(T)) {
        \\        .array => |info| info.child,
        \\        .vector => |info| info.child,
        \\        else => @compileError("no child"),
        \\    };
        \\}
        \\fn hold(comptime T: type) void {
        \\    var held: Child(T) = undefined;
        \\    _ = &held;
        \\}
        \\pub fn open(comptime T: type) void {
        \\    var held: Child(T) = undefined;
        \\    _ = &held;
        \\}
        \\pub fn run() void {
        \\    hold([1]Ed25519.SecretKey);
        \\    hold([1]Ed25519.PublicKey);
        \\}
    ;
    const secret = try runWith(pack.secrets, keys, &std_files, &std_imports);
    try std.testing.expectEqual(@as(usize, 2), secret.undecided);
    // One of them the note at a public generic nothing the run binds.
    try std.testing.expectEqual(@as(usize, 1), secret.unbound);
    try std.testing.expectEqual(@as(usize, 1), secret.findings);
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

test "A013 leaves a .? whose optional holds a value on every path: checked or set, a capture's else that sets it, a bool that says so (Bounds' presence)" {
    try expect(pack.contracts,
        \\const std = @import("std");
        \\const D = struct { closing: ?u8 = null, n: u8 = 0 };
        \\pub fn place(d: *D, r: *std.Io.Reader) !u8 {
        \\    const b = try r.takeByte();
        \\    if (d.closing == null) d.closing = b;
        \\    return d.closing.?;
        \\}
        \\pub fn local(r: *std.Io.Reader) !u8 {
        \\    const b = try r.takeByte();
        \\    var x: ?u8 = null;
        \\    if (b > 3) x = b;
        \\    if (x == null) x = 0;
        \\    return x.?;
        \\}
        \\pub fn captured(d: *D, r: *std.Io.Reader) !u8 {
        \\    const b = try r.takeByte();
        \\    if (d.closing) |*k| k.* +%= 1 else d.closing = b;
        \\    return d.closing.?;
        \\}
        \\pub fn flagged(r: *std.Io.Reader, workers: []const bool) !u8 {
        \\    const b = try r.takeByte();
        \\    const got: ?u8 = if (b > 3) b else null;
        \\    var refused = got == null;
        \\    for (workers) |w| refused = refused or w;
        \\    if (!refused) return got.?;
        \\    return 0;
        \\}
        \\pub fn after(d: *D, r: *std.Io.Reader) !u8 {
        \\    d.closing = try r.takeByte();
        \\    d.n = d.closing.?;
        \\    return d.closing.?;
        \\}
    , 0);
}

test "A013 leaves a catch unreachable whose call never fails there: a divisor at least 1 to std's divCeil read at the call's binding, a program callee's failing exit ruled out, a comptime false that returns first" {
    try expect(pack.contracts,
        \\const std = @import("std");
        \\const tile = 1 << 16;
        \\fn outer(d: usize) !usize {
        \\    if (d == 0) return error.Zero;
        \\    return d;
        \\}
        \\fn load(comptime careful: bool, have: usize, n: usize) !usize {
        \\    if (!careful) return n;
        \\    if (have < n) return error.NeedInput;
        \\    return n;
        \\}
        \\pub fn constant(r: *std.Io.Reader) !usize {
        \\    const in = try r.take(8);
        \\    return std.math.divCeil(usize, in[0], tile) catch unreachable;
        \\}
        \\pub fn plus(r: *std.Io.Reader) !usize {
        \\    const in = try r.take(8);
        \\    return std.math.divCeil(usize, in[0], @as(usize, in[1]) + 1) catch unreachable;
        \\}
        \\pub fn program(r: *std.Io.Reader) !usize {
        \\    const in = try r.take(8);
        \\    return outer(@as(usize, in[0]) + 1) catch unreachable;
        \\}
        \\pub fn fast(r: *std.Io.Reader) !usize {
        \\    const in = try r.take(8);
        \\    return load(false, in[0], in[1]) catch unreachable;
        \\}
    , 0);
}

test "A013 leaves what runs as the program compiles, and tests, alone" {
    try expectNoted(pack.contracts,
        \\const std = @import("std");
        \\pub fn Make(comptime n: usize) type { if (n == 0) unreachable; return struct { pub fn get() usize { return n; } }; }
        \\const table = blk: { if (false) unreachable; break :blk 1; };
        \\pub fn f() void { comptime std.debug.assert(true); }
        \\test { std.debug.assert(true); }
    , 1, 0);
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
    // A const of a run-time value, a local whose type only its value gives, a var alias and an
    // alias of an alias. (Stores into another object's field or a global are no longer A014's:
    // the 0.8 cut keeps the certain return shape.)
    try expect(pack.lifetimes, "pub fn f(x: u8) []const u8 { const buf = [_]u8{ x, 1 }; return buf[0..]; }", 1);
    try expect(pack.lifetimes, "pub fn f(n: usize) []u8 { var buf = [_]u8{ 0, 0, 0, 0 }; buf[0] = 1; return buf[0..n]; }", 1);
    try expect(pack.lifetimes, "pub fn f() *u32 { var x: u32 = 1; x += 1; var p: *u32 = undefined; p = &x; return p; }", 1);
    try expect(pack.lifetimes, "pub fn f() *u32 { var x: u32 = 1; x += 1; const a = &x; const b = a; return b; }", 1);
    // Stored by a destructure into a `var` alias that is returned.
    try expect(pack.lifetimes, "pub fn f() *u32 { var x: u32 = 1; x += 1; var p: *u32 = undefined; p, _ = .{ &x, 0 }; return p; }", 1);
    // A slice of a pointer local points where the pointer does: into a local array it was
    // given, and nowhere in the frame where it is made from an integer, its type unresolved (a
    // generic's `@TypeOf(slice.ptr)`, relic-b's warp c.zig:774).
    try expect(pack.lifetimes, "pub fn f(n: u8) []u8 { var buf: [4]u8 = .{ n, n, n, n }; buf[0] = 1; const p: [*]u8 = &buf; return p[0..2]; }", 1);
    try expectNoted(pack.lifetimes, "fn m(s: anytype, at: usize) @TypeOf(s) { const p: @TypeOf(s.ptr) = @ptrFromInt(at); return p[0..s.len]; } pub fn f(x: anytype) void { _ = m(x, 8); }", 1, 0);
    try expectNoted(pack.lifetimes, "fn m(s: anytype, at: usize) @TypeOf(s) { const p: @TypeOf(s.ptr) = @ptrCast(@alignCast(@as(*u8, @ptrFromInt(at)))); return p[0..s.len]; } pub fn f(x: anytype) void { _ = m(x, 8); }", 1, 0);
}

test "A014 leaves static storage, pointers, copies and a store a defer clears on every exit alone" {
    try expect(pack.lifetimes, "pub fn f() []const u8 { const table = [_]u8{ 1, 2 }; return table[0..]; }", 0);
    try expect(pack.lifetimes, "pub fn f() []const u8 { comptime { var buf: [2]u8 = .{ 1, 2 }; buf[0] = 3; const out = buf; return &out; } }", 0);
    try expectNoted(pack.lifetimes, "pub fn Make(comptime n: usize) type { var x: [n]u8 = undefined; x[0] = 1; _ = &x; return struct {}; }", 1, 0);
    try expect(pack.lifetimes, "const N = struct { v: u32 }; pub fn f(head: *N) *u32 { var node: *N = head; node.v += 1; return &node.v; }", 0);
    try expect(pack.lifetimes, "pub fn f(items: []u8) []u8 { var s: []u8 = items; s = s[1..]; return s[0..1]; }", 0);
    try expect(pack.lifetimes, "pub fn f() [4]u8 { var buf: [4]u8 = undefined; buf[0] = 1; return buf; }", 0);
    try expect(pack.lifetimes, "const T = struct { cur: ?*u32 = null }; pub fn f(t: *T) void { var x: u32 = 1; x += 1; t.cur = &x; defer t.cur = null; }", 0);
    try expect(pack.lifetimes, "pub fn f() u32 { var x: u32 = 1; var p: *u32 = undefined; p = &x; p.* += 1; return x; }", 0);
    try expect(pack.lifetimes, "const T = struct { cur: ?*u32 = null }; pub fn f(t: *T) void { var x: u32 = 1; x += 1; t.cur = &x; defer { t.cur = null; } }", 0);
    // Twins: a destructure that stores no pointer into the frame, and the clear spelled
    // otherwise, naming the same memory.
    try expect(pack.lifetimes, "const T = struct { p: ?*u32 = null }; pub fn f(t: *T, y: *u32) void { var x: u32 = 1; x += 1; t.p, _ = .{ y, x }; }", 0);
    try expect(pack.lifetimes, "const T = struct { cur: ?*u32 = null }; pub fn f(t: *T) void { var x: u32 = 1; x += 1; t.cur = &x; defer (t).cur = null; }", 0);
}

test "the aegis escape covers the pack's findings on its line, is listed with them, and refuses glint-ignore" {
    var project = try sources.projectWithSources(std.testing.allocator,
        \\const std = @import("std");
        \\// aegis: internal(A007): the counter aegis's own Atomic would wrap; measured in bench/count.zig
        \\var hits: u32 = 0;
        \\pub fn f(r: *std.Io.Reader) !u4 {
        \\    const b = try r.takeByte(); // aegis: no-danger(A010): the peer's protocol sends a nibble here
        \\    return @intCast(b);
        \\}
        \\pub fn g() void {} // aegis: design(A010): nothing here
    , &std_files, &std_imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{ .{ .rule = pack.shared_state, .level = .gate }, .{ .rule = pack.integers, .level = .gate } } }, .{ .project_rules = &pack.rules });
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
        \\    const b = try r.takeByte(); // aegis: no-danger(A009): another rule's
        \\    return @intCast(b);
        \\}
        \\pub fn g(r: *std.Io.Reader) !u4 {
        \\    const b = try r.takeByte(); // aegis: no-danger: every rule's
        \\    return @intCast(b);
        \\}
    , &std_files, &std_imports);
    defer other.deinit();
    var named = try glint.runConfigured(std.testing.allocator, &other, .{ .enabled = .empty, .selections = &.{ .{ .rule = pack.untrusted_input, .level = .gate }, .{ .rule = pack.integers, .level = .gate } } }, .{ .project_rules = &pack.rules });
    defer named.deinit();
    // f's escape covers A009 alone, so A010 stays on its line; g's covers nothing it names.
    try std.testing.expectEqual(@as(usize, 3), named.diagnostics.len); // safe: fixture counts are representable.
    try std.testing.expectEqual(@as(u32, 3), named.diagnostics[0].span.line);
    try std.testing.expectEqual(@as(u32, 7), named.diagnostics[1].span.line);
    try std.testing.expectEqual(@as(u32, 7), named.diagnostics[2].span.line);
    try std.testing.expectEqual(@as(usize, 2), named.escapes.len); // safe: fixture counts are representable.
    try std.testing.expectEqualStrings("A009", named.escapes[0].covered[0].name);
    try std.testing.expectEqual(@as(usize, 2), named.escapes[1].covered.len); // safe: fixture counts are representable.
    try std.testing.expect(!named.complete);
    try std.testing.expectEqual(@as(usize, 1), named.malformed.len); // safe: fixture counts are representable.
    var refused = try sources.projectWithSources(std.testing.allocator, "var hits: u32 = 0; // glint-ignore: A007 -- no-danger: one thread\n", &std_files, &std_imports);
    defer refused.deinit();
    var rejected = try glint.runConfigured(std.testing.allocator, &refused, .{ .enabled = .empty, .selections = &.{.{ .rule = pack.shared_state, .level = .gate }} }, .{ .project_rules = &pack.rules });
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
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = rule, .level = .report }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var result: Run = .{ .findings = report.diagnostics.len, .undecided = 0 };
    result.countUndecided(report, rule);
    return result;
}

test "A015 judges a public generic at each binding, a consumer's among them, and leaves a type that does not resolve undecided" {
    // The package alone binds its type function and its generic only to a number: nothing.
    const lib =
        \\pub fn Box(comptime T: type) type { return struct { v: T, pub fn deinit(b: *@This()) void { b.v.close(); } }; }
        \\pub fn View(comptime T: type) type { return struct { v: T }; }
        \\pub const Plain = Box(u32);
        \\pub fn make(comptime T: type) T { return undefined; }
        \\pub fn use() u32 { return make(u32); }
    ;
    try expectNoted(pack.ownership, lib, 1, 0);
    // A consumer binding them to a file: a field its type function releases holds an owner by
    // hand, and a result hands one over; a field nothing releases is a borrow.
    const result = try runWithDependency(pack.ownership,
        \\const std = @import("std");
        \\const dep = @import("dep");
        \\pub const S = struct { b: dep.Box(std.Io.File), w: dep.View(std.Io.File) };
        \\pub fn f() void { _ = dep.make(std.Io.File); }
    , lib);
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqual(@as(usize, 2), result.findings);
    // A field whose type does not resolve may hold one: undecided, never clear.
    const missing = try run(pack.ownership,
        \\const ext = @import("missing");
        \\pub const S = struct { f: ext.Handle };
    );
    try std.testing.expectEqual(@as(usize, 1), missing.undecided);
    try std.testing.expectEqual(@as(usize, 0), missing.findings);
}

test "A015 reads a public generic's returns at a binding with its parameters that call's arguments" {
    // `pass` returns its parameter: at a binding handed a file just opened, the result is that
    // owner; handed one the caller holds, a view of it.
    const result = try runWithDependency(pack.ownership,
        \\const std = @import("std");
        \\const dep = @import("dep");
        \\pub fn opened(dir: std.Io.Dir, io: std.Io) !void { const file = dep.pass(std.Io.File, try dir.openFile(io, "x", .{})); _ = file; }
        \\pub fn held(file: *const std.Io.File) void { const view = dep.pass(std.Io.File, file.*); _ = view; }
    ,
        \\pub fn pass(comptime T: type, x: T) T { return x; }
    );
    try std.testing.expectEqual(@as(usize, 0), result.undecided);
    try std.testing.expectEqual(@as(usize, 1), result.findings);
}

test "A015 reads a container a type function makes inside another's with the outer call's arguments, and a type function's every return" {
    // `Outer(T)` holds a `Box(T)`, which releases what it holds: the consumer's
    // `Outer(std.Io.File)` makes `Box`'s field own the file by hand, and `Opt(std.Io.Dir)` through
    // an optional; aegis's own owner holds it as the answer.
    const lib =
        \\pub fn Box(comptime T: type) type { return struct { f: T, pub fn deinit(b: *@This()) void { b.f.close(); } }; }
        \\pub fn Outer(comptime T: type) type { return struct { b: Box(T) }; }
        \\pub fn Opt(comptime T: type) type { return struct { b: ?Box(T) }; }
        \\pub fn Bits(comptime n: usize) type { if (n <= 64) return Narrow(n); return Wide(n); }
        \\fn Narrow(comptime n: usize) type { return struct { mask: @Int(.unsigned, n) }; }
        \\fn Wide(comptime n: usize) type { return struct { masks: [(n + 63) / 64]u64 }; }
        \\pub fn Set(comptime E: type) type { return struct { bits: Bits(@typeInfo(E).@"enum".fields.len) }; }
        \\pub fn Pick(comptime T: type, comptime n: usize) type { if (n > 3) return Box(T); return struct { g: T }; }
    ;
    const nested = try runWithDependency(pack.ownership,
        \\const std = @import("std");
        \\const dep = @import("dep");
        \\pub const S = dep.Outer(std.Io.File);
        \\pub const O = dep.Opt(std.Io.Dir);
        \\pub const W = struct { s: dep.Outer(std.Io.File) };
    , lib);
    try std.testing.expectEqual(@as(usize, 0), nested.undecided);
    try std.testing.expectEqual(@as(usize, 3), nested.findings);
    try expect(pack.ownership,
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\fn shut(f: *std.Io.File) void { _ = f; }
        \\pub fn Outer(comptime T: type) type { return struct { o: aegis.own.Owned(T, shut) }; }
        \\pub const S = Outer(std.Io.File);
    , 0);
    // A set over an enum, whose bits are one of two containers by its size, each a number's:
    // decided, nothing held. One of whose returns is a container the function declares, which
    // only its template reads: undecided, never clear.
    const chosen = try runWithDependency(pack.ownership,
        \\const std = @import("std");
        \\const dep = @import("dep");
        \\pub const E = enum { a, b };
        \\pub const Flags = dep.Set(E);
        \\pub const P = dep.Pick(std.Io.File, 1);
    , lib);
    try std.testing.expectEqual(@as(usize, 1), chosen.undecided);
    try std.testing.expectEqual(@as(usize, 0), chosen.findings);
}

test "A015 reads a type built by reflection on its argument: the fields a comptime loop writes, the prong a switch on type information takes" {
    // ensign's shapes: options and commands each of one type, `Partial(T)` an optional of each
    // of T's fields' types written element by element, `Tag(T)` and `Fields(T)` enums.
    const lib =
        \\pub const Option = struct { short: ?u8 = null };
        \\pub fn Options(comptime T: type) type {
        \\    const fields = @typeInfo(T).@"struct";
        \\    const final = fields.field_names[0..fields.field_names.len].*;
        \\    return @Struct(.auto, null, &final, &@splat(Option), &@splat(.{}));
        \\}
        \\pub fn Commands(comptime T: type) type {
        \\    for (@typeInfo(T).@"struct".field_types) |F| {
        \\        if (@typeInfo(F) != .@"union") continue;
        \\        return @Struct(.auto, null, @typeInfo(F).@"union".field_names, &@splat(Option), &@splat(.{}));
        \\    }
        \\    return struct {};
        \\}
        \\pub fn Partial(comptime T: type) type {
        \\    const fields = @typeInfo(T).@"struct";
        \\    var types: [fields.field_names.len]type = undefined;
        \\    var len: usize = 0;
        \\    for (fields.field_types) |F| {
        \\        types[len] = ?F;
        \\        len += 1;
        \\    }
        \\    const final_types = types[0..len].*;
        \\    return @Struct(.auto, null, fields.field_names, &final_types, &@splat(.{}));
        \\}
        \\pub fn Spec(comptime T: type) type {
        \\    return struct { options: Options(T), commands: Commands(T), sets: Partial(T) };
        \\}
        \\pub fn Keep(comptime T: type) type {
        \\    return struct { held: Partial(T), pub fn deinit(k: *@This()) void { inline for (@typeInfo(T).@"struct".field_names) |name| if (@field(k.held, name)) |held| held.close(); } };
        \\}
        \\pub fn Tag(comptime T: type) type {
        \\    return switch (@typeInfo(T)) {
        \\        .@"enum" => |info| info.tag_type,
        \\        .@"union" => |info| info.tag_type orelse @compileError("untagged"),
        \\        else => @compileError("no tag"),
        \\    };
        \\}
        \\pub fn Fields(comptime T: type) type {
        \\    switch (@typeInfo(T)) {
        \\        .@"union" => |u| if (u.tag_type) |EnumTag| return EnumTag,
        \\        else => {},
        \\    }
        \\    if (@typeInfo(T).@"struct".field_names.len == 0) return enum {};
        \\    return @Enum(u8, .exhaustive, @typeInfo(T).@"struct".field_names, &@splat(0));
        \\}
    ;
    // A plain argument: every one decided, nothing held.
    const plain = try runWithDependency(pack.ownership,
        \\const dep = @import("dep");
        \\const Value = union(enum) { a: u8, b };
        \\const Plain = struct { name: []const u8, n: u32 = 0, pub const spec: dep.Spec(@This()) = undefined; };
        \\pub const K = dep.Tag(Value);
        \\pub const E = dep.Tag(enum(u8) { x });
        \\pub const F = dep.Fields(Plain);
        \\pub const G = dep.Fields(Value);
    , lib);
    try std.testing.expectEqual(@as(usize, 0), plain.undecided);
    try std.testing.expectEqual(@as(usize, 0), plain.findings);
    // One holding a file: `Partial` holds it, an optional of it, a borrow in a spec nothing
    // releases and an owner by hand in `Keep`, which releases it; one whose field's type does
    // not resolve: undecided, never clear.
    const held = try runWithDependency(pack.ownership,
        \\const std = @import("std");
        \\const dep = @import("dep");
        \\const ext = @import("missing");
        \\const Holds = struct { out: std.Io.File, pub const spec: dep.Spec(@This()) = undefined; pub const kept: dep.Keep(@This()) = undefined; };
        \\const Unseen = struct { h: ext.Handle, pub const spec: dep.Spec(@This()) = undefined; };
    , lib);
    try std.testing.expectEqual(@as(usize, 2), held.undecided);
    try std.testing.expectEqual(@as(usize, 1), held.findings);
}

test "A015 reads a tuple's fields, named by position only, as fields" {
    try expect(pack.ownership,
        \\const std = @import("std");
        \\pub const S = struct { pair: struct { std.Io.File, u32 } };
        \\pub const T = struct { std.Io.Dir, *std.Io.File };
    , 2);
    // An enum's or a union's field written without a type parses as a tuple's does: a name,
    // neither held nor undecided.
    const names = try run(pack.ownership,
        \\pub const Kind = enum { secret, bytes, scalar };
        \\pub const Tag = union(enum) { none, some: u8 };
        \\pub const Raw = struct { u8, u32 };
    );
    try std.testing.expectEqual(@as(usize, 0), names.undecided);
    try std.testing.expectEqual(@as(usize, 0), names.findings);
}

test "A015 finds std resources held by value in a field the program releases, or returned by value, not borrowed by pointer" {
    // Conn's stream and log and Log's file are released, as Options' `cwd` is through a local;
    // Options' `out`, written and released nowhere, holds what its caller gives it.
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
        \\pub fn lent(o: *aegis.own.Owned(std.Io.Dir, shut)) std.Io.Dir { return o.borrow().*; }
    , 6);
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
    , 0); // Nor the fields (Slot.file, Process.cwd, Context.cwd): written and released nowhere.
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
    , 5); // And the field Wrapped.handle, given what `opened` made; Proc.dir is given nothing.
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
    , 3); // Conn.stream, moved out but never written or released, holds what it is given.
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

test "A021 finds a second lock taken while a guard is held, unless both are ranked by Order" {
    try expect(pack.lock_order,
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\const L = aegis.BlockingGuarded(u32);
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
        \\const O = aegis.Order(&.{ .{ .name = "a" }, .{ .name = "b", .after = &.{0} } });
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

test "A019 reads a module republishing aegis beside code of its own as the program's: only aegis's own package leaves it" {
    // `wrap` republishes all of aegis's root and names a field of what it cannot resolve as
    // `interface`: the program's code, whose use of the field leaves the conversion a finding.
    const wrap: sources.Extra = .{ .name = "wrap/root.zig", .package = "wrap", .bytes =
        \\const aegis = @import("aegis");
        \\pub const Atomic = aegis.Atomic;
        \\pub const BlockingGuarded = aegis.BlockingGuarded;
        \\pub const bounded = aegis.bounded;
        \\pub const Condition = aegis.Condition;
        \\pub const Confined = aegis.Confined;
        \\pub const err = aegis.err;
        \\pub const Guarded = aegis.Guarded;
        \\pub const handle = aegis.handle;
        \\pub const id = aegis.id;
        \\pub const InitContext = aegis.InitContext;
        \\pub const input = aegis.input;
        \\pub const int = aegis.int;
        \\pub const Lazy = aegis.Lazy;
        \\pub const Once = aegis.Once;
        \\pub const Order = aegis.Order;
        \\pub const own = aegis.own;
        \\pub const RwGuarded = aegis.RwGuarded;
        \\pub const scope = aegis.scope;
        \\pub const secret = aegis.secret;
        \\pub const Secret = aegis.Secret;
        \\pub const SecretBytes = aegis.SecretBytes;
        \\pub const Shared = aegis.Shared;
        \\pub const SpinRwGuarded = aegis.SpinRwGuarded;
        \\pub const state = aegis.state;
        \\pub const units = aegis.units;
        \\pub fn peek() usize {
        \\    const s = @import("hidden").get();
        \\    return @field(s, "interface").end;
        \\}
        \\
    };
    const extra = &(std_files ++ [_]sources.Extra{wrap});
    const imports = &(std_imports ++ [_]sources.ExtraImport{ .{ .spelling = "wrap", .target = std_files.len }, .{ .from = std_files.len, .spelling = "aegis", .target = sources.aegis_file }, .{ .from = std_files.len, .spelling = "std", .target = 0 } });
    const found = try runWith(pack.unsafe_set, comptime edited(interface_program, "const std = @import(\"std\");\n", "const std = @import(\"std\");\nconst wrap = @import(\"wrap\");\n"), extra, imports);
    try std.testing.expectEqualSlices(u32, &.{ 12, 12 }, found.lines[0..found.findings]);
}

test "A019 reads every file a path import joins to the program, selected or not: a copy of an interface field there leaves the conversion a finding" {
    // `other.zig`, outside the selection, copies the field it is handed: 11, the conversion
    // and its alignment.
    const program = comptime edited(interface_program, "pub fn use() !usize {", "const other = @import(\"other.zig\");\npub fn use() !usize {\n    var t: Sink = .init();\n    other.keep(&t);");
    const other: sources.Extra = .{ .name = "other.zig", .bytes = "pub fn keep(s: anytype) void { const copy = s.interface; _ = copy; }" };
    const found = try runWith(pack.unsafe_set, program, &(std_files ++ [_]sources.Extra{other}), &(std_imports ++ [_]sources.ExtraImport{.{ .spelling = "other.zig", .target = std_files.len }}));
    try std.testing.expectEqualSlices(u32, &.{ 11, 11 }, found.lines[0..found.findings]);
}

test "A012 gives a function handed out no length for a parameter whose type has none" {
    // std sums the key's bytes, as many as they are: a `u32` key's are `@sizeOf(u32)`,
    // whatever code outside gives `number`; a slice key's are as many as `bytes` is given.
    const keys: sources.Extra = .{ .name = "std/keys.zig", .bytes =
        \\pub fn sum(input: []const u8) u64 {
        \\    var t: u64 = 0;
        \\    for (input) |b| t +%= b;
        \\    return t;
        \\}
        \\pub fn asBytes(ptr: *const u32) *const [4]u8 {
        \\    return @ptrCast(ptr);
        \\}
        \\pub fn hashKey(key: u32) u64 {
        \\    return sum(asBytes(&key));
        \\}
    };
    const found = try runWith(pack.bounded_work,
        \\const keys = @import("keys.zig");
        \\fn number(k: u32) u64 {
        \\    return keys.hashKey(k);
        \\}
        \\fn bytes(k: []const u8) u64 {
        \\    return keys.sum(k);
        \\}
        \\pub const handed = .{ &number, &bytes };
    , &(std_files ++ [_]sources.Extra{keys}), &(std_imports ++ [_]sources.ExtraImport{ .{ .from = 0, .spelling = "keys.zig", .target = std_files.len }, .{ .spelling = "keys.zig", .target = std_files.len } }));
    // Neither sizes a thing: a loop over memory, a slice key's bytes as many as they are, is
    // what reading it is (A012, docs/design.md), and a `u32` key's are its type's.
    try std.testing.expectEqual(0, found.findings);
    try std.testing.expectEqual(0, found.undecided);
}

/// `program` after the fixes of `rule`'s findings and its stale escapes.
fn fixed(rule: glint.Rule, program: []const u8) ![]u8 {
    var project = try sources.projectWithSources(std.testing.allocator, program, &std_files, &std_imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
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
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = selections[0..rules.len] }, .{ .project_rules = &pack.rules });
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
        \\    const x = try r.takeInt(i64, .little); // aegis: no-danger: probe
        \\    return table[@intCast(x)];
        \\}
        \\
    ;
    const both: []const glint.Rule = &.{ pack.untrusted_input, pack.integers };
    // A009 and A010 both find something on the line; the record holds A010 only, so A009, new
    // since, is left to the owner.
    {
        const out = try fixedBy(both, older, "glint: escape: consumer:3:44: no-danger: probe (A010)\nglint: 3 files\n");
        defer std.testing.allocator.free(out.bytes);
        try std.testing.expect(std.mem.find(u8, out.bytes, "// aegis: no-danger(A010): probe") != null);
    }
    {
        const out = try fixedBy(both, older, "escape: consumer:3:44: no-danger: probe (A009 at 3:19, A010 at 3:19, A013 at 3:5)\n");
        defer std.testing.allocator.free(out.bytes);
        try std.testing.expect(std.mem.find(u8, out.bytes, "// aegis: no-danger(A009, A010): probe") != null);
    }
    // No record of the escape, or one of another line, column or words (moved or reworded
    // since), or of rules that find nothing now, or a line in another form that names it:
    // nothing is written, and the escape stays for its owner to name.
    inline for (.{
        "",
        "glint: escape: consumer:9:44: no-danger: probe (A010)\n",
        "glint: escape: consumer:3:42: no-danger: probe (A010)\n",
        "glint: escape: consumer:3:44: design: probe (A010)\n",
        "glint: escape: consumer:3:44: no-danger: probe two (A010)\n",
        "glint: escape: consumer:3:44: no-danger: probe (A013)\n",
        "note: escape: consumer:3:44: no-danger: probe (A010)\n",
        "glint: A010: consumer:3:19: see escape: consumer:3:44: no-danger: probe (A010)\n",
    }) |record| {
        const out = try fixedBy(both, older, record);
        defer std.testing.allocator.free(out.bytes);
        try std.testing.expectEqualStrings(older, out.bytes);
    }
    // A line in the record's form that is no escape's whole record is refused, not guessed at.
    var records = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer records.deinit();
    inline for (.{
        "escape: consumer:3: no-danger: probe (A010)\n",
        "escape: consumer:3:44: no-danger probe (A010)\n",
        "glint: escape: consumer:3:44: no-danger: probe (A010\n",
        "escape: consumer:3:44: no-danger: probe (A010 near 4:18)\n",
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
        try std.testing.expectEqual(null, std.mem.find(u8, out.bytes, "aegis:"));
    }
    // A record line that names an escape and is not one is refused.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidEscapeRecord, glint.Fix.escapeRecord(arena.allocator(), "glint: escape: consumer:x:1: no-danger: why (A010)\n"));
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

test "A008 decides a method called through a generic's bound type where the binding names it" {
    // parallax's interner: its context's equality, whatever context a consumer binds.
    try expectNoted(pack.secrets,
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
    , 1, 0);
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
    try std.testing.expectEqual(@as(usize, 2), result.undecided);
    // One of them the note at a public generic nothing the run binds.
    try std.testing.expectEqual(@as(usize, 1), result.unbound);
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

/// `run` with the fixture std and a dependency imported as "dep", not selected.
fn runWithDependency(rule: glint.Rule, program: []const u8, dependency: []const u8) !Run {
    const files = std_files ++ [_]sources.Extra{.{ .name = "dep/dep.zig", .bytes = dependency }};
    const imports = std_imports ++ [_]sources.ExtraImport{ .{ .spelling = "dep", .target = std_files.len }, .{ .from = std_files.len, .spelling = "std", .target = 0 } };
    var project = try sources.projectWithSources(std.testing.allocator, program, &files, &imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = rule, .level = .report }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var result: Run = .{ .findings = 0, .undecided = 0 };
    for (report.diagnostics) |d| if (d.rule == rule) {
        result.findings += 1;
    };
    result.countUndecided(report, rule);
    return result;
}

test "A020 and A009 read a flag given only literals by the conditions it is given them under" {
    // `if (total == seed) more = false`: `while (more)` runs as long as the peer's seed says.
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\pub fn churn(io: std.Io, r: *std.Io.Reader) !u64 {
        \\    _ = io;
        \\    const seed = try r.takeInt(u64, 0);
        \\    var more = true;
        \\    var total: u64 = 0;
        \\    while (more) {
        \\        total +%= 1;
        \\        if (total == seed) more = false;
        \\    }
        \\    return total;
        \\}
    , 1);
    try expect(pack.untrusted_input,
        \\const std = @import("std");
        \\pub fn f(r: *std.Io.Reader, out: *u64) !void {
        \\    const n = try r.takeInt(u64, 0);
        \\    var i: u64 = 0;
        \\    var more = true;
        \\    while (more) : (i += 1) {
        \\        out.* +%= i;
        \\        if (i == n) more = false;
        \\    }
        \\}
    , 1);
    // Under a condition the program sets, the same flag is bounded by the program.
    try expect(pack.cancellation,
        \\const std = @import("std");
        \\pub fn churn(io: std.Io) u64 {
        \\    _ = io;
        \\    var more = true;
        \\    var total: u64 = 0;
        \\    while (more) {
        \\        total +%= 1;
        \\        if (total == 64) more = false;
        \\    }
        \\    return total;
        \\}
    , 0);
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
    try std.testing.expectEqual(@as(usize, 1), found.undecided); // safe: fixture counts are representable.
    // One of them the note at a public generic nothing the run binds.
    try std.testing.expectEqual(@as(usize, 1), found.unbound);
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
    // A type the dependency names that does not resolve may be one: undecided, never clean,
    // but where every value a variable is given is an enum literal, a tag.
    const unknown = try runWithDependency(pack.shared_state,
        \\const dep = @import("dep");
        \\const Held = struct { lock: [2]dep.Elsewhere };
        \\pub fn pick(x: bool) void {
        \\    const tag: dep.Elsewhere = if (x) .a else .b;
        \\    _ = tag;
        \\    var lock: dep.Elsewhere = undefined;
        \\    _ = &lock;
        \\}
    , dependency);
    // `dep.Elsewhere` spells the name of the dependency's lock alias (`Lock`): each value it
    // types is judged once, by what it holds.
    try std.testing.expectEqual(@as(usize, 2), unknown.undecided); // safe: fixture counts are representable.
    try std.testing.expectEqual(@as(usize, 0), unknown.findings);
}

test "A007 reads a dependency's function-local constant of a computed name as no alias, and its container-level one as any name" {
    const program =
        \\const dep = @import("dep");
        \\const Kind = enum { call, none };
        \\pub const table = [_]struct { []const u8, Kind }{ .{ "param", .call }, .{ "array_type", .none } };
    ;
    // shakedown's `const call = comptime @field(IoCall, name);`: named only in its function's
    // body, so the program's `.call` reaches no lock.
    const local = try runWithDependency(pack.shared_state, program,
        \\const std = @import("std");
        \\pub fn pick(comptime name: []const u8) void {
        \\    const call = comptime @field(std.Io, name);
        \\    _ = call;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), local.undecided); // safe: fixture counts are representable.
    try std.testing.expectEqual(@as(usize, 0), local.findings);
    // The same constant at the container: `dep.call` may be any of std.Io's members, a lock too,
    // so the program's `.call` leaves undecided sites a program without it does not.
    const container =
        \\const std = @import("std");
        \\pub const call = @field(std.Io, @import("missing.zig").name);
    ;
    const member = try runWithDependency(pack.shared_state, program, container);
    const without = try runWithDependency(pack.shared_state,
        \\const dep = @import("dep");
        \\const Kind = enum { call, none };
        \\pub const table = [_]struct { []const u8, Kind }{ .{ "array_type", .none } };
    , container);
    try std.testing.expect(member.undecided > without.undecided);
    try std.testing.expectEqual(@as(usize, 0), member.findings);
}

test "A015 flags a field the program releases or writes an owner into, and a borrow it is only given as none" {
    // Lent's fields hold what they are given: an own.OwnedIo's borrow().*, a handle made from a
    // parameter's, a parameter. An opened file stored and never released is a leak (Leak,
    // Stored); a borrow released by mistake (Mistake) is an owner by hand, as is one released
    // by a call, through a capture, or through a getter's return (`opened` returns an owner too).
    const found = try run(pack.ownership,
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\fn shut(f: *std.Io.File, io: std.Io) void { _ = io; f.close(); }
        \\fn opened() std.Io.File { return undefined; }
        \\fn release(f: std.Io.File) void { f.close(); }
        \\const Lent = struct { file: std.Io.File, dir: std.Io.Dir, out: std.Io.File };
        \\pub fn lend(dir: std.Io.Dir, out: std.Io.File, owner: *aegis.own.OwnedIo(std.Io.File, shut)) Lent { return .{ .file = owner.borrow().*, .dir = .{ .handle = dir.handle }, .out = out }; }
        \\const Leak = struct { file: std.Io.File };
        \\pub fn leak() Leak { return .{ .file = opened() }; }
        \\const Mistake = struct { file: std.Io.File };
        \\pub fn mistake(file: std.Io.File) void { const m: Mistake = .{ .file = file }; m.file.close(); }
        \\const ByCall = struct { file: std.Io.File };
        \\pub fn byCall(b: *ByCall) void { release(b.file); }
        \\const ByCapture = struct { file: ?std.Io.File };
        \\pub fn byCapture(b: *ByCapture) void { if (b.file) |f| f.close(); }
        \\const ByGetter = struct { file: std.Io.File, fn get(b: *ByGetter) std.Io.File { return b.file; } };
        \\pub fn byGetter(b: *ByGetter) void { b.get().close(); }
        \\const Stored = struct { file: std.Io.File };
        \\pub fn store(s: *Stored) void { s.file = opened(); }
    );
    try std.testing.expectEqual(@as(usize, 0), found.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 4, 8, 10, 12, 14, 16, 18 }, found.lines[0..found.findings]);
    // A release through a receiver that does not resolve may be this field's: undecided, not
    // cleared; one that releases nothing decides nothing.
    const doubted = try run(pack.ownership,
        \\const std = @import("std");
        \\const ext = @import("missing");
        \\const Held = struct { file: std.Io.File };
        \\pub fn f(x: ext.T) void { x.file.close(); }
    );
    try std.testing.expectEqual(@as(usize, 0), doubted.findings);
    try std.testing.expectEqual(@as(usize, 1), doubted.undecided);
    try expect(pack.ownership,
        \\const std = @import("std");
        \\const ext = @import("missing");
        \\const Held = struct { file: std.Io.File };
        \\pub fn f(x: ext.T) i32 { return x.file.handle; }
    , 0);
}

test "A015 reads a function returning a call of a view, in any file, as a view" {
    // airlock's `Lock.file`, returning `l.pending.file()`, Pending's view of its field.
    const views: sources.Extra = .{ .name = "pending.zig", .bytes =
        \\const std = @import("std");
        \\pub const Pending = struct {
        \\    held: std.Io.File,
        \\    pub fn file(p: *Pending) std.Io.File { return p.held; }
        \\    pub fn opened(p: *Pending) std.Io.File { _ = p; return undefined; }
        \\};
    };
    const found = try runWith(pack.ownership,
        \\const std = @import("std");
        \\const Pending = @import("pending.zig").Pending;
        \\const Lock = struct {
        \\    pending: Pending,
        \\    pub fn file(l: *Lock) std.Io.File { return l.pending.file(); }
        \\    pub fn open(l: *Lock) std.Io.File { return l.pending.opened(); }
        \\};
    , &(std_files ++ [_]sources.Extra{views}), &(std_imports ++ [_]sources.ExtraImport{ .{ .spelling = "pending.zig", .target = std_files.len }, .{ .from = std_files.len, .spelling = "std", .target = 0 } }));
    try std.testing.expectEqualSlices(u32, &.{6}, found.lines[0..found.findings]);
}

test "A015 reads a switch over an owned-or-lent union as a view where each prong is one" {
    // airlock's `Parent.directory`: an own.OwnedIo's borrow().*, the lent handle, no value.
    // A prong that opens (`fresh`), and a `borrow` of no aegis owner (`faked`), are not views.
    const found = try run(pack.ownership,
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\fn shut(d: *std.Io.Dir, io: std.Io) void { _ = d; _ = io; }
        \\fn opened() std.Io.Dir { return undefined; }
        \\const Parent = union(enum) {
        \\    owned: aegis.own.OwnedIo(std.Io.Dir, shut),
        \\    lent: std.Io.Dir,
        \\    closed,
        \\    fn directory(p: *Parent) std.Io.Dir { return switch (p.*) { .owned => |*held| held.borrow().*, .lent => |lent| lent, .closed => unreachable }; }
        \\    fn fresh(p: *Parent) std.Io.Dir { return switch (p.*) { .owned => opened(), .lent => |lent| lent, .closed => unreachable }; }
        \\};
        \\const Fake = struct { held: std.Io.Dir, fn borrow(f: *Fake) *const std.Io.Dir { _ = f; return undefined; } };
        \\pub fn faked(f: *Fake) std.Io.Dir { return f.borrow().*; }
    );
    try std.testing.expectEqual(@as(usize, 0), found.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 4, 10, 13 }, found.lines[0..found.findings]);
}

test "A015 judges a public type's resource field where the program writes or releases it" {
    // a15_base: a public type's raw field says lent, and nothing here writes or releases it.
    try expect(pack.ownership,
        \\const std = @import("std");
        \\pub const S = struct { f: std.Io.File };
    , 0);
    // An importer writing an owner into it, closing it, or handing an owner to a keeper that
    // stores it in a field the keeper releases, is flagged at its own line (`opened` returns an
    // owner too), as is closing std's `File.Reader.file`; one it is lent (a parameter, one
    // unwrapped `orelse return`, an `own.Lent`'s `get()`), an owner the caller releases itself,
    // one a type that never releases its field is given (a reader, lent it), or one handed to
    // std's `File.reader`, which std's keeps as a copy it is lent, is not.
    const lib: sources.Extra = .{ .name = "lib.zig", .bytes =
        \\const std = @import("std");
        \\pub const S = struct { f: std.Io.File };
        \\pub const Keeper = struct { held: std.Io.File, pub fn keep(k: *Keeper, f: std.Io.File) void { k.held = f; } pub fn deinit(k: *Keeper) void { k.held.close(); } };
        \\pub const Reader = struct { file: std.Io.File, pub fn init(f: std.Io.File) Reader { return .{ .file = f }; } };
    };
    const imports = &(std_imports ++ [_]sources.ExtraImport{ .{ .spelling = "lib.zig", .target = std_files.len }, .{ .from = std_files.len, .spelling = "std", .target = 0 } });
    const found = try runWith(pack.ownership,
        \\const std = @import("std");
        \\const lib = @import("lib.zig");
        \\fn opened() std.Io.File { return undefined; }
        \\pub fn write(s: *lib.S) void { s.f = opened(); }
        \\pub fn close(s: *lib.S) void { s.f.close(); }
        \\pub fn keep(k: *lib.Keeper) void { k.keep(opened()); }
        \\pub fn lend(s: *lib.S, f: std.Io.File) void { s.f = f; }
        \\pub fn borrowed(k: *lib.Keeper) void { const f = opened(); defer f.close(); k.keep(f); }
        \\pub fn read() lib.Reader { return .init(opened()); }
        \\pub fn maybe(k: *lib.Keeper, f: ?std.Io.File) void { const g = f orelse return; k.keep(g); }
        \\pub fn lent(k: *lib.Keeper, o: *aegis.own.Owned(std.Io.File, shut)) void { k.keep(o.borrow().*); }
        \\pub fn stream() void { var r = opened().reader(undefined, &.{}); _ = &r; }
        \\pub fn done(r: *std.Io.File.Reader) void { r.file.close(); }
        \\const aegis = @import("aegis");
        \\fn shut(_: *std.Io.File) void {}
    , &(std_files ++ [_]sources.Extra{lib}), imports);
    try std.testing.expectEqual(@as(usize, 0), found.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 3, 4, 5, 6, 13 }, found.lines[0..found.findings]);
    // Passed where nothing resolves, a release of it may be one: undecided, not flagged.
    const passed = try runWith(pack.ownership,
        \\const std = @import("std");
        \\const lib = @import("lib.zig");
        \\const ext = @import("missing");
        \\pub fn pass(s: *lib.S) void { ext.release(s.f); }
        \\pub fn sync(s: *lib.S) void { ext.sync(s.f.handle); }
    , &(std_files ++ [_]sources.Extra{lib}), imports);
    try std.testing.expectEqual(@as(usize, 0), passed.findings);
    try std.testing.expectEqual(@as(usize, 2), passed.undecided);
    // A keeper that does not resolve may keep it: undecided.
    const doubted = try run(pack.ownership,
        \\const std = @import("std");
        \\const ext = @import("missing");
        \\fn opened() std.Io.File { return undefined; }
        \\pub fn keep(k: ext.Keeper, f: std.Io.File) void { k.keep(f); }
        \\pub fn give(k: ext.Keeper) void { k.keep(opened()); }
    );
    try std.testing.expectEqualSlices(u32, &.{3}, doubted.lines[0..doubted.findings]);
    try std.testing.expectEqual(@as(usize, 1), doubted.undecided);
    // A type no other file can name is judged at its field, as before.
    const private = try run(pack.ownership,
        \\const std = @import("std");
        \\fn opened() std.Io.File { return undefined; }
        \\const S = struct { f: std.Io.File };
        \\pub fn write(s: *S) void { s.f = opened(); }
    );
    try std.testing.expectEqualSlices(u32, &.{ 2, 3 }, private.lines[0..private.findings]);
}

test "A015 reads a field by meaning: @field with its name, a destructure's place and a pointer capture write it as `=` does" {
    // Each writes an owner into its field, or releases it, in the field's own file; one given a
    // parameter by a destructure is lent it.
    const found = try run(pack.ownership,
        \\const std = @import("std");
        \\fn opened() std.Io.File { return undefined; }
        \\const ByField = struct { file: std.Io.File };
        \\pub fn byField(s: *ByField) void { @field(s, "file") = opened(); }
        \\const ByDestructure = struct { file: std.Io.File, n: u32 };
        \\pub fn byDestructure(s: *ByDestructure) void { s.file, s.n = .{ opened(), 1 }; }
        \\const ByCapture = struct { file: ?std.Io.File };
        \\pub fn byCapture(s: *ByCapture) void { if (s.file) |*p| p.* = opened(); }
        \\const ByRelease = struct { file: std.Io.File };
        \\pub fn byRelease(s: *ByRelease, f: std.Io.File) void { s.file = f; @field(s, "file").close(); }
        \\const Lent = struct { file: std.Io.File, n: u32 };
        \\pub fn lent(s: *Lent, f: std.Io.File) void { s.file, s.n = .{ f, 1 }; }
    );
    try std.testing.expectEqual(@as(usize, 0), found.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 2, 3, 5, 7, 9 }, found.lines[0..found.findings]);
    // `@field` by a name it computes may be the field: undecided.
    const computed = try run(pack.ownership,
        \\const std = @import("std");
        \\const ByName = struct { file: std.Io.File };
        \\pub fn byName(s: *ByName, comptime name: []const u8) void { @field(s, name).close(); }
    );
    try std.testing.expectEqual(@as(usize, 0), computed.findings);
    try std.testing.expectEqual(@as(usize, 2), computed.undecided);
    // One of them the note at a public generic nothing the run binds.
    try std.testing.expectEqual(@as(usize, 1), computed.unbound);
    // At another file's type, the same writes and release are flagged where this file does them.
    const lib: sources.Extra = .{ .name = "lib.zig", .bytes =
        \\const std = @import("std");
        \\pub const S = struct { f: std.Io.File };
    };
    const imports = &(std_imports ++ [_]sources.ExtraImport{ .{ .spelling = "lib.zig", .target = std_files.len }, .{ .from = std_files.len, .spelling = "std", .target = 0 } });
    const foreign = try runWith(pack.ownership,
        \\const std = @import("std");
        \\const lib = @import("lib.zig");
        \\fn opened() std.Io.File { return undefined; }
        \\pub fn field(s: *lib.S) void { @field(s, "f") = opened(); }
        \\pub fn destructure(s: *lib.S, n: *u32) void { s.f, n.* = .{ opened(), 1 }; }
        \\pub fn release(s: *lib.S) void { @field(s, "f").close(); }
        \\pub fn lend(s: *lib.S, f: std.Io.File, n: *u32) void { s.f, n.* = .{ f, 1 }; }
    , &(std_files ++ [_]sources.Extra{lib}), imports);
    try std.testing.expectEqual(@as(usize, 0), foreign.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 3, 4, 5, 6 }, foreign.lines[0..foreign.findings]);
}

test "A015 reads a call of a function returning its parameter as the argument it is handed" {
    // `pass(opened())` is the owner `opened` made; `pass(f)` of a parameter stays a view.
    const found = try run(pack.ownership,
        \\const std = @import("std");
        \\fn opened() std.Io.File { return undefined; }
        \\fn pass(f: std.Io.File) std.Io.File { return f; }
        \\const Stored = struct { file: std.Io.File };
        \\pub fn store(s: *Stored) void { s.file = pass(opened()); }
        \\const Lent = struct { file: std.Io.File };
        \\pub fn lend(s: *Lent, f: std.Io.File) void { s.file = pass(f); }
        \\const Method = struct { file: std.Io.File, fn keep(m: *Method, f: std.Io.File) std.Io.File { _ = m; return f; } };
        \\pub fn method(m: *Method) void { m.file = m.keep(opened()); }
    );
    try std.testing.expectEqual(@as(usize, 0), found.undecided);
    try std.testing.expectEqualSlices(u32, &.{ 2, 4, 8 }, found.lines[0..found.findings]);
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
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = rule, .level = .report }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var result: Run = .{ .findings = 0, .undecided = 0 };
    for (report.diagnostics) |d| if (d.rule == rule) {
        if (result.findings < result.lines.len) result.lines[result.findings] = d.span.line;
        result.findings += 1;
    };
    result.countUndecided(report, rule);
    return result;
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

test "A009 and A010 read a destructure and a pointer capture as writes of what they bind" {
    inline for (.{
        .{ pack.integers, "pub fn f(r: *std.Io.Reader) !u64 {\n    var v: u64 = 5;\n    v, _ = .{ try r.takeInt(u64, 0), 0 };\n    return v * 1000;\n}\n" },
        .{ pack.integers, "pub fn f(r: *std.Io.Reader) !u64 {\n    var o: ?u64 = 5;\n    const n: u64 = try r.takeInt(u64, 0);\n    if (o) |*p| p.* = n;\n    return o.? * 1000;\n}\n" },
        .{ pack.untrusted_input, "pub fn f(r: *std.Io.Reader, out: *u8) !void {\n    var n: usize = 5;\n    n, _ = .{ try r.takeInt(u32, 0), 0 };\n    var i: usize = 0;\n    while (i < n) : (i += 1) out.* +%= 1;\n}\n" },
    }) |case| expect(case[0], "const std = @import(\"std\");\n" ++ case[1], 1) catch |err| {
        std.debug.print("VARIANT<<{s}>>\n", .{case[1]});
        return err;
    };
    // The same destructure of the program's own values stays clear.
    try expect(pack.integers,
        \\const std = @import("std");
        \\pub fn f() u64 {
        \\    var v: u64 = 5;
        \\    v, _ = .{ 7, 0 };
        \\    return v * 1000;
        \\}
    , 0);
}

const captured_field_program =
    \\pub const Observer = struct { boundary: ?*const fn (*Observer) void = null };
    \\const Counter = struct {
    \\    n: usize = 0,
    \\    observer: Observer = .{ .boundary = seen },
    \\    fn seen(o: *Observer) void {
    \\        const self: *Counter = @alignCast(@fieldParentPtr("observer", o));
    \\        self.n += 1;
    \\    }
    \\};
    \\pub fn scan(seen_by: ?*Observer) void {
    \\    if (seen_by) |observer| if (observer.boundary) |boundary| boundary(observer);
    \\}
    \\
;

test "A019 reads a call through a function field's captured payload as one through the field" {
    // `if (o.f) |f| f(o)` hands the interface as `o.f.?(o)` does: what the field holds is judged
    // where it is installed, never left undecided at the call.
    const captured = try run(pack.unsafe_set, captured_field_program);
    const unwrapped = try runEdited(pack.unsafe_set, captured_field_program, "if (observer.boundary) |boundary| boundary(observer);", "observer.boundary.?(observer);");
    try std.testing.expectEqual(@as(usize, 0), captured.undecided);
    try std.testing.expectEqual(unwrapped.undecided, captured.undecided);
    try std.testing.expectEqual(unwrapped.findings, captured.findings);
}

/// The findings of `rule` in `program`, as `line * 4096 + column` in report order, with the
/// rules of `selected` on.
fn findingsAmong(rule: glint.Rule, selected: []const glint.Rule, program: []const u8, out: *std.ArrayList(u64)) !void {
    var project = try sources.projectAs(std.testing.allocator, program, .{}, &std_files, &std_imports);
    defer project.deinit();
    var selections: [pack.rules.len]glint.Config.Selection = undefined;
    for (selected, 0..) |each, i| selections[i] = .{ .rule = each, .level = .report };
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = selections[0..selected.len] }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    for (report.diagnostics) |d| if (d.rule == rule) try out.append(std.testing.allocator, @as(u64, d.span.line) * 4096 + d.span.column);
    std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
}

test "a rule's findings are the same alone and beside every other rule: no answer kept for the run is what the first asker's depth or order left of it" {
    // `width`'s greatest return read first through a chain of calls and casts (`first`), then at
    // a switch's prongs (`pick`): the product fits either way. A list grown by input, an index
    // from input and an unreachable input chooses give the other rules a finding each.
    const program =
        \\const std = @import("std");
        \\const Kind = enum { short, long };
        \\fn w0(kind: Kind) usize { return switch (kind) { .short => 20, .long => 32 }; }
        \\fn w1(kind: Kind) usize { return w0(kind); }
        \\fn w2(kind: Kind) usize { return w1(kind); }
        \\fn w3(kind: Kind) usize { return w2(kind); }
        \\fn w4(kind: Kind) usize { return w3(kind); }
        \\fn w5(kind: Kind) usize { return w4(kind); }
        \\fn w6(kind: Kind) usize { return w5(kind); }
        \\fn w7(kind: Kind) usize { return w6(kind); }
        \\fn w8(kind: Kind) usize { return w7(kind); }
        \\fn w9(kind: Kind) usize { return w8(kind); }
        \\fn w10(kind: Kind) usize { return w9(kind); }
        \\pub fn first(r: *std.Io.Reader) !usize {
        \\    const a = try r.takeInt(u8, 0);
        \\    return @as(usize, a) + @as(usize, @as(usize, @as(usize, w10(.short))));
        \\}
        \\pub fn pick(r: *std.Io.Reader) !usize {
        \\    const width: usize = switch (try r.takeInt(u8, 0)) {
        \\        1 => w10(.short),
        \\        2 => w10(.long),
        \\        else => return error.Invalid,
        \\    };
        \\    return 2 * width;
        \\}
        \\pub fn grown(gpa: std.mem.Allocator, r: *std.Io.Reader, table: []const u8) !u8 {
        \\    const n = try r.takeInt(u32, 0);
        \\    const held = try gpa.alloc(u8, n);
        \\    defer gpa.free(held);
        \\    if (n == 7) unreachable;
        \\    return table[n] + @as(u8, @intCast(n * 3));
        \\}
    ;
    const all = [_]glint.Rule{ pack.untrusted_input, pack.integers, pack.bounded_work, pack.contracts };
    var every: [pack.rules.len]glint.Rule = undefined;
    for (pack.rules, 0..) |each, i| every[i] = each.definition.id;
    var some: usize = 0;
    for (all) |rule| {
        var alone: std.ArrayList(u64) = .empty;
        defer alone.deinit(std.testing.allocator);
        try findingsAmong(rule, &.{rule}, program, &alone);
        var four: std.ArrayList(u64) = .empty;
        defer four.deinit(std.testing.allocator);
        try findingsAmong(rule, &all, program, &four);
        var beside: std.ArrayList(u64) = .empty;
        defer beside.deinit(std.testing.allocator);
        try findingsAmong(rule, &every, program, &beside);
        try std.testing.expectEqualSlices(u64, alone.items, four.items);
        try std.testing.expectEqualSlices(u64, alone.items, beside.items);
        some += alone.items.len;
    }
    // The fixture gives the rules something to disagree on.
    try std.testing.expect(some >= 4);
}
