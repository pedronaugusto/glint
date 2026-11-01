//! glint's soundness suite: each case in `<rule>/<row>/<case>/` run under its rule, std and
//! aegis real, every case its own program over one store that reads each file once. A
//! `hole.zig` must flag or be left undecided; a `twin.zig` must be clean. The row is a
//! `Constructs.Row`: how the case moves the value its rule judges. A case's `glint.json` is the
//! policy its rule reads (P006's disallowed declarations, A018's peer writers): its options
//! alone, since the case's rule is the one that runs.
//!
//! Each rule's directory is a column of the matrix, and its `expected.zon` the rule's own: the
//! cases glint does not pass yet (`open`, each a path under the rule's directory), the rows with
//! no hole or no twin yet (`no_hole`, `no_twin`), and the rows through which the rule's value
//! cannot move (`na`, each with its reason), which hold no case. Each list is exact: a case that
//! starts passing, or a cell that gains its hole or twin, fails the run until the list says so,
//! as a new failure does.
//!
//! Usage: soundness SUITE ZIG_LIB AEGIS_ROOT
const std = @import("std");
const glint = @import("glint");
const Row = glint.Constructs.Row;

/// A rule's `expected.zon`.
const Expected = struct {
    no_hole: []const Row = &.{},
    no_twin: []const Row = &.{},
    na: []const Row = &.{},
    open: []const []const u8 = &.{},
};

const Role = enum { hole, twin };
const Verdict = enum { flagged, undecided, clean };

/// A row's cases under one rule.
const Cell = struct { holes: usize = 0, twins: usize = 0 };

/// A rule's column: what its `expected.zon` says, what its cases hold, and how many fail.
const Column = struct {
    rule: []const u8,
    expected: Expected,
    cells: std.EnumArray(Row, Cell) = .initFill(.{}),
    failing: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 4) return error.Usage;
    const suite_path, const lib, const aegis = .{ args[1], args[2], args[3] };
    var suite = try std.Io.Dir.cwd().openDir(io, suite_path, .{ .iterate = true });
    defer suite.close(io);

    var store: glint.Project.Store = .init(init.gpa);
    defer store.deinit();
    var failures: std.Io.Writer.Allocating = .init(a);
    const w = &failures.writer;
    var columns: std.ArrayList(Column) = .empty;
    var cases: usize = 0;

    for (try sortedEntries(a, io, suite, ".", .directory)) |rule| {
        const column = try columns.addOne(a);
        column.* = .{ .rule = rule, .expected = try expectedOf(a, init.gpa, io, suite, rule) };
        var open: std.StringHashMapUnmanaged(void) = .empty;
        for (column.expected.open) |path| try open.put(a, path, {});
        var rule_dir = try suite.openDir(io, rule, .{ .iterate = true });
        defer rule_dir.close(io);
        for (try sortedEntries(a, io, rule_dir, ".", .directory)) |row_name| {
            const row = std.meta.stringToEnum(Row, row_name) orelse {
                try w.print("{s}/{s}/: no row of Constructs\n", .{ rule, row_name });
                continue;
            };
            if (row == .none) try w.print("{s}/none/: a case that moves no value\n", .{rule});
            for (try sortedEntries(a, io, rule_dir, row_name, .directory)) |case| {
                const case_path = try std.Io.Dir.path.join(a, &.{ row_name, case });
                const policy_path = try std.Io.Dir.path.join(a, &.{ case_path, "glint.json" });
                const policy: ?[]const u8 = if (rule_dir.access(io, policy_path, .{})) try std.Io.Dir.path.join(a, &.{ suite_path, rule, policy_path }) else |err| switch (err) {
                    error.FileNotFound => null,
                    else => return err,
                };
                var any = false;
                for ([_]Role{ .hole, .twin }) |role| {
                    const path = try std.fmt.allocPrint(a, "{s}/{t}.zig", .{ case_path, role });
                    rule_dir.access(io, path, .{}) catch |err| switch (err) {
                        error.FileNotFound => continue,
                        else => return err,
                    };
                    any = true;
                    cases += 1;
                    switch (role) {
                        .hole => column.cells.getPtr(row).holes += 1,
                        .twin => column.cells.getPtr(row).twins += 1,
                    }
                    const absolute = try std.Io.Dir.path.join(a, &.{ suite_path, rule, path });
                    const verdict = try judge(init.gpa, io, &store, rule, lib, aegis, policy, absolute);
                    const passes = switch (role) {
                        .hole => verdict != .clean,
                        .twin => verdict == .clean,
                    };
                    const listed = open.remove(path);
                    if (!passes) column.failing += 1;
                    if (passes and listed) try w.print("{s}/{s}: passes now; take it off {s}/expected.zon's open list\n", .{ rule, path, rule });
                    if (!passes and !listed) try w.print("{s}/{s}: {t}, where a {t} must be {s}\n", .{ rule, path, verdict, role, if (role == .hole) "flagged or undecided" else "clean" });
                }
                if (!any) try w.print("{s}/{s}/: no hole.zig or twin.zig\n", .{ rule, case_path });
            }
        }
        var left = open.keyIterator();
        while (left.next()) |path| try w.print("{s}/{s}: on {s}/expected.zon's open list, and no such case\n", .{ rule, path.*, rule });
    }

    // The matrix: per cell its holes and twins, `.` where it has neither.
    var out_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buffer);
    const o = &out.interface;
    try o.print("{s:<13}", .{"row"});
    for (columns.items) |column| try o.print(" {s:<5}", .{column.rule});
    try o.writeByte('\n');
    var empty: usize = 0;
    for (std.enums.values(Row)) |row| {
        if (row == .none) continue;
        try o.print("{s:<13}", .{@tagName(row)});
        for (columns.items) |column| {
            const counts = column.cells.get(row);
            const expected = column.expected;
            const na = std.mem.findScalar(Row, expected.na, row) != null;
            if (!na and counts.holes + counts.twins == 0) empty += 1;
            if (na and counts.holes + counts.twins == 0) try o.print(" {s:<5}", .{"-"}) else if (counts.holes + counts.twins == 0) try o.print(" {s:<5}", .{"."}) else {
                var text: [16]u8 = undefined;
                try o.print(" {s:<5}", .{try std.fmt.bufPrint(&text, "{d}+{d}", .{ counts.holes, counts.twins })});
            }
            // Each list of missing rows is exact; a row the rule's value cannot move through
            // holds no case and misses none.
            if (na) {
                if (counts.holes + counts.twins != 0) try w.print("{s}/{t}: a case in a row {s}/expected.zon names na\n", .{ column.rule, row, column.rule });
                continue;
            }
            const declared_hole = std.mem.findScalar(Row, expected.no_hole, row) != null;
            const declared_twin = std.mem.findScalar(Row, expected.no_twin, row) != null;
            if ((counts.holes == 0) != declared_hole) try w.print("{s}/{t}: {s}\n", .{ column.rule, row, if (declared_hole) "has a hole now; take it off no_hole" else "has no hole; name it in no_hole" });
            if ((counts.twins == 0) != declared_twin) try w.print("{s}/{t}: {s}\n", .{ column.rule, row, if (declared_twin) "has a twin now; take it off no_twin" else "has no twin; name it in no_twin" });
        }
        try o.writeByte('\n');
    }
    var failing: usize = 0;
    try o.writeAll("open:");
    for (columns.items) |column| {
        failing += column.failing;
        if (column.failing != 0) try o.print(" {s} {d}", .{ column.rule, column.failing });
    }
    try o.print("\n{d} cases, {d} open, {d} cells empty; a cell is holes+twins, . none yet, - none possible\n", .{ cases, failing, empty });
    try o.flush();
    if (failures.written().len != 0) {
        std.debug.print("{s}", .{failures.written()});
        std.process.exit(1);
    }
}

/// The `expected.zon` of `rule`'s directory.
fn expectedOf(a: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, suite: std.Io.Dir, rule: []const u8) !Expected {
    const path = try std.Io.Dir.path.join(a, &.{ rule, "expected.zon" });
    const source = try suite.readFileAllocOptions(io, path, a, .limited(1024 * 1024), .of(u8), 0);
    var diagnostics: std.zon.parse.Diagnostics = .{ .errors = &.{} };
    return std.zon.parse.fromSlice(Expected, .{ .gpa = gpa, .arena = a, .source = source, .diagnostics = &diagnostics }) catch |err| {
        std.debug.print("{f}\n", .{diagnostics.fmt(path)});
        return err;
    };
}
/// What glint says of the file at `path` under `rule` alone, with the case's policy if it has one.
fn judge(gpa: std.mem.Allocator, io: std.Io, store: *glint.Project.Store, rule: []const u8, lib: []const u8, aegis: []const u8, policy: ?[]const u8, path: []const u8) !Verdict {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const module = try std.fmt.allocPrint(a, "aegis={s}", .{aegis});
    var output: std.Io.Writer.Allocating = .init(a);
    var problems: std.Io.Writer.Allocating = .init(a);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "glint", "--only", rule, "--zig-lib-path", lib, "--module", module });
    if (policy) |config| try args.appendSlice(a, &.{ "--config", config });
    try args.append(a, path);
    _ = try glint.cli.executeStored(gpa, io, args.items, &output.writer, &problems.writer, store);
    var verdict: Verdict = .clean;
    var lines = std.mem.splitScalar(u8, output.written(), '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, rule) and std.mem.startsWith(u8, line[rule.len..], ": ")) return .flagged;
        // Every run notes that std's ZIR references are indexed in part; that decides nothing.
        if (std.mem.startsWith(u8, line, "coverage: ") and std.mem.find(u8, line, "std-ZIR declaration references") == null) verdict = .undecided;
    }
    return verdict;
}

/// The names of `sub`'s entries of `kind`, sorted.
fn sortedEntries(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub: []const u8, kind: std.Io.File.Kind) ![]const []const u8 {
    var opened = try dir.openDir(io, sub, .{ .iterate = true });
    defer opened.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var each = opened.iterate();
    while (try each.next(io)) |entry| {
        if (entry.kind == kind) try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}
