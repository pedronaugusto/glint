//! D001: a private declaration nothing in its file names.
//!
//! Zig makes a declaration without `pub` reachable only from its own file: another file's
//! member access, `@field` or `@hasDecl` cannot see it, `@hasDecl` sees no private
//! declaration even in its own file, and a container's type information lists only public
//! declaration names. So a std hook (`format`, `jsonStringify`) cannot call a private one,
//! and a private declaration is used only where its file spells its name: an identifier, a
//! member access or declaration literal (`.name`), or `@field` with that name. Every spelling
//! counts as a use unless the identifier resolves lexically to another declaration (Zig
//! rejects an ambiguous one); a use inside the declaration itself does not count. A spelling
//! of the same name that is no use of it (an error name, an asm operand, a field or enum
//! literal) still counts, so a miss is allowed and a wrong report is not. A file holding a
//! `@field` whose name is not a plain string literal reports nothing: a computed name may
//! reach any declaration of a type. No reachability: a declaration only dead code names is
//! not reported.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Model = @import("Model.zig");
const Ast = std.zig.Ast;

const Candidate = struct {
    decl: Model.Declaration.Id,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    used: bool = false,
    /// Unused, and its finding is not suppressed: reported.
    reported: bool = false,

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
    // A `@field` names a declaration by its literal name; a computed name may name any, so the
    // file's findings are withheld.
    for (tree.nodes.items(.tag), 0..) |tag, n| {
        switch (tag) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
        const main = tree.nodeMainToken(node);
        if (!std.mem.eql(u8, tree.tokenSlice(main), "@field")) continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = tree.builtinCallParams(&buffer, node) orelse continue;
        if (args.len != 2) continue;
        if (tree.nodeTag(args[1]) != .string_literal) return;
        const name = std.zig.string_literal.parseAlloc(a, tree.tokenSlice(tree.nodeMainToken(args[1]))) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        candidates.spelled(model, name, main);
    }
    const resolved = try a.alloc(?Model.Declaration.Id, tree.tokens.len);
    @memset(resolved, null);
    for (model.references) |reference| if (reference.declaration) |d| {
        if (model.declarations[@backingInt(d)].kind != .field) resolved[reference.token] = d;
    };
    // A label (`blk: {`, `break :blk`) is of another namespace than declarations: no spelling.
    const labels = try labelTokens(a, tree);
    for (0..tree.tokens.len) |t| {
        const token: Ast.TokenIndex = @intCast(t);
        if (tree.tokenTag(token) != .identifier or declared[token] or labels[token] or fieldName(tree, token)) continue;
        if (resolved[token]) |d| if (candidates.resolvedUse(d, token)) continue;
        candidates.spelled(model, try Model.identifier(a, tree.tokenSlice(token)), token);
    }
    // A container's finding stands for what it holds only where it is reported: one suppressed
    // there leaves its declarations' own findings.
    for (candidates.list.items) |*candidate| {
        if (!candidate.used) candidate.reported = !try context.suppressedAt(.D001, model.declarations[@backingInt(candidate.decl)].token);
    }
    for (candidates.list.items) |candidate| {
        if (candidate.used or within(candidates.list.items, model, tree, candidate)) continue;
        const decl = model.declarations[@backingInt(candidate.decl)];
        try context.at(.D001, decl.token, try a.print("private declaration '{s}' is named nowhere in its file, the only place Zig lets it be used", .{decl.name}));
    }
}

/// The tokens that are labels, by the forms that write one: a labeled block's, loop's or
/// `switch`'s label, and the label a `break` or `continue` names.
fn labelTokens(a: std.mem.Allocator, tree: *const Ast) Context.Error![]const bool {
    const labels = try a.alloc(bool, tree.tokens.len);
    @memset(labels, false);
    for (tree.nodes.items(.tag), 0..) |tag, n| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
        const label: ?Ast.TokenIndex = switch (tag) {
            .@"break", .@"continue" => tree.nodeData(node).opt_token_and_opt_node[0].unwrap(),
            .block, .block_semicolon, .block_two, .block_two_semicolon => blk: {
                const brace = tree.nodeMainToken(node);
                break :blk if (brace >= 2 and tree.tokenTag(brace - 1) == .colon and tree.tokenTag(brace - 2) == .identifier) brace - 2 else null;
            },
            else => if (tree.fullWhile(node)) |loop| loop.label_token else if (tree.fullFor(node)) |loop| loop.label_token else if (tree.fullSwitch(node)) |choice| choice.label_token else null,
        };
        if (label) |token| labels[token] = true;
    }
    return labels;
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

/// A declaration inside a container that is itself reported: the container is the finding.
fn within(candidates: []const Candidate, model: *const Model, tree: *const Ast, candidate: Candidate) bool {
    const decl = model.declarations[@backingInt(candidate.decl)];
    for (candidates) |outer| {
        if (!outer.reported or outer.decl == candidate.decl) continue;
        if (model.declarations[@backingInt(outer.decl)].kind != .variable) continue;
        if (outer.first <= candidate.first and candidate.last <= outer.last and tree.firstToken(decl.node) > outer.first) return true;
    }
    return false;
}
