//! Lexical identity and std-lowered declarations. No type/comptime execution.
const std = @import("std");
const File = @import("File.zig");
const Ast = std.zig.Ast;
const Model = @This();

scopes: []Scope,
declarations: []Declaration,
references: []Reference,
token_scopes: []const Scope.Id,
node_references: []const ?Reference.Id,
node_parents: []const ?Ast.Node.Index,
zir_declarations: []const LoweredDeclaration,
zir_references: []const LoweredReference,
operations: []const Operation,
node_operations: []const ?Operation.Id,
unknown_references: usize,
/// Import expressions indexed once for repeated coverage queries.
import_nodes: []const Ast.Node.Index,
/// The std-ZIR reference index is partial; lexical references remain a separate query.
lowered_coverage: enum { partial, not_requested, invalid_front_end, budget_exhausted },

pub const Kind = enum { file, container, function, block, branch, loop, @"test", @"comptime" };
pub const Scope = struct {
    kind: Kind,
    node: Ast.Node.Index,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    parent: ?Id = null,
    names: std.StringHashMapUnmanaged(Declaration.Id) = .empty,
    /// Set by `init` counting the scopes once they are in order.
    id: Id = undefined,

    /// A scope of one model, made only by counting its scopes.
    pub const Id = enum(u32) { _ };
};
pub const Declaration = struct {
    name: []const u8,
    token: Ast.TokenIndex,
    node: Ast.Node.Index,
    scope: Scope.Id,
    kind: enum { variable, function, parameter, capture, field },
    public: bool = false,
    exported: bool = false,
    references: u32 = 0,
    lowered: ?std.zig.Zir.Inst.Index = null,

    /// A declaration of one model, made only as it is appended or by counting them.
    pub const Id = enum(u32) { _ };
};
pub const Reference = struct {
    token: Ast.TokenIndex,
    node: Ast.Node.Index,
    declaration: ?Declaration.Id,
    unknown: ?enum { primitive, unresolved, invalid_lowering, before_declaration, literal_context } = null,

    /// A reference of one model, made only as it is appended.
    pub const Id = enum(u32) { _ };
};
pub const Operation = struct {
    instruction: std.zig.Zir.Inst.Index,
    node: Ast.Node.Index,
    kind: enum { call, member_call, member, reflection, type_info },

    /// An operation of one model, made only by counting them.
    pub const Id = enum(u32) { _ };
};

pub const LoweredReference = struct { instruction: std.zig.Zir.Inst.Index, token: Ast.TokenIndex, declaration: ?Declaration.Id };

pub const LoweredDeclaration = struct {
    instruction: std.zig.Zir.Inst.Index,
    node: Ast.Node.Index,
    name: []const u8,
    public: bool,
    type_body: ?[]const std.zig.Zir.Inst.Index,
    value_body: ?[]const std.zig.Zir.Inst.Index,
};
pub const InitError = std.mem.Allocator.Error || error{InvalidIdentifier};

pub fn init(file: *File) InitError!Model {
    const a = file.arena.allocator();
    const tree = &file.tree;
    var scopes: std.ArrayList(Scope) = .empty;
    try scopes.append(a, .{ .kind = .file, .node = .root, .first = 0, .last = @intCast(tree.tokens.len - 1) });
    const node_parents = if (tree.errors.len == 0) try parents(a, tree) else try a.alloc(?Ast.Node.Index, 0);
    if (tree.errors.len == 0) try collectScopes(a, tree, node_parents, &scopes);
    std.mem.sort(Scope, scopes.items[1..], {}, scopeLess);
    for (scopes.items, 0..) |*scope, i| scope.id = @fromBackingInt(@intCast(i));
    const token_scopes = try a.alloc(Scope.Id, tree.tokens.len);
    try assignScopes(a, scopes.items, token_scopes);
    var declarations: std.ArrayList(Declaration) = .empty;
    var lowered: std.ArrayList(LoweredDeclaration) = .empty;
    // AstGen can leave uninitialized declaration payloads after rejection.
    // Preserve the failed frontend and never inspect that partial instruction stream.
    if (file.status == .parsed and file.zir != null) for (file.zir.?.instructions.items(.tag), 0..) |tag, index| {
        const zir = file.zir.?;
        if (tag != .declaration) continue;
        const instruction: std.zig.Zir.Inst.Index = @fromBackingInt(@intCast(index));
        const decl = zir.getDeclaration(instruction);
        try lowered.append(a, .{ .instruction = instruction, .node = decl.src_node, .name = zir.nullTerminatedString(decl.name), .public = decl.is_pub, .type_body = decl.type_body, .value_body = decl.value_body });
    };
    if (tree.errors.len == 0) try collectDeclarations(a, tree, token_scopes, scopes.items, &declarations);
    const by_node = try a.alloc(?std.zig.Zir.Inst.Index, tree.nodes.len);
    @memset(by_node, null);
    for (lowered.items) |decl| {
        by_node[@backingInt(decl.node)] = decl.instruction; // safe: enum identities index their owning frozen tables without narrowing.
        if (tree.nodeTag(decl.node) == .fn_decl) by_node[@backingInt(tree.nodeData(decl.node).node_and_node[0])] = decl.instruction; // safe: enum identities index their owning frozen tables without narrowing.
    }
    for (declarations.items) |*decl| decl.lowered = by_node[@backingInt(decl.node)]; // safe: enum identities index their owning frozen tables without narrowing.
    const node_references = try a.alloc(?Reference.Id, tree.nodes.len);
    @memset(node_references, null);
    const node_operations = try a.alloc(?Operation.Id, tree.nodes.len);
    @memset(node_operations, null);
    var operations: std.ArrayList(Operation) = .empty;
    var model: Model = .{ .scopes = scopes.items, .declarations = declarations.items, .references = &.{}, .token_scopes = token_scopes, .node_references = node_references, .node_parents = node_parents, .zir_declarations = lowered.items, .zir_references = &.{}, .operations = &.{}, .node_operations = node_operations, .unknown_references = 0, .import_nodes = &.{}, .lowered_coverage = if (file.status != .parsed) .invalid_front_end else if (file.zir == null) .not_requested else .partial };
    var references: std.ArrayList(Reference) = .empty;
    var import_nodes: std.ArrayList(Ast.Node.Index) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, index| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(index));
        switch (tag) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) try import_nodes.append(a, node),
            else => {},
        }
        if (tag != .identifier and tag != .enum_literal and tag != .test_decl) continue; // safe: std node/token/instruction indexes and bounded table lengths fit u32.
        const token = if (tag == .test_decl) tree.nodeData(node).opt_token_and_node[0].unwrap() orelse continue else tree.nodeMainToken(node);
        if (tree.tokenTag(token) != .identifier) continue;
        const name = try identifier(a, tree.tokenSlice(token));
        if (std.mem.eql(u8, name, "_") or std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false") or std.mem.eql(u8, name, "null") or std.mem.eql(u8, name, "undefined")) continue;
        const decl = model.lookup(token_scopes[token], name, token);
        var ref_record: Reference = .{ .token = token, .node = node, .declaration = decl };
        if (tag == .enum_literal) {
            ref_record.unknown = .literal_context;
            model.unknown_references += 1;
            if (decl) |d| model.declarations[@backingInt(d)].references += 1;
        } else if (decl) |d| model.declarations[@backingInt(d)].references += 1 else {
            ref_record.unknown = if (primitive(name)) .primitive else .unresolved;
            if (ref_record.unknown.? != .primitive) model.unknown_references += 1;
        }
        try references.append(a, ref_record);
        node_references[index] = @fromBackingInt(@intCast(references.items.len - 1));
    }
    model.references = try references.toOwnedSlice(a);
    model.import_nodes = try import_nodes.toOwnedSlice(a);
    if (file.status == .parsed and file.zir != null) {
        var zir_refs: std.ArrayList(LoweredReference) = .empty;
        const visited = try a.alloc(bool, file.zir.?.instructions.len);
        @memset(visited, false);
        for (lowered.items) |decl| {
            const baseline = tree.nodeMainToken(decl.node);
            if (decl.type_body) |body| try walkLowered(a, file.zir.?, body, baseline, decl.node, tree, &model, visited, &zir_refs, &operations, 0);
            if (decl.value_body) |body| try walkLowered(a, file.zir.?, body, baseline, decl.node, tree, &model, visited, &zir_refs, &operations, 0);
        }
        model.zir_references = try zir_refs.toOwnedSlice(a);
        model.operations = try operations.toOwnedSlice(a);
        for (model.operations, 0..) |operation, i| node_operations[@backingInt(operation.node)] = @fromBackingInt(@intCast(i));
    }

    try classifyTests(a, tree, &model);
    return model;
}

fn classifyTests(a: std.mem.Allocator, tree: *const Ast, model: *Model) InitError!void {
    for (model.scopes) |*scope| {
        if (scope.kind != .branch) continue;
        var parent = model.parentOf(scope.node);
        while (parent) |node| {
            if (tree.fullIf(node)) |condition| {
                const polarity = try testCondition(a, tree, model, condition.ast.cond_expr, 0) orelse break;
                if ((polarity and scope.node == condition.ast.then_expr) or (!polarity and condition.ast.else_expr.unwrap() == scope.node)) scope.kind = .@"test";
                break;
            }
            parent = model.parentOf(node);
        }
    }
}

// Only a real builtin import (possibly through lexical aliases) establishes test context.
fn testCondition(a: std.mem.Allocator, tree: *const Ast, model: *const Model, node: Ast.Node.Index, depth: usize) InitError!?bool {
    if (depth >= 32) return null;
    switch (tree.nodeTag(node)) {
        .bool_not => return if (try testCondition(a, tree, model, tree.nodeData(node).node, depth + 1)) |v| !v else null,
        .grouped_expression => return testCondition(a, tree, model, tree.nodeData(node).node_and_token[0], depth + 1),
        .@"comptime" => return testCondition(a, tree, model, tree.nodeData(node).node, depth + 1),
        .field_access => {
            const data = tree.nodeData(node).node_and_token;
            if (!std.mem.eql(u8, try identifier(a, tree.tokenSlice(data[1])), "is_test")) return null;
            return if (try builtinAlias(a, tree, model, data[0], depth + 1)) true else null;
        },
        else => return null,
    }
}

/// The build modes a compile-time condition over `builtin.mode` holds in: `mode == .debug`,
/// `!=`, `!`, `and`, `or`, `true` and `false`, through the builtin import's and the mode's
/// lexical aliases and a constant that names such a condition. Null for anything else.
pub fn modes(a: std.mem.Allocator, tree: *const Ast, model: *const Model, node: Ast.Node.Index, depth: usize) InitError!?Modes {
    if (depth >= 32) return null;
    switch (tree.nodeTag(node)) {
        .bool_not => return if (try modes(a, tree, model, tree.nodeData(node).node, depth + 1)) |held| held.complement() else null,
        .grouped_expression => return modes(a, tree, model, tree.nodeData(node).node_and_token[0], depth + 1),
        .@"comptime" => return modes(a, tree, model, tree.nodeData(node).node, depth + 1),
        .bool_and, .bool_or => {
            const sides = tree.nodeData(node).node_and_node;
            const left = (try modes(a, tree, model, sides[0], depth + 1)) orelse return null;
            const right = (try modes(a, tree, model, sides[1], depth + 1)) orelse return null;
            return if (tree.nodeTag(node) == .bool_and) left.intersectWith(right) else left.unionWith(right);
        },
        .equal_equal, .bang_equal => {
            const sides = tree.nodeData(node).node_and_node;
            const named = for ([_][2]Ast.Node.Index{ sides, .{ sides[1], sides[0] } }) |pair| {
                if (tree.nodeTag(pair[1]) != .enum_literal or !try modeValue(a, tree, model, pair[0], depth + 1)) continue;
                break std.meta.stringToEnum(std.builtin.OptimizeMode, try identifier(a, tree.tokenSlice(tree.nodeMainToken(pair[1])))) orelse return null;
            } else return null;
            const equal: Modes = .initOne(named);
            return if (tree.nodeTag(node) == .equal_equal) equal else equal.complement();
        },
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            if (std.mem.eql(u8, name, "true")) return .full;
            if (std.mem.eql(u8, name, "false")) return .empty;
            const ref = model.reference(node) orelse return null;
            const d = ref.declaration orelse return null;
            const v = tree.fullVarDecl(model.declarations[@backingInt(d)].node) orelse return null;
            if (tree.tokenTag(v.ast.mut_token) != .keyword_const) return null;
            return modes(a, tree, model, v.ast.init_node.unwrap() orelse return null, depth + 1);
        },
        else => return null,
    }
}
/// A set of build modes.
pub const Modes = std.EnumSet(std.builtin.OptimizeMode);

/// Whether `node` is `builtin.mode`, through lexical aliases.
fn modeValue(a: std.mem.Allocator, tree: *const Ast, model: *const Model, node: Ast.Node.Index, depth: usize) InitError!bool {
    if (depth >= 32) return false;
    switch (tree.nodeTag(node)) {
        .identifier => {
            const ref = model.reference(node) orelse return false;
            const d = ref.declaration orelse return false;
            const v = tree.fullVarDecl(model.declarations[@backingInt(d)].node) orelse return false;
            if (tree.tokenTag(v.ast.mut_token) != .keyword_const) return false;
            return modeValue(a, tree, model, v.ast.init_node.unwrap() orelse return false, depth + 1);
        },
        .field_access => {
            const data = tree.nodeData(node).node_and_token;
            if (!std.mem.eql(u8, try identifier(a, tree.tokenSlice(data[1])), "mode")) return false;
            return builtinAlias(a, tree, model, data[0], depth + 1);
        },
        else => return false,
    }
}

fn builtinAlias(a: std.mem.Allocator, tree: *const Ast, model: *const Model, node: Ast.Node.Index, depth: usize) InitError!bool {
    if (depth >= 32) return false;
    if (tree.nodeTag(node) == .identifier) {
        const ref = model.reference(node) orelse return false;
        const d = ref.declaration orelse return false;
        const v = tree.fullVarDecl(model.declarations[@backingInt(d)].node) orelse return false;
        return if (v.ast.init_node.unwrap()) |init_node| builtinAlias(a, tree, model, init_node, depth + 1) else false;
    }
    var buffer: [2]Ast.Node.Index = undefined;
    const args = tree.builtinCallParams(&buffer, node) orelse return false;
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import") or args.len != 1 or tree.nodeTag(args[0]) != .string_literal) return false;
    const value = std.zig.string_literal.parseAlloc(a, tree.tokenSlice(tree.nodeMainToken(args[0]))) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return std.mem.eql(u8, value, "builtin");
}

fn parents(a: std.mem.Allocator, tree: *const Ast) InitError![]const ?Ast.Node.Index {
    const Span = struct { node: Ast.Node.Index, first: Ast.TokenIndex, last: Ast.TokenIndex };
    const ordered = try a.alloc(Span, tree.nodes.len - 1);
    for (ordered, 1..) |*span, n| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
        span.* = .{ .node = node, .first = tree.firstToken(node), .last = tree.lastToken(node) };
    }
    std.mem.sort(Span, ordered, {}, struct {
        fn less(_: void, l: Span, r: Span) bool {
            if (l.first != r.first) return l.first < r.first;
            return if (l.last != r.last) l.last > r.last else @backingInt(l.node) > @backingInt(r.node); // safe: enum identities index their owning frozen tables without narrowing.
        }
    }.less);
    const result = try a.alloc(?Ast.Node.Index, tree.nodes.len);
    @memset(result, null);
    var stack: std.ArrayList(Span) = .empty;
    for (ordered) |span| {
        while (stack.items.len != 0 and stack.items[stack.items.len - 1].last < span.last) _ = stack.pop();
        result[@backingInt(span.node)] = if (stack.items.len != 0) stack.items[stack.items.len - 1].node else .root; // safe: enum identities index their owning frozen tables without narrowing.
        try stack.append(a, span);
    }
    return result;
}

fn walkLowered(a: std.mem.Allocator, zir: std.zig.Zir, body: []const std.zig.Zir.Inst.Index, baseline: Ast.TokenIndex, baseline_node: Ast.Node.Index, tree: *const Ast, model: *Model, visited: []bool, refs: *std.ArrayList(LoweredReference), operations: *std.ArrayList(Operation), depth: usize) InitError!void {
    if (depth >= 128) {
        model.lowered_coverage = .budget_exhausted;
        return;
    }
    const Inst = std.zig.Zir.Inst;
    for (body) |instruction| {
        const i = @backingInt(instruction); // safe: enum identities index their owning frozen tables without narrowing.
        if (visited[i]) continue;
        visited[i] = true;
        const tag = zir.instructions.items(.tag)[i];
        const data = zir.instructions.items(.data)[i];
        switch (tag) {
            .call, .field_call, .field_ptr, .field_ptr_load, .field_ptr_named, .field_ptr_named_load, .has_decl, .type_info => {
                const node = (if (tag == .type_info) data.un_node.src_node else data.pl_node.src_node).toAbsolute(baseline_node);
                if (@backingInt(node) >= tree.nodes.len) { // safe: reject source mappings outside the frozen AST.
                    model.lowered_coverage = .budget_exhausted;
                    continue;
                }
                try operations.append(a, .{ .instruction = instruction, .node = node, .kind = switch (tag) {
                    .call => .call,
                    .field_call => .member_call,
                    .field_ptr, .field_ptr_load => .member,
                    .type_info => .type_info,
                    else => .reflection,
                } });
                if (tag == .call or tag == .field_call) {
                    const flags = if (tag == .call) zir.extraData(Inst.Call, data.pl_node.payload_index).data.flags else zir.extraData(Inst.FieldCall, data.pl_node.payload_index).data.flags;
                    const end = if (tag == .call) zir.extraData(Inst.Call, data.pl_node.payload_index).end else zir.extraData(Inst.FieldCall, data.pl_node.payload_index).end;
                    if (flags.args_len != 0) {
                        const final_end = zir.extra[end + flags.args_len - 1];
                        try walkLowered(a, zir, zir.bodySlice(end + flags.args_len, final_end - flags.args_len), baseline, baseline_node, tree, model, visited, refs, operations, depth + 1);
                    }
                }
            },
            .@"defer" => try walkLowered(a, zir, zir.bodySlice(data.@"defer".index, data.@"defer".len), baseline, baseline_node, tree, model, visited, refs, operations, depth + 1),
            .decl_ref, .decl_val => {
                const token = data.str_tok.src_tok.toAbsolute(baseline);
                if (token >= tree.tokens.len) continue;
                const name = zir.nullTerminatedString(data.str_tok.start);
                try refs.append(a, .{ .instruction = instruction, .token = token, .declaration = model.lookup(model.scopeOf(token), name, token) });
            },
            .func, .func_inferred, .func_fancy => {
                const info = zir.getFnInfo(instruction);
                try walkLowered(a, zir, info.param_body, baseline, baseline_node, tree, model, visited, refs, operations, depth + 1);
                try walkLowered(a, zir, info.ret_ty_body, baseline, baseline_node, tree, model, visited, refs, operations, depth + 1);
                try walkLowered(a, zir, info.body, baseline, baseline_node, tree, model, visited, refs, operations, depth + 1);
            },
            .block, .block_inline, .loop => {
                const extra = zir.extraData(Inst.Block, data.pl_node.payload_index);
                try walkLowered(a, zir, zir.bodySlice(extra.end, extra.data.body_len), baseline, baseline_node, tree, model, visited, refs, operations, depth + 1);
            },
            .block_comptime => {
                const extra = zir.extraData(Inst.BlockComptime, data.pl_node.payload_index);
                try walkLowered(a, zir, zir.bodySlice(extra.end, extra.data.body_len), baseline, baseline_node, tree, model, visited, refs, operations, depth + 1);
            },
            .condbr, .condbr_inline => {
                const extra = zir.extraData(Inst.CondBr, data.pl_node.payload_index);
                try walkLowered(a, zir, zir.bodySlice(extra.end, extra.data.then_body_len + extra.data.else_body_len), baseline, baseline_node, tree, model, visited, refs, operations, depth + 1);
            },
            .@"try", .try_ptr => {
                const extra = zir.extraData(Inst.Try, data.pl_node.payload_index);
                try walkLowered(a, zir, zir.bodySlice(extra.end, extra.data.body_len), baseline, baseline_node, tree, model, visited, refs, operations, depth + 1);
            },
            .param, .param_comptime => {
                const extra = zir.extraData(Inst.Param, data.pl_tok.payload_index);
                try walkLowered(a, zir, zir.bodySlice(extra.end, extra.data.type.body_len), baseline, baseline_node, tree, model, visited, refs, operations, depth + 1);
            },
            else => {}, // No alternate IR: unsupported structured instruction coverage stays in std ZIR.
        }
    }
}

pub fn lookup(self: *const Model, start: Scope.Id, name: []const u8, token: Ast.TokenIndex) ?Declaration.Id {
    var scope: ?Scope.Id = start;
    while (scope) |s| {
        const each = &self.scopes[@backingInt(s)];
        if (each.names.get(name)) |decl| {
            const d = self.declarations[@backingInt(decl)];
            if (each.kind == .file or each.kind == .container or d.token <= token) return decl;
        }
        scope = each.parent;
    }
    return null;
}

/// The file's own scope, which holds every other.
pub fn root(self: *const Model) Scope.Id {
    return self.scopes[0].id;
}

/// The scope holding `token`; the file's own for a token past the file's.
pub fn scopeOf(self: *const Model, token: Ast.TokenIndex) Scope.Id {
    return if (token < self.token_scopes.len) self.token_scopes[token] else self.root();
}

/// The node `node` is part of; null for the root, and for a node past the file's tree.
pub fn parentOf(self: *const Model, node: Ast.Node.Index) ?Ast.Node.Index {
    const index = @backingInt(node);
    return if (index < self.node_parents.len) self.node_parents[index] else null;
}

/// The reference an identifier is; null for any other node, and for a node past the file's tree.
pub fn reference(self: *const Model, node: Ast.Node.Index) ?Reference {
    const index = @backingInt(node);
    if (index >= self.node_references.len) return null;
    return if (self.node_references[index]) |id| self.references[@backingInt(id)] else null;
}

/// The operation the lowering made of `node`; null for none, and for a node past the file's tree.
pub fn operationOf(self: *const Model, node: Ast.Node.Index) ?Operation {
    const index = @backingInt(node);
    if (index >= self.node_operations.len) return null;
    return if (self.node_operations[index]) |id| self.operations[@backingInt(id)] else null;
}

fn scopeLess(_: void, lhs: Scope, rhs: Scope) bool {
    if (lhs.first != rhs.first) return lhs.first < rhs.first;
    if (lhs.last != rhs.last) return lhs.last > rhs.last;
    // A branch whose expression is a container (`.windows => struct { ... }`) spans the same
    // tokens: the container is the inner scope, so its members are its own. A branch's or a
    // loop's body that is a block is the block's scope, so its declarations are the block's.
    return inner(lhs.kind) < inner(rhs.kind);
}

fn inner(kind: Kind) u2 {
    return switch (kind) {
        .container => 2,
        .block => 1,
        else => 0,
    };
}

fn addScope(a: std.mem.Allocator, tree: *const Ast, list: *std.ArrayList(Scope), node: Ast.Node.Index, kind: Kind) InitError!void {
    try list.append(a, .{ .kind = kind, .node = node, .first = tree.firstToken(node), .last = tree.lastToken(node) });
}

fn collectScopes(a: std.mem.Allocator, tree: *const Ast, node_parents: []const ?Ast.Node.Index, list: *std.ArrayList(Scope)) InitError!void {
    for (tree.nodes.items(.tag), 0..) |tag, index| {
        if (index == 0) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(index));
        var container_buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&container_buffer, node) != null) {
            try addScope(a, tree, list, node, .container);
            continue;
        }
        var fn_buffer: [1]Ast.Node.Index = undefined;
        if (tag != .fn_decl and tree.fullFnProto(&fn_buffer, node) != null) {
            const p = node_parents[index];
            if (p == null or tree.nodeTag(p.?) != .fn_decl) try addScope(a, tree, list, node, .function);
        }
        switch (tag) {
            .fn_decl => try addScope(a, tree, list, node, .function),
            .block, .block_semicolon, .block_two, .block_two_semicolon => try addScope(a, tree, list, node, .block),
            .test_decl => try addScope(a, tree, list, node, .@"test"),
            .@"comptime" => try addScope(a, tree, list, node, .@"comptime"),
            else => {},
        }
        if (tree.fullIf(node)) |value| {
            try addScope(a, tree, list, value.ast.then_expr, .branch);
            if (value.ast.else_expr.unwrap()) |other| try addScope(a, tree, list, other, .branch);
        }
        if (tree.fullWhile(node)) |value| {
            // The body's scope, from the continue expression on: a capture is visible there too.
            const body = value.ast.then_expr;
            try list.append(a, .{ .kind = .loop, .node = body, .first = tree.firstToken(value.ast.cont_expr.unwrap() orelse body), .last = tree.lastToken(body) });
            if (value.ast.else_expr.unwrap()) |other| try addScope(a, tree, list, other, .branch);
        }
        if (tag == .@"catch") try addScope(a, tree, list, tree.nodeData(node).node_and_node[1], .branch);
        if (tree.fullSwitchCase(node)) |value| try addScope(a, tree, list, value.ast.target_expr, .branch);
        if (tree.fullFor(node)) |value| {
            try addScope(a, tree, list, value.ast.then_expr, .loop);
        }
    }
}

fn assignScopes(a: std.mem.Allocator, scopes: []Scope, tokens: []Scope.Id) InitError!void {
    var stack: std.ArrayList(Scope.Id) = .empty;
    try stack.append(a, scopes[0].id);
    var next: usize = 1;
    for (tokens, 0..) |*out, token| {
        while (stack.items.len > 1 and scopes[@backingInt(stack.items[stack.items.len - 1])].last < token) _ = stack.pop();
        while (next < scopes.len and scopes[next].first == token) : (next += 1) {
            scopes[next].parent = stack.items[stack.items.len - 1];
            try stack.append(a, scopes[next].id);
        }
        out.* = stack.items[stack.items.len - 1];
    }
}

fn addDeclaration(a: std.mem.Allocator, tree: *const Ast, scopes: []Scope, list: *std.ArrayList(Declaration), decl: Declaration) InitError!void {
    var value = decl;
    value.name = try identifier(a, tree.tokenSlice(decl.token));
    if (std.mem.eql(u8, value.name, "_")) return;
    try list.append(a, value);
    const id: Declaration.Id = @fromBackingInt(@intCast(list.items.len - 1));
    if (value.kind != .field) try scopes[@backingInt(value.scope)].names.put(a, value.name, id);
}

fn enclosing(scopes: []const Scope, start: Scope.Id, kind: Kind) ?Scope.Id {
    var scope: ?Scope.Id = start;
    while (scope) |s| {
        if (scopes[@backingInt(s)].kind == kind) return s;
        scope = scopes[@backingInt(s)].parent;
    }
    return null;
}

fn declarationScope(scopes: []const Scope, start: Scope.Id) Scope.Id {
    var result = start;
    while (true) switch (scopes[@backingInt(result)].kind) {
        .function, .@"test", .@"comptime" => result = scopes[@backingInt(result)].parent orelse break,
        else => break,
    };
    return result;
}

fn collectDeclarations(a: std.mem.Allocator, tree: *const Ast, tokens: []const Scope.Id, scopes: []Scope, list: *std.ArrayList(Declaration)) InitError!void {
    for (tree.nodes.items(.tag), 0..) |tag, index| {
        if (index == 0) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(index));
        if (tree.fullVarDecl(node)) |value| {
            const token = value.ast.mut_token + 1;
            try addDeclaration(a, tree, scopes, list, .{ .name = "", .node = node, .token = token, .scope = tokens[token], .kind = .variable, .public = value.visib_token != null, .exported = if (value.extern_export_token) |t| tree.tokenTag(t) == .keyword_export else false });
        }
        var fn_buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&fn_buffer, node)) |function| {
            // fullFnProto also accepts fn_decl. Its proto node occurs separately.
            if (tag == .fn_decl) continue;
            if (function.name_token) |token| {
                try addDeclaration(a, tree, scopes, list, .{ .name = "", .node = node, .token = token, .scope = declarationScope(scopes, tokens[token]), .kind = .function, .public = function.visib_token != null, .exported = if (function.extern_export_inline_token) |t| tree.tokenTag(t) == .keyword_export else false });
            }
            const function_scope = enclosing(scopes, tokens[function.ast.fn_token], .function) orelse tokens[function.ast.fn_token];
            var it = function.iterate(tree);
            while (it.next()) |param| if (param.name_token) |token| {
                try addDeclaration(a, tree, scopes, list, .{ .name = "", .node = param.type_expr orelse node, .token = token, .scope = function_scope, .kind = .parameter });
            };
        }
        if (tree.fullContainerField(node)) |field| if (!field.ast.tuple_like) {
            try addDeclaration(a, tree, scopes, list, .{ .name = "", .node = node, .token = field.ast.main_token, .scope = tokens[field.ast.main_token], .kind = .field });
        };
        if (tree.fullIf(node)) |value| {
            if (value.payload_token) |token| try capture(a, tree, scopes, list, token, tokens[tree.firstToken(value.ast.then_expr)], node);
            if (value.error_token) |token| if (value.ast.else_expr.unwrap()) |body| try capture(a, tree, scopes, list, token, tokens[tree.firstToken(body)], node);
        }
        if (tree.fullWhile(node)) |value| {
            // The loop's scope, which holds its continue expression and its body.
            const loop = for (scopes) |scope| {
                if (scope.kind == .loop and scope.node == value.ast.then_expr) break scope.id;
            } else tokens[tree.firstToken(value.ast.then_expr)];
            if (value.payload_token) |token| try capture(a, tree, scopes, list, token, loop, node);
            if (value.error_token) |token| if (value.ast.else_expr.unwrap()) |body| try capture(a, tree, scopes, list, token, tokens[tree.firstToken(body)], node);
        }
        if (tag == .@"catch") {
            const token = tree.nodeMainToken(node);
            const body = tree.nodeData(node).node_and_node[1];
            if (tree.tokenTag(token + 1) == .pipe) try capture(a, tree, scopes, list, token + 2, tokens[tree.firstToken(body)], node);
        }
        if (tree.fullSwitchCase(node)) |value| if (value.payload_token) |token| {
            const scope = tokens[tree.firstToken(value.ast.target_expr)];
            try capture(a, tree, scopes, list, token, scope, node);
            const name = if (tree.tokenTag(token) == .asterisk) token + 1 else token;
            if (tree.tokenTag(name + 1) == .comma) try capture(a, tree, scopes, list, name + 2, scope, node);
        };
        if (tree.fullFor(node)) |value| {
            var token = value.payload_token;
            while (tree.tokenTag(token) != .pipe) : (token += 1) {
                if (tree.tokenTag(token) == .identifier) try capture(a, tree, scopes, list, token, tokens[tree.firstToken(value.ast.then_expr)], node);
            }
        }
    }
}

fn capture(a: std.mem.Allocator, tree: *const Ast, scopes: []Scope, list: *std.ArrayList(Declaration), token: Ast.TokenIndex, scope: Scope.Id, node: Ast.Node.Index) InitError!void {
    const name = if (tree.tokenTag(token) == .asterisk) token + 1 else token;
    try addDeclaration(a, tree, scopes, list, .{ .name = "", .node = node, .token = name, .scope = scope, .kind = .capture });
}

/// The name a struct literal's field value is given under (`.name = value`): two tokens before
/// the value.
pub fn initName(tree: *const Ast, value: Ast.Node.Index) ?Ast.TokenIndex {
    const at = tree.firstToken(value);
    if (at < 2) return null;
    return at - 2;
}

/// Whether a function's return type is written after `!`: its error set is inferred.
pub fn inferredErrors(tree: *const Ast, return_type: Ast.Node.Index) bool {
    const first = tree.firstToken(return_type);
    return first > 0 and tree.tokenTag(first - 1) == .bang;
}

/// The position among a `for` loop's captures of the one named at `token`, a discarded `_`
/// counted: the input it takes is the loop's input at that position.
pub fn capturePosition(tree: *const Ast, loop: Ast.full.For, token: Ast.TokenIndex) ?usize {
    var position: usize = 0;
    var at = loop.payload_token;
    while (tree.tokenTag(at) != .pipe) : (at += 1) {
        if (at == token) return position;
        if (tree.tokenTag(at) == .comma) position += 1;
    }
    return null;
}

pub fn identifier(a: std.mem.Allocator, raw: []const u8) InitError![]const u8 {
    if (!std.mem.startsWith(u8, raw, "@\"")) return raw;
    return std.zig.string_literal.parseAlloc(a, raw[1..]) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidLiteral => error.InvalidIdentifier,
    };
}

pub fn primitive(name: []const u8) bool {
    if (name.len > 1 and (name[0] == 'u' or name[0] == 'i') and std.ascii.isDigit(name[1])) {
        for (name[1..]) |c| if (!std.ascii.isDigit(c)) return false;
        return true;
    }
    return std.StaticStringMap(void).initComptime(.{
        .{ "bool", {} },      .{ "void", {} },         .{ "noreturn", {} },       .{ "type", {} },        .{ "anyerror", {} },
        .{ "anyopaque", {} }, .{ "comptime_int", {} }, .{ "comptime_float", {} }, .{ "usize", {} },       .{ "isize", {} },
        .{ "f16", {} },       .{ "f32", {} },          .{ "f64", {} },            .{ "f80", {} },         .{ "f128", {} },
        .{ "c_char", {} },    .{ "c_short", {} },      .{ "c_ushort", {} },       .{ "c_int", {} },       .{ "c_uint", {} },
        .{ "c_long", {} },    .{ "c_ulong", {} },      .{ "c_longlong", {} },     .{ "c_ulonglong", {} }, .{ "c_longdouble", {} },
    }).has(name);
}

test "binding distinguishes strings and conservatively retains declaration literals" {
    var file = try File.init(std.testing.allocator, "const unused = @import(\"unused\"); const used = @import(\"used\"); pub fn f() void { _ = used; _ = .unused; _ = \"unused\"; }", .{});
    defer file.deinit();
    const model = try init(&file);
    try std.testing.expectEqual(@as(u32, 1), model.declarations[0].references); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expectEqual(@as(u32, 1), model.declarations[1].references); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expect(model.zir_declarations.len >= 3);
}

test "binding keeps enclosing containers and captures" {
    var file = try File.init(std.testing.allocator, "const Outer = struct { pub const Value = struct {}; pub fn f(x: ?Value) void { if (x) |value| { _ = value; } } };", .{});
    defer file.deinit();
    const model = try init(&file);
    var captured = false;
    for (model.declarations) |decl| if (decl.kind == .capture) {
        captured = true;
        try std.testing.expectEqual(@as(u32, 1), decl.references); // safe: explicit compile-time type selection; the value is representable in that type.
    };
    try std.testing.expect(captured);
    try std.testing.expectEqual(@as(usize, 0), model.unknown_references); // safe: explicit compile-time type selection; the value is representable in that type.
}

test "binding isolates catch and switch captures from outside scopes" {
    var file = try File.init(std.testing.allocator, "pub fn f(v: union(enum) { a: u8, b: void }) !u8 { const x = g() catch |err| return err; return switch (v) { .a => |value| value + x, .b => x }; } fn g() !u8 { return 1; }", .{});
    defer file.deinit();
    const model = try init(&file);
    var captures: usize = 0;
    for (model.declarations) |decl| if (decl.kind == .capture) {
        captures += 1;
        try std.testing.expectEqual(@as(u32, 1), decl.references); // safe: explicit compile-time type selection; the value is representable in that type.
    };
    try std.testing.expectEqual(@as(usize, 2), captures); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expectEqual(@as(usize, 2), model.unknown_references); // safe: two declaration literals retain unknown type context; captures remain resolved.
}

test "binding destructuring declares separate locals and tracks mutation references" {
    var file = try File.init(std.testing.allocator, "pub fn f() u8 { const a, var b = .{ @as(u8, 1), @as(u8, 2) }; b += 1; return a + b; }", .{});
    defer file.deinit();
    const model = try init(&file);
    var locals: usize = 0;
    for (model.declarations) |decl| if (decl.kind == .variable) {
        locals += 1;
        try std.testing.expectEqual(@as(u32, if (std.mem.eql(u8, decl.name, "b")) 2 else 1), decl.references); // safe: explicit compile-time type selection; the value is representable in that type.
    };
    try std.testing.expectEqual(@as(usize, 2), locals); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expectEqual(@as(usize, 0), model.unknown_references); // safe: explicit compile-time type selection; the value is representable in that type.
}

test "morning named tests retain declaration references" {
    var file = try File.init(std.testing.allocator, "fn target() void {} test target {}", .{});
    defer file.deinit();
    const model = try init(&file);
    try std.testing.expectEqual(@as(u32, 1), model.declarations[0].references); // safe: one named test reference.
}
