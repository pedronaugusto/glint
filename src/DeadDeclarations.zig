//! D001: a private declaration nothing in its file names.
//!
//! Zig makes a declaration without `pub` reachable only from its own file: another file's
//! member access, `@field` or `@hasDecl` cannot see it, `@hasDecl` sees no private
//! declaration even in its own file, and a container's type information lists only public
//! declaration names. So a std hook (`format`, `jsonStringify`) cannot call a private one,
//! and a private declaration is used only where its file spells its name: an identifier, a
//! member access or declaration literal (`.name`), or `@field` with that name. Every spelling
//! counts as a use unless the identifier resolves lexically to another declaration (Zig
//! rejects an ambiguous one); a use inside the declaration itself does not count. A `@field`
//! whose name is computed reaches nothing on a run-time value (there it names only fields), every
//! declaration of its receiver's container on a type, and leaves the file undecided when the
//! receiver could be a type and does not resolve. No reachability: a declaration only
//! dead code names is not reported.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Ast = std.zig.Ast;

const Candidate = struct { decl: u32, first: Ast.TokenIndex, last: Ast.TokenIndex, used: bool = false };

pub fn check(context: *Context) Context.Error!void {
    if (!context.config.has(.D001)) return;
    const index = context.file.raw();
    const model = &context.project.models[index];
    const tree = &context.project.files[index].tree;
    const a = context.allocator;
    var candidates: std.ArrayList(Candidate) = .empty;
    var by_name: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    const declared = try a.alloc(bool, tree.tokens.len);
    @memset(declared, false);
    for (model.declarations, 0..) |decl, d| {
        declared[decl.token] = true;
        if (decl.public or decl.exported or (decl.kind != .function and decl.kind != .variable)) continue;
        if (model.scopes[decl.scope].kind != .file and model.scopes[decl.scope].kind != .container) continue;
        var whole = decl.node;
        if (decl.kind == .variable) {
            const init = tree.fullVarDecl(decl.node).?.ast.init_node.unwrap();
            // Z013 is the import case, one predicate owner.
            if (init) |node| if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) continue;
        } else if (model.node_parents[@backingInt(decl.node)]) |parent| { // safe: the checked AST indexes its own parent table.
            if (tree.nodeTag(parent) == .fn_decl) whole = parent;
        }
        const entry = try by_name.getOrPut(a, decl.name);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(a, @intCast(candidates.items.len)); // aegis: no-danger: bounded declaration table fits u32.
        try candidates.append(a, .{ .decl = @intCast(d), .first = tree.firstToken(whole), .last = tree.lastToken(whole) }); // aegis: no-danger: bounded declaration table fits u32.
    }
    if (candidates.items.len == 0) return;
    const resolved = try a.alloc(?u32, tree.tokens.len);
    @memset(resolved, null);
    for (model.references) |reference| if (reference.declaration) |d| {
        if (model.declarations[d].kind != .field) resolved[reference.token] = d;
    };
    for (0..tree.tokens.len) |t| {
        const token: Ast.TokenIndex = @intCast(t); // aegis: no-danger: bounded token table fits u32.
        if (tree.tokenTag(token) != .identifier or declared[token] or fieldName(tree, token)) continue;
        if (resolved[token]) |d| {
            if (find(candidates.items, by_name, model.declarations[d].name, d)) |c| {
                use(&candidates.items[c], token);
                continue;
            }
        }
        spelled(candidates.items, by_name, try Model.identifier(a, tree.tokenSlice(token)), token);
    }
    var undecided = false;
    for (tree.nodes.items(.tag), 0..) |tag, n| {
        switch (tag) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n)); // aegis: no-danger: bounded AST node table fits u32.
        const main = tree.nodeMainToken(node);
        if (!std.mem.eql(u8, tree.tokenSlice(main), "@field")) continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        if (args.len != 2) continue;
        if (tree.nodeTag(args[1]) == .string_literal) {
            const literal = tree.tokenSlice(tree.nodeMainToken(args[1]));
            const name = std.zig.string_literal.parseAlloc(a, literal) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidLiteral => continue, // The parser rejects it; no use to count.
            };
            spelled(candidates.items, by_name, name, main);
            continue;
        }
        // On a value `@field` reaches only fields; only a type's declarations can be named.
        if (try context.facts.runtime(context.file, args[0])) continue;
        if (!try computed(context, candidates.items, model, try context.facts.resolve(context.file, args[0]), main)) {
            undecided = true;
            try context.undecided(.D001, tree.tokenStart(main), .unresolved, "a @field with a computed name on a receiver that does not resolve may name any private declaration of this file");
        }
    }
    if (undecided) return;
    for (candidates.items) |candidate| {
        if (candidate.used or within(candidates.items, model, tree, candidate)) continue;
        const decl = model.declarations[candidate.decl];
        try context.at(.D001, decl.token, try a.print("private declaration '{s}' is named nowhere in its file, the only place Zig lets it be used", .{decl.name}));
    }
}

/// A struct literal's field name (`.{ .name = x }`) names a field, never a declaration.
fn fieldName(tree: *const Ast, token: Ast.TokenIndex) bool {
    if (token < 2 or token + 1 >= tree.tokens.len) return false;
    if (tree.tokenTag(token - 1) != .period or tree.tokenTag(token + 1) != .equal) return false;
    return switch (tree.tokenTag(token - 2)) {
        .l_brace, .comma => true,
        else => false,
    };
}

fn find(candidates: []const Candidate, by_name: std.StringHashMapUnmanaged(std.ArrayList(u32)), name: []const u8, decl: u32) ?u32 {
    const list = by_name.get(name) orelse return null;
    for (list.items) |c| if (candidates[c].decl == decl) return c;
    return null;
}

fn use(candidate: *Candidate, token: Ast.TokenIndex) void {
    if (token < candidate.first or token > candidate.last) candidate.used = true;
}

fn spelled(candidates: []Candidate, by_name: std.StringHashMapUnmanaged(std.ArrayList(u32)), name: []const u8, token: Ast.TokenIndex) void {
    const list = by_name.get(name) orelse return;
    for (list.items) |c| use(&candidates[c], token);
}

/// A computed `@field` name reaches every declaration of its receiver's container. False when
/// the receiver does not resolve, so any private declaration may be the one it names.
fn computed(context: *Context, candidates: []Candidate, model: *const Model, value: Facts.Value, token: Ast.TokenIndex) Context.Error!bool {
    switch (value) {
        .container, .instance => |container| {
            if (container.symbolic) return false;
            if (!container.file.eql(context.file)) return true; // Another file's container shows this one nothing private.
            for (candidates) |*candidate| if (model.declarations[candidate.decl].scope == container.scope) use(candidate, token);
            return true;
        },
        .pointer, .optional, .error_union => |child| return computed(context, candidates, model, child.*, token),
        .alternatives => |each| {
            for (each) |one| if (!try computed(context, candidates, model, one, token)) return false;
            return true;
        },
        .primitive, .scalar, .error_set, .function, .array, .literal, .reified, .fn_type => return true,
        .unknown, .reflected => return false,
    }
}

/// A declaration inside a container that is itself reported: the container is the finding.
fn within(candidates: []const Candidate, model: *const Model, tree: *const Ast, candidate: Candidate) bool {
    const decl = model.declarations[candidate.decl];
    for (candidates) |outer| {
        if (outer.used or outer.decl == candidate.decl) continue;
        if (model.declarations[outer.decl].kind != .variable) continue;
        if (outer.first <= candidate.first and candidate.last <= outer.last and tree.firstToken(decl.node) > outer.first) return true;
    }
    return false;
}
