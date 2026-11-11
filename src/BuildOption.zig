//! Hygiene, build scripts only (a file named `build.zig`): a module created with a hard-coded
//! `.optimize` (an enum literal: `.ReleaseFast`) where the script also reads the user's choice
//! with `standardOptimizeOption`, or a hard-coded `.target` (`b.resolveTargetQuery(…)`) where it
//! reads `standardTargetOptions`: that module ignores what `-Doptimize` or `-Dtarget` says. Read:
//! the options a call of std's `Build.createModule` or `Build.addModule` is given (Zig 0.17's
//! executables, libraries and tests take a module, not these options), each call resolved by its
//! callee (`Governed.stdCall`). A host-only tool is still a module that ignores the option: the
//! report says which.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Facts = @import("Facts.zig");
const Governed = @import("Governed.zig");
const Written = @import("Written.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    if (!std.mem.endsWith(u8, c.project.at(c.file).input.name, "build.zig")) return;
    const tree = &c.project.at(c.file).file.tree;
    const calls = try Facts.calls.in(c.facts, c.file);
    var reads_optimize = false;
    var reads_target = false;
    for (calls) |call| {
        if (try Governed.stdCall(c, call.node, "Build.standardOptimizeOption") == .yes) reads_optimize = true;
        if (try Governed.stdCall(c, call.node, "Build.standardTargetOptions") == .yes) reads_target = true;
    }
    if (!reads_optimize and !reads_target) return;
    for (calls) |call| {
        const position: usize = if (try Governed.stdCall(c, call.node, "Build.createModule") == .yes) 0 else if (try Governed.stdCall(c, call.node, "Build.addModule") == .yes) 1 else continue;
        const args = switch (call.args) {
            .known => |args| args,
            .unknown => continue,
        };
        // The receiver `b` is the first argument a bound call passes.
        const written = if (call.receiver == .bound) args[@min(args.len, 1)..] else args;
        if (written.len <= position) continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const options = tree.fullStructInit(&buffer, Written.ungrouped(tree, written[position])) orelse continue;
        for (options.ast.fields) |field| {
            const name = tree.tokenSlice(tree.firstToken(field) - 2);
            if (reads_optimize and std.mem.eql(u8, name, "optimize") and tree.nodeTag(Written.ungrouped(tree, field)) == .enum_literal) {
                try c.at(rule, tree.firstToken(field), "a module built with a hard-coded optimize mode where the script reads -Doptimize (standardOptimizeOption): this module ignores it");
            }
            if (reads_target and std.mem.eql(u8, name, "target") and Facts.calls.written(tree, Written.ungrouped(tree, field)) and try Governed.stdCall(c, Written.ungrouped(tree, field), "Build.resolveTargetQuery") == .yes) {
                try c.at(rule, tree.firstToken(field), "a module built for a hard-coded target where the script reads -Dtarget (standardTargetOptions): this module ignores it");
            }
        }
    }
}

const breadth = @import("breadth_test.zig");

test "breadth: build option: a hard-coded optimize or target beside the standard option reported; the option passed, or no standard option, not" {
    const head = "const std = @import(\"std\");\npub fn build(b: *std.Build) void {\n    const optimize = b.standardOptimizeOption(.{});\n    const target = b.standardTargetOptions(.{});\n";
    try breadth.expectFindingsNamed(check, "build.zig", head ++ "    _ = b.createModule(.{ .target = target, .optimize = .ReleaseFast });\n    _ = b.createModule(.{ .target = b.resolveTargetQuery(.{}), .optimize = optimize });\n}\n", 2);
    try breadth.expectFindingsNamed(check, "build.zig", head ++ "    _ = b.createModule(.{ .target = target, .optimize = optimize });\n}\n", 0);
    try breadth.expectFindingsNamed(check, "build.zig", "const std = @import(\"std\");\npub fn build(b: *std.Build) void {\n    _ = b.createModule(.{ .optimize = .ReleaseFast });\n}\n", 0);
    try breadth.expectFindingsNamed(check, "tool.zig", head ++ "    _ = b.createModule(.{ .target = target, .optimize = .ReleaseFast });\n}\n", 0);
}
