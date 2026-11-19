//! A package's public surface (contract v1's `--surface` and `glint surface`): one line for each
//! declaration a consumer reaches through the modules the package exports, read with glint's
//! project model (its declarations, their visibility and scopes), so a release can tell whether it
//! removed or changed one.
//!
//! A line names the declaration by its path from the module (`conduit.Child.spawn`) and holds
//! what a consumer's code depends on: a function's parameter and return types, a field's type,
//! the fields a struct literal must name, the expression a public constant aliases, a
//! constant's value, and an exhaustive enum's tags and a tagged union's fields as one set,
//! which every exhaustive switch names. A type is written as what it names: a container by the
//! public path it is listed under, an alias by what it comes to. Whitespace, comments and
//! parameter names are not part of it. The caller compares whole lines.
//!
//! A facade is read through: an import of a module of the package's own leads where the build
//! binds the name, as the lint reads it, so the declaration is listed with its shape. Another
//! package's module, std's among them, is a line, not its surface.
//!
//! What the lines cannot see: the body of a function that returns a type, an inferred error
//! set (`!T`), which only the compiler's analysis knows. Moved from preflight's
//! checks/surface.zig, which read it through glint's library.
const std = @import("std");
const Ast = std.zig.Ast;
const Project = @import("Project.zig");
const Model = @import("Model.zig");
const Contract = @import("Contract.zig");
const Assembly = @import("Assembly.zig");

/// The surface's format, its first line: the lines are versioned with the project file.
pub const header = "glint-surface 1";

/// What listing a surface fails with: memory, a file of another project.
pub const Error = std.mem.Allocator.Error || Project.QueryError || std.Io.Writer.Error;

/// How deep an alias is followed.
const max_depth = 32;

/// The surface's lines, sorted and without repeats: each exported module's root walked twice,
/// first to learn the public path each container is listed under, then to list the lines, a
/// container named in a signature by that path whatever it is spelled there.
pub fn lines(a: std.mem.Allocator, project: *const Project, exported: []const Contract.ProjectFile.Exported) Error![]const []const u8 {
    var walk: Walk = .{ .a = a, .project = project, .lines = .empty, .open = .empty, .naming = true };
    for ([_]bool{ true, false }) |naming| {
        walk.naming = naming;
        walk.lines = .empty;
        for (exported) |module| {
            const root = try Assembly.normalize(a, module.root);
            const file = for (project.sources) |*source| {
                if (std.mem.eql(u8, source.input.name, root)) break source.id;
            } else continue;
            try walk.container(module.name, file, .root, 0);
        }
    }
    const listed = walk.lines.items;
    std.mem.sort([]const u8, listed, {}, lessThan);
    var unique: std.ArrayList([]const u8) = .empty;
    for (listed) |line| if (unique.items.len == 0 or !std.mem.eql(u8, unique.items[unique.items.len - 1], line)) try unique.append(a, line);
    return unique.items;
}

/// The surface as a file holds it: `header`, then one line each.
pub fn write(writer: *std.Io.Writer, listed: []const []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(header ++ "\n");
    for (listed) |line| try writer.print("{s}\n", .{line});
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// Whether `path`, from the package's root, is the package's own file: inside it, and not a
/// fetched package's or a build's cache.
fn own(path: []const u8) bool {
    if (path.len == 0 or std.Io.Dir.path.isAbsolute(path) or std.mem.startsWith(u8, path, "../")) return false;
    for ([_][]const u8{ "zig-pkg/", ".zig-cache/", "zig-out/" }) |outside| if (std.mem.startsWith(u8, path, outside)) return false;
    return true;
}

/// The string an `@import("...")` names, or null for any other call.
fn importSpelling(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => {},
        else => return null,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return null;
    const first = tree.nodeData(node).opt_node_and_opt_node[0].unwrap() orelse return null;
    if (tree.nodeTag(first) != .string_literal) return null;
    const literal = tree.tokenSlice(tree.nodeMainToken(first));
    if (literal.len < 2) return null;
    return literal[1 .. literal.len - 1];
}

const Walk = struct {
    a: std.mem.Allocator,
    project: *const Project,
    lines: std.ArrayList([]const u8),
    /// The containers being listed, so a container that reaches itself ends there.
    open: std.ArrayList(struct { file: Project.FileId, node: Ast.Node.Index }),
    /// The public path each container is listed under: the shortest, the first in order of
    /// those as short. A signature names a container by it.
    names: std.AutoHashMapUnmanaged(Place, []const u8) = .empty,
    /// Whether this walk learns `names`, its lines then not yet the surface's.
    naming: bool,

    fn handle(w: *Walk, file: Project.FileId) Project.Handle {
        return w.project.handle(file);
    }

    fn tree(w: *Walk, file: Project.FileId) Project.QueryError!*const Ast {
        return w.project.syntax(w.handle(file));
    }

    fn add(w: *Walk, comptime fmt: []const u8, args: anytype) !void {
        try w.lines.append(w.a, try w.a.print(fmt, args));
    }

    /// The scope glint's model gives the container at `node` (the file's own at the root).
    fn scopeOf(w: *Walk, file: Project.FileId, node: Ast.Node.Index) Project.QueryError!?Model.Scope.Id {
        const scopes = try w.project.scopes(w.handle(file));
        if (node == .root) return scopes[0].id;
        for (scopes) |scope| if (scope.kind == .container and scope.node == node) return scope.id;
        return null;
    }

    /// Lists the public declarations and the fields of the container at `node` in `file`.
    fn container(w: *Walk, prefix: []const u8, file: Project.FileId, node: Ast.Node.Index, depth: usize) Error!void {
        if (depth > max_depth) return;
        for (w.open.items) |open| if (open.file == file and open.node == node) return;
        try w.open.append(w.a, .{ .file = file, .node = node });
        defer _ = w.open.pop();
        if (w.naming) {
            const entry = try w.names.getOrPut(w.a, .{ .file = file, .node = node });
            if (!entry.found_existing or prefix.len < entry.value_ptr.len or (prefix.len == entry.value_ptr.len and std.mem.lessThan(u8, prefix, entry.value_ptr.*))) entry.value_ptr.* = prefix;
        }
        const t = try w.tree(file);
        const scope = (try w.scopeOf(file, node)) orelse return;
        const declarations = try w.project.declarations(w.handle(file));
        var required: std.ArrayList([]const u8) = .empty;
        // An enum's tags and a union's fields, `_` left out: what an exhaustive switch names.
        var named: std.ArrayList([]const u8) = .empty;
        var exhaustive = true;
        var fields: usize = 0;
        const is_enum = node != .root and isEnum(t, node);
        // The fields, from the syntax: an enum's tags and a tuple's fields have no `name:`.
        var container_buffer: [2]Ast.Node.Index = undefined;
        const members = if (node == .root) t.rootDecls() else (t.fullContainerDecl(&container_buffer, node) orelse return).ast.members;
        for (members) |member| {
            const field = t.fullContainerField(member) orelse continue;
            const positional = field.ast.tuple_like and !is_enum and !isUnion(t, node);
            const name = if (positional) try w.a.print("{d}", .{fields}) else t.tokenSlice(field.ast.main_token);
            fields += 1;
            // `_` is no tag a consumer names: it makes the enum non-exhaustive.
            if (std.mem.eql(u8, name, "_")) {
                exhaustive = false;
                continue;
            }
            try named.append(w.a, name);
            if (is_enum) {
                try w.add("{s}.{s} tag", .{ prefix, name });
                continue;
            }
            // A union's `a,` is a field of type void; a tuple's field is its type alone.
            const bare = field.ast.tuple_like and !positional;
            const type_text = if (bare) "void" else if (field.ast.type_expr.unwrap()) |expr| try w.tokens(file, t, expr) else "void";
            try w.add("{s}.{s} field: {s}", .{ prefix, name, type_text });
            if (field.ast.value_expr == .none) try required.append(w.a, name);
        }
        for (declarations) |declaration| {
            if (declaration.scope != scope) continue;
            switch (declaration.kind) {
                .function => if (declaration.public) {
                    var buffer: [1]Ast.Node.Index = undefined;
                    const proto = t.fullFnProto(&buffer, declaration.node) orelse continue;
                    const name = t.tokenSlice(proto.name_token.?);
                    try w.add("{s}.{s} {s}", .{ prefix, name, try w.signature(file, t, proto) });
                    try w.made(try w.a.print("{s}.{s}()", .{ prefix, name }), file, declaration.node, depth);
                },
                .variable => if (declaration.public) try w.variable(prefix, file, declaration.node, depth),
                else => {},
            }
        }
        if (!is_enum and ((node == .root and fields != 0) or (node != .root and isStruct(t, node)))) {
            std.mem.sort([]const u8, required.items, {}, lessThan);
            try w.add("{s} requires: {s}", .{ prefix, try std.mem.join(w.a, ", ", required.items) });
        }
        // A tag or a union field added breaks every exhaustive switch over the type, and `_`
        // added or taken away breaks each switch either way: the whole set is one line.
        std.mem.sort([]const u8, named.items, {}, lessThan);
        if (is_enum) {
            if (exhaustive) {
                try w.add("{s} exhaustive: {s}", .{ prefix, try std.mem.join(w.a, ", ", named.items) });
            } else try w.add("{s} non-exhaustive", .{prefix});
        } else if (node != .root and isTagged(t, node)) try w.add("{s} tagged: {s}", .{ prefix, try std.mem.join(w.a, ", ", named.items) });
    }

    /// The members of the type a function that returns one makes (`pub fn List(comptime T:
    /// type) type { return struct { ... }; }`), under `path`: what each of its `return`s
    /// gives, as far as the project shows it.
    fn made(w: *Walk, path: []const u8, file: Project.FileId, proto_node: Ast.Node.Index, depth: usize) !void {
        const t = try w.tree(file);
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = t.fullFnProto(&buffer, proto_node) orelse return;
        const returned = proto.ast.return_type.unwrap() orelse return;
        if (t.nodeTag(returned) != .identifier or !std.mem.eql(u8, t.tokenSlice(t.nodeMainToken(returned)), "type")) return;
        const body = for (t.nodes.items(.tag), 0..) |tag, n| {
            if (tag != .fn_decl) continue;
            const decl, const block = t.nodeData(@fromBackingInt(@intCast(n))).node_and_node;
            if (decl == proto_node) break block;
        } else return;
        const first = t.firstToken(body);
        const last = t.lastToken(body);
        for (t.nodes.items(.tag), 0..) |tag, n| {
            if (tag != .@"return") continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
            const token = t.nodeMainToken(node);
            if (token < first or token > last) continue;
            const value = t.nodeData(node).opt_node.unwrap() orelse continue;
            _ = try w.describe(path, file, value, depth + 1);
        }
    }

    fn variable(w: *Walk, prefix: []const u8, file: Project.FileId, node: Ast.Node.Index, depth: usize) !void {
        const t = try w.tree(file);
        const decl = t.fullVarDecl(node) orelse return;
        const name = t.tokenSlice(decl.ast.mut_token + 1);
        const path = try w.a.print("{s}.{s}", .{ prefix, name });
        const mutability = t.tokenSlice(decl.ast.mut_token);
        if (decl.ast.type_node.unwrap()) |type_node| try w.add("{s} {s}: {s}", .{ path, mutability, try w.tokens(file, t, type_node) });
        const init = decl.ast.init_node.unwrap() orelse return;
        if (isLiteral(t, init)) {
            if (decl.ast.type_node == .none) try w.add("{s} {s}", .{ path, mutability });
            // What a consumer computes with: a value changed needs an entry, though no build breaks.
            if (std.mem.eql(u8, mutability, "const")) try w.add("{s} value = {s}", .{ path, try w.tokens(file, t, init) });
            return;
        }
        const described = try w.describe(path, file, init, depth + 1);
        if (decl.ast.type_node == .none) try w.add("{s} {s} {s}", .{ path, mutability, described });
    }

    /// What a public constant is, listing the members of any container it is or names under
    /// `path`: a container's kind as it is written (`struct`, `enum ( u8 )`, a file is a
    /// struct), else `= ` and the expression it comes to, followed through the names it is
    /// spelled with, so a renamed alias or a moved file is no change. A comptime choice
    /// between two (`if (linux) A else B`) lists the members of both.
    fn describe(w: *Walk, path: []const u8, file: Project.FileId, node: Ast.Node.Index, depth: usize) Error![]const u8 {
        if (depth > max_depth) return "= ...";
        switch (w.resolve(file, node, depth)) {
            .container => |place| {
                try w.container(path, place.file, place.node, depth + 1);
                return w.head(place);
            },
            .expression => |place| {
                const t = try w.tree(place.file);
                if (t.fullIf(place.node)) |choice| if (choice.ast.else_expr.unwrap()) |otherwise| {
                    const then = try w.describe(path, place.file, choice.ast.then_expr, depth + 1);
                    const other = try w.describe(path, place.file, otherwise, depth + 1);
                    return w.a.print("either {s} or {s}", .{ then, other });
                };
                return w.a.print("= {s}", .{try w.tokens(place.file, t, place.node)});
            },
        }
    }

    /// A container's kind as it is written before its members: `struct`, `enum ( u8 )`,
    /// `extern union`; a file is a struct.
    fn head(w: *Walk, place: Place) ![]const u8 {
        if (place.node == .root) return "struct";
        const t = try w.tree(place.file);
        var last = t.firstToken(place.node);
        while (t.tokenTag(last + 1) != .l_brace) last += 1;
        return w.span(place.file, t, t.firstToken(place.node), last, &.{}, 0);
    }

    const Place = struct { file: Project.FileId, node: Ast.Node.Index };
    const Resolved = union(enum) {
        /// A container the project holds: a container expression, or a file.
        container: Place,
        /// The expression a name comes to where it is no container the project holds.
        expression: Place,
    };

    /// Follows an expression through the names it is spelled with to a container, or to the
    /// expression they come to.
    fn resolve(w: *Walk, file: Project.FileId, node: Ast.Node.Index, depth: usize) Resolved {
        const here: Resolved = .{ .expression = .{ .file = file, .node = node } };
        if (depth > max_depth) return here;
        const t = w.tree(file) catch return here;
        if (isContainer(t, node)) return .{ .container = .{ .file = file, .node = node } };
        switch (t.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma => {
                const spelling = importSpelling(t, node) orelse return here;
                const target = w.project.imported(file, spelling) orelse return here;
                // Another package's module, std's among them, is a line, not its surface.
                if (!own(w.project.at(target).input.name)) return here;
                return .{ .container = .{ .file = target, .node = .root } };
            },
            .identifier => {
                const name = t.tokenSlice(t.nodeMainToken(node));
                const scopes = w.project.scopes(w.handle(file)) catch return here;
                var scope = w.scopeAt(file, t.nodeMainToken(node));
                while (scope) |s| : (scope = scopes[@backingInt(s)].parent) {
                    const index = scopes[@backingInt(s)].names.get(name) orelse continue;
                    return w.declared(file, index, depth) orelse here;
                }
                return here;
            },
            .field_access => {
                const left, const member = t.nodeData(node).node_and_token;
                const outer = switch (w.resolve(file, left, depth + 1)) {
                    .container => |place| place,
                    .expression => return here,
                };
                const scope = (w.scopeOf(outer.file, outer.node) catch return here) orelse return here;
                const scopes = w.project.scopes(w.handle(outer.file)) catch return here;
                const index = scopes[@backingInt(scope)].names.get(t.tokenSlice(member)) orelse return here;
                return w.declared(outer.file, index, depth) orelse here;
            },
            else => return here,
        }
    }

    /// What the constant a name binds comes to; null for any other declaration.
    fn declared(w: *Walk, file: Project.FileId, index: Model.Declaration.Id, depth: usize) ?Resolved {
        const declarations = w.project.declarations(w.handle(file)) catch return null;
        const declaration = declarations[@backingInt(index)];
        if (declaration.kind != .variable) return null;
        const t = w.tree(file) catch return null;
        const decl = t.fullVarDecl(declaration.node) orelse return null;
        if (decl.ast.type_node != .none) return null;
        const init = decl.ast.init_node.unwrap() orelse return null;
        return w.resolve(file, init, depth + 1);
    }

    fn scopeAt(w: *Walk, file: Project.FileId, token: Ast.TokenIndex) ?Model.Scope.Id {
        const scopes = w.project.scopes(w.handle(file)) catch return null;
        var best = &scopes[0];
        for (scopes) |*scope| {
            if (scope.first <= token and token <= scope.last and scope.first >= best.first and scope.last <= best.last) best = scope;
        }
        return best.id;
    }

    /// The tokens of `node`, one space apart, doc comments left out, each name as `canonical`
    /// gives it.
    fn tokens(w: *Walk, file: Project.FileId, t: *const Ast, node: Ast.Node.Index) ![]const u8 {
        return w.span(file, t, t.firstToken(node), t.lastToken(node), &.{}, 0);
    }

    /// The tokens from `first` to `last` of `file`, one space apart, doc comments and `skipped`
    /// left out. Once the walk knows `names`, a name a declaration binds is written as what it
    /// comes to (`canonical`), so respelling a type through an alias changes no line, and
    /// changing what a private alias names does.
    fn span(w: *Walk, file: Project.FileId, t: *const Ast, first: Ast.TokenIndex, last: Ast.TokenIndex, skipped: []const Ast.TokenIndex, depth: usize) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(w.a);
        var token = first;
        while (token <= last) : (token += 1) {
            if (t.tokenTag(token) == .doc_comment or t.tokenTag(token) == .container_doc_comment) continue;
            if (std.mem.findScalar(Ast.TokenIndex, skipped, token) != null) continue;
            if (out.written().len != 0) try out.writer.writeByte(' ');
            const resolving = !w.naming and depth <= max_depth;
            const chain = if (resolving) chainEnd(t, token, last) else token;
            if (resolving and nameStart(t, token)) {
                try out.writer.writeAll(try w.canonical(file, t, token, chain, depth));
                token = chain;
            } else try out.writer.writeAll(t.tokenSlice(token));
        }
        return out.written();
    }

    /// The name `first..last` of `file` spells (`a`, `a.b.C`, `@This()`), as a signature
    /// means it: a container by the public path it is listed under, a constant by the
    /// expression it comes to, and anything the package does not declare as it is spelled.
    fn canonical(w: *Walk, file: Project.FileId, t: *const Ast, first: Ast.TokenIndex, last: Ast.TokenIndex, depth: usize) ![]const u8 {
        const spelled = try w.span(file, t, first, last, &.{}, max_depth + 1);
        if (depth > max_depth) return spelled;
        if (t.tokenTag(first) == .builtin) {
            const place = w.enclosing(file, first) orelse return spelled;
            return w.names.get(place) orelse spelled;
        }
        const node = chainNode(t, first, last) orelse return spelled;
        return switch (w.resolve(file, node, depth)) {
            .container => |place| w.names.get(place) orelse spelled,
            .expression => |place| if (place.file == file and place.node == node) spelled else {
                const target = try w.tree(place.file);
                return w.span(place.file, target, target.firstToken(place.node), target.lastToken(place.node), &.{}, depth + 1);
            },
        };
    }

    /// The container `@This()` at `token` of `file` names: the innermost one around it.
    fn enclosing(w: *Walk, file: Project.FileId, token: Ast.TokenIndex) ?Place {
        const scopes = w.project.scopes(w.handle(file)) catch return null;
        var scope = w.scopeAt(file, token);
        while (scope) |s| : (scope = scopes[@backingInt(s)].parent) {
            if (s == scopes[0].id) return .{ .file = file, .node = .root };
            if (scopes[@backingInt(s)].kind == .container) return .{ .file = file, .node = scopes[@backingInt(s)].node };
        }
        return null;
    }

    /// `fn (types) return`: the prototype without its name and the names of its parameters.
    fn signature(w: *Walk, file: Project.FileId, t: *const Ast, proto: Ast.full.FnProto) ![]const u8 {
        var skipped: std.ArrayList(Ast.TokenIndex) = .empty;
        if (proto.name_token) |token| try skipped.append(w.a, token);
        var it = proto.iterate(t);
        while (it.next()) |param| if (param.name_token) |token| {
            if (param.type_expr != null and t.tokenTag(token + 1) == .colon) {
                try skipped.append(w.a, token);
                try skipped.append(w.a, token + 1);
            }
        };
        return w.span(file, t, proto.ast.fn_token, t.lastToken(proto.ast.return_type.unwrap() orelse return w.span(file, t, proto.ast.fn_token, proto.ast.fn_token, &.{}, 0)), skipped.items, 0);
    }
};

/// Whether `token` starts a name: an identifier no `.` comes before, or `@This`.
fn nameStart(t: *const Ast, token: Ast.TokenIndex) bool {
    if (token > 0 and t.tokenTag(token - 1) == .period) return false;
    return switch (t.tokenTag(token)) {
        .identifier => true,
        .builtin => std.mem.eql(u8, t.tokenSlice(token), "@This"),
        else => false,
    };
}

/// The last token of the name starting at `token` (`a.b.C`; `@This()`), no further than
/// `last`; `token` itself when no name starts there.
fn chainEnd(t: *const Ast, token: Ast.TokenIndex, last: Ast.TokenIndex) Ast.TokenIndex {
    if (!nameStart(t, token)) return token;
    if (t.tokenTag(token) == .builtin) {
        if (token + 2 <= last and t.tokenTag(token + 1) == .l_paren and t.tokenTag(token + 2) == .r_paren) return token + 2;
        return token;
    }
    var end = token;
    while (end + 2 <= last and t.tokenTag(end + 1) == .period and t.tokenTag(end + 2) == .identifier) end += 2;
    return end;
}

/// The identifier or field access spanning exactly `first..last`.
fn chainNode(t: *const Ast, first: Ast.TokenIndex, last: Ast.TokenIndex) ?Ast.Node.Index {
    for (t.nodes.items(.tag), 0..) |tag, n| {
        if (tag != .identifier and tag != .field_access) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
        if (t.firstToken(node) == first and t.lastToken(node) == last) return node;
    }
    return null;
}

fn isContainer(t: *const Ast, node: Ast.Node.Index) bool {
    var buffer: [2]Ast.Node.Index = undefined;
    return t.fullContainerDecl(&buffer, node) != null;
}

fn containerKeyword(t: *const Ast, node: Ast.Node.Index) ?std.zig.Token.Tag {
    var buffer: [2]Ast.Node.Index = undefined;
    const decl = t.fullContainerDecl(&buffer, node) orelse return null;
    return t.tokenTag(decl.ast.main_token);
}

fn isEnum(t: *const Ast, node: Ast.Node.Index) bool {
    return containerKeyword(t, node) == .keyword_enum;
}

fn isUnion(t: *const Ast, node: Ast.Node.Index) bool {
    return containerKeyword(t, node) == .keyword_union;
}

fn isStruct(t: *const Ast, node: Ast.Node.Index) bool {
    return containerKeyword(t, node) == .keyword_struct;
}

/// A union with a tag, `union(enum)` or `union(Tag)`: one a switch takes.
fn isTagged(t: *const Ast, node: Ast.Node.Index) bool {
    var buffer: [2]Ast.Node.Index = undefined;
    const decl = t.fullContainerDecl(&buffer, node) orelse return false;
    return t.tokenTag(decl.ast.main_token) == .keyword_union and (decl.ast.enum_token != null or decl.ast.arg != .none);
}

/// A literal whose value is not part of the surface: a number, a string, a character, `true`.
fn isLiteral(t: *const Ast, node: Ast.Node.Index) bool {
    return switch (t.nodeTag(node)) {
        .number_literal, .string_literal, .multiline_string_literal, .char_literal, .enum_literal => true,
        .identifier => {
            const name = t.tokenSlice(t.nodeMainToken(node));
            return std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false") or std.mem.eql(u8, name, "null");
        },
        else => false,
    };
}

const testing = std.testing;

/// The surface of the package `files` holds, its module `pkg` rooted at src/root.zig, its build's
/// modules `modules` (a project file's JSON list): read as `glint surface` reads it.
fn surfaceOf(a: std.mem.Allocator, files: []const [2][]const u8, modules: []const u8) ![]const []const u8 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for (files) |file| {
        if (std.Io.Dir.path.dirname(file[0])) |parent| try tmp.dir.createDirPath(testing.io, parent);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = file[0], .data = file[1] });
    }
    const json = try a.print(
        \\{{"version": 1, "root": ".", "modules": {s}, "exported": [{{"name": "pkg", "root": "src/root.zig"}}],
        \\ "files": [{{"path": "src/root.zig", "kind": "production", "ships": true, "max_function_lines": 120}}],
        \\ "policy": {{"levels": [], "shipped_bans": [], "fact_budget": 1}}}}
    , .{modules});
    var problems: std.Io.Writer.Allocating = .init(a);
    const project_file = try Contract.readProject(a, json, &problems.writer);
    const assembled = try Assembly.assemble(a, testing.allocator, testing.io, tmp.dir, project_file, &problems.writer);
    var project = try Project.init(testing.allocator, assembled.inputs, assembled.imports, .{ .io = testing.io, .lowering = false });
    defer project.deinit();
    // Each line is written on the arena: it outlives the project.
    return lines(a, &project, project_file.exported);
}

test "surface: the surface lists public declarations through files, aliases and containers, and nothing private" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const listed = try surfaceOf(a, &.{
        .{
            "src/root.zig",
            \\//! The root.
            \\pub const Map = @import("map.zig");
            \\pub const Alias = Hidden;
            \\pub const limit = 64;
            \\pub const std = @import("std");
            \\const Hidden = struct {
            \\    a: u8,
            \\    b: u16 = 0,
            \\    pub fn get(self: Hidden, index: usize) u8 { _ = index; return self.a; }
            \\    fn private() void {}
            \\};
            \\fn helper() void {}
        },
        .{
            "src/map.zig",
            \\/// A kind.
            \\pub const Kind = enum { one, two };
            \\pub fn put(key: []const u8, value: u32) !void { _ = key; _ = value; }
            \\const secret = 1;
        },
    }, "[]");
    const expected = [_][]const u8{
        "pkg.Alias const struct",
        "pkg.Alias requires: a",
        "pkg.Alias.a field: u8",
        "pkg.Alias.b field: u16",
        "pkg.Alias.get fn ( pkg.Alias , usize ) u8",
        "pkg.Map const struct",
        "pkg.Map.Kind const enum",
        "pkg.Map.Kind exhaustive: one, two",
        "pkg.Map.Kind.one tag",
        "pkg.Map.Kind.two tag",
        "pkg.Map.put fn ( [ ] const u8 , u32 ) ! void",
        "pkg.limit const",
        "pkg.limit value = 64",
        "pkg.std const = @import ( \"std\" )",
    };
    try testing.expectEqualStrings(try std.mem.join(a, "\n", &expected), try std.mem.join(a, "\n", listed));
}

test "surface: the members of a type a function makes are listed under its call" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const listed = try surfaceOf(a, &.{.{
        "src/root.zig",
        \\pub fn List(comptime T: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        items: []T,
        \\        pub fn append(self: *Self, item: T) void { _ = self; _ = item; }
        \\    };
        \\}
    }}, "[]");
    const expected = [_][]const u8{
        "pkg.List fn ( comptime type ) type",
        "pkg.List() requires: items",
        "pkg.List().append fn ( * pkg.List() , T ) void",
        "pkg.List().items field: [ ] T",
    };
    try testing.expectEqualStrings(try std.mem.join(a, "\n", &expected), try std.mem.join(a, "\n", listed));
}

test "surface: a re-export of a module of the package's own lists what it declares, as a relative import does; another package's module stays a line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The package's module imports `pkg_core`, a module of its own, and `dep`, another package's.
    const modules =
        \\[{"root": "src/root.zig", "imports": [{"name": "pkg_core", "module": 1}, {"name": "dep", "module": 2}]},
        \\ {"root": "src/core/root.zig"}, {"root": "zig-pkg/dep/src/dep.zig"}]
    ;
    const core = [_][2][]const u8{
        .{ "src/core/root.zig", "pub const archive = @import(\"archive.zig\");\n" },
        .{ "src/core/archive.zig", "pub const Archive = struct { path: []const u8, pub fn open(path: []const u8) Archive { return .{ .path = path }; } };\npub const limit: u32 = 8;\n" },
        .{ "zig-pkg/dep/src/dep.zig", "pub const Dep = struct { x: u8 };\n" },
    };
    const direct = try surfaceOf(a, &(.{.{ "src/root.zig", "pub const archive = @import(\"core/root.zig\").archive;\n" }} ++ core), modules);
    const exported = try surfaceOf(a, &(.{.{ "src/root.zig", "pub const archive = @import(\"pkg_core\").archive;\npub const Dep = @import(\"dep\").Dep;\n" }} ++ core), modules);
    var open = false;
    for (direct) |line| open = open or std.mem.startsWith(u8, line, "pkg.archive.Archive.open");
    try testing.expect(open);
    var dep_lines: usize = 0;
    for (exported) |line| {
        // The other package's struct is a line, not listed member by member.
        try testing.expect(!std.mem.startsWith(u8, line, "pkg.Dep.x"));
        if (std.mem.startsWith(u8, line, "pkg.Dep")) {
            dep_lines += 1;
            continue;
        }
        for (direct) |one| {
            if (std.mem.eql(u8, one, line)) break;
        } else return error.TestUnexpectedResult;
    }
    try testing.expectEqual(direct.len, exported.len - dep_lines);
}
