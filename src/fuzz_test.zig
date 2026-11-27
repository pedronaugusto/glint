//! Fuzz targets for what glint parses from outside: a file's suppression and escape comments,
//! a package's `lint_rules` table read from its root (PackageRules, version 1 and 2), and a whole
//! file linted by the built-in rules, the configuration JSON, and a binary's DWARF parsed and
//! indexed. Each is a shakedown `check`
//! property: the input never panics, never leaks (the testing allocator checks) and never hangs,
//! and some input is accepted, so the property is not checking refusals alone; what it reports
//! is the unit tests'. A plain test run reads each example and then seeded cases, the examples
//! changed and any bytes; `zig build fuzz` searches from them.
const std = @import("std");
const shakedown = @import("shakedown");
const Suppression = @import("Suppression.zig");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const PackageRules = @import("PackageRules.zig");
const Runner = @import("Runner.zig");
const Rule = @import("Rule.zig");
const configure = @import("configure.zig").configure;
const Compiled = @import("Compiled.zig");
const Dwarf = Compiled.Dwarf;

/// `run` over each example, then over shakedown's cases: an example with a few bytes changed,
/// cut or added, or any bytes, up to `size`. `run` says whether it accepted the input, and some
/// case must be accepted.
fn property(comptime size: usize, comptime run: fn ([]const u8) anyerror!bool, examples: []const []const u8) !void {
    const Any = struct {
        fn body(given: []const []const u8, c: *shakedown.Case) anyerror!void {
            var buffer: [size]u8 = undefined;
            if (try run(shakedown.gen.mutated(c.source, &buffer, given))) c.reached("accepted");
        }
    };
    for (examples) |text| _ = try run(text);
    try shakedown.check(std.testing.allocator, examples, Any.body, .{ .reach = &.{"accepted"} });
}

fn suppressions(bytes: []const u8) anyerror!bool {
    const gpa = std.testing.allocator;
    var project = Project.init(gpa, &.{.{ .name = "fuzzed.zig", .bytes = bytes }}, &.{}, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // A file past the limits is refused before any comment is read.
        else => return false,
    };
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var malformed: std.ArrayList(Suppression.Malformed) = .empty;
    _ = try Suppression.parseConfigured(arena.allocator(), project.sources[0].file, &.{}, &malformed);
    return malformed.items.len == 0;
}

test "fuzz: suppression and escape comments" {
    try property(2048, suppressions, &.{
        Suppression.opening ++ "Z026 -- the reason\nfn f() void {}\n",
        "pub fn f() void {} " ++ Suppression.opening ++ "Z026, P006 -- two rules\n",
        "// " ++ Suppression.keyword ++ "\n" ++ Suppression.opening ++ "-- \n",
    });
}

fn lintRules(bytes: []const u8) anyerror!bool {
    const gpa = std.testing.allocator;
    var project = Project.init(gpa, &.{.{ .name = "root.zig", .bytes = bytes }}, &.{}, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // A project glint refuses whole has no table to read.
        else => return false,
    };
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator(), .backing = gpa };
    defer facts.deinit();
    _ = try PackageRules.of(&facts, project.sources[0].id);
    return true;
}

test "fuzz: a package's lint_rules table" {
    try property(4096, lintRules, &.{
        "pub const lint_rules = .{ .version = 2, .rules = .{.{ .id = \"X001\", .name = \"x\", .kind = .ban, .reads = .syntax, .default = .off, .purpose = \"p\" }} };",
        "pub const lint_rules = .{ .version = 1 };",
        "pub const lint_rules = .{ .version = 2, .replaces = .{.{ .decl = @This(), .why = \"w\" }} };",
        "pub const lint_rules = 3;",
    });
}

fn linted(bytes: []const u8) anyerror!bool {
    const gpa = std.testing.allocator;
    var project = Project.init(gpa, &.{.{ .name = "fuzzed.zig", .bytes = bytes }}, &.{}, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer project.deinit();
    var report = Runner.run(gpa, &project, .{ .config = Rule.Config.reviewed() }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // A file whose comments read as a suppression of two findings stops the run, as
        // the CLI ends it.
        error.AmbiguousSuppression => return false,
        else => return err,
    };
    defer report.deinit();
    return report.complete;
}

test "fuzz: a file linted by the built-in rules" {
    try property(2048, linted, &.{
        "const std = @import(\"std\");\npub fn main() void { std.debug.print(\"x\", .{}); }\n",
        "pub fn f(a: ?u8) u8 { return a orelse 0; }\n",
        "fn g() !void {} pub fn f() void { g() catch {}; }\n",
        "pub fn f( { ",
    });
}

fn configured(bytes: []const u8) anyerror!bool {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // A document refused for its JSON is the answer: the CLI says so. Its rule names are
    // resolved later, against the run's rules (`cli.resolve`).
    _ = configure(arena.allocator(), bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return true;
}

test "fuzz: the configuration JSON" {
    try property(4096, configured, &.{
        "{\"profile\": \"reviewed\", \"rules\": [{\"id\": \"Z026\", \"level\": \"gate\"}]}",
        "{\"profile\": \"reviewed\", \"max_line_length\": 120, \"disallowed\": [{\"source\": \"std\", \"declaration\": \"debug.print\", \"reason\": \"r\", \"replacement\": \"x\"}]}",
        "{\"function_exceptions\": [{\"function\": \"f\", \"lines\": 200, \"reason\": \"r\"}]}",
        "{\"profile\": \"reviewed\", \"max_parameters\": 4, \"max_nesting\": 3, \"max_stack_array\": 4096, \"rules\": [{\"id\": \"P013\", \"level\": \"report\"}]}",
        "{",
    });
}

fn indexed(bytes: []const u8) anyerror!bool {
    const dwarf = Dwarf.parse(std.testing.allocator, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidDebugInfo, error.NotElf64, error.CompressedSection, error.MissingSection => return false,
    };
    // A DWARF kept is indexed whole, as a run indexes it.
    var index = try Compiled.init(std.testing.allocator, dwarf, "/pkg");
    index.deinit();
    return true;
}

// The sample is an ELF whose DWARF the reader keeps (Dwarf.zig's tests): most changes to it land
// past the header, where random bytes never reach.
test "fuzz: a binary's DWARF, parsed and indexed" {
    const gpa = std.testing.allocator;
    const example = try Dwarf.sampleForTests(gpa);
    defer gpa.free(example);
    try std.testing.expect(try indexed(example));
    try property(16384, indexed, &.{example});
}
