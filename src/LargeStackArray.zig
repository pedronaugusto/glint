//! Hygiene: a local array so large that one call's frame may not fit the stack it runs on, a
//! thread's above all: a `var` in a function body whose written type is `[N]T`, with `N` an
//! integer literal or literal arithmetic and `T` a primitive whose size its spelling states
//! (`u8`, `i32`, `f64`, `bool`), of more than `limit` bytes. Zig compiles a 64 MiB local array and
//! the program aborts when it runs. A `const` local holding a value known as it compiles is not in
//! the frame, so only `var` is read, and nothing inside `comptime` or in a function returning
//! `type`. A length or element whose size is not written leaves the site unread.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Written = @import("Written.zig");

/// The most bytes a local array may take before it is reported. TODO(0.8): configurable, as
/// `max_line_length` is, once the rule is registered.
pub const limit: u64 = 64 * 1024;

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    return checkLimit(c, rule, limit);
}

pub fn checkLimit(c: *Context, rule: Rule, most: u64) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .simple_var_decl, .local_var_decl, .aligned_var_decl => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const declared = tree.fullVarDecl(node) orelse continue;
        if (tree.tokenTag(declared.ast.mut_token) != .keyword_var or declared.comptime_token != null) continue;
        const written = declared.ast.type_node.unwrap() orelse continue;
        const bytes = arrayBytes(tree, written) orelse continue;
        if (bytes <= most) continue;
        if (!inRuntimeFunction(tree, model, node)) continue;
        try c.at(rule, declared.ast.mut_token + 1, try c.allocator.print("a local array of {d} bytes, above the {d} a frame is allowed here: a thread's stack may not hold it; allocate it, or keep it in a container", .{ bytes, most }));
    }
}

/// The bytes `[N]T` takes, `N` a literal integer and `T` a primitive of written size, nested
/// arrays multiplied; null for any other type.
fn arrayBytes(tree: *const Ast, node: Ast.Node.Index) ?u64 {
    const at = Written.ungrouped(tree, node);
    switch (tree.nodeTag(at)) {
        .array_type => {
            const length, const element = tree.nodeData(at).node_and_node;
            const n = Written.literalInteger(tree, length) orelse return null;
            const each = arrayBytes(tree, element) orelse return null;
            return std.math.mul(u64, std.math.cast(u64, n) orelse return null, each) catch null;
        },
        else => {},
    }
    return switch (Written.primitive(tree, at) orelse return null) {
        .sized => |sized| (@as(u64, sized.bits) + 7) / 8,
        .boolean => 1,
        .float => {
            const name = tree.tokenSlice(tree.nodeMainToken(at));
            for ([_]struct { []const u8, u64 }{ .{ "f16", 2 }, .{ "f32", 4 }, .{ "f64", 8 }, .{ "f128", 16 } }) |known| {
                if (std.mem.eql(u8, name, known[0])) return known[1];
            }
            return null;
        },
        .integer => null,
    };
}

/// Whether `node` is in a function body that runs: not inside a `comptime` block or expression,
/// and not in a function whose written return type is `type`.
fn inRuntimeFunction(tree: *const Ast, model: *const @import("Model.zig"), node: Ast.Node.Index) bool {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        // A container's own `var` (a struct declared in a function) is static, not the frame's.
        var members: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&members, parent) != null) return false;
        switch (tree.nodeTag(parent)) {
            .@"comptime" => return false,
            .fn_decl => {
                var buffer: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buffer, parent) orelse return false;
                const result = proto.ast.return_type.unwrap() orelse return true;
                const named = Written.ungrouped(tree, result);
                return !(tree.nodeTag(named) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(named)), "type"));
            },
            else => {},
        }
    }
    return false;
}

const breadth = @import("breadth.zig");

test "breadth: large stack array: a local var over the limit reported; a const, a small one, a container's, a type function's not" {
    try breadth.expectFindings(check, "pub fn f() u8 { var buf: [1 << 20]u8 = undefined; buf[0] = 1; return buf[0]; }", 1);
    try breadth.expectFindings(check, "pub fn f() u32 { var buf: [256][256]u32 = undefined; buf[0][0] = 1; return buf[0][0]; }", 1);
    try breadth.expectFindings(check, "pub fn f() u8 { var buf: [4096]u8 = undefined; buf[0] = 1; return buf[0]; }", 0);
    try breadth.expectFindings(check, "pub fn f() u8 { const buf: [1 << 20]u8 = @splat(0); return buf[0]; }", 0);
    try breadth.expectFindings(check, "var buf: [1 << 20]u8 = undefined; pub fn f() u8 { return buf[0]; }", 0);
    try breadth.expectFindings(check, "pub fn T() type { var n: [1 << 20]u8 = undefined; _ = &n; return u8; }", 0);
    try breadth.expectFindings(check, "const N = 1 << 20; pub fn f() u8 { var buf: [N]u8 = undefined; buf[0] = 1; return buf[0]; }", 0);
}
