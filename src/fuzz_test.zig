//! Fuzz targets for what glint parses from outside: a file's suppression and escape comments,
//! a package's `lint_rules` table read from its root (PackageRules, version 1 and 2), and a whole
//! file linted by the built-in rules. The configuration JSON's target is in cli.zig, next to
//! its private parser. Each target's property is that the input never panics, never leaks (the
//! testing allocator checks) and never hangs; what it reports is the unit tests'. A plain test
//! run reads each target's corpus once; `zig build test --fuzz` searches from it.
const std = @import("std");
const File = @import("File.zig");
const Suppression = @import("Suppression.zig");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const PackageRules = @import("PackageRules.zig");
const Runner = @import("Runner.zig");
const Rule = @import("Rule.zig");

test "fuzz: suppression and escape comments" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buffer: [2048]u8 = undefined;
            const bytes = buffer[0..smith.slice(&buffer)];
            const gpa = std.testing.allocator;
            var file = File.initWithLowering(gpa, bytes, .{}, true, .zig) catch |err| switch (err) {
                error.OutOfMemory => return err,
                // A file past the limits is refused before any comment is read.
                error.SourceTooLarge, error.SourceTooComplex => return,
            };
            defer file.deinit();
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var malformed: std.ArrayList(Suppression.Malformed) = .empty;
            _ = try Suppression.parseConfigured(arena.allocator(), &file, &.{}, &malformed);
        }
    };
    try std.testing.fuzz({}, Target.one, .{ .corpus = &.{
        "// glint-ignore: Z026 -- the reason\nfn f() void {}\n",
        "pub fn f() void {} // glint-ignore: Z026, P006 -- two rules\n",
        "// aegis: design(A019): a reason\nconst x = 1;\n",
        "// glint-ignore\n// glint-ignore: -- \n// aegis:\n",
    } });
}

test "fuzz: a package's lint_rules table" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buffer: [4096]u8 = undefined;
            const bytes = buffer[0..smith.slice(&buffer)];
            const gpa = std.testing.allocator;
            var project = Project.init(gpa, &.{.{ .name = "root.zig", .bytes = bytes }}, &.{}, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                // A project glint refuses whole has no table to read.
                else => return,
            };
            defer project.deinit();
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var facts: Facts = .{ .project = &project, .gpa = arena.allocator(), .backing = gpa };
            defer facts.deinit();
            _ = try PackageRules.of(&facts, project.sources[0].id);
        }
    };
    try std.testing.fuzz({}, Target.one, .{ .corpus = &.{
        "pub const lint_rules = .{ .version = 2, .rules = .{.{ .id = \"X001\", .name = \"x\", .kind = .ban, .reads = .syntax, .default = .off, .purpose = \"p\" }} };",
        "pub const lint_rules = .{ .version = 1 };",
        "pub const lint_rules = .{ .version = 2, .replaces = .{.{ .decl = @This(), .why = \"w\" }} };",
        "pub const lint_rules = 3;",
    } });
}

test "fuzz: a file linted by the built-in rules" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buffer: [2048]u8 = undefined;
            const bytes = buffer[0..smith.slice(&buffer)];
            const gpa = std.testing.allocator;
            var project = Project.init(gpa, &.{.{ .name = "fuzzed.zig", .bytes = bytes }}, &.{}, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return,
            };
            defer project.deinit();
            var report = Runner.run(gpa, &project, Rule.Config.reviewed()) catch |err| switch (err) {
                error.OutOfMemory => return err,
                // A file whose comments read as a suppression of two findings stops the run, as
                // the CLI ends it.
                error.AmbiguousSuppression => return,
                else => return err,
            };
            report.deinit();
        }
    };
    try std.testing.fuzz({}, Target.one, .{ .corpus = &.{
        "const std = @import(\"std\");\npub fn main() void { std.debug.print(\"x\", .{}); }\n",
        "pub fn f(a: ?u8) u8 { return a orelse 0; }\n",
        "fn g() !void {} pub fn f() void { g() catch {}; }\n",
        "pub fn f( { ",
    } });
}
