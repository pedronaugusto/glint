//! Optional explicitly adopted published-type obligations. No security or lifetime proof.
const std = @import("std");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const Context = @import("RuleContext.zig");
const Contract = @import("AegisContract.zig");
const Rule = @import("Rule.zig").Rule;
const Ast = std.zig.Ast;
pub const access: Rule = @fromBackingInt(@intCast(1100)); // safe: compiled pack identities are reserved stable u16 values.
pub const copies: Rule = @fromBackingInt(@intCast(1101)); // safe: compiled pack identities are reserved stable u16 values.
pub const cleanup: Rule = @fromBackingInt(@intCast(1102)); // safe: compiled pack identities are reserved stable u16 values.
pub const scalar: Rule = @fromBackingInt(@intCast(1103)); // safe: compiled pack identities are reserved stable u16 values.
pub const capacity: Rule = @fromBackingInt(@intCast(1104)); // safe: compiled pack identities are reserved stable u16 values.
pub const rules = [_]Context.Rule{
    .{ .definition = .{ .id = access, .name = "A001", .group = .family_policy, .purpose = "secret disclosure or shared-state access without a live capability", .version = 2, .exception = .aegis }, .check = checkAccess },
    .{ .definition = .{ .id = copies, .name = "A002", .group = .family_policy, .purpose = "duplicated secret owner or lock capability; borrowed storage escapes", .version = 2, .exception = .aegis }, .check = checkCopies },
    .{ .definition = .{ .id = cleanup, .name = "A003", .group = .family_policy, .purpose = "missing owner cleanup or use after cleanup/transfer on a supported local path", .version = 2, .exception = .aegis }, .check = checkCleanup },
    .{ .definition = .{ .id = scalar, .name = "A004", .group = .family_policy, .purpose = "domain/unit or all-build integer checks bypassed by raw arithmetic/casts", .version = 2, .exception = .aegis }, .check = checkScalar },
    .{ .definition = .{ .id = capacity, .name = "A005", .group = .family_policy, .purpose = "SecretBytes adoption truncates wipe capacity or lacks proven allocation ownership", .version = 2, .exception = .aegis }, .check = checkCapacity },
};
/// Starts a check of this file. The library's own files are its safe-type internals, and a
/// published member that no longer resolves is reported where the library is imported, so a
/// renamed declaration cannot make a gate quietly stop seeing it.
fn begin(c: *Context, rule: Rule) Context.Error!bool {
    if (try c.inLibrary(Contract.library, c.file)) return false;
    if (try c.drift(Contract.library)) |gap| {
        const detail = try c.allocator.print("published member {s} of {s} does not resolve ({t}); its operations are not recognized in this file", .{ gap.path, gap.module, gap.why });
        try c.undecided(rule, gap.start, .unresolved, detail);
    }
    return true;
}
fn checkAccess(c: *Context) Context.Error!void {
    if (!try begin(c, access)) return;
    const tree = try c.project.syntax(try c.source());
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .field_access) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: AST node table supplies bounded indexes.
        const data = tree.nodeData(node).node_and_token;
        const name = try Model.identifier(c.allocator, tree.tokenSlice(data[1]));
        if (!backingName(name)) continue;
        const k = (try requiredOwner(c, data[0], access, data[1])) orelse continue;
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
fn backingName(name: []const u8) bool {
    for ([_][]const u8{ "material", "allocation", "used_len", "gpa", "data", "lock", "owner" }) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}
fn requiredOwner(c: *Context, node: Ast.Node.Index, rule: Rule, token: Ast.TokenIndex) Context.Error!?Contract.Kind {
    if (try Contract.owner(c, node)) |k| return k;
    switch (try typed(c, try c.facts.resolve(c.file, node), 0)) {
        .owner => |k| return k,
        .other => return null,
        .unknown => {
            const tree = try c.project.syntax(try c.source());
            try c.undecided(rule, tree.tokenStart(token), .unresolved, "candidate receiver/value has no resolved operation contract");
            return null;
        },
    }
}
const Typed = union(enum) { owner: Contract.Kind, other, unknown };
/// Whether `container` is declared inside a published aegis type, as a guarded value's guard
/// is: its own operations belong to that type's contract.
fn nestedInPublished(c: *Context, container: Facts.Container) Context.Error!bool {
    const found = try c.facts.publication(Contract.library);
    const scopes = c.project.models[container.file.raw()].scopes; // safe: a resolved container's file indexes the frozen model table.
    var scope = scopes[container.scope].parent;
    while (scope) |s| : (scope = scopes[s].parent) {
        for (found.entries) |entry| if (entry.target == .container and entry.target.container.file.eql(container.file) and entry.target.container.scope == s) return true;
    }
    return false;
}
/// What a resolved value's type says: a published aegis type, a type that is not aegis, or
/// unknown. A type nested in a published one that the contract does not list stays unknown
/// rather than counted out, as does a choice between types that disagree.
fn typed(c: *Context, value: Facts.Value, depth: usize) Context.Error!Typed {
    if (depth == 64) return .unknown;
    return switch (value) {
        .unknown => .unknown,
        .pointer, .array, .optional, .error_union => |payload| typed(c, payload.*, depth + 1),
        .alternatives => |each| blk: {
            const first = try typed(c, each[0], depth + 1);
            for (each[1..]) |one| if (!std.meta.eql(first, try typed(c, one, depth + 1))) break :blk .unknown;
            break :blk first;
        },
        .container, .instance => |container| blk: {
            if (try c.role(Contract.library, value)) |k| break :blk .{ .owner = k };
            break :blk if (try nestedInPublished(c, container)) .unknown else .other;
        },
        else => .other,
    };
}
fn checkCopies(c: *Context) Context.Error!void {
    if (!try begin(c, copies)) return;
    const tree = try c.project.syntax(try c.source());
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: AST node table supplies bounded indexes.
        if (tree.fullVarDecl(node)) |v| {
            const init = v.ast.init_node.unwrap() orelse continue;
            if (tree.nodeTag(init) != .identifier) continue;
            // `undefined`, `true`, `false` and `null` are values, not references to an owner.
            if (c.project.models[c.file.raw()].reference(init) == null) continue; // safe: the checked source handle indexes this frozen model.
            // Plain data, as the copy or its source is declared, holds no owner: the copy is decided.
            if (v.ast.type_node.unwrap()) |t| if (try plainType(c, c.file, t, 0)) continue;
            if (try plainValue(c, c.file, init, 0)) continue;
            // A copied pointer is an alias, which this rule leaves out, whatever it points at.
            if (pointerShaped(try c.facts.resolve(c.file, init))) continue;
            const k = (try requiredOwner(c, init, copies, tree.nodeMainToken(init))) orelse continue;
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
/// Whether a type expression is plain data: a primitive type (`usize`, `bool`, `type`), or an array,
/// slice, pointer, optional or error union of plain data. No aegis owner or capability is such a value.
fn plainType(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: usize) Context.Error!bool {
    if (depth == 64) return false;
    const tree = &c.project.files[file.raw()].tree; // safe: the file handle indexes the frozen project table.
    if (tree.fullPtrType(node)) |ptr| return plainType(c, file, ptr.ast.child_type, depth + 1);
    if (tree.fullArrayType(node)) |array| return plainType(c, file, array.ast.elem_type, depth + 1);
    return switch (tree.nodeTag(node)) {
        .optional_type => plainType(c, file, tree.nodeData(node).node, depth + 1),
        .error_union => plainType(c, file, tree.nodeData(node).node_and_node[1], depth + 1),
        .identifier => try c.facts.resolve(file, node) == .primitive,
        else => false,
    };
}

/// Whether a value is plain data by what is written where it comes from: a literal, a local or
/// parameter declared plain or initialized with plain data, an element or the address of plain data,
/// or the result of a function declared to return plain data.
fn plainValue(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: usize) Context.Error!bool {
    if (depth == 64) return false;
    const tree = &c.project.files[file.raw()].tree; // safe: the file handle indexes the frozen project table.
    const model = &c.project.models[file.raw()]; // safe: the file handle indexes the frozen project table.
    switch (tree.nodeTag(node)) {
        .number_literal, .char_literal, .string_literal => return true,
        .@"comptime", .@"try", .address_of => return plainValue(c, file, tree.nodeData(node).node, depth + 1),
        .grouped_expression => return plainValue(c, file, tree.nodeData(node).node_and_token[0], depth + 1),
        // Arrays joined: plain when what they are made of is.
        .array_cat => {
            const sides = tree.nodeData(node).node_and_node;
            return try plainValue(c, file, sides[0], depth + 1) and try plainValue(c, file, sides[1], depth + 1);
        },
        .array_access => return plainValue(c, file, tree.nodeData(node).node_and_node[0], depth + 1),
        .identifier => {
            const ref = model.reference(node) orelse return false;
            const index = ref.declaration orelse return false;
            const decl = model.declarations[index];
            if (decl.kind == .parameter) return plainType(c, file, decl.node, depth + 1);
            const v = tree.fullVarDecl(decl.node) orelse return false;
            if (v.ast.type_node.unwrap()) |t| return plainType(c, file, t, depth + 1);
            const init = v.ast.init_node.unwrap() orelse return false;
            return plainValue(c, file, init, depth + 1);
        },
        .call_one, .call_one_comma, .call, .call_comma => {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, node).?;
            const decl = (try c.facts.definition(file, call.ast.fn_expr)) orelse return false;
            const origin = (try c.facts.origin(decl)) orelse return false;
            const record = c.project.models[origin.file.raw()].declarations[origin.index]; // safe: the origin indexes its own frozen model.
            if (record.kind != .function) return false;
            const written = &c.project.files[origin.file.raw()].tree; // safe: the origin indexes the frozen project table.
            var proto_buffer: [1]Ast.Node.Index = undefined;
            const proto = written.fullFnProto(&proto_buffer, record.node) orelse return false;
            const result = proto.ast.return_type.unwrap() orelse return false;
            return plainType(c, origin.file, result, depth + 1);
        },
        else => return false,
    }
}

fn pointerShaped(value: Facts.Value) bool {
    return switch (value) {
        .pointer => true,
        .optional => |inner| inner.* == .pointer,
        else => false,
    };
}
fn ownedValue(c: *Context, node: Ast.Node.Index, depth: usize) Context.Error!bool {
    if (depth == 64) return false;
    const tree = try c.project.syntax(try c.source());
    const index = Contract.local(c, node) orelse return false;
    const decl = c.project.models[c.file.raw()].declarations[index];
    if (decl.kind == .parameter) return tree.fullPtrType(decl.node) == null and try Contract.owner(c, decl.node) != null;
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
    const name = try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]));
    return std.mem.eql(u8, name, "init") or std.mem.eql(u8, name, "adopt") or std.mem.eql(u8, name, "acquire");
}

fn exposure(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const data = tree.nodeData(call.ast.fn_expr).node_and_token;
    const name = try Model.identifier(c.allocator, tree.tokenSlice(data[1]));
    if (!std.mem.eql(u8, name, "expose") and !std.mem.eql(u8, name, "exposeMut") and !std.mem.eql(u8, name, "value")) return false;
    const k = (try requiredOwner(c, data[0], copies, data[1])) orelse return false;
    return ((k == .secret or k == .bytes) and (std.mem.eql(u8, name, "expose") or std.mem.eql(u8, name, "exposeMut"))) or (k == .guard and std.mem.eql(u8, name, "value"));
}
fn checkCleanup(c: *Context) Context.Error!void {
    if (!try begin(c, cleanup)) return;
    const tree = try c.project.syntax(try c.source());
    const model = &c.project.models[c.file.raw()];
    for (model.declarations) |decl| {
        if (decl.kind != .variable or model.scopes[decl.scope].kind != .block) continue;
        const v = tree.fullVarDecl(decl.node) orelse continue;
        const init = v.ast.init_node.unwrap() orelse continue;
        // Only actual acquisition expressions, never an owner alias or type alias.
        var call_buffer: [1]Ast.Node.Index = undefined;
        const acquisition = if (tree.nodeTag(init) == .@"try") tree.nodeData(init).node else init;
        const acquired = tree.fullCall(&call_buffer, acquisition) orelse continue;
        if (tree.nodeTag(acquired.ast.fn_expr) != .field_access) continue;
        const operation = try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(acquired.ast.fn_expr).node_and_token[1]));
        if (!std.mem.eql(u8, operation, "init") and !std.mem.eql(u8, operation, "adopt") and !std.mem.eql(u8, operation, "acquire")) continue;
        const k = (try requiredOwner(c, acquisition, cleanup, tree.nodeMainToken(acquired.ast.fn_expr))) orelse continue;
        if (k != .secret and k != .bytes and k != .guard) continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, model.scopes[decl.scope].node) orelse continue;
        const at = for (statements, 0..) |stmt, i| {
            if (stmt == decl.node) break i + 1;
        } else continue;
        const flow: Flow = .{ .c = c, .tree = tree, .model = model, .token = decl.token };
        switch (try flow.walk(statements[at..], .live)) {
            .falls => |state| if (state == .live) try c.at(cleanup, decl.token, "recognized local acquisition reaches block end without cleanup; review ownership obligation"),
            .ends => {},
            .uncertain => try c.undecided(cleanup, tree.tokenStart(decl.token), .unsupported, "cleanup/error exits/transfers/aliases require unsupported flow facts; no leak claimed"),
        }
    }
}

/// The paths of a block after a local acquisition, statement by statement. The owner is live
/// until a direct `deinit` releases it or a `defer` schedules one; an `if` is followed into
/// its branches. Undecided: an exit (`return`, `try`, a `break` or `continue` that leaves the
/// block) while live, an `if` whose branches leave the owner in different states, any use of
/// the owner but its members (its address, a copy, an argument: a transfer or an alias), a
/// release nested where the walk does not follow, a use after release. Findings: a second
/// direct cleanup, the owner's address discarded after release.
const Flow = struct {
    c: *Context,
    tree: *const Ast,
    model: *const Model,
    token: Ast.TokenIndex,

    const State = enum { live, released, deferred };
    const Outcome = union(enum) { falls: State, ends, uncertain };

    fn walk(f: Flow, statements: []const Ast.Node.Index, start: State) Context.Error!Outcome {
        var state = start;
        for (statements) |stmt| {
            const tag = f.tree.nodeTag(stmt);
            const deferred = tag == .@"defer" and try release(f.c, f.tree.nodeData(stmt).node, f.token);
            if (deferred or try release(f.c, stmt, f.token)) {
                if (state != .live) try f.c.at(cleanup, f.tree.nodeMainToken(stmt), if (deferred) "same local capability has repeated cleanup scheduled on this straight-line path" else "same local capability is cleaned twice on this straight-line path");
                state = if (deferred) .deferred else .released;
                continue;
            }
            // A discard of the owner's address has no retaining call or mutation.
            if (f.discardedAddress(stmt)) {
                if (state == .released) try f.c.at(cleanup, f.tree.nodeMainToken(f.tree.nodeData(f.tree.nodeData(stmt).node_and_node[1]).node), "same local owner used after cleanup on this straight-line path");
                continue;
            }
            if (state == .released) {
                if (try f.reacquired(stmt)) {
                    state = .live;
                    continue;
                }
                if (try f.uses(stmt) != .none) return .uncertain;
                continue;
            }
            if (state == .live) if (f.tree.fullIf(stmt)) |branch| {
                const then_outcome = try f.walkBranch(branch.ast.then_expr);
                const else_outcome: Outcome = if (branch.ast.else_expr.unwrap()) |other| try f.walkBranch(other) else .{ .falls = .live };
                if (try f.uses(branch.ast.cond_expr) != .none or f.exits(branch.ast.cond_expr)) return .uncertain;
                switch (try join(then_outcome, else_outcome)) {
                    .falls => |next| state = next,
                    .ends => return .ends,
                    .uncertain => return .uncertain,
                }
                continue;
            };
            // Deferred, the release runs on every exit; live, an exit would skip it.
            switch (try f.uses(stmt)) {
                .none, .members => {},
                .other => return .uncertain,
            }
            if (state == .live and f.exits(stmt)) return .uncertain;
        }
        return .{ .falls = state };
    }

    fn walkBranch(f: Flow, node: Ast.Node.Index) Context.Error!Outcome {
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = f.tree.blockStatements(&buffer, node) orelse &[_]Ast.Node.Index{node};
        var outcome = try f.walk(statements, .live);
        // A cleanup a branch defers runs as the branch ends.
        if (outcome == .falls and outcome.falls == .deferred) outcome = .{ .falls = .released };
        // A branch that ends in an exit after releasing ends there.
        if (outcome == .falls and outcome.falls != .live and statements.len != 0 and endsInExit(f.tree, statements[statements.len - 1])) return .ends;
        return outcome;
    }

    fn join(a: Outcome, b: Outcome) Context.Error!Outcome {
        if (a == .uncertain or b == .uncertain) return .uncertain;
        if (a == .ends) return b;
        if (b == .ends) return a;
        return if (a.falls == b.falls) a else .uncertain;
    }

    const Use = enum { none, members, other };
    /// How `node` uses the owner: not at all, only through its members (a nested `deinit`
    /// counts as other), or otherwise.
    fn uses(f: Flow, node: Ast.Node.Index) Context.Error!Use {
        const first = f.tree.firstToken(node);
        const last = f.tree.lastToken(node);
        var found: Use = .none;
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const candidate: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: AST node table supplies bounded indexes.
            const main = f.tree.nodeMainToken(candidate);
            if (main < first or main > last) continue;
            const ref = f.model.reference(candidate) orelse continue;
            const index = ref.declaration orelse continue;
            if (f.model.declarations[index].token != f.token) continue;
            const parent = f.model.node_parents[i] orelse return .other;
            if (f.tree.nodeTag(parent) != .field_access or f.tree.nodeData(parent).node_and_token[0] != candidate) return .other;
            if (std.mem.eql(u8, try Model.identifier(f.c.allocator, f.tree.tokenSlice(f.tree.nodeData(parent).node_and_token[1])), "deinit")) return .other;
            found = .members;
        }
        return found;
    }

    /// Whether `node` can leave the block the owner lives in: a `return`, a `try`, or a
    /// `break` or `continue` that is labeled or not inside a loop within `node`.
    fn exits(f: Flow, node: Ast.Node.Index) bool {
        const first = f.tree.firstToken(node);
        const last = f.tree.lastToken(node);
        for (first..last + 1) |raw_token| {
            const token: Ast.TokenIndex = @intCast(raw_token); // safe: bounded by the node's own token range.
            switch (f.tree.tokenTag(token)) {
                .keyword_return, .keyword_try => return true,
                .keyword_break, .keyword_continue => {
                    if (f.tree.tokenTag(token + 1) == .colon) return true;
                    if (!f.insideLoop(token, node)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    fn insideLoop(f: Flow, token: Ast.TokenIndex, root: Ast.Node.Index) bool {
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .@"break" and tag != .@"continue") continue;
            if (f.tree.nodeMainToken(@fromBackingInt(@intCast(i))) != token) continue; // safe: AST node table supplies bounded indexes.
            var at = f.model.node_parents[i];
            while (at) |parent| : (at = f.model.node_parents[@backingInt(parent)]) { // safe: an AST node index reads its own parent table
                if (f.tree.fullWhile(parent) != null or f.tree.fullFor(parent) != null) return true;
                if (parent == root) return false;
            }
            return false;
        }
        return false;
    }

    /// `owner = x.init(...)`, `x.adopt(...)` or `x.acquire()`: live again.
    fn reacquired(f: Flow, stmt: Ast.Node.Index) Context.Error!bool {
        if (f.tree.nodeTag(stmt) != .assign) return false;
        const data = f.tree.nodeData(stmt).node_and_node;
        const index = Contract.local(f.c, data[0]) orelse return false;
        if (f.model.declarations[index].token != f.token) return false;
        var call_buffer: [1]Ast.Node.Index = undefined;
        const value = if (f.tree.nodeTag(data[1]) == .@"try") f.tree.nodeData(data[1]).node else data[1];
        const call = f.tree.fullCall(&call_buffer, value) orelse return false;
        if (f.tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
        const operation = try Model.identifier(f.c.allocator, f.tree.tokenSlice(f.tree.nodeData(call.ast.fn_expr).node_and_token[1]));
        return std.mem.eql(u8, operation, "init") or std.mem.eql(u8, operation, "adopt") or std.mem.eql(u8, operation, "acquire");
    }

    /// `_ = &owner;`
    fn discardedAddress(f: Flow, stmt: Ast.Node.Index) bool {
        if (f.tree.nodeTag(stmt) != .assign) return false;
        const data = f.tree.nodeData(stmt).node_and_node;
        if (f.tree.nodeTag(data[0]) != .identifier or !std.mem.eql(u8, f.tree.tokenSlice(f.tree.nodeMainToken(data[0])), "_") or f.tree.nodeTag(data[1]) != .address_of) return false;
        const index = Contract.local(f.c, f.tree.nodeData(data[1]).node) orelse return false;
        return f.model.declarations[index].token == f.token;
    }
};

fn endsInExit(tree: *const Ast, stmt: Ast.Node.Index) bool {
    return switch (tree.nodeTag(stmt)) {
        .@"return", .@"break", .@"continue", .unreachable_literal => true,
        else => false,
    };
}
fn release(c: *Context, node: Ast.Node.Index, token: Ast.TokenIndex) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const data = tree.nodeData(call.ast.fn_expr).node_and_token;
    const index = Contract.local(c, data[0]) orelse return false;
    return c.project.models[c.file.raw()].declarations[index].token == token and std.mem.eql(u8, try Model.identifier(c.allocator, tree.tokenSlice(data[1])), "deinit");
}
fn raw(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = try c.project.syntax(try c.source());
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access or call.ast.params.len != 0) return false;
    const data = tree.nodeData(call.ast.fn_expr).node_and_token;
    if (!std.mem.eql(u8, try Model.identifier(c.allocator, tree.tokenSlice(data[1])), "raw")) return false;
    return try requiredOwner(c, data[0], scalar, data[1]) == .scalar;
}
fn checkScalar(c: *Context) Context.Error!void {
    if (!try begin(c, scalar)) return;
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
    if (!try begin(c, capacity)) return;
    const tree = try c.project.syntax(try c.source());
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: AST node table supplies bounded indexes.
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) continue;
        const data = tree.nodeData(call.ast.fn_expr).node_and_token;
        if (!std.mem.eql(u8, try Model.identifier(c.allocator, tree.tokenSlice(data[1])), "adopt") or call.ast.params.len != 3) continue;
        if (try requiredOwner(c, data[0], capacity, data[1]) != .bytes) continue;
        if (tree.fullSlice(call.ast.params[1])) |slice| {
            if (slice.ast.end.unwrap() != null) try c.at(capacity, tree.nodeMainToken(node), "SecretBytes.adopt receives an explicitly bounded slice: full allocator capacity/exclusive ownership must be retained; extent is undecided");
        }
        try c.undecided(capacity, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "slice syntax cannot prove full allocator extent, provenance, alignment or exclusive transfer; runtime wipe/free obligations remain");
    }
}
