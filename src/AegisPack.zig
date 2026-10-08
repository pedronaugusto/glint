//! Optional report-only published-type obligations. No security or lifetime proof.
const std = @import("std");
const Facts = @import("Facts.zig");
const Context = @import("RuleContext.zig");
const Contract = @import("AegisContract.zig");
const Rule = @import("Rule.zig").Rule;
const Ast = std.zig.Ast;
pub const pinned = Contract.pinned;
pub const access: Rule = @fromBackingInt(@intCast(1100)); // safe: compiled pack identities are reserved stable u16 values.
pub const copies: Rule = @fromBackingInt(@intCast(1101)); // safe: compiled pack identities are reserved stable u16 values.
pub const cleanup: Rule = @fromBackingInt(@intCast(1102)); // safe: compiled pack identities are reserved stable u16 values.
pub const scalar: Rule = @fromBackingInt(@intCast(1103)); // safe: compiled pack identities are reserved stable u16 values.
pub const capacity: Rule = @fromBackingInt(@intCast(1104)); // safe: compiled pack identities are reserved stable u16 values.
pub const rules = [_]Context.Rule{
    .{ .definition = .{ .id = access, .name = "A001", .group = .family_policy, .purpose = "secret disclosure or shared-state access without a live capability", .report_only = true, .exception = .aegis }, .check = checkAccess },
    .{ .definition = .{ .id = copies, .name = "A002", .group = .family_policy, .purpose = "duplicated secret owner or lock capability; borrowed storage escapes", .report_only = true, .exception = .aegis }, .check = checkCopies },
    .{ .definition = .{ .id = cleanup, .name = "A003", .group = .family_policy, .purpose = "missing owner cleanup or use after cleanup/transfer on a supported local path", .report_only = true, .exception = .aegis }, .check = checkCleanup },
    .{ .definition = .{ .id = scalar, .name = "A004", .group = .family_policy, .purpose = "domain/unit or all-build integer checks bypassed by raw arithmetic/casts", .report_only = true, .exception = .aegis }, .check = checkScalar },
    .{ .definition = .{ .id = capacity, .name = "A005", .group = .family_policy, .purpose = "SecretBytes adoption truncates wipe capacity or lacks proven allocation ownership", .report_only = true, .exception = .aegis }, .check = checkCapacity },
};
fn internal(c: *Context) Context.Error!bool {
    return try Contract.source(c, c.file) != null;
}
fn limits(c: *Context, rule: Rule) Context.Error!void {
    try c.undecided(rule, 0, .unsupported, "published-source identities and direct AST shapes over std ZIR only; generic evaluation, reflection, hooks, retained aliases and interprocedural flow remain undecided");
}
fn checkAccess(c: *Context) Context.Error!void {
    if (try internal(c)) return;
    try limits(c, access);
    const tree = try c.project.syntax(try c.source());
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .field_access) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: AST node table supplies bounded indexes.
        const data = tree.nodeData(node).node_and_token;
        const k = (try Contract.owner(c, data[0])) orelse continue;
        const name = tree.tokenSlice(data[1]);
        const backing = switch (k) {
            .secret => std.mem.eql(u8, name, "material"),
            .bytes => std.mem.eql(u8, name, "allocation") or std.mem.eql(u8, name, "used_len") or std.mem.eql(u8, name, "gpa"),
            .guarded => std.mem.eql(u8, name, "data") or std.mem.eql(u8, name, "lock"),
            .guard => std.mem.eql(u8, name, "owner"),
            .scalar => false,
        };
        if (backing) try c.at(access, data[1], "published aegis backing field bypasses exposure/guard/ownership contract; review this access");
    }
}
fn checkCopies(c: *Context) Context.Error!void {
    if (try internal(c)) return;
    try limits(c, copies);
    const tree = try c.project.syntax(try c.source());
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: AST node table supplies bounded indexes.
        if (tree.fullVarDecl(node)) |v| {
            const init = v.ast.init_node.unwrap() orelse continue;
            if (tree.nodeTag(init) != .identifier) continue;
            const k = (try Contract.owner(c, init)) orelse continue;
            if (k != .scalar) {
                if (!try ownedValue(c, init, 0)) continue;
                try c.at(copies, tree.nodeMainToken(node), "copy of a recognized live owner/capability requires explicit transfer; lifetime and publication are undecided");
            }
        }
        if (tag == .@"return") {
            const expr = tree.nodeData(node).opt_node.unwrap() orelse continue;
            if (try exposure(c, expr)) try c.at(copies, tree.nodeMainToken(node), "returned secret/guard borrow can outlive its capability; caller lifetime is undecided");
        }
    }
}
fn ownedValue(c: *Context, node: Ast.Node.Index, depth: usize) Context.Error!bool {
    if (depth == 64) return false;
    const tree = try c.project.syntax(try c.source());
    const index = Contract.local(c, node) orelse return false;
    const decl = c.project.models[c.file.raw()].declarations[index];
    const v = tree.fullVarDecl(decl.node) orelse return false;
    if (v.ast.type_node.unwrap()) |t| {
        if (tree.fullPtrType(t) != null) return false;
        if (tree.nodeTag(t) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(t)), "type")) return false;
        return try Contract.owner(c, t) != null;
    }
    var init = v.ast.init_node.unwrap() orelse return false;
    if (tree.nodeTag(init) == .identifier) return ownedValue(c, init, depth + 1);
    if (tree.nodeTag(init) == .@"try") init = tree.nodeData(init).node;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, init) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const name = tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]);
    return std.mem.eql(u8, name, "init") or std.mem.eql(u8, name, "adopt") or std.mem.eql(u8, name, "acquire");
}

fn exposure(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const data = tree.nodeData(call.ast.fn_expr).node_and_token;
    const k = (try Contract.owner(c, data[0])) orelse return false;
    const name = tree.tokenSlice(data[1]);
    return ((k == .secret or k == .bytes) and (std.mem.eql(u8, name, "expose") or std.mem.eql(u8, name, "exposeMut"))) or (k == .guard and std.mem.eql(u8, name, "value"));
}
fn checkCleanup(c: *Context) Context.Error!void {
    if (try internal(c)) return;
    try limits(c, cleanup);
    const tree = try c.project.syntax(try c.source());
    const model = &c.project.models[c.file.raw()];
    for (model.declarations) |decl| {
        if (decl.kind != .variable or model.scopes[decl.scope].kind != .block) continue;
        const v = tree.fullVarDecl(decl.node) orelse continue;
        const init = v.ast.init_node.unwrap() orelse continue;
        // Only actual acquisition expressions, never an owner alias or type alias.
        var call_buffer: [1]Ast.Node.Index = undefined;
        const acquisition = if (tree.nodeTag(init) == .@"try") tree.nodeData(init).node else init;
        if (tree.fullCall(&call_buffer, acquisition) == null) continue;
        const k = (try Contract.owner(c, acquisition)) orelse continue;
        if (k != .secret and k != .bytes and k != .guard) continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, model.scopes[decl.scope].node) orelse continue;
        var found = false;
        var normal_cleanup = false;
        var released = false;
        var uncertain = false;
        for (statements) |stmt| {
            if (stmt == decl.node) {
                found = true;
                continue;
            }
            if (!found) continue;
            const tag = tree.nodeTag(stmt);
            if (tag == .@"defer") {
                if (try release(c, tree.nodeData(stmt).node, decl.token)) {
                    normal_cleanup = true;
                    continue;
                }
            }
            if (try release(c, stmt, decl.token)) {
                if (released or normal_cleanup) try c.at(cleanup, tree.nodeMainToken(stmt), "same local capability is cleaned twice on this straight-line path");
                released = true;
                continue;
            }
            // A discard of this owner's address has no retaining call or mutation.
            if (tag == .assign) {
                const data = tree.nodeData(stmt).node_and_node;
                if (tree.nodeTag(data[0]) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(data[0])), "_") and tree.nodeTag(data[1]) == .address_of) {
                    const target = tree.nodeData(data[1]).node;
                    if (Contract.local(c, target)) |index| if (model.declarations[index].token == decl.token) {
                        if (released) try c.at(cleanup, tree.nodeMainToken(target), "same local owner used after cleanup on this straight-line path");
                        continue;
                    };
                }
            }
            uncertain = true;
            break;
        }
        if (uncertain) try c.undecided(cleanup, tree.tokenStart(decl.token), .unsupported, "cleanup/error exits/transfers/aliases require unsupported flow facts; no leak claimed") else if (!normal_cleanup and !released) try c.at(cleanup, decl.token, "recognized local acquisition reaches block end without cleanup; review ownership obligation");
    }
}

fn release(c: *Context, node: Ast.Node.Index, token: Ast.TokenIndex) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const data = tree.nodeData(call.ast.fn_expr).node_and_token;
    const index = Contract.local(c, data[0]) orelse return false;
    return c.project.models[c.file.raw()].declarations[index].token == token and std.mem.eql(u8, tree.tokenSlice(data[1]), "deinit");
}
fn raw(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access or call.ast.params.len != 0) return false;
    const data = tree.nodeData(call.ast.fn_expr).node_and_token;
    return std.mem.eql(u8, tree.tokenSlice(data[1]), "raw") and try Contract.owner(c, data[0]) == .scalar;
}
fn checkScalar(c: *Context) Context.Error!void {
    if (try internal(c)) return;
    try limits(c, scalar);
    const tree = try c.project.syntax(try c.source());
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: AST node table supplies bounded indexes.
        switch (tag) {
            .add, .sub, .mul, .div, .mod, .shl, .add_wrap, .sub_wrap, .mul_wrap, .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal => {
                const operands = tree.nodeData(node).node_and_node;
                if (try raw(c, operands[0]) or try raw(c, operands[1])) try c.at(scalar, tree.nodeMainToken(node), "raw aegis scalar operation bypasses domain/unit or checked arithmetic; explicit boundary semantics required");
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                if (!std.mem.eql(u8, name, "@intCast") and !std.mem.eql(u8, name, "@truncate") and !std.mem.eql(u8, name, "@enumFromInt")) continue;
                var buffer: [2]Ast.Node.Index = undefined;
                for (Facts.builtinArgs(tree, node, &buffer)) |arg| if (try raw(c, arg)) try c.at(scalar, tree.nodeMainToken(node), "raw aegis scalar cast can discard domain/range/all-build failure checks; use checked conversion or justify boundary");
            },
            else => {},
        }
    }
}
fn checkCapacity(c: *Context) Context.Error!void {
    if (try internal(c)) return;
    try limits(c, capacity);
    const tree = try c.project.syntax(try c.source());
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: AST node table supplies bounded indexes.
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) continue;
        const data = tree.nodeData(call.ast.fn_expr).node_and_token;
        if (!std.mem.eql(u8, tree.tokenSlice(data[1]), "adopt") or try Contract.owner(c, data[0]) != .bytes or call.ast.params.len != 3) continue;
        if (tree.fullSlice(call.ast.params[1])) |slice| {
            if (slice.ast.end.unwrap() != null) try c.at(capacity, tree.nodeMainToken(node), "SecretBytes.adopt receives an explicitly bounded slice: full allocator capacity/exclusive ownership must be retained; extent is undecided");
        }
        try c.undecided(capacity, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "slice syntax cannot prove full allocator extent, provenance, alignment or exclusive transfer; runtime wipe/free obligations remain");
    }
}
