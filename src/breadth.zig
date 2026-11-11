//! The breadth hygiene rules (glint 0.8): seven rules, each in its own file, that read the syntax
//! and the type a declaration writes, and report only what is certain. Until they are registered
//! as built-in rules, each runs and is tested as a project rule of the id below.
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

/// What a run of one breadth rule over one file found (`run`): its findings' messages and
/// whether it left anything undecided.
pub const Found = struct { messages: std.ArrayList([]const u8) = .empty, undecided: usize = 0 };

/// Runs `check` over the first file of `project` under `test_id`, as the runner runs a project
/// rule: its own Facts, the file's context, a sink that keeps each finding's message.
pub fn run(gpa: std.mem.Allocator, project: *const Project, file: Project.FileId, comptime check: Check) !Found {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var facts: Facts = .{ .project = project, .gpa = a, .backing = gpa };
    defer facts.deinit();
    var sink: Context.Sink = .{ .diagnostic = Collect.diagnostic, .coverage = Collect.coverage, .config = Collect.configOf };
    var collector: Collect = .{ .gpa = gpa };
    const before = collecting;
    collecting = &collector;
    defer collecting = before;
    const definitions = [_]rules.Definition{projectRule(check).definition};
    var context: Context = .{ .allocator = a, .backing = gpa, .project = project, .file = file, .config = selected(), .facts = &facts, .definitions = &definitions, .sink = &sink };
    try check(&context, test_id);
    return collector.found;
}

/// The collector the sink of the run in progress on this thread hands each finding to: a sink's
/// callbacks are given the sink alone.
threadlocal var collecting: ?*Collect = null;

const Collect = struct {
    found: Found = .{},
    gpa: std.mem.Allocator,

    fn diagnostic(_: *Context.Sink, _: Rule, _: u32, _: u32, message: []const u8, _: []const Report.Span, _: []const Report.Edit) Context.Error!void {
        const self = collecting orelse return;
        try self.found.messages.append(self.gpa, try self.gpa.dupe(u8, message));
    }
    fn coverage(_: *Context.Sink, _: Report.Coverage) Context.Error!void {
        const self = collecting orelse return;
        self.found.undecided += 1;
    }
    fn configOf(_: *Context.Sink, _: Project.FileId) rules.Config {
        return selected();
    }
};

fn selected() rules.Config {
    var config: rules.Config = .none();
    config.selections = &.{.{ .rule = test_id, .level = .report }};
    return config;
}

/// Runs `check` over `source` (with `fixture_std` as std) and expects `expected` findings and
/// nothing undecided.
pub fn expectFindings(comptime check: Check, source: []const u8, expected: usize) !void {
    const gpa = std.testing.allocator;
    var project = try Project.init(gpa, &.{
        .{ .name = "fixture", .stem = "Fixture", .bytes = source },
        .{ .name = "standard", .bytes = fixture_std, .selected = false },
    }, &.{.{ .from = 0, .target = 1, .spelling = "std" }}, .{});
    defer project.deinit();
    var found = try run(gpa, &project, project.sources[0].id, check);
    defer {
        for (found.messages.items) |m| gpa.free(m);
        found.messages.deinit(gpa);
    }
    try std.testing.expectEqual(expected, found.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), found.undecided);
}

test {
    _ = SameOperands;
    _ = RepeatedCondition;
    _ = NarrowWidened;
    _ = LargeStackArray;
    _ = FixedComparison;
    _ = ExpectComparison;
    _ = DiscardedCount;
}
