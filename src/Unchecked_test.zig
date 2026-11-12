//! P007 (operations Zig leaves unchecked), P008 (identifying integers of one type) and P009 (a
//! pointer into the frame carried out): the sites each finds and the sites it leaves alone, over a
//! std laid out as Zig 0.17's.
const std = @import("std");
const glint = @import("glint");
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
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = rule, .level = .report }} }, .{});
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
fn expect(rule: glint.Rule, program: []const u8, findings: usize) !void {
    const result = try run(rule, program);
    try std.testing.expectEqual(@as(usize, 0), result.undecided); // safe: fixture counts are representable.
    try std.testing.expectEqual(findings, result.findings);
}

test "P007 finds the unchecked operations, a cast nested in another once, a suppression covering one, never an address read" {
    try expect(.P007,
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
        \\    const s: *u8 = @ptrFromInt(a); // glint-ignore: P007 -- an address the kernel hands back
        \\    _ = s;
        \\    return @intFromPtr(p);
        \\}
    , 5);
}

test "P009 finds a pointer into the frame carried out of the call" {
    try expect(.P009, "pub fn f(n: usize) []u8 { var buf: [16]u8 = undefined; buf[0] = 1; return buf[0..n]; }", 1);
    try expect(.P009, "pub fn f() *u32 { var x: u32 = 1; x += 1; const out = &x; return out; }", 1);
    try expect(.P009, "const R = struct { s: []u8 }; pub fn f(n: usize) R { var buf: [8]u8 = undefined; buf[0] = 1; return .{ .s = buf[0..n] }; }", 1);
    // A const of a run-time value, a local whose type only its value gives, a var alias and an
    // alias of an alias. (Stores into another object's field or a global are no longer A014's:
    // the 0.8 cut keeps the certain return shape.)
    try expect(.P009, "pub fn f(x: u8) []const u8 { const buf = [_]u8{ x, 1 }; return buf[0..]; }", 1);
    try expect(.P009, "pub fn f(n: usize) []u8 { var buf = [_]u8{ 0, 0, 0, 0 }; buf[0] = 1; return buf[0..n]; }", 1);
    try expect(.P009, "pub fn f() *u32 { var x: u32 = 1; x += 1; var p: *u32 = undefined; p = &x; return p; }", 1);
    try expect(.P009, "pub fn f() *u32 { var x: u32 = 1; x += 1; const a = &x; const b = a; return b; }", 1);
    // Stored by a destructure into a `var` alias that is returned.
    try expect(.P009, "pub fn f() *u32 { var x: u32 = 1; x += 1; var p: *u32 = undefined; p, _ = .{ &x, 0 }; return p; }", 1);
    // A slice of a pointer local points where the pointer does: into a local array it was
    // given, and nowhere in the frame where it is made from an integer, its type unresolved (a
    // generic's `@TypeOf(slice.ptr)`, relic-b's warp c.zig:774).
    try expect(.P009, "pub fn f(n: u8) []u8 { var buf: [4]u8 = .{ n, n, n, n }; buf[0] = 1; const p: [*]u8 = &buf; return p[0..2]; }", 1);
    try expect(.P009, "fn m(s: anytype, at: usize) @TypeOf(s) { const p: @TypeOf(s.ptr) = @ptrFromInt(at); return p[0..s.len]; } pub fn f(x: anytype) void { _ = m(x, 8); }", 0);
    try expect(.P009, "fn m(s: anytype, at: usize) @TypeOf(s) { const p: @TypeOf(s.ptr) = @ptrCast(@alignCast(@as(*u8, @ptrFromInt(at)))); return p[0..s.len]; } pub fn f(x: anytype) void { _ = m(x, 8); }", 0);
}

test "P009 leaves static storage, pointers, copies and a store a defer clears on every exit alone" {
    try expect(.P009, "pub fn f() []const u8 { const table = [_]u8{ 1, 2 }; return table[0..]; }", 0);
    try expect(.P009, "pub fn f() []const u8 { comptime { var buf: [2]u8 = .{ 1, 2 }; buf[0] = 3; const out = buf; return &out; } }", 0);
    try expect(.P009, "pub fn Make(comptime n: usize) type { var x: [n]u8 = undefined; x[0] = 1; _ = &x; return struct {}; }", 0);
    try expect(.P009, "const N = struct { v: u32 }; pub fn f(head: *N) *u32 { var node: *N = head; node.v += 1; return &node.v; }", 0);
    try expect(.P009, "pub fn f(items: []u8) []u8 { var s: []u8 = items; s = s[1..]; return s[0..1]; }", 0);
    try expect(.P009, "pub fn f() [4]u8 { var buf: [4]u8 = undefined; buf[0] = 1; return buf; }", 0);
    try expect(.P009, "const T = struct { cur: ?*u32 = null }; pub fn f(t: *T) void { var x: u32 = 1; x += 1; t.cur = &x; defer t.cur = null; }", 0);
    try expect(.P009, "pub fn f() u32 { var x: u32 = 1; var p: *u32 = undefined; p = &x; p.* += 1; return x; }", 0);
    try expect(.P009, "const T = struct { cur: ?*u32 = null }; pub fn f(t: *T) void { var x: u32 = 1; x += 1; t.cur = &x; defer { t.cur = null; } }", 0);
    // Twins: a destructure that stores no pointer into the frame, and the clear spelled
    // otherwise, naming the same memory.
    try expect(.P009, "const T = struct { p: ?*u32 = null }; pub fn f(t: *T, y: *u32) void { var x: u32 = 1; x += 1; t.p, _ = .{ y, x }; }", 0);
    try expect(.P009, "const T = struct { cur: ?*u32 = null }; pub fn f(t: *T) void { var x: u32 = 1; x += 1; t.cur = &x; defer (t).cur = null; }", 0);
}

test "P008 finds identifying integers of one type meeting, not other integers" {
    try expect(.P008,
        \\const NodeIndex = u32;
        \\pub fn link(parent_id: u32, child_id: u32) void { _ = parent_id; _ = child_id; }
        \\pub fn move(from: NodeIndex, toIndex: u32) void { _ = from; _ = toIndex; }
        \\pub const Edge = struct { source_index: usize, target_index: usize, weight: usize };
        \\pub fn clamp(x: u32, lo: u32, hi: u32) u32 { _ = lo; _ = hi; return x; }
        \\pub fn pair(node_id: u32, slot_id: u64) void { _ = node_id; _ = slot_id; }
        \\fn private(a_id: u32, b_id: u32) void { _ = a_id; _ = b_id; }
    , 2);
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

test "P007 reads a module republishing aegis beside code of its own as the program's: only aegis's own package leaves it" {
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
    const found = try runWith(.P007, comptime edited(interface_program, "const std = @import(\"std\");\n", "const std = @import(\"std\");\nconst wrap = @import(\"wrap\");\n"), extra, imports);
    try std.testing.expectEqualSlices(u32, &.{12}, found.lines[0..found.findings]);
}

test "P007 reads every file a path import joins to the program, selected or not: a copy of an interface field there leaves the conversion a finding" {
    // `other.zig`, outside the selection, copies the field it is handed: 11, the conversion
    // and its alignment.
    const program = comptime edited(interface_program, "pub fn use() !usize {", "const other = @import(\"other.zig\");\npub fn use() !usize {\n    var t: Sink = .init();\n    other.keep(&t);");
    const other: sources.Extra = .{ .name = "other.zig", .bytes = "pub fn keep(s: anytype) void { const copy = s.interface; _ = copy; }" };
    const found = try runWith(.P007, program, &(std_files ++ [_]sources.Extra{other}), &(std_imports ++ [_]sources.ExtraImport{.{ .spelling = "other.zig", .target = std_files.len }}));
    try std.testing.expectEqualSlices(u32, &.{11}, found.lines[0..found.findings]);
}

/// `program` after the fixes of `rule`'s findings and its stale escapes.
fn fixed(rule: glint.Rule, program: []const u8) ![]u8 {
    var project = try sources.projectWithSources(std.testing.allocator, program, &std_files, &std_imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = rule, .level = .gate }} }, .{});
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
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = selections[0..rules.len] }, .{});
    defer report.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = try glint.Fix.escapeRecord(arena.allocator(), record);
    const changed = try glint.Fix.apply(arena.allocator(), &project, &report, .{ .escapes_before = before });
    const bytes = if (changed.len == 0) program else changed[0].bytes;
    return .{ .bytes = try std.testing.allocator.dupe(u8, bytes), .stale = report.stale.len };
}

test "one suppression names each rule it covers on its line, one site each; the aegis escape form is malformed" {
    var project = try sources.projectWithSources(std.testing.allocator,
        \\pub fn f(parent_id: u32, child_id: u32) *u8 { return @ptrFromInt(parent_id + child_id); } // glint-ignore: P007, P008 -- the board's two register ids
        \\pub fn g(parent_id: u32, child_id: u32) *u8 { return @ptrFromInt(parent_id + child_id); } // glint-ignore: P007 -- only the conversion
        \\pub fn h(a: usize) *u8 { return @ptrFromInt(a); } // aegis: boundary(A019): the old form
    , &std_files, &std_imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{ .{ .rule = .P007, .level = .gate }, .{ .rule = .P008, .level = .gate } } }, .{});
    defer report.deinit();
    // g's P008 stands, and h's P007 under a comment glint reads no more.
    try std.testing.expectEqual(@as(usize, 2), report.diagnostics.len); // safe: fixture counts are representable.
    try std.testing.expectEqual(@as(u32, 2), report.diagnostics[0].span.line);
    try std.testing.expectEqual(@as(u32, 3), report.diagnostics[1].span.line);
    try std.testing.expectEqual(@as(usize, 3), report.suppressed); // safe: f's two and g's one.
    try std.testing.expectEqual(@as(usize, 1), report.malformed.len); // safe: the old escape.
    try std.testing.expect(!report.complete);
}

test "the fix rewrites the aegis escape into glint-ignore under today's names, names an older one from a run's record, and removes one naming only a rule that went" {
    const program =
        \\pub fn a(p: usize) *u8 {
        \\    return @ptrFromInt(p); // aegis: internal(A019, A014): the page the kernel hands back
        \\}
        \\pub fn b(p: usize) *u8 {
        \\    return @ptrFromInt(p); // aegis: boundary: the device register
        \\}
        \\pub fn c(p: usize) *u8 {
        \\    return @ptrFromInt(p); // aegis: no-danger(A010): gone with the flow engine
        \\}
        \\pub fn d(p: usize) *u8 {
        \\    return @ptrFromInt(p); // aegis: design: no record names it
        \\}
        \\
    ;
    const out = try fixedBy(&.{.P007}, program, "glint: escape: consumer:5:28: boundary: the device register (A019)\n");
    defer std.testing.allocator.free(out.bytes);
    try std.testing.expectEqualStrings(
        \\pub fn a(p: usize) *u8 {
        \\    return @ptrFromInt(p); // glint-ignore: P007, P009 -- internal: the page the kernel hands back
        \\}
        \\pub fn b(p: usize) *u8 {
        \\    return @ptrFromInt(p); // glint-ignore: P007 -- boundary: the device register
        \\}
        \\pub fn c(p: usize) *u8 {
        \\    return @ptrFromInt(p);
        \\}
        \\pub fn d(p: usize) *u8 {
        \\    return @ptrFromInt(p); // aegis: design: no record names it
        \\}
        \\
    , out.bytes);
    // A record line that names an escape and is not one is refused.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidEscapeRecord, glint.Fix.escapeRecord(arena.allocator(), "glint: escape: consumer:x:1: no-danger: why (A019)\n"));
}

test "P007 reads @setRuntimeSafety on the build mode in each mode: off where the build keeps the checks, undecided on anything else" {
    // fiat-crypto's form: checked only in debug, so off in safe builds.
    try expect(.P007,
        \\const mode = @import("builtin").mode;
        \\pub fn f(a: u64, b: u64) u64 {
        \\    @setRuntimeSafety(mode == .debug);
        \\    return a +% b;
        \\}
    , 1);
    // Through the builtin import and a constant: off nowhere the build keeps checks.
    try expect(.P007,
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
    try expect(.P007,
        \\const builtin = @import("builtin");
        \\pub fn f(a: u64, b: u64) u64 {
        \\    @setRuntimeSafety(builtin.mode == .fast);
        \\    return a +% b;
        \\}
    , 1);
    const other = try run(.P007,
        \\const flags = struct { var checked: bool = true; };
        \\pub fn f(a: u64, b: u64) u64 {
        \\    @setRuntimeSafety(flags.checked);
        \\    return a +% b;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), other.undecided);
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

test "P007 reads a call through a function field's captured payload as one through the field" {
    // `if (o.f) |f| f(o)` hands the interface as `o.f.?(o)` does: what the field holds is judged
    // where it is installed, never left undecided at the call.
    const captured = try run(.P007, captured_field_program);
    const unwrapped = try runEdited(.P007, captured_field_program, "if (observer.boundary) |boundary| boundary(observer);", "observer.boundary.?(observer);");
    try std.testing.expectEqual(@as(usize, 0), captured.undecided);
    try std.testing.expectEqual(unwrapped.undecided, captured.undecided);
    try std.testing.expectEqual(unwrapped.findings, captured.findings);
}
