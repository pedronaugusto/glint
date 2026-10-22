//! Assertion metrics: how many functions a file declares and the assertion calls in them, each
//! counted by the declaration its callee resolves to (std's `debug.assert`, aegis's `assert`
//! contracts), never by spelling. A call named like one whose callee does not resolve is counted
//! apart. A report, never a proof or a gate: a count says nothing about what an assertion checks.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Library = @import("Library.zig").Library;
const Report = @import("Report.zig");
const Ast = std.zig.Ast;

pub const Kind = Report.Metrics.Kind;
pub const Counts = Report.Metrics.Counts;

const Lib = Library(Kind);
/// Where std and aegis publish their assertions. Nothing is required: a program that imports
/// neither, or an aegis without one of them, just counts none.
pub const library: Lib = .{ .modules = &.{
    .{ .name = "std", .members = &.{.{ .path = "debug.assert", .role = .std_assert, .required = false }} },
    .{ .name = "aegis", .members = &aegis_members },
    .{ .name = "aegis.assert", .members = &assert_members },
} };
const aegis_members = blk: {
    var members: [assert_members.len]Lib.Member = undefined;
    for (assert_members, &members) |member, *each| each.* = .{ .path = "assert." ++ member.path, .role = member.role, .required = false };
    break :blk members;
};
const assert_members = [_]Lib.Member{
    .{ .path = "invariant", .role = .invariant, .required = false },
    .{ .path = "pre", .role = .pre, .required = false },
    .{ .path = "post", .role = .post, .required = false },
    .{ .path = "never", .role = .never, .required = false },
    .{ .path = "debug", .role = .debug, .required = false },
    .{ .path = "debugCheck", .role = .debug_check, .required = false },
};

/// Counts the context's file.
pub fn count(context: *Context) Context.Error!Counts {
    const index = context.file.raw();
    const tree = &context.project.files[index].tree;
    const parents = context.project.models[index].node_parents;
    var counts: Counts = .{};
    if (tree.errors.len != 0) return counts;
    const asserted = try context.allocator.alloc(bool, tree.nodes.len);
    @memset(asserted, false);
    for (tree.nodes.items(.tag), 0..) |tag, n| {
        if (tag == .fn_decl) counts.functions += 1;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n)); // aegis: no-danger: bounded AST node table fits u32.
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        const value = try context.facts.resolve(context.file, call.ast.fn_expr);
        const kind = if (value == .function) try context.role(library, value) else null;
        if (kind) |k| {
            counts.assertions[@backingInt(k)] += 1; // safe: a kind indexes its own count table.
            if (function(tree, parents, node)) |f| asserted[@backingInt(f)] = true; // safe: the checked AST indexes its own node table.
        } else if (value == .unknown and spelledLike(tree, call.ast.fn_expr)) counts.unresolved += 1;
    }
    for (asserted) |yes| {
        if (yes) counts.asserted += 1;
    }
    return counts;
}

/// The function whose own body holds `node`, if any; a test block holds it otherwise.
fn function(tree: *const Ast, parents: []const ?Ast.Node.Index, node: Ast.Node.Index) ?Ast.Node.Index {
    var at = parents[@backingInt(node)]; // safe: the checked AST indexes its own parent table.
    while (at) |parent| : (at = parents[@backingInt(parent)]) { // safe: the checked AST indexes its own parent table.
        switch (tree.nodeTag(parent)) {
            .fn_decl => return parent,
            .test_decl => return null,
            else => {},
        }
    }
    return null;
}

fn spelledLike(tree: *const Ast, callee: Ast.Node.Index) bool {
    const token = switch (tree.nodeTag(callee)) {
        .identifier => tree.nodeMainToken(callee),
        .field_access => tree.nodeData(callee).node_and_token[1],
        else => return false,
    };
    const name = tree.tokenSlice(token);
    for ([_][]const u8{ "assert", "invariant", "pre", "post", "never", "debugCheck" }) |spelling| if (std.mem.eql(u8, name, spelling)) return true;
    return false;
}
