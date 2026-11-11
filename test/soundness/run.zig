//! glint's soundness suite: each case in `<rule>/<row>/<case>/` run under its rule, std and
//! aegis real, every case its own program. The cases are judged on a pool of workers, each with
//! its own store that reads each file once, and their verdicts read in case order, so a run's
//! output is the same at any number of workers. A
//! `hole.zig` must flag or be left undecided; a `twin.zig` must be clean. Undecided is any
//! coverage glint writes of the case (std's note that its ZIR references are indexed in part
//! aside, unless the budget cut it), a malformed suppression, or a run glint says is incomplete
//! for nothing it wrote. The row is a
//! `Constructs.Row`: how the case moves the value its rule judges. A case's `glint.json` is the
//! policy its rule reads (P006's disallowed declarations, A018's peer writers): its options
//! alone, since the case's rule is the one that runs. A case's `before.zig` is a file the run
//! selects ahead of the case's, as a program's other file: what the case's file reads after it
//! (a run-wide answer, the budget left) is the case. What glint says of `before.zig` itself is
//! not read.
//!
//! Each rule's directory is a column of the matrix, and its `expected.zon` the rule's own: the
//! cases glint does not pass yet (`open`, each a path under the rule's directory), the rows with
//! no hole or no twin yet (`no_hole`, `no_twin`), and the rows through which the rule's value
//! cannot move (`na`, each with its reason), which hold no case. Each list is exact: a case that
//! starts passing, or a cell that gains its hole or twin, fails the run until the list says so,
//! as a new failure does.
//!
//! Every case is a program Zig compiles: the Zig that runs the suite compiles each selected
//! case's files (`hole.zig`, `twin.zig`, `before.zig`) first, each its own module with aegis and
//! every public declaration referenced, and a case it refuses fails the run at its path, or is
//! open where its rule's `open` list names it (a refused case never passes). A case's
//! `stubs/<name>.zig` is a module named `<name>` the compiler is given and glint is not: a module
//! a program has that glint is not handed. A case's `module/module.zig` is a module named
//! `module` both are given, the files of `module/` selected: a package's published code, the case
//! a package of its own where a `build.zig.zon` stands beside it. A case's files share what is beside them (a `dep.zig` its hole and twin import), which a file
//! of one compilation may belong to one module alone, so each kind of file is a compilation of
//! its own; Zig's cache (`.zig-cache` in the run's directory, the package root) keeps what has
//! not changed.
//!
//! Usage: soundness SUITE ZIG ZIG_LIB AEGIS_ROOT JOBS [RULES]: ZIG the compiler; JOBS the
//! workers (0, one per CPU); RULES the rules whose cases alone run, by comma (none, every
//! rule's).
const std = @import("std");
const builtin = @import("builtin");
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

/// A case to judge, and what its verdict is read against.
const Job = struct {
    column: usize,
    path: []const u8,
    role: Role,
    listed: bool,
    policy: ?[]const u8,
    before: ?[]const u8,
    absolute: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 6 and args.len != 7) return error.Usage;
    const suite_path, const lib, const aegis = .{ args[1], args[3], args[4] };
    const tools: Tools = .{ .zig = args[2], .lib = lib, .aegis = aegis, .cache = ".zig-cache" };
    const jobs_asked = try std.fmt.parseInt(usize, args[5], 10);
    var selected: std.ArrayList([]const u8) = .empty;
    if (args.len == 7) {
        var each = std.mem.tokenizeScalar(u8, args[6], ',');
        while (each.next()) |rule| try selected.append(a, rule);
    }
    var suite = try std.Io.Dir.cwd().openDir(io, suite_path, .{ .iterate = true });
    defer suite.close(io);

    var failures: std.Io.Writer.Allocating = .init(a);
    const w = &failures.writer;
    var columns: std.ArrayList(Column) = .empty;
    var jobs: std.ArrayList(Job) = .empty;

    const rules = try sortedEntries(a, io, suite, ".", .directory);
    for (selected.items) |rule| if (!contains(rules, rule)) try w.print("{s}: no such rule's cases\n", .{rule});
    for (rules) |rule| {
        if (selected.items.len != 0 and !contains(selected.items, rule)) continue;
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
                const policy = try caseFile(a, io, rule_dir, suite_path, rule, case_path, "glint.json");
                const before = try caseFile(a, io, rule_dir, suite_path, rule, case_path, "before.zig");
                var any = false;
                for ([_]Role{ .hole, .twin }) |role| {
                    const path = try std.fmt.allocPrint(a, "{s}/{t}.zig", .{ case_path, role });
                    rule_dir.access(io, path, .{}) catch |err| switch (err) {
                        error.FileNotFound => continue,
                        else => return err,
                    };
                    any = true;
                    switch (role) {
                        .hole => column.cells.getPtr(row).holes += 1,
                        .twin => column.cells.getPtr(row).twins += 1,
                    }
                    try jobs.append(a, .{
                        .column = columns.items.len - 1,
                        .path = path,
                        .role = role,
                        .listed = open.remove(path),
                        .policy = policy,
                        .before = before,
                        .absolute = try std.Io.Dir.path.join(a, &.{ suite_path, rule, path }),
                    });
                }
                if (!any) try w.print("{s}/{s}/: no hole.zig or twin.zig\n", .{ rule, case_path });
            }
        }
        var left = open.keyIterator();
        while (left.next()) |path| try w.print("{s}/{s}: on {s}/expected.zon's open list, and no such case\n", .{ rule, path.*, rule });
    }

    // The case files Zig refuses, by their path.
    var refusals: std.StringHashMapUnmanaged(void) = .empty;
    try compiled(a, init.gpa, io, tools, suite_path, columns.items, jobs.items, &refusals, w);

    const verdicts = try a.alloc(anyerror!Verdict, jobs.items.len);
    var pool: Pool = .{ .jobs = jobs.items, .columns = columns.items, .verdicts = verdicts, .lib = lib, .aegis = aegis };
    const workers = @min(if (jobs_asked != 0) jobs_asked else std.Thread.getCpuCount() catch 1, @max(jobs.items.len, 1));
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..workers) |_| try group.concurrent(io, Pool.work, .{ &pool, init.gpa, io });
    try group.await(io);
    if (peakResident()) |peak| {
        const ceiling = held_ceiling + workers * worker_ceiling;
        if (peak > ceiling) try w.print("the suite's peak resident memory is {d} MiB at {d} workers, past its ceiling of {d} MiB: a run keeps memory it should give back\n", .{ peak >> 20, workers, ceiling >> 20 });
    }
    for (jobs.items, verdicts) |job, result| {
        const verdict = try result;
        const column = &columns.items[job.column];
        // A case Zig refuses is no program, so it passes nothing; it was named where refused.
        const compiles = !refusals.contains(job.absolute) and !(if (job.before) |before| refusals.contains(before) else false);
        const passes = compiles and switch (job.role) {
            .hole => verdict != .clean,
            .twin => verdict == .clean,
        };
        if (!passes) column.failing += 1;
        if (passes and job.listed) try w.print("{s}/{s}: passes now; take it off {s}/expected.zon's open list\n", .{ column.rule, job.path, column.rule });
        if (!passes and !job.listed and compiles) try w.print("{s}/{s}: {t}, where a {t} must be {s}\n", .{ column.rule, job.path, verdict, job.role, if (job.role == .hole) "flagged or undecided" else "clean" });
    }

    // The matrix: per cell its holes and twins, `.` where it has neither. Streaming, not
    // positional: a stdout that is a file the build's other output goes to (a gate's log) is
    // written on from where it stands, where a positional writer writes from offset 0, over
    // what is there, a failing step's message among it.
    var out_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);
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
    try o.print("\n{d} cases, {d} open, {d} cells empty; a cell is holes+twins, . none yet, - none possible\n", .{ jobs.items.len, failing, empty });
    try o.flush();
    if (failures.written().len != 0) {
        std.debug.print("{s}", .{failures.written()});
        std.process.exit(1);
    }
}

/// The most memory one worker holds at its peak (its store, and the run of the case it judges),
/// and the most the suite holds beside its workers. A suite past them fails: a run that keeps
/// memory it should give back (each reading of a loop's scratch kept to the run's end, 11-03,
/// which took the suite past 32 GiB at one worker per CPU) fails here instead of exhausting the
/// machine that runs it. Measured on aarch64-macos, ReleaseSafe (11-03): 2970 MiB at 4 workers,
/// 11547 MiB at 16, so about 715 MiB a worker and 110 MiB beside them; the ceilings keep two
/// fifths more a worker.
const worker_ceiling: usize = 1024 << 20;
const held_ceiling: usize = 512 << 20;

/// This process's peak resident memory in bytes, null where its system does not say.
fn peakResident() ?usize {
    const usage = switch (builtin.os.tag) {
        .linux, .dragonfly, .freebsd, .netbsd, .openbsd, .illumos, .serenity, .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => std.posix.getrusage(std.posix.rusage.SELF),
        else => return null,
    };
    const peak: usize = @intCast(usage.maxrss);
    // Darwin's is in bytes, the others' in KiB.
    return if (builtin.os.tag.isDarwin()) peak else peak * 1024;
}

/// The Zig that compiles the cases, what it compiles them with, and the cache its compilations
/// keep (and their scratch in).
const Tools = struct { zig: []const u8, lib: []const u8, aegis: []const u8, cache: []const u8 };

/// A file of a case, as the run names it (`<rule>/<row>/<case>/<file>`) and opens it, and
/// whether its rule's `open` list names it.
const CaseFile = struct { name: []const u8, absolute: []const u8, listed: bool = false };

/// The kinds of a case's files, each compiled apart.
const kinds = [_][]const u8{ "hole.zig", "twin.zig", "before.zig" };

/// One kind's compilation, run beside the others on its own arena.
const Compilation = struct {
    kind: []const u8,
    files: std.ArrayList(CaseFile) = .empty,
    arena: std.heap.ArenaAllocator,
    result: anyerror!std.process.RunResult = error.NotRun,

    fn run(c: *Compilation, io: std.Io, tools: Tools) void {
        c.result = compile(c.arena.allocator(), io, tools, c.kind, c.files.items);
    }
};

/// Whether every selected case's files compile: a case one does not fails the run, named with
/// the compiler's first error about it.
fn compiled(a: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, tools: Tools, suite_path: []const u8, columns: []const Column, jobs: []const Job, refusals: *std.StringHashMapUnmanaged(void), w: *std.Io.Writer) !void {
    var compilations: [kinds.len]Compilation = undefined;
    for (&compilations, kinds) |*c, kind| c.* = .{ .kind = kind, .arena = .init(gpa) };
    defer for (&compilations) |*c| c.arena.deinit();
    var befores: std.StringHashMapUnmanaged(void) = .empty;
    for (jobs) |job| {
        const rule = columns[job.column].rule;
        try compilations[@backingInt(job.role)].files.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}/{s}", .{ rule, job.path }), .absolute = job.absolute, .listed = job.listed });
        const before = job.before orelse continue;
        if ((try befores.getOrPut(a, before)).found_existing) continue;
        const case = std.Io.Dir.path.dirname(job.path) orelse ".";
        try compilations[2].files.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}/{s}/before.zig", .{ rule, case }), .absolute = before });
    }
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (&compilations) |*c| if (c.files.items.len != 0) try group.concurrent(io, Compilation.run, .{ c, io, tools });
    try group.await(io);
    for (&compilations) |*c| {
        if (c.files.items.len == 0) continue;
        const result = try c.result;
        const failed = switch (result.term) {
            .exited => |code| code != 0,
            else => true,
        };
        if (failed) try refused(a, w, std.Io.Dir.path.basename(suite_path), c.kind, c.files.items, result.stderr, refusals);
    }
}

/// One compilation of `files`, every one of them `kind`: a root whose comptime blocks reference
/// each file's public declarations, each file its own module with aegis, libc linked for the
/// cases that call it. It compiles for the target the cases are written for (macOS on arm64,
/// whose libc some of them call), whatever runner the suite runs on, so every runner reads the
/// same cases the same way. Nothing is emitted; the arguments go in a response file, as they
/// are many.
fn compile(a: std.mem.Allocator, io: std.Io, tools: Tools, kind: []const u8, files: []const CaseFile) !std.process.RunResult {
    var random: [8]u8 = undefined;
    io.random(&random);
    const scratch = try std.Io.Dir.path.join(a, &.{ tools.cache, "tmp", try std.fmt.allocPrint(a, "soundness-{s}-{s}", .{ std.Io.Dir.path.stem(kind), &std.fmt.bytesToHex(&random, .lower) }) });
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, scratch);
    defer cwd.deleteTree(io, scratch) catch {}; // The scratch is the run's own; one left behind is litter, not a verdict.
    var root: std.Io.Writer.Allocating = .init(a);
    try root.writer.writeAll("const std = @import(\"std\");\n");
    var arguments: std.ArrayList([]const u8) = .empty;
    try arguments.appendSlice(a, &.{ "-fno-emit-bin", "-target", "aarch64-macos", "-lc", "--name", try std.fmt.allocPrint(a, "soundness-{s}", .{std.Io.Dir.path.stem(kind)}), "--zig-lib-dir", tools.lib, "--cache-dir", tools.cache });
    for (files, 0..) |_, index| try arguments.appendSlice(a, &.{ "--dep", try std.fmt.allocPrint(a, "case{d}", .{index}) });
    const root_path = try std.Io.Dir.path.join(a, &.{ scratch, "cases.zig" });
    try arguments.append(a, try std.fmt.allocPrint(a, "-Mroot={s}", .{root_path}));
    var stubs: std.ArrayList([]const u8) = .empty;
    for (files, 0..) |file, index| {
        // The case's stubs: each a module of its own, named for the case's import.
        const case = std.Io.Dir.path.dirname(file.absolute) orelse ".";
        for (try stubsOf(a, io, case)) |stub| {
            try arguments.appendSlice(a, &.{ "--dep", try std.fmt.allocPrint(a, "{s}=stub{d}", .{ std.Io.Dir.path.stem(stub), stubs.items.len }) });
            try stubs.append(a, stub);
        }
        // Each file's references in a comptime block of its own, with the quota a file of many
        // declarations takes.
        try root.writer.print("comptime {{\n    @setEvalBranchQuota(100_000);\n    for (std.meta.declarations(@import(\"case{d}\"))) |name| _ = &@field(@import(\"case{d}\"), name);\n}}\n", .{ index, index });
        try arguments.appendSlice(a, &.{ "--dep", "aegis", try std.fmt.allocPrint(a, "-Mcase{d}={s}", .{ index, file.absolute }) });
    }
    for (stubs.items, 0..) |stub, index| try arguments.appendSlice(a, &.{ "--dep", "aegis", try std.fmt.allocPrint(a, "-Mstub{d}={s}", .{ index, stub }) });
    try arguments.append(a, try std.fmt.allocPrint(a, "-Maegis={s}", .{tools.aegis}));
    try cwd.writeFile(io, .{ .sub_path = root_path, .data = root.written() });
    var response: std.Io.Writer.Allocating = .init(a);
    for (arguments.items, 0..) |argument, index| {
        if (index != 0) try response.writer.writeByte(' ');
        try response.writer.writeByte('"');
        for (argument) |byte| {
            if (byte == '\\' or byte == '"') try response.writer.writeByte('\\');
            try response.writer.writeByte(byte);
        }
        try response.writer.writeByte('"');
    }
    const response_path = try std.Io.Dir.path.join(a, &.{ scratch, "args" });
    try cwd.writeFile(io, .{ .sub_path = response_path, .data = response.written() });
    return std.process.run(a, io, .{
        .argv = &.{ tools.zig, "build-obj", try std.fmt.allocPrint(a, "@{s}", .{response_path}) },
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024 * 1024),
    });
}

/// The `.zig` files of `case`'s `stubs` directory, sorted; none where it has none.
fn stubsOf(a: std.mem.Allocator, io: std.Io, case: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(a, try zigFiles(a, io, try std.Io.Dir.path.join(a, &.{ case, "stubs" })));
    for (try moduleFiles(a, io, case)) |file| if (std.mem.eql(u8, std.Io.Dir.path.basename(file), "module.zig")) try out.append(a, file);
    return out.items;
}

/// The files of a case's own module, `module/`: none where it has none.
fn moduleFiles(a: std.mem.Allocator, io: std.Io, case: []const u8) ![]const []const u8 {
    return zigFiles(a, io, try std.Io.Dir.path.join(a, &.{ case, "module" }));
}

/// The `.zig` files directly in `path`, sorted: none where there is no such directory.
fn zigFiles(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const []const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var out: std.ArrayList([]const u8) = .empty;
    var each = dir.iterate();
    while (try each.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) try out.append(a, try std.Io.Dir.path.join(a, &.{ path, entry.name }));
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

/// The cases a failed compilation refused, into `refusals`: each error's case is the first case
/// file its lines name (its own place, or where an error in std or aegis is called from), named
/// once with its first error unless its rule's `open` list names it. An error that names no case
/// is written as the compiler gave it.
fn refused(a: std.mem.Allocator, w: *std.Io.Writer, suite_name: []const u8, kind: []const u8, files: []const CaseFile, stderr: []const u8, refusals: *std.StringHashMapUnmanaged(void)) !void {
    // A case's directory under the suite (`<rule>/<row>/<case>`), to the file of this kind.
    var by_case: std.StringHashMapUnmanaged(usize) = .empty;
    for (files, 0..) |file, index| try by_case.put(a, std.Io.Dir.path.dirname(file.name) orelse file.name, index);
    const named = try a.alloc(bool, files.len);
    @memset(named, false);
    var any = false;
    var blocks = Blocks{ .lines = std.mem.splitScalar(u8, stderr, '\n') };
    while (blocks.next()) |block| {
        any = true;
        const message = block.first;
        var case: ?usize = null;
        for (block.lines) |line| {
            case = caseIn(line, suite_name, &by_case) orelse continue;
            break;
        }
        if (case) |index| {
            if (named[index]) continue;
            named[index] = true;
            try refusals.put(a, files[index].absolute, {});
            if (!files[index].listed) try w.print("{s}: does not compile on the pinned Zig: {s}\n", .{ files[index].name, message });
        } else try w.print("soundness: compiling the cases' {s}: {s}\n", .{ kind, message });
    }
    if (!any) try w.print("soundness: compiling the cases' {s} failed: {s}\n", .{ kind, stderr });
}

/// The compiler's errors, each its first line and every line up to the next.
const Blocks = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    held: ?[]const u8 = null,
    buffer: [256][]const u8 = undefined,

    const Block = struct { first: []const u8, lines: []const []const u8 };

    fn next(blocks: *Blocks) ?Block {
        const first = blocks.held orelse while (blocks.lines.next()) |line| {
            if (isError(line)) break line;
        } else return null;
        blocks.held = null;
        var count: usize = 0;
        blocks.buffer[count] = first;
        count += 1;
        while (blocks.lines.next()) |line| {
            if (isError(line)) {
                blocks.held = line;
                break;
            }
            if (count < blocks.buffer.len) {
                blocks.buffer[count] = line;
                count += 1;
            }
        }
        return .{ .first = first, .lines = blocks.buffer[0..count] };
    }
};

/// Whether `line` opens an error at a place (`<path>:<line>:<column>: error: ...`); the count
/// of errors the compiler ends with names none.
fn isError(line: []const u8) bool {
    return !std.mem.startsWith(u8, line, "error: ") and std.mem.find(u8, line, ": error: ") != null;
}

/// The case a line names, by the first path in it under the suite (`<suite>/<rule>/<row>/<case>/`).
fn caseIn(line: []const u8, suite_name: []const u8, by_case: *const std.StringHashMapUnmanaged(usize)) ?usize {
    var rest = line;
    while (std.mem.find(u8, rest, suite_name)) |at| {
        const after = rest[at + suite_name.len ..];
        rest = after;
        if (after.len == 0 or after[0] != '/') continue;
        var parts = std.mem.splitScalar(u8, after[1..], '/');
        var length: usize = 0;
        for (0..3) |_| {
            const part = parts.next() orelse break;
            length += part.len + 1;
        } else if (by_case.get(after[1..length])) |index| return index;
    }
    return null;
}

/// The cases a run judges, shared by its workers: each takes the next case not yet taken and
/// judges it over its own store, the verdict going to the case's slot.
const Pool = struct {
    jobs: []const Job,
    columns: []const Column,
    verdicts: []anyerror!Verdict,
    lib: []const u8,
    aegis: []const u8,
    next: std.atomic.Value(usize) = .init(0),

    fn work(pool: *Pool, gpa: std.mem.Allocator, io: std.Io) void {
        var store: glint.Project.Store = .init(gpa);
        defer store.deinit();
        while (true) {
            const index = pool.next.fetchAdd(1, .monotonic);
            if (index >= pool.jobs.len) return;
            const job = pool.jobs[index];
            pool.verdicts[index] = judge(gpa, io, &store, pool.columns[job.column].rule, pool.lib, pool.aegis, job);
        }
    }
};

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
/// The path of the case's file `name`, as the run opens it; null where the case has none.
fn caseFile(a: std.mem.Allocator, io: std.Io, rule_dir: std.Io.Dir, suite_path: []const u8, rule: []const u8, case_path: []const u8, name: []const u8) !?[]const u8 {
    const path = try std.Io.Dir.path.join(a, &.{ case_path, name });
    rule_dir.access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try std.Io.Dir.path.join(a, &.{ suite_path, rule, path });
}

/// What glint says of the case's file under `rule` alone, with the case's policy if it has one,
/// after its `before.zig` if it has one, whose own findings and coverage are not read.
fn judge(gpa: std.mem.Allocator, io: std.Io, store: *glint.Project.Store, rule: []const u8, lib: []const u8, aegis: []const u8, job: Job) !Verdict {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const module = try std.fmt.allocPrint(a, "aegis={s}", .{aegis});
    var output: std.Io.Writer.Allocating = .init(a);
    var problems: std.Io.Writer.Allocating = .init(a);
    var args: std.ArrayList([]const u8) = .empty;
    // Every case's records are read back as they were built (summaries' cross-check).
    try args.appendSlice(a, &.{ "glint", "--only", rule, "--zig-lib-path", lib, "--module", module, "--summary-check" });
    if (job.policy) |config| try args.appendSlice(a, &.{ "--config", config });
    if (job.before) |before| try args.append(a, before);
    const own = try moduleFiles(a, io, std.Io.Dir.path.dirname(job.absolute) orelse ".");
    for (own) |file| if (std.mem.eql(u8, std.Io.Dir.path.basename(file), "module.zig")) try args.appendSlice(a, &.{ "--module", try std.fmt.allocPrint(a, "module={s}", .{file}) });
    try args.appendSlice(a, own);
    try args.append(a, job.absolute);
    // A suppression that would cover two findings stops the run, which glint's command line
    // ends as an incomplete one (status 2, `main`): the case is read as that run is.
    const status = glint.cli.executeStored(gpa, io, args.items, &output.writer, &problems.writer, store) catch |err| switch (err) {
        error.AmbiguousSuppression => 2,
        else => |e| return e,
    };
    return verdictOf(output.written(), status, rule, job.before);
}

/// What a run's text output and exit status say of the case: flagged where `rule` finds
/// anything outside `before`; else undecided where glint writes coverage of any file but
/// `before` (`--only` runs its rule at report level, where its coverage leaves the run
/// complete), a malformed suppression, or, without `before`, says the run is incomplete
/// (status 2); else clean.
fn verdictOf(output: []const u8, status: u8, rule: []const u8, before: ?[]const u8) Verdict {
    var verdict: Verdict = .clean;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (before) |path| if (about(line, rule, path) or about(line, "coverage", path) or about(line, "suppression", path)) continue;
        if (std.mem.startsWith(u8, line, rule) and std.mem.startsWith(u8, line[rule.len..], ": ")) return .flagged;
        if ((std.mem.startsWith(u8, line, "coverage: ") or std.mem.startsWith(u8, line, "suppression: ")) and !note(line)) verdict = .undecided;
    }
    // An incomplete run no line explains is the case's, where no `before` is there to be it.
    if (verdict == .clean and status == 2 and before == null) return .undecided;
    return verdict;
}

/// Whether `line` is a note that decides nothing: std's ZIR references indexed in part, which
/// every parsed file gets (its budget cut short is no note), or a suppression that suppresses
/// nothing.
fn note(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "suppression: ")) return std.mem.endsWith(u8, line, " suppresses nothing");
    return std.mem.find(u8, line, ": unsupported: std-ZIR declaration references ") != null;
}

test "a case's verdict: any coverage of its files is undecided, std's note alone is not" {
    const zir = "coverage: /s/case.zig: unsupported: std-ZIR declaration references are indexed only through supported structured bodies; lexical references are indexed separately\n";
    const exhausted = "coverage: /s/case.zig: budget_exhausted: std-ZIR declaration references are indexed only through supported structured bodies; lexical references are indexed separately\n";
    try std.testing.expectEqual(Verdict.clean, verdictOf(zir, 0, "A009", null));
    try std.testing.expectEqual(Verdict.undecided, verdictOf(exhausted, 2, "A009", null));
    try std.testing.expectEqual(Verdict.undecided, verdictOf("suppression: /s/case.zig:1:1: malformed: an aegis escape names the rules it covers\n", 2, "A009", null));
    try std.testing.expectEqual(Verdict.clean, verdictOf("suppression: /s/case.zig:1:1: A009 suppresses nothing\n", 0, "A009", null));
    // A rule at report level leaves the run complete with its coverage: still undecided.
    try std.testing.expectEqual(Verdict.undecided, verdictOf("coverage: /s/case.zig: unsupported: cleanup/error exits require unsupported flow facts; no leak claimed\n" ++ zir, 0, "A003", null));
    try std.testing.expectEqual(Verdict.undecided, verdictOf(zir, 2, "A009", null));
    try std.testing.expectEqual(Verdict.flagged, verdictOf("A009: /s/case.zig:3:5: input used\ncoverage: /s/case.zig: unresolved: x\n", 2, "A009", null));
}
test "what a run says of before.zig alone is not the case's" {
    const before = "/s/before.zig";
    const zir = "coverage: /s/case.zig: unsupported: std-ZIR declaration references are indexed only through supported structured bodies; lexical references are indexed separately\n";
    try std.testing.expectEqual(Verdict.clean, verdictOf("A009: /s/before.zig:1:1: input used\ncoverage: /s/before.zig: budget_exhausted: semantic fact budget exhausted\n" ++ zir, 2, "A009", before));
    try std.testing.expectEqual(Verdict.undecided, verdictOf("coverage: /s/before.zig: budget_exhausted: x\ncoverage: /s/case.zig: budget_exhausted: semantic fact budget exhausted\n", 2, "A009", before));
    try std.testing.expectEqual(Verdict.flagged, verdictOf("A009: /s/before.zig:1:1: input used\nA009: /s/case.zig:2:1: input used\n", 1, "A009", before));
}

test "a compile error is the case's whose file it names first, at it or calling into std or aegis; an open case's is not written" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]CaseFile{
        .{ .name = "A007/assignment/held/twin.zig", .absolute = "/s/soundness/A007/assignment/held/twin.zig", .listed = true },
        .{ .name = "A009/call/shadow/twin.zig", .absolute = "/s/soundness/A009/call/shadow/twin.zig" },
        .{ .name = "A010/call/fine/twin.zig", .absolute = "/s/soundness/A010/call/fine/twin.zig" },
    };
    const stderr =
        \\/s/soundness/A009/call/shadow/twin.zig:3:8: error: function parameter shadows declaration of 'f'
        \\pub fn f(f: u8) void {
        \\aegis/src/Atomic.zig:9:17: error: an atomic cell holds an enum
        \\aegis/src/Atomic.zig:44:25: note: called at comptime here
        \\test/soundness/A007/assignment/held/twin.zig:3:23: note: called at comptime here
        \\aegis/src/Atomic.zig:9:17: error: an atomic cell holds an enum
        \\test/soundness/A007/assignment/held/twin.zig:7:23: note: called at comptime here
        \\lib/std/meta.zig:248:20: error: deprecated in favor of @typeInfo
        \\error: 4 compilation errors
        \\
    ;
    var out: std.Io.Writer.Allocating = .init(a);
    var refusals: std.StringHashMapUnmanaged(void) = .empty;
    try refused(a, &out.writer, "soundness", "twin.zig", &files, stderr, &refusals);
    try std.testing.expectEqualStrings(
        \\A009/call/shadow/twin.zig: does not compile on the pinned Zig: /s/soundness/A009/call/shadow/twin.zig:3:8: error: function parameter shadows declaration of 'f'
        \\soundness: compiling the cases' twin.zig: lib/std/meta.zig:248:20: error: deprecated in favor of @typeInfo
        \\
    , out.written());
    // Both refused cases are refused, the open one too; the one the errors do not name is not.
    try std.testing.expect(refusals.contains(files[0].absolute) and refusals.contains(files[1].absolute) and !refusals.contains(files[2].absolute));
    // Output that names no error is the compilation's failure as a whole.
    out.clearRetainingCapacity();
    try refused(a, &out.writer, "soundness", "twin.zig", &files, "killed\n", &refusals);
    try std.testing.expectEqualStrings("soundness: compiling the cases' twin.zig failed: killed\n\n", out.written());
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

/// Whether `line` is `<kind>: <path>:...`, a finding or coverage line of the file at `path`.
fn about(line: []const u8, kind: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, line, kind) or !std.mem.startsWith(u8, line[kind.len..], ": ")) return false;
    const rest = line[kind.len + 2 ..];
    return std.mem.startsWith(u8, rest, path) and std.mem.startsWith(u8, rest[path.len..], ":");
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |each| if (std.mem.eql(u8, each, name)) return true;
    return false;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}
