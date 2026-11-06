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

const Candidate = struct {
    decl: Model.Declaration.Id,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    used: bool = false,

    /// A candidate of one check, made only as it is appended.
    const Id = enum(u32) { _ };
};
/// The candidates by their declaration, and the containers that hold them: a spelling no
/// reference resolves reaches a candidate only as Zig's member lookup in one of those
/// containers finds it by that name (`Model.Scope.names`).
const Candidates = struct {
    list: std.ArrayList(Candidate) = .empty,
    by_decl: std.AutoHashMapUnmanaged(Model.Declaration.Id, Candidate.Id) = .empty,
    scopes: std.ArrayList(Model.Scope.Id) = .empty,

    fn add(self: *Candidates, a: std.mem.Allocator, model: *const Model, candidate: Candidate) !void {
        try self.list.append(a, candidate);
        try self.by_decl.put(a, candidate.decl, @fromBackingInt(@intCast(self.list.items.len - 1)));
        const scope = model.declarations[@backingInt(candidate.decl)].scope;
        if (std.mem.findScalar(Model.Scope.Id, self.scopes.items, scope) == null) try self.scopes.append(a, scope);
    }

    /// A use at `token` of the candidate `decl` is, if it is one.
    fn resolvedUse(self: *Candidates, decl: Model.Declaration.Id, token: Ast.TokenIndex) bool {
        const c = self.by_decl.get(decl) orelse return false;
        use(&self.list.items[@backingInt(c)], token);
        return true;
    }

    /// A use at `token` of each candidate a container that holds candidates declares under
    /// `name`, as Zig's member lookup finds it.
    fn spelled(self: *Candidates, model: *const Model, name: []const u8, token: Ast.TokenIndex) void {
        for (self.scopes.items) |scope| if (model.scopes[@backingInt(scope)].names.get(name)) |decl| {
            _ = self.resolvedUse(decl, token);
        };
    }
};

pub fn check(context: *Context) Context.Error!void {
    if (!context.config.has(.D001)) return;
    const source = context.project.at(context.file);
    const model = &source.model;
    const tree = &source.file.tree;
    const a = context.allocator;
    var candidates: Candidates = .{};
    const declared = try a.alloc(bool, tree.tokens.len);
    @memset(declared, false);
    for (model.declarations, 0..) |decl, d| {
        declared[decl.token] = true;
        if (decl.public or decl.exported or (decl.kind != .function and decl.kind != .variable)) continue;
        if (model.scopes[@backingInt(decl.scope)].kind != .file and model.scopes[@backingInt(decl.scope)].kind != .container) continue;
        var whole = decl.node;
        if (decl.kind == .variable) {
            const init = tree.fullVarDecl(decl.node).?.ast.init_node.unwrap();
            // Z013 is the import case, one predicate owner.
            if (init) |node| if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) continue;
        } else if (model.parentOf(decl.node)) |parent| {
            if (tree.nodeTag(parent) == .fn_decl) whole = parent;
        }
        try candidates.add(a, model, .{ .decl = @fromBackingInt(@intCast(d)), .first = tree.firstToken(whole), .last = tree.lastToken(whole) });
    }
    if (candidates.list.items.len == 0) return;
    const resolved = try a.alloc(?Model.Declaration.Id, tree.tokens.len);
    @memset(resolved, null);
    for (model.references) |reference| if (reference.declaration) |d| {
        if (model.declarations[@backingInt(d)].kind != .field) resolved[reference.token] = d;
    };
    for (0..tree.tokens.len) |t| {
        const token: Ast.TokenIndex = @intCast(t);
        if (tree.tokenTag(token) != .identifier or declared[token] or fieldName(tree, token)) continue;
        if (resolved[token]) |d| if (candidates.resolvedUse(d, token)) continue;
        candidates.spelled(model, try Model.identifier(a, tree.tokenSlice(token)), token);
    }
    var undecided = false;
    for (0..tree.nodes.len) |n| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
        if (!Facts.isBuiltin(tree, node, "@field")) continue;
        const main = tree.nodeMainToken(node);
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        if (args.len != 2) continue;
        // The names it spells (a literal, a `const` holding one, a list it ranges over).
        switch (try context.facts.fieldName(context.file, args[1])) {
            .name => |name| {
                candidates.spelled(model, name, main);
                continue;
            },
            .names => |names| {
                for (names) |name| candidates.spelled(model, name, main);
                continue;
            },
            .each_of, .computed => {},
        }
        // On a value `@field` reaches only fields; only a type's declarations can be named.
        if (try context.facts.runtime(context.file, args[0])) continue;
        if (!try computed(context, candidates.list.items, model, try context.facts.resolve(context.file, args[0]), main)) {
            undecided = true;
            try context.undecided(.D001, tree.tokenStart(main), .unresolved, "a @field with a computed name on a receiver that does not resolve may name any private declaration of this file");
        }
    }
    if (undecided) return;
    for (candidates.list.items) |candidate| {
        if (candidate.used or within(candidates.list.items, model, tree, candidate)) continue;
        const decl = model.declarations[@backingInt(candidate.decl)];
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

fn use(candidate: *Candidate, token: Ast.TokenIndex) void {
    if (token < candidate.first or token > candidate.last) candidate.used = true;
}

/// A computed `@field` name reaches every declaration of its receiver's container. False when
/// the receiver does not resolve, so any private declaration may be the one it names.
fn computed(context: *Context, candidates: []Candidate, model: *const Model, value: Facts.Value, token: Ast.TokenIndex) Context.Error!bool {
    switch (value) {
        .container, .instance => |container| {
            if (container.symbolic) return false;
            if (container.file != context.file) return true; // Another file's container shows this one nothing private.
            for (candidates) |*candidate| if (model.declarations[@backingInt(candidate.decl)].scope == container.scope) use(candidate, token);
            return true;
        },
        .pointer => |child| return computed(context, candidates, model, child.child.*, token),
        .optional, .error_union => |child| return computed(context, candidates, model, child.*, token),
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
    const decl = model.declarations[@backingInt(candidate.decl)];
    for (candidates) |outer| {
        if (outer.used or outer.decl == candidate.decl) continue;
        if (model.declarations[@backingInt(outer.decl)].kind != .variable) continue;
        if (outer.first <= candidate.first and candidate.last <= outer.last and tree.firstToken(decl.node) > outer.first) return true;
    }
    return false;
}
