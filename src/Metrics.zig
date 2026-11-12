//! Assertion metrics: how many functions a file declares and the assertion calls in them, each
//! counted by the declaration its callee resolves to (std's `debug.assert`, and each declaration a
//! package's `lint_rules` names in its place, a `.with` of an entry replacing it), never by spelling. A call whose callee does not resolve counts as none. A report, never a proof or a gate: a count says nothing about what an assertion checks.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Model = @import("Model.zig");
const Governed = @import("Governed.zig");
const Replaced = @import("Replaced.zig");
const Facts = @import("Facts.zig");
const Report = @import("Report.zig");
const Ast = std.zig.Ast;

pub const Kind = Report.Metrics.Kind;
pub const Counts = Report.Metrics.Counts;

/// Counts the context's file.
pub fn count(context: *Context) Context.Error!Counts {
    const source = context.project.at(context.file);
    const tree = &source.file.tree;
    const model = &source.model;
    var counts: Counts = .{};
    if (tree.errors.len != 0) return counts;
    const replacements = try Replaced.assertions(context);
    const asserted = try context.allocator.alloc(bool, tree.nodes.len);
    @memset(asserted, false);
    for (tree.nodes.items(.tag), 0..) |tag, n| {
        if (tag == .fn_decl) counts.functions += 1;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        const value = try context.facts.resolve(context.file, call.ast.fn_expr);
        // std's by std's contract, at its path; a replacement by the declaration a package names.
        const kind: ?Kind = if (value != .function) null else if (try Governed.stdCall(context, node, "debug.assert") == .yes) .std_assert else if (among(replacements, value.function)) .replacement else null;
        if (kind) |k| {
            counts.assertions[@backingInt(k)] += 1; // safe: a kind indexes its own count table.
            if (function(tree, model, node)) |f| asserted[@backingInt(f)] = true; // safe: the checked AST indexes its own node table.
        }
    }
    for (asserted) |yes| {
        if (yes) counts.asserted += 1;
    }
    return counts;
}

/// The function whose own body holds `node`, if any; a test block holds it otherwise.
fn function(tree: *const Ast, model: *const Model, node: Ast.Node.Index) ?Ast.Node.Index {
    var at = model.parentOf(node);
    while (at) |parent| : (at = model.parentOf(parent)) {
        switch (tree.nodeTag(parent)) {
            .fn_decl => return parent,
            .test_decl => return null,
            else => {},
        }
    }
    return null;
}

fn among(decls: []const Facts.Decl, decl: Facts.Decl) bool {
    for (decls) |each| if (std.meta.eql(each, decl)) return true;
    return false;
}
