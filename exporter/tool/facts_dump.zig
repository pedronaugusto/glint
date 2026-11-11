//! facts_dump FILE: a compiled-facts file as text, for the exporter's conformance fixtures.
//! Nothing in the text depends on InternPool numbering, ZIR instruction numbers or analysis
//! order: bodies in the file's canonical order by name, each with its comptime arguments by
//! structure, its caller, how many results it has and what it calls. A function instance's
//! `__anon_N`/`__func_N` suffix is dropped. Bodies of files outside the directory of the root
//! (std's) are left out unless `--all` is given. The file is read by glint's own reader
//! (src/compiled_read.zig), so what it refuses the dump refuses.
const std = @import("std");
const reader = @import("reader");
// The format's own file, copied beside the tool by round.sh: glint's reader keeps its copy private.
const format = @import("format");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.skip();
    var path: ?[]const u8 = null;
    var all = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--all")) all = true else path = arg;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path orelse return error.NoFile, gpa, .limited(1 << 30));
    var buffer: [1 << 16]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    const w = &out.interface;
    const records = switch (try reader.read(gpa, .init(bytes), .{})) {
        .kept => |kept| kept,
        .refused => |why| {
            try w.print("refused {t}\n", .{why});
            try w.flush();
            return;
        },
    };
    // The records glint read, in the format's layout again; every id among them is checked.
    const builder = try toBuilder(gpa, &records);
    const view: View = .{ .b = &builder, .config = builder.config.items, .files = builder.files.items, .values = builder.values.items, .bodies = builder.bodies.items };
    // It is canonical: writing it again changes nothing.
    const ordered = try format.canonical(gpa, &builder);
    const again = try ordered.finish();
    try w.print("canonical {s}\n", .{if (std.mem.eql(u8, again, bytes)) "yes" else "NO"});

    var root_directory: []const u8 = "";
    for (view.config) |each| {
        const key = view.string(each.key);
        if (std.mem.eql(u8, key, "root_directory")) root_directory = view.string(each.value);
        // What differs by machine is left out.
        if (std.mem.eql(u8, key, "root_directory") or std.mem.eql(u8, key, "target")) continue;
        try w.print("config {s}={s}\n", .{ key, view.string(each.value) });
    }
    const names = try gpa.alloc([]const u8, view.bodies.len);
    for (names, view.bodies) |*name, body| name.* = if (body.function == format.none) "(unnamed)" else plain(view.string(view.values[body.function].text));

    var lines: std.ArrayList([]const u8) = .empty;
    for (view.bodies, 0..) |body, id| {
        const own = std.mem.startsWith(u8, view.string(view.files[body.file].path), root_directory) and root_directory.len != 0;
        if (!own and !all) continue;
        var line: std.Io.Writer.Allocating = .init(gpa);
        const l = &line.writer;
        const kind: format.Body.Kind = @fromBackingInt(body.kind);
        try l.print("body {t} {s}(", .{ kind, names[id] });
        for (view.run(body.arguments), 0..) |argument, position| {
            if (position != 0) try l.writeAll(", ");
            try writeValue(l, &view, argument, 0);
        }
        try l.writeAll(")");
        if (body.caller != format.none) {
            try l.print(" in {s} at ", .{names[body.caller]});
            try writeCallSite(l, &view, view.bodies[body.caller], body.call, body.call_visit);
        }
        try l.print(" results={s}", .{if (body.results_len == 0) "none" else "some"});
        // What it calls, each callee once with its count, in name order.
        var callees: std.ArrayList([]const u8) = .empty;
        for (view.resultsOf(body)) |result| {
            if (result.callee == format.none) continue;
            if (result.callee == format.Result.runtime_callee) {
                try callees.append(gpa, "(runtime pointer)");
                continue;
            }
            var callee: std.Io.Writer.Allocating = .init(gpa);
            try writeValue(&callee.writer, &view, result.callee, 0);
            try callees.append(gpa, callee.written());
        }
        std.mem.sort([]const u8, callees.items, {}, lessText);
        var at: usize = 0;
        while (at < callees.items.len) {
            var end = at + 1;
            while (end < callees.items.len and std.mem.eql(u8, callees.items[end], callees.items[at])) end += 1;
            try l.print("\n  calls {s} x{d}", .{ callees.items[at], end - at });
            at = end;
        }
        try lines.append(gpa, line.written());
    }
    // The file's order is by path and instruction; the text's is by the line, so a fixture
    // does not change when a declaration moves.
    std.mem.sort([]const u8, lines.items, {}, lessText);
    for (lines.items) |line| try w.print("{s}\n", .{line});
    try w.flush();
}

fn lessText(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// A name without the instance suffix the compiler numbers it with.
fn plain(name: []const u8) []const u8 {
    inline for (.{ "__anon_", "__func_" }) |marker| {
        if (std.mem.findLast(u8, name, marker)) |at| {
            const digits = name[at + marker.len ..];
            const numeric = digits.len != 0 and for (digits) |c| {
                if (c < '0' or c > '9') break false;
            } else true;
            if (numeric) return name[0..at];
        }
    }
    return name;
}

/// The records as the dump reads them: every id among them was checked by the reader.
const View = struct {
    b: *const format.Builder,
    config: []const format.Config = &.{},
    files: []const format.File = &.{},
    values: []const format.Value = &.{},
    bodies: []const format.Body = &.{},

    fn string(view: *const View, text: format.Text) []const u8 {
        return view.b.strings.items[text.start..][0..text.len];
    }
    fn run(view: *const View, list: format.Run) []const u32 {
        return view.b.extra.items[list.start..][0..list.len];
    }
    fn resultsOf(view: *const View, body: format.Body) []const format.Result {
        return view.b.results.items[body.results_start..][0..body.results_len];
    }
};

fn rawId(id: anytype) u32 {
    return if (id) |known| @backingInt(known) else format.none;
}

fn toBuilder(gpa: std.mem.Allocator, records: *const reader.Records) !format.Builder {
    var b: format.Builder = .{ .gpa = gpa };
    try b.strings.appendSlice(gpa, records.strings);
    try b.extra.appendSlice(gpa, records.extra);
    for (records.config) |each| try b.config.append(gpa, .{ .key = .{ .start = each.key.start, .len = each.key.len }, .value = .{ .start = each.value.start, .len = each.value.len } });
    for (records.files) |each| try b.files.append(gpa, .{ .path = .{ .start = each.path.start, .len = each.path.len }, .hash = each.hash });
    for (records.values) |each| try b.values.append(gpa, .{ .kind = @backingInt(each.kind), .a = each.a, .b = each.b, .c = each.c, .list = .{ .start = each.list.start, .len = each.list.len }, .text = .{ .start = each.text.start, .len = each.text.len } });
    for (records.bodies) |each| try b.bodies.append(gpa, .{
        .kind = @backingInt(each.kind),
        .file = @backingInt(each.file),
        .declaration = each.declaration,
        .function = rawId(each.function),
        .arguments = .{ .start = each.arguments.start, .len = each.arguments.len },
        .caller = rawId(each.caller),
        .call = each.call,
        .call_visit = each.call_visit,
        .result = rawId(each.result),
        .results_start = each.results_start,
        .results_len = each.results_len,
    });
    for (records.results) |each| try b.results.append(gpa, .{
        .instruction = each.instruction,
        .visit = each.visit,
        .value = rawId(each.value),
        .type = rawId(each.type),
        .callee = switch (each.callee) {
            .none => format.none,
            .runtime => format.Result.runtime_callee,
            .function => |callee| @backingInt(callee),
        },
    });
    return b;
}

/// Where a call analysed in place was made, without ZIR numbers: what the caller's result at
/// its call (instruction and visit) is. The call's own result is the inlined body's (`runtime`
/// or the value it folded to); a key on another instruction shows that one's instead (an
/// argument's call, `no result`), so a fixture tells a wrong key from a right one.
fn writeCallSite(w: *std.Io.Writer, view: *const View, caller: format.Body, call: u32, visit: u32) std.Io.Writer.Error!void {
    for (view.resultsOf(caller)) |result| {
        if (result.instruction != call or result.visit != visit) continue;
        if (result.callee == format.Result.runtime_callee) return w.writeAll("call (runtime pointer)");
        if (result.callee != format.none) {
            try w.writeAll("call ");
            return writeValue(w, view, result.callee, 0);
        }
        if (result.value != format.none) return writeValue(w, view, result.value, 0);
        if (result.type != format.none) {
            try w.writeAll("runtime ");
            return writeValue(w, view, result.type, 0);
        }
        return w.writeAll("runtime");
    }
    return w.writeAll("no result");
}

fn writeValue(w: *std.Io.Writer, view: *const View, id: u32, depth: u8) std.Io.Writer.Error!void {
    if (id == format.none) return w.writeAll("-");
    if (depth > 8) return w.writeAll("...");
    const value = view.values[id];
    const kind: format.Value.Kind = @fromBackingInt(value.kind);
    switch (kind) {
        .unwritten => try w.print("unwritten:{s}", .{view.string(value.text)}),
        .simple_type, .simple => try w.writeAll(view.string(value.text)),
        .int_type => try w.print("{s}{d}", .{ if (value.b == 1) "i" else "u", value.a }),
        .pointer_type => {
            try w.writeAll(switch (value.b) {
                0 => "*",
                1 => "[*]",
                2 => "[]",
                else => "[*c]",
            });
            if (value.c == 1) try w.writeAll("const ");
            try writeValue(w, view, value.a, depth + 1);
        },
        .optional_type => {
            try w.writeAll("?");
            try writeValue(w, view, value.a, depth + 1);
        },
        .array_type => {
            const len = view.run(value.list);
            try w.print("[{d}]", .{if (len.len == 2) @as(u64, len[0]) | (@as(u64, len[1]) << 32) else 0});
            try writeValue(w, view, value.a, depth + 1);
        },
        .vector_type => {
            try w.print("@Vector({d}, ", .{value.b});
            try writeValue(w, view, value.a, depth + 1);
            try w.writeAll(")");
        },
        .error_union_type => {
            try w.writeAll("!");
            try writeValue(w, view, value.b, depth + 1);
        },
        .declared_type => try w.print("{s}", .{plain(view.string(value.text))}),
        .function => try w.print("fn {s}", .{plain(view.string(value.text))}),
        .int => {
            const magnitude = view.run(value.list);
            try w.print("{s}{d}", .{ if (value.b == 1) "-" else "", if (magnitude.len == 2) @as(u64, magnitude[0]) | (@as(u64, magnitude[1]) << 32) else 0 });
        },
        .enum_literal => try w.print(".{s}", .{view.string(value.text)}),
        .enum_tag => {
            try writeValue(w, view, value.a, depth + 1);
            try w.print("#{d}", .{value.c});
        },
        .err => try w.print("error.{s}", .{view.string(value.text)}),
        .aggregate => {
            try writeValue(w, view, value.a, depth + 1);
            try w.writeAll("{");
            for (view.run(value.list), 0..) |element, position| {
                if (position != 0) try w.writeAll(", ");
                try writeValue(w, view, element, depth + 1);
            }
            try w.writeAll("}");
        },
        .slice => {
            try w.writeAll("slice ");
            try writeValue(w, view, value.c, depth + 1);
        },
        .optional => {
            try w.writeAll("some ");
            try writeValue(w, view, value.b, depth + 1);
        },
        else => try w.print("kind{d}", .{value.kind}),
    }
}
