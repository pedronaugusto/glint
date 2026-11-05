const std = @import("std");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const Summary = @import("Summary.zig");
const Value = Facts.Value;

const lib =
    \\pub fn Box(comptime T: type) type {
    \\    return struct {
    \\        item: T,
    \\        pub fn Pair(comptime U: type) type { return struct { left: T, right: U }; }
    \\    };
    \\}
    \\pub fn Flagged(comptime on: bool, comptime T: type) type {
    \\    if (on) return struct { set: T };
    \\    return struct { clear: T };
    \\}
    \\pub fn Named(comptime tag: enum { a, b }) type {
    \\    return switch (tag) { .a => struct { a: u8 }, .b => struct { b: u16 } };
    \\}
    \\pub fn Wrap(comptime T: type) type { return Box(T); }
    \\pub fn Local(comptime T: type) type {
    \\    const Inner = struct { t: T };
    \\    return Inner;
    \\}
    \\pub fn Gated(comptime on: bool) type {
    \\    if (on) return Box(if (on) u8 else u16);
    \\    return Box(u32);
    \\}
    \\pub const Plain = struct { x: u32, next: ?*Plain = null, f: *const fn () void = plain };
    \\pub fn plain() void {}
    \\pub var global: Plain = .{ .x = 1 };
    \\pub fn set(p: *Plain, any: anytype, bytes: []u8) void {
    \\    p.x = 2;
    \\    global.x +%= 1;
    \\    p.next = &global;
    \\    any.thing = 3;
    \\    @memcpy(bytes, std.mem.asBytes(p));
    \\    defer p.f = plain;
    \\    const q: Plain = p.*;
    \\    _ = q;
    \\}
    \\pub fn keep(comptime T: type, value: T) T {
    \\    var local = value;
    \\    local = local;
    \\    return local;
    \\}
    \\pub fn hand(comptime T: type, v: T) T {
    \\    return keep(T, v);
    \\}
    \\pub fn each(any: anytype) void {
    \\    const held = any;
    \\    _ = held;
    \\}
    \\const std = @import("std");
;

const root =
    \\const lib = @import("lib.zig");
    \\const builtin = @import("builtin");
    \\const Bytes = lib.Box(u8);
    \\const Nested = lib.Box(u8).Pair(u16);
    \\const Again = lib.Box(u8).Pair(u16);
    \\const On = lib.Flagged(true, u8);
    \\const Tagged = lib.Named(.b);
    \\const Wrapped = lib.Wrap(u8);
    \\const Inner = lib.Local(u8);
    \\const Opened = lib.Gated(true);
    \\const P = *const lib.Plain;
    \\const S = []u8;
    \\const M = [*]const u8;
    \\const A = [4]lib.Plain;
    \\const O = ?*lib.Plain;
    \\const E = anyerror!u8;
    \\const Set = error{Fail};
    \\const F = *const fn (u8) void;
    \\const f = lib.plain;
    \\const I = @typeInfo(lib.Plain);
    \\const Choice = if (builtin.os.tag == .linux) lib.Plain else lib.Box(u8);
    \\const lit = .{ .a = @as(u8, 1) };
    \\const Gone = @import("missing").Thing;
    \\const n: u8 = 3;
    \\const int = u32;
;

const Run = struct {
    project: Project,
    arena: std.heap.ArenaAllocator,
    facts: Facts,
    names: Summary.Names,

    /// The fixture's two files, `lib` first or last: the same sources under other run ids.
    fn init(run: *Run, lib_first: bool, lib_bytes: []const u8) !void {
        const a: Project.Input = .{ .name = "lib.zig", .bytes = lib_bytes };
        const b: Project.Input = .{ .name = "root.zig", .bytes = root };
        const inputs: [2]Project.Input = if (lib_first) .{ a, b } else .{ b, a };
        const root_at: usize = if (lib_first) 1 else 0;
        run.project = try Project.init(std.testing.allocator, &inputs, &.{.{ .from = root_at, .spelling = "lib.zig", .target = 1 - root_at }}, .{});
        run.arena = .init(std.testing.allocator);
        run.facts = .{ .project = &run.project, .gpa = run.arena.allocator() };
        run.names = try Summary.Names.byInput(std.testing.allocator, &run.project);
    }

    fn deinit(run: *Run) void {
        run.names.deinit(std.testing.allocator);
        run.facts.deinit();
        run.arena.deinit();
        run.project.deinit();
    }

    /// The value of each of root's declarations, in source order.
    fn values(run: *Run) ![]Value {
        const source = for (run.project.sources) |*s| {
            if (std.mem.eql(u8, s.input.name, "root.zig")) break s;
        } else unreachable; // unreachable: the fixture has root.zig
        var found: std.ArrayList(Value) = .empty;
        for (source.model.declarations) |d| {
            if (d.kind != .variable) continue;
            const init_node = source.file.tree.fullVarDecl(d.node).?.ast.init_node.unwrap() orelse continue;
            try found.append(run.arena.allocator(), try run.facts.resolve(source.id, init_node));
        }
        return found.items;
    }

    /// lib's function `name`.
    fn declared(run: *Run, name: []const u8) Facts.Decl {
        const source = for (run.project.sources) |*s| {
            if (std.mem.eql(u8, s.input.name, "lib.zig")) break s;
        } else unreachable; // unreachable: the fixture has lib.zig
        for (source.model.declarations, 0..) |d, i| if (d.kind == .function and std.mem.eql(u8, d.name, name)) return .{ .file = source.id, .index = @fromBackingInt(@intCast(i)) };
        unreachable; // unreachable: lib declares each name asked
    }

    fn write(run: *Run, all: []const Value) ![]u8 {
        var writer = try Summary.Writer.init(std.testing.allocator, &run.facts, &run.names);
        defer writer.deinit();
        for (all) |v| try writer.value(v);
        return run.arena.allocator().dupe(u8, writer.bytes.items);
    }

    fn read(run: *Run, bytes: []const u8, n: usize) ![]Value {
        var reader = try Summary.Reader.init(&run.facts, &run.names, bytes);
        defer reader.deinit();
        const out = try run.arena.allocator().alloc(Value, n);
        for (out) |*v| v.* = try reader.value();
        try std.testing.expect(reader.done());
        return out;
    }
};

/// What the fixture's values hold, so a row reads every kind it means to.
fn covers(all: []const Value) struct { made: bool, reading: bool, assumed: bool, bound: bool, kinds: usize } {
    var seen: std.EnumSet(std.meta.Tag(Value)) = .empty;
    var made = false;
    var reading = false;
    var assumed = false;
    var bound = false;
    for (all) |v| {
        seen.insert(std.meta.activeTag(v));
        const k = switch (v) {
            .container, .instance => |k| k,
            .alternatives => |each| for (each) |one| {
                if (one == .container) break one.container;
            } else continue,
            else => continue,
        };
        const m = k.made_by orelse continue;
        made = true;
        reading = reading or m.env != null or m.reading != null;
        assumed = assumed or m.assumed != null;
        bound = bound or m.bound != null;
    }
    return .{ .made = made, .reading = reading, .assumed = assumed, .bound = bound, .kinds = seen.count() };
}

test "a value is written in ids that hold across runs: read back into a run of the same sources under other run ids, it is the same value and writes the same bytes" {
    var first: Run = undefined;
    try first.init(true, lib);
    defer first.deinit();
    var second: Run = undefined;
    try second.init(false, lib);
    defer second.deinit();
    try std.testing.expect(first.project.sources[0].id == second.project.sources[0].id);
    try std.testing.expect(!std.mem.eql(u8, first.project.sources[0].input.name, second.project.sources[0].input.name));

    const resolved = try first.values();
    // And a making under settled assumptions, as a type function's branch on a comptime
    // parameter makes one: each kind of assumption, the set kept once in the run.
    const lib_file = first.project.sources[0];
    const box = first.declared("Box");
    const settled = try first.facts.intern(&.{
        .{ .parameter = first.declared("Flagged"), .value = .{ .boolean = true } },
        .{ .parameter = first.declared("Named"), .value = .{ .tag = "b" } },
    });
    const making = try first.arena.allocator().create(Facts.Made);
    making.* = .{ .function = box, .file = lib_file.id, .call = lib_file.model.declarations[@backingInt(box.index)].node, .assumed = settled };
    const live = try std.mem.concat(first.arena.allocator(), Value, &.{ resolved, &.{.{ .container = .{ .file = lib_file.id, .scope = @fromBackingInt(1), .made_by = making } }} });
    const shape = covers(live);
    try std.testing.expect(shape.made and shape.reading and shape.bound and shape.assumed);
    try std.testing.expect(shape.kinds >= 12);
    const bytes = try first.write(live);

    // Into the run that wrote them: each value is the one resolved, a kept reading the same one.
    const back = try first.read(bytes, live.len);
    for (live, back) |one, other| try std.testing.expect(Facts.sameValue(one, other));

    // Into another run: what it resolves itself, and what it writes, the same bytes.
    const moved = try second.read(bytes, live.len);
    const own = try second.values();
    for (own, moved[0..own.len]) |one, other| try std.testing.expect(Facts.sameValue(one, other));
    try std.testing.expectEqualSlices(u8, bytes, try second.write(moved));
    try std.testing.expectEqualSlices(u8, try first.write(resolved), try second.write(own));
    const held = second.facts.settled.items[@backingInt(moved[live.len - 1].container.made_by.?.assumed.?)].held;
    try std.testing.expectEqual(2, held.len);
    try std.testing.expectEqual(second.declared("Named"), held[1].parameter);
    // Read again, the set is the one the run keeps.
    try std.testing.expectEqual(moved[live.len - 1].container.made_by.?.assumed, (try second.read(bytes, live.len))[live.len - 1].container.made_by.?.assumed);
}

test "a stream is refused against other sources, cut short, or of another version" {
    var first: Run = undefined;
    try first.init(true, lib);
    defer first.deinit();
    const live = try first.values();
    const bytes = try first.write(live);

    // lib.zig with one more byte: its ids may name other declarations.
    var changed: Run = undefined;
    try changed.init(true, lib ++ "\n");
    defer changed.deinit();
    try std.testing.expectError(error.Stale, changed.read(bytes, live.len));

    try std.testing.expectError(error.Truncated, first.read(bytes[0 .. bytes.len - 1], live.len));
    var other = try first.arena.allocator().dupe(u8, bytes);
    other[0] = Summary.version + 1;
    try std.testing.expectError(error.Version, first.read(other, live.len));
}

test "a file's access index reads back into another run of the same sources as the index that run builds" {
    var first: Run = undefined;
    try first.init(true, lib);
    defer first.deinit();
    var second: Run = undefined;
    try second.init(false, lib);
    defer second.deinit();
    first.facts.check_records = &Summary.check;
    var writer = try Summary.Writer.init(std.testing.allocator, &first.facts, &first.names);
    defer writer.deinit();
    var sites: usize = 0;
    for (first.project.sources) |source| {
        const writes = try Facts.accesses.writesOf(&first.facts, source.id);
        const reads = try Facts.accesses.readsOf(&first.facts, source.id);
        sites += writes.stores.items.len + reads.places.count();
        try Summary.writeAccesses(&writer, writes);
        try Summary.writeAccesses(&writer, reads);
    }
    try std.testing.expect(sites > 8);
    var reader = try Summary.Reader.init(&second.facts, &second.names, writer.bytes.items);
    defer reader.deinit();
    // In the order the first run wrote them: lib, then root.
    for ([_][]const u8{ "lib.zig", "root.zig" }) |name| {
        const id = second.names.files.get(name).?;
        try std.testing.expect(Summary.sameAccesses(try Facts.accesses.writesOf(&second.facts, id), try Summary.readAccesses(&reader)));
        try std.testing.expect(Summary.sameAccesses(try Facts.accesses.readsOf(&second.facts, id), try Summary.readAccesses(&reader)));
    }
    try std.testing.expect(reader.done());
}

test "a run's parameter copies, closed over the calls that pass a parameter on, read back into another run of the same sources as the copies it finds" {
    var first: Run = undefined;
    try first.init(true, lib);
    defer first.deinit();
    var second: Run = undefined;
    try second.init(false, lib);
    defer second.deinit();
    first.facts.check_records = &Summary.check;
    const handed = try first.facts.parameterCopies(first.declared("hand"));
    // `hand` copies nothing itself: what it has, it has through the call that passes `v` on.
    try std.testing.expect(handed.len != 0);
    try std.testing.expect((try first.facts.parameterCopies(first.declared("each"))).len != 0);
    var writer = try Summary.Writer.init(std.testing.allocator, &first.facts, &first.names);
    defer writer.deinit();
    try Summary.writeCopies(&writer, &first.facts.copies.?);
    var reader = try Summary.Reader.init(&second.facts, &second.names, writer.bytes.items);
    defer reader.deinit();
    const back = try Summary.readCopies(&reader);
    try std.testing.expect(reader.done());
    _ = try second.facts.parameterCopies(second.declared("hand"));
    try std.testing.expect(Summary.sameCopies(&second.facts.copies.?, &back));
}
