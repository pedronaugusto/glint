//! The construct matrix of `Facts.calls`: each way a program calls a function, the callee each
//! call is read to call, and where it cannot be known, `any`, never none.
const std = @import("std");
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");
const calls = Facts.calls;

const Row = struct {
    name: []const u8,
    source: []const u8,
    /// Each call found, as "line callee args": the callee a function's name, a choice's names
    /// joined by "|", or "any" and its reason; args their count, "r" first where a receiver is
    /// bound, "?" and why where they are not known.
    expected: []const []const u8,
};

const fns = "fn a() void {}\nfn b() void {}\n";
const method = "const S = struct {\n    fn m(self: S, x: u8) void {\n        _ = self;\n        _ = x;\n    }\n};\n";
const vtable = "const V = struct { f: *const fn () void };\n";
const typed = "const T = struct {\n    fn init(n: u8) T {\n        _ = n;\n        return .{};\n    }\n    fn take(self: T, t: T) void {\n        _ = self;\n        _ = t;\n    }\n};\n";

const rows = [_]Row{
    .{ .name = "direct", .source = fns ++ "fn w() void {\n    a();\n}\n", .expected = &.{"4 a 0"} },
    .{ .name = "method on a value", .source = method ++ "fn w(s: S) void {\n    s.m(1);\n}\n", .expected = &.{"8 m r2"} },
    .{ .name = "method through a pointer", .source = method ++ "fn w(s: *const S) void {\n    s.m(1);\n}\n", .expected = &.{"8 m r2"} },
    .{ .name = "method through its type", .source = method ++ "fn w(s: S) void {\n    S.m(s, 1);\n}\n", .expected = &.{"8 m 2"} },
    .{ .name = "a constant bound to a function", .source = fns ++ "const c = a;\nfn w() void {\n    c();\n}\n", .expected = &.{"5 a 0"} },
    .{ .name = "a constant bound to its address", .source = fns ++ "const p = &a;\nfn w() void {\n    p();\n    p.*();\n}\n", .expected = &.{ "5 a 0", "6 a 0" } },
    .{ .name = "a local constant", .source = fns ++ "fn w() void {\n    const p = &b;\n    p();\n}\n", .expected = &.{"5 b 0"} },
    .{ .name = "@call", .source = fns ++ "fn w() void {\n    @call(.auto, a, .{});\n}\n", .expected = &.{"4 a 0"} },
    .{ .name = "@call of a method", .source = method ++ "fn w(s: S) void {\n    @call(.never_inline, S.m, .{ s, 1 });\n}\n", .expected = &.{"8 m 2"} },
    .{ .name = "@call given no tuple literal", .source = fns ++ "fn w() void {\n    const t = .{};\n    @call(.auto, a, t);\n}\n", .expected = &.{"5 a ? unsupported"} },
    .{ .name = "@field spelled, through a type", .source = method ++ "fn w(s: S) void {\n    @field(S, \"m\")(s, 1);\n}\n", .expected = &.{"8 m 2"} },
    .{ .name = "@field spelled, on a value", .source = method ++ "fn w(s: S) void {\n    @field(s, \"m\")(1);\n}\n", .expected = &.{"8 m r2"} },
    .{ .name = "@field spelled, through a generic's instance, as its member access", .source = "fn G(comptime T: type) type {\n    return struct {\n        fn m(x: T) void {\n            _ = x;\n        }\n    };\n}\nconst L = G(u8);\nfn w() void {\n    @field(L, \"m\")(1);\n    L.m(1);\n}\n", .expected = &.{ "10 m 1", "11 m 1", "8 G 1" } },
    .{ .name = "@field computed", .source = fns ++ "fn w(comptime n: []const u8) void {\n    @field(@This(), n)();\n}\n", .expected = &.{"4 any comptime_dependent 0"} },
    .{ .name = "a function pointer's every store", .source = vtable ++ fns ++ "const x: V = .{ .f = &a };\nconst y: V = .{ .f = &b };\nfn w(v: V) void {\n    v.f();\n}\n", .expected = &.{"7 a|b 0"} },
    .{ .name = "a function pointer whose address is taken", .source = vtable ++ fns ++ "const x: V = .{ .f = &a };\nfn z(v: *V) *const *const fn () void {\n    return &v.f;\n}\nfn w(v: V) void {\n    v.f();\n}\n", .expected = &.{"9 any unresolved 0"} },
    .{ .name = "@call through a function pointer", .source = vtable ++ fns ++ "const x: V = .{ .f = &a };\nfn w(v: V) void {\n    @call(.auto, v.f, .{});\n}\n", .expected = &.{"6 a 0"} },
    .{ .name = "a mutable local's every store", .source = fns ++ "fn w(c: bool) void {\n    var f: *const fn () void = &a;\n    if (c) f = &b;\n    f();\n}\n", .expected = &.{"6 a|b 0"} },
    .{ .name = "a mutable local set after undefined", .source = fns ++ "fn w() void {\n    var f: *const fn () void = undefined;\n    f = &b;\n    f();\n}\n", .expected = &.{"6 b 0"} },
    .{ .name = "a mutable local whose address is taken", .source = fns ++ "fn w() void {\n    var f: *const fn () void = &a;\n    const q = &f;\n    q.* = &b;\n    f();\n}\n", .expected = &.{"7 any unresolved 0"} },
    .{ .name = "a private global's every store", .source = fns ++ "var h: *const fn () void = &a;\nfn s() void {\n    h = &b;\n}\nfn w() void {\n    h();\n}\n", .expected = &.{"8 a|b 0"} },
    .{ .name = "a public global", .source = fns ++ "pub var h: *const fn () void = &a;\nfn w() void {\n    h();\n}\n", .expected = &.{"5 any unresolved 0"} },
    .{ .name = "a parameter", .source = "fn w(f: *const fn () void) void {\n    f();\n}\n", .expected = &.{"2 any unresolved 0"} },
    .{ .name = "a capture", .source = fns ++ "const fs = [_]*const fn () void{ &a, &b };\nfn w() void {\n    for (fs) |f| f();\n}\n", .expected = &.{"5 a|b 0"} },
    .{ .name = "an element of a constant table", .source = fns ++ "fn w(i: usize) void {\n    const t = [_]*const fn () void{ &a, &b };\n    t[i]();\n}\n", .expected = &.{"5 a|b 0"} },
    .{ .name = "a typeless literal's field", .source = fns ++ "fn w() void {\n    const ops = .{ .run = &a };\n    ops.run();\n}\n", .expected = &.{"5 a 0"} },
    .{ .name = "a mutable local's address dropped", .source = fns ++ "fn w() void {\n    var f: *const fn () void = &a;\n    _ = &f;\n    f();\n}\n", .expected = &.{"6 a 0"} },
    .{ .name = "a branch's every result", .source = fns ++ "fn w(c: bool) void {\n    const f = if (c) &a else &b;\n    f();\n}\n", .expected = &.{"5 a|b 0"} },
    .{ .name = "a private function's parameter, bound at its calls", .source = fns ++ "fn apply(f: *const fn () void) void {\n    f();\n}\nfn w() void {\n    apply(&a);\n}\n", .expected = &.{ "4 a 0", "7 apply 1" } },
    .{ .name = "a comptime parameter, bound at its calls", .source = fns ++ "fn twice(comptime f: fn () void) void {\n    f();\n}\npub fn w() void {\n    twice(b);\n}\n", .expected = &.{ "4 b 0", "7 twice 1" } },
    .{ .name = "a public function's parameter", .source = fns ++ "pub fn apply(f: *const fn () void) void {\n    f();\n}\nfn w() void {\n    apply(&a);\n}\n", .expected = &.{ "4 any unresolved 0", "7 apply 1" } },
    .{ .name = "an optional's payload", .source = fns ++ "fn w(c: bool) void {\n    const m: ?*const fn () void = if (c) &a else null;\n    if (m) |f| f();\n}\n", .expected = &.{"5 a 0"} },
    .{ .name = "an optional unwrapped", .source = fns ++ "fn w() void {\n    const m: ?*const fn () void = &a;\n    m.?();\n}\n", .expected = &.{"5 a 0"} },
    .{ .name = "a cast of a function's pointer", .source = fns ++ "fn w() void {\n    const f: *const fn () void = @ptrCast(&a);\n    f();\n}\n", .expected = &.{"5 a 0"} },
    .{ .name = "a destructure's elements", .source = fns ++ "fn w() void {\n    const f, const g = .{ a, b };\n    f();\n    g();\n}\n", .expected = &.{ "5 a 0", "6 b 0" } },
    .{ .name = "an inline for over a tuple of functions", .source = fns ++ "fn w() void {\n    inline for (.{ a, b }) |f| f();\n}\n", .expected = &.{"4 a|b 0"} },
    .{ .name = "a labeled block's every break", .source = fns ++ "fn w(c: bool) void {\n    const f = blk: {\n        if (c) break :blk &a;\n        break :blk &b;\n    };\n    f();\n}\n", .expected = &.{"8 a|b 0"} },
    .{ .name = "a load of memory a caller gives", .source = fns ++ "pub fn w(slot: **const fn () void) void {\n    @atomicStore(*const fn () void, slot, &a, .release);\n    @atomicLoad(*const fn () void, slot, .acquire)();\n}\n", .expected = &.{"5 any unresolved 0"} },
    .{ .name = "its dereference, which the load reads as", .source = fns ++ "pub fn w(slot: **const fn () void) void {\n    slot.*();\n}\n", .expected = &.{"4 any unresolved 0"} },
    .{ .name = "an element", .source = fns ++ "var fs = [_]*const fn () void{ &a, &b };\nfn w() void {\n    fs[0]();\n}\n", .expected = &.{"5 any unresolved 0"} },
    .{ .name = "a call's result", .source = fns ++ "fn get() *const fn () void {\n    return &a;\n}\nfn w() void {\n    get()();\n}\n", .expected = &.{ "7 any unresolved 0", "7 get 0" } },
    .{ .name = "a member of a holder that does not resolve", .source = "fn w(s: anytype) void {\n    s.m();\n}\n", .expected = &.{"2 any generic ? generic"} },
    .{ .name = "a decl literal, its place a variable's type", .source = typed ++ "fn w() void {\n    const t: T = .init(1);\n    _ = t;\n}\n", .expected = &.{"12 init 1"} },
    .{ .name = "a decl literal, its place a parameter's type", .source = typed ++ "fn put(t: T) void {\n    _ = t;\n}\nfn w() void {\n    put(.init(1));\n}\n", .expected = &.{ "15 init 1", "15 put 1" } },
    .{ .name = "a method of a choice of holders binds the one chosen", .source = typed ++ "const U = struct {\n    fn take(self: *const U, t: T) void {\n        _ = self;\n        _ = t;\n    }\n};\nfn w(comptime c: bool, s: *const T, u: *const U, t: T) void {\n    const h = if (c) s else u;\n    h.take(t);\n}\n", .expected = &.{"19 take|take r2"} },
    .{ .name = "a decl literal, its place a parameter past a bound receiver", .source = typed ++ "fn w(s: T) void {\n    s.take(.init(1));\n}\n", .expected = &.{ "12 init 1", "12 take r2" } },
    .{ .name = "a decl literal, its place a field of a prong's literal, an if's branch and orelse's other value", .source = typed ++ "const H = struct { t: T };\nfn w(c: bool, o: ?T, u: union(enum) { a, b }) void {\n    const h: H = switch (u) {\n        .a => .{ .t = .init(1) },\n        .b => .{ .t = if (c) .init(2) else o orelse .init(3) },\n    };\n    _ = h;\n}\n", .expected = &.{ "14 init 1", "15 init 1", "15 init 1" } },
    .{ .name = "a decl literal, its place a generic's parameter, which gives it no type", .source = typed ++ "fn put(t: anytype) void {\n    _ = t;\n}\nfn w() void {\n    put(.init(1));\n}\n", .expected = &.{ "15 any comptime_dependent 1", "15 put 1" } },
};

fn name(project: *const Project, decl: Facts.Decl) []const u8 {
    return project.at(decl.file).model.declarations[@backingInt(decl.index)].name;
}

fn found(a: std.mem.Allocator, project: *const Project, call: calls.Call) ![]const u8 {
    const tree = &project.at(call.file).file.tree;
    const line = tree.tokenLocation(0, tree.firstToken(call.node)).line + 1;
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.print("{d} ", .{line});
    switch (call.callee) {
        .function => |decl| try out.writer.writeAll(name(project, decl)),
        .choice => |each| {
            var names: std.ArrayList([]const u8) = .empty;
            for (each) |decl| try names.append(a, name(project, decl));
            std.mem.sort([]const u8, names.items, {}, lessThan);
            for (names.items, 0..) |one, i| try out.writer.print("{s}{s}", .{ if (i == 0) "" else "|", one });
        },
        .any => |why| try out.writer.print("any {t}", .{why}),
    }
    switch (call.args) {
        .known => |args| try out.writer.print(" {s}{d}", .{ if (call.receiver == .bound) "r" else "", args.len }),
        .unknown => |why| try out.writer.print(" ? {t}", .{why}),
    }
    return out.written();
}

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

test "calls: each construct's callee is read, and any where it cannot be known" {
    var failed = false;
    for (rows) |row| {
        var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = row.source }}, &.{}, .{});
        defer project.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var facts: Facts = .{ .project = &project, .gpa = a };
        defer facts.deinit();
        var lines: std.ArrayList([]const u8) = .empty;
        for (try calls.in(&facts, project.sources[0].id)) |call| try lines.append(a, try found(a, &project, call));
        std.mem.sort([]const u8, lines.items, {}, lessThan);
        const same = lines.items.len == row.expected.len and for (lines.items, row.expected) |got, want| {
            if (!std.mem.eql(u8, got, want)) break false;
        } else true;
        if (same) continue;
        failed = true;
        std.debug.print("{s}: expected", .{row.name});
        for (row.expected) |want| std.debug.print(" [{s}]", .{want});
        std.debug.print(", found", .{});
        for (lines.items) |got| std.debug.print(" [{s}]", .{got});
        std.debug.print("\n", .{});
    }
    try std.testing.expect(!failed);
}

test "calls: a call of one argument keeps it past the next call read" {
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "fn one(x: u8) void {\n    _ = x;\n}\nfn w() void {\n    one(7);\n    one(8);\n}\n" }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const tree = &project.sources[0].file.tree;
    const made = try calls.in(&facts, project.sources[0].id);
    try std.testing.expectEqual(@as(usize, 2), made.len);
    for (made, [_][]const u8{ "7", "8" }) |call, literal| {
        try std.testing.expectEqualStrings(literal, tree.getNodeSource(call.args.known[0]));
    }
}

test "calls: a function-running call makes a deferred call of its function with the tuple's elements, found by meaning" {
    // `concurrent` and `async` declare their tuple `std.meta.ArgsTuple(@TypeOf(function))`;
    // `spawn` hands both to a function whose body `@call`s them; `other` takes a tuple it never
    // runs, as `anytype`: no call of `work` is read there.
    const fixture_std = "pub const meta = struct {\n    pub fn ArgsTuple(comptime F: type) type {\n        _ = F;\n        return struct {};\n    }\n};\n";
    const source =
        \\const std = @import("std");
        \\const Io = struct {
        \\    fn concurrent(io: Io, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) void {
        \\        _ = io;
        \\        _ = args;
        \\    }
        \\};
        \\const Group = struct {
        \\    fn async(g: *Group, io: Io, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) void {
        \\        _ = g;
        \\        _ = io;
        \\        _ = args;
        \\    }
        \\};
        \\fn start(comptime function: anytype, args: anytype) void {
        \\    @call(.auto, function, args);
        \\}
        \\fn spawn(comptime function: anytype, args: anytype) void {
        \\    start(function, args);
        \\}
        \\fn other(function: anytype, args: anytype) void {
        \\    _ = function;
        \\    _ = args;
        \\}
        \\fn work(x: u8) void {
        \\    _ = x;
        \\}
        \\fn w(io: Io, g: *Group) void {
        \\    io.concurrent(work, .{1});
        \\    g.async(io, work, .{2});
        \\    spawn(work, .{3});
        \\    other(work, .{4});
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{ .{ .name = "root", .bytes = source }, .{ .name = "std", .bytes = fixture_std, .selected = false } }, &.{.{ .from = 0, .spelling = "std", .target = 1 }}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var facts: Facts = .{ .project = &project, .gpa = a };
    defer facts.deinit();
    var lines: std.ArrayList([]const u8) = .empty;
    for (try calls.in(&facts, project.sources[0].id)) |call| {
        const later = (try calls.deferredOf(&facts, call)) orelse continue;
        try std.testing.expect(later.deferred);
        try lines.append(a, try found(a, &project, later));
    }
    std.mem.sort([]const u8, lines.items, {}, lessThan);
    // `start(function, args)` in `spawn` runs `spawn`'s own parameters: `work`, its one
    // binding, with a tuple that is no literal there.
    const expected = [_][]const u8{ "19 work ? unsupported", "29 work 1", "30 work 1", "31 work 1" };
    try std.testing.expectEqual(expected.len, lines.items.len);
    for (expected, lines.items) |want, got| try std.testing.expectEqualStrings(want, got);
}
