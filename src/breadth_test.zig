//! The breadth rules (glint 0.8): twenty-five hygiene rules and opt-in bans, each in its own file, that
//! read the syntax and the type a declaration writes, and report only what is certain. Registered as
//! built-in rules (`Rule.zig`, run from `Builtins.check`); their unit tests run each one alone, as a
//! project rule of the id below, which the measuring tool also uses.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const Report = @import("Report.zig");
const rules = @import("Rule.zig");

pub const SameOperands = @import("SameOperands.zig");
pub const RepeatedCondition = @import("RepeatedCondition.zig");
pub const NarrowWidened = @import("NarrowWidened.zig");
pub const LargeStackArray = @import("LargeStackArray.zig");
pub const FixedComparison = @import("FixedComparison.zig");
pub const ExpectComparison = @import("ExpectComparison.zig");
pub const DiscardedCount = @import("DiscardedCount.zig");
pub const ExpectEqualOrder = @import("ExpectEqualOrder.zig");
pub const NeverLoops = @import("NeverLoops.zig");
pub const SelfRecursion = @import("SelfRecursion.zig");
pub const DocComment = @import("DocComment.zig");
pub const FieldNaming = @import("FieldNaming.zig");
pub const UnwrapTrap = @import("UnwrapTrap.zig");
pub const UndefinedReason = @import("UndefinedReason.zig");
pub const LeftoverDebugging = @import("LeftoverDebugging.zig");
pub const ConstantCondition = @import("ConstantCondition.zig");
pub const InexactFloat = @import("InexactFloat.zig");
pub const NanComparison = @import("NanComparison.zig");
pub const NarrowCounter = @import("NarrowCounter.zig");
pub const UndefinedConst = @import("UndefinedConst.zig");
pub const DeadErrdefer = @import("DeadErrdefer.zig");
pub const BuildOption = @import("BuildOption.zig");
pub const PublicAnytype = @import("PublicAnytype.zig");
pub const FunctionShape = @import("FunctionShape.zig");
pub const EmptyBranch = @import("EmptyBranch.zig");

/// A rule's check, as each breadth rule exports it.
pub const Check = fn (*Context, Rule) Context.Error!void;

/// The id the breadth rules run under as project rules, in tests and measurements.
pub const test_id: Rule = @fromBackingInt(2001); // safe: an extension id this file owns, validated by glint.

/// The breadth rule `check` as a project rule under `test_id`.
pub fn projectRule(comptime check: Check) Context.Rule {
    const wrapped = struct {
        fn run(c: *Context) Context.Error!void {
            return check(c, test_id);
        }
    };
    return .{ .definition = .{ .id = test_id, .name = "BREADTH", .group = .zig_style, .purpose = "breadth hygiene rule under test" }, .check = wrapped.run };
}

/// A small std the breadth rules' tests resolve `@import("std")` to: what they read of it.
pub const fixture_std =
    \\pub const testing = struct {
    \\    pub fn expect(ok: bool) !void { if (!ok) return error.TestUnexpectedResult; }
    \\    pub fn expectEqual(expected: anytype, actual: anytype) !void { _ = expected; _ = actual; }
    \\};
    \\pub const math = struct {
    \\    pub inline fn nan(comptime T: type) T { return 0; }
    \\    pub fn isNan(x: anytype) bool { return x != x; }
    \\};
    \\pub const Build = struct {
    \\    pub const Module = struct { pub const CreateOptions = struct { target: ?u8 = null, optimize: ?enum { Debug, ReleaseSafe, ReleaseFast, ReleaseSmall } = null }; };
    \\    pub fn standardOptimizeOption(b: *Build, options: struct {}) @FieldType(Module.CreateOptions, "optimize") { _ = b; _ = options; return null; }
    \\    pub fn standardTargetOptions(b: *Build, options: struct {}) u8 { _ = b; _ = options; return 0; }
    \\    pub fn resolveTargetQuery(b: *Build, query: struct {}) u8 { _ = b; _ = query; return 0; }
    \\    pub fn createModule(b: *Build, options: Module.CreateOptions) *Module { _ = b; _ = options; return undefined; }
    \\    pub fn addModule(b: *Build, name: []const u8, options: Module.CreateOptions) *Module { _ = b; _ = name; _ = options; return undefined; }
    \\};
    \\pub const posix = struct {
    \\    pub fn read(fd: i32, buf: []u8) !usize { _ = fd; return buf.len; }
    \\};
    \\pub const Io = struct {
    \\    pub const Writer = struct {
    \\        end: usize = 0,
    \\        pub fn write(w: *Writer, bytes: []const u8) !usize { _ = w; return bytes.len; }
    \\        pub fn writeAll(w: *Writer, bytes: []const u8) !void { _ = w; _ = bytes; }
    \\    };
    \\    pub const Reader = struct {
    \\        seek: usize = 0,
    \\        pub fn readSliceShort(r: *Reader, buffer: []u8) !usize { _ = r; return buffer.len; }
    \\        pub fn readSliceAll(r: *Reader, buffer: []u8) !void { _ = r; _ = buffer; }
    \\    };
    \\};
;

/// What a run of one breadth rule over one file found (`run`): its findings' messages and any
/// run error it raised.
pub const Found = struct {
    messages: std.ArrayList([]const u8) = .empty,
    refused: usize = 0,
    fixes: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Found, gpa: std.mem.Allocator) void {
        for (self.messages.items) |m| gpa.free(m);
        for (self.fixes.items) |f| gpa.free(f);
        self.messages.deinit(gpa);
        self.fixes.deinit(gpa);
    }
};

/// Runs `check` over the first file of `project` under `test_id`, as the runner runs a project
/// rule: its own Facts, the file's context, a sink that keeps each finding's message.
pub fn run(gpa: std.mem.Allocator, project: *const Project, file: Project.FileId, comptime check: Check) !Found {
    return runWith(gpa, project, file, check, .none());
}

/// As `run`, under `base`'s options (its limits) with the rule selected.
pub fn runWith(gpa: std.mem.Allocator, project: *const Project, file: Project.FileId, comptime check: Check, base: rules.Config) !Found {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var facts: Facts = .{ .project = project, .gpa = a, .backing = gpa };
    defer facts.deinit();
    var sink: Context.Sink = .{ .diagnostic = Collect.diagnostic, .refuse = Collect.refuse, .config = Collect.configOf };
    var collector: Collect = .{ .gpa = gpa, .config = selected(base) };
    const before = collecting;
    collecting = &collector;
    defer collecting = before;
    const definitions = [_]rules.Definition{projectRule(check).definition};
    var context: Context = .{ .allocator = a, .backing = gpa, .project = project, .file = file, .config = collector.config, .facts = &facts, .definitions = &definitions, .sink = &sink };
    try check(&context, test_id);
    return collector.found;
}

/// The collector the sink of the run in progress on this thread hands each finding to: a sink's
/// callbacks are given the sink alone.
threadlocal var collecting: ?*Collect = null;

const Collect = struct {
    found: Found = .{},
    gpa: std.mem.Allocator,
    config: rules.Config,

    fn diagnostic(_: *Context.Sink, _: Rule, _: u32, _: u32, message: []const u8, _: []const Report.Span, fix: []const Report.Edit) Context.Error!void {
        const self = collecting orelse return;
        try self.found.messages.append(self.gpa, try self.gpa.dupe(u8, message));
        for (fix) |edit| try self.found.fixes.append(self.gpa, try self.gpa.dupe(u8, edit.text));
    }
    fn refuse(_: *Context.Sink, _: []const u8) Context.Error!void {
        const self = collecting orelse return;
        self.found.refused += 1;
    }
    fn configOf(_: *Context.Sink, _: Project.FileId) rules.Config {
        const self = collecting orelse return selected(.none());
        return self.config;
    }
};

fn selected(base: rules.Config) rules.Config {
    var config = base;
    config.selections = &.{.{ .rule = test_id, .level = .report }};
    return config;
}

/// Runs `check` over `source` (with `fixture_std` as std) and expects `expected` findings and
/// no run error.
pub fn expectFindings(comptime check: Check, source: []const u8, expected: usize) !void {
    return expectFindingsNamed(check, "fixture", source, expected);
}

/// As `expectFindings`, the file named `name` (`build.zig`).
pub fn expectFindingsNamed(comptime check: Check, name: []const u8, source: []const u8, expected: usize) !void {
    const gpa = std.testing.allocator;
    var project = try Project.init(gpa, &.{
        .{ .name = name, .stem = "Fixture", .bytes = source },
        .{ .name = "standard", .bytes = fixture_std, .selected = false },
    }, &.{.{ .from = 0, .target = 1, .spelling = "std" }}, .{});
    defer project.deinit();
    var found = try run(gpa, &project, project.sources[0].id, check);
    defer found.deinit(gpa);
    try std.testing.expectEqual(expected, found.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), found.refused);
}

/// As `expectFindings`, under `base`'s options (its limits).
pub fn expectFindingsWith(comptime check: Check, base: rules.Config, source: []const u8, expected: usize) !void {
    const gpa = std.testing.allocator;
    var project = try Project.init(gpa, &.{
        .{ .name = "fixture", .stem = "Fixture", .bytes = source },
        .{ .name = "standard", .bytes = fixture_std, .selected = false },
    }, &.{.{ .from = 0, .target = 1, .spelling = "std" }}, .{});
    defer project.deinit();
    var found = try runWith(gpa, &project, project.sources[0].id, check, base);
    defer found.deinit(gpa);
    try std.testing.expectEqual(expected, found.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), found.refused);
}

/// As `expectFindings`, and the fix edits' texts, in order, are `fixes`.
pub fn expectFixes(comptime check: Check, source: []const u8, expected: usize, fixes: []const []const u8) !void {
    const gpa = std.testing.allocator;
    var project = try Project.init(gpa, &.{
        .{ .name = "fixture", .stem = "Fixture", .bytes = source },
        .{ .name = "standard", .bytes = fixture_std, .selected = false },
    }, &.{.{ .from = 0, .target = 1, .spelling = "std" }}, .{});
    defer project.deinit();
    var found = try run(gpa, &project, project.sources[0].id, check);
    defer found.deinit(gpa);
    try std.testing.expectEqual(expected, found.messages.items.len);
    try std.testing.expectEqual(fixes.len, found.fixes.items.len);
    for (fixes, found.fixes.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

test {
    _ = SameOperands;
    _ = RepeatedCondition;
    _ = NarrowWidened;
    _ = LargeStackArray;
    _ = FixedComparison;
    _ = ExpectComparison;
    _ = DiscardedCount;
    _ = ExpectEqualOrder;
    _ = NeverLoops;
    _ = SelfRecursion;
    _ = DocComment;
    _ = FieldNaming;
    _ = UnwrapTrap;
    _ = UndefinedReason;
    _ = LeftoverDebugging;
    _ = ConstantCondition;
    _ = InexactFloat;
    _ = NanComparison;
    _ = NarrowCounter;
    _ = UndefinedConst;
    _ = DeadErrdefer;
    _ = BuildOption;
    _ = PublicAnytype;
    _ = FunctionShape;
    _ = EmptyBranch;
}
