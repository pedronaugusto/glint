//! Hygiene, opt-in: a container field or an enum tag not named as Zig's style guide names it (the
//! langref's "Names": a type is TitleCase, a callable camelCase, everything else snake_case). A
//! field whose written type is `type` is TitleCase; one whose written type is a function or a
//! pointer to one, camelCase; any other field or tag, snake_case. A name written `@"..."`, a
//! non-exhaustive enum's `_`, and a field of an `extern` or `packed` container (laid out by a
//! foreign contract, which names it) are not read. Error names are not read: the guide states no
//! case for them.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const names = @import("names.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var members_buffer: [2]Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&members_buffer, node) orelse continue;
        if (container.layout_token) |layout| switch (tree.tokenTag(layout)) {
            .keyword_extern, .keyword_packed => continue,
            else => {},
        };
        for (container.ast.members) |member| {
            const field = tree.fullContainerField(member) orelse continue;
            const token = field.ast.main_token;
            if (tree.tokenTag(token) != .identifier) continue;
            const name = tree.tokenSlice(token);
            if (name[0] == '@' or std.mem.eql(u8, name, "_")) continue;
            const wanted: enum { title, camel, snake } = if (field.ast.type_expr.unwrap()) |written| kind: {
                if (isType(tree, written)) break :kind .title;
                if (callable(tree, written)) break :kind .camel;
                break :kind .snake;
            } else .snake;
            const ok = switch (wanted) {
                .title => names.isPascalCase(name),
                .camel => names.isValidFunctionName(name),
                .snake => names.isSnakeCase(name),
            };
            if (ok) continue;
            try c.at(rule, token, try c.allocator.print("field '{s}' should be {s}", .{ name, switch (wanted) {
                .title => "TitleCase: its type is `type`",
                .camel => "camelCase: it holds a function",
                .snake => "snake_case",
            } }));
        }
    }
}

fn isType(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "type");
}

/// Whether a written type is a function type or a pointer (optional or not) to one.
fn callable(tree: *const Ast, node: Ast.Node.Index) bool {
    var buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&buffer, node) != null) return true;
    if (tree.fullPtrType(node)) |pointer| return callable(tree, pointer.ast.child_type);
    if (tree.nodeTag(node) == .optional_type) return callable(tree, tree.nodeData(node).node);
    return false;
}

const breadth = @import("breadth.zig");

test "breadth: field naming: a camel field, a snake type field and an upper tag reported; the guide's forms, extern and quoted not" {
    try breadth.expectFindings(check, "pub const S = struct { someField: u32 };", 1);
    try breadth.expectFindings(check, "pub const S = struct { some_field: u32, Kind: type, drawFrame: *const fn () void };", 0);
    try breadth.expectFindings(check, "pub const S = struct { kind: type, draw_frame: *const fn () void };", 2);
    try breadth.expectFindings(check, "pub const E = enum { ok, Bad, _ };", 1);
    try breadth.expectFindings(check, "pub const C = extern struct { someField: u32 };", 0);
    try breadth.expectFindings(check, "pub const S = struct { @\"Quoted\": u32 };", 0);
}
