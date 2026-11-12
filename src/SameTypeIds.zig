//! P008: two identifying integers of one type meeting in one public signature or one public
//! struct, where nothing keeps one from standing for the other, read from the shape alone.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Rule = @import("Rule.zig").Rule;
const Ast = std.zig.Ast;

/// Two or more identifying integers of one type meeting in one public signature or one
/// public struct, where nothing keeps one from standing for the other. A signature is a
/// function's or a function type's (`*const fn (parent_id: u32, child_id: u32) void`), a public
/// function being a `pub` or an `export` one (`exported`), and a
/// struct any container `reached` from outside the file: by a `pub` name, a name a reached
/// declaration uses (`pub const Link = Edge;`), a public signature's (an anonymous struct
/// parameter) or what a reached type function returns. Two names are one integer when their
/// types resolve to it, or are spelled the same and are an integer whatever a build chooses
/// (`const Id = if (wide) u64 else u32`); a type that does not resolve, or a choice that may
/// meet the other's, is a finding: it cannot be shown to be another.
pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    const reaches = try reached(c, tree, model);
    for (model.declarations, 0..) |decl, index| {
        if (decl.kind != .function or !(decl.public or reaches[index] or exported(tree, decl)) or c.inTest(decl.token)) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, decl.node) orelse continue;
        try signature(c, rule, tree, proto, decl.token);
    }
    for (0..tree.nodes.len) |raw| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        switch (tree.nodeTag(node)) {
            .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto => {},
            else => continue,
        }
        const parent = model.parentOf(node) orelse continue;
        if (tree.nodeTag(parent) == .fn_decl or c.inTest(tree.firstToken(node)) or !try reachedFrom(c, tree, model, reaches, node)) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        try signature(c, rule, tree, tree.fullFnProto(&buffer, node) orelse continue, tree.firstToken(node));
    }
    for (model.scopes) |scope| {
        if (scope.kind != .container and scope.kind != .file) continue;
        if (scope.kind == .container and !publicContainer(tree, model, scope.node) and !try reachedFrom(c, tree, model, reaches, scope.node)) continue;
        var names: std.ArrayList(Ast.TokenIndex) = .empty;
        var kinds: std.ArrayList(Kind) = .empty;
        for (model.declarations) |decl| {
            if (decl.kind != .field or decl.scope != scope.id or c.inTest(decl.token) or !identifies(decl.name)) continue;
            const written = (model.containerField(tree, decl.node) orelse continue).ast.type_expr.unwrap() orelse continue;
            const kind = (try kindOf(c, tree, written)) orelse continue;
            try names.append(c.allocator, decl.token);
            try kinds.append(c.allocator, kind);
        }
        const pair = meet(names.items, kinds.items) orelse continue;
        if (pair.same == .maybe) {
            try c.at(rule, pair.second, try c.allocator.print("fields '{s}' and '{s}' identify, and their types may be one integer: one may be stored for the other", .{ tree.tokenSlice(pair.first), tree.tokenSlice(pair.second) }));
            continue;
        }
        try c.at(rule, pair.second, try c.allocator.print("fields '{s}' and '{s}' are both {s} that identify: one may be stored for the other; a distinct type for each (an enum, or a package's id type) keeps them apart", .{ tree.tokenSlice(pair.first), tree.tokenSlice(pair.second), pair.kind }));
    }
}

/// A016 over one signature's parameters, reported at `at`.
fn signature(c: *Context, rule: Rule, tree: *const Ast, proto: Ast.full.FnProto, at: Ast.TokenIndex) Context.Error!void {
    var names: std.ArrayList(Ast.TokenIndex) = .empty;
    var kinds: std.ArrayList(Kind) = .empty;
    var it = proto.iterate(tree);
    while (it.next()) |param| {
        const name = param.name_token orelse continue;
        // By the name it declares: `@"parent_id"` is `parent_id`.
        if (param.comptime_noalias != null or !identifies(try Model.identifier(c.allocator, tree.tokenSlice(name)))) continue;
        // `anytype` is whatever a caller gives, an integer among them.
        const kind: Kind = if (param.type_expr) |written| (try kindOf(c, tree, written)) orelse continue else .{ .spelled = "anytype", .unknown = true };
        try names.append(c.allocator, name);
        try kinds.append(c.allocator, kind);
    }
    const pair = meet(names.items, kinds.items) orelse return;
    if (pair.same == .maybe) return c.at(rule, at, try c.allocator.print("'{s}' and '{s}' identify, and their types may be one integer: one may be passed for the other", .{ tree.tokenSlice(pair.first), tree.tokenSlice(pair.second) }));
    try c.at(rule, at, try c.allocator.print("'{s}' and '{s}' are both {s} that identify: one may be passed for the other; a distinct type for each (an enum, or a package's id type) keeps them apart", .{ tree.tokenSlice(pair.first), tree.tokenSlice(pair.second), pair.kind }));
}

/// What an identifying name's type may be as an integer (`kindOf`): the integers it resolves
/// to, one or a build's choice; whether each choice is one (`all`); whether which one it is
/// does not resolve (`unknown`).
const Kind = struct {
    spelled: []const u8,
    integers: []const []const u8 = &.{},
    all: bool = false,
    unknown: bool = false,
};

/// The integers a type written at `node` may be; null for a type that is none in any build.
fn kindOf(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!?Kind {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    const spelled = tree.source[tree.tokenStart(first) .. tree.tokenStart(last) + tree.tokenSlice(last).len];
    const value = try c.facts.resolve(c.file, node);
    switch (value) {
        .unknown, .reflected => return .{ .spelled = spelled, .unknown = true },
        // `@Int` of a width computed as the program compiles: an integer, which one unread.
        .primitive => |name| return if (std.mem.eql(u8, name, "@Int")) .{ .spelled = spelled, .all = true, .unknown = true } else .{ .spelled = spelled, .integers = try c.allocator.dupe([]const u8, &.{integer(value) orelse return null}), .all = true },
        .alternatives => |each| {
            var integers: std.ArrayList([]const u8) = .empty;
            var computed: usize = 0;
            for (each) |alternative| {
                if (integer(alternative)) |name| try integers.append(c.allocator, name);
                if (alternative == .primitive and std.mem.eql(u8, alternative.primitive, "@Int")) computed += 1;
            }
            if (integers.items.len + computed == 0) return null;
            return .{ .spelled = spelled, .integers = integers.items, .all = integers.items.len + computed == each.len, .unknown = computed != 0 };
        },
        else => return null,
    }
}

/// The first two names that are one integer, or else the first two that may be (`.maybe`).
fn meet(names: []const Ast.TokenIndex, kinds: []const Kind) ?struct { first: Ast.TokenIndex, second: Ast.TokenIndex, kind: []const u8, same: enum { yes, maybe } } {
    var maybe: ?[2]usize = null;
    for (kinds, 0..) |kind, i| for (kinds[0..i], 0..) |earlier, j| switch (oneInteger(earlier, kind)) {
        .yes => return .{ .first = names[j], .second = names[i], .kind = if (kind.integers.len == 1) kind.integers[0] else kind.spelled, .same = .yes },
        .maybe => if (maybe == null) {
            maybe = .{ j, i };
        },
        .no => {},
    };
    const pair = maybe orelse return null;
    return .{ .first = names[pair[0]], .second = names[pair[1]], .kind = kinds[pair[1]].spelled, .same = .maybe };
}

/// Whether two types are one integer in every build, may be in some, or never are.
fn oneInteger(a: Kind, b: Kind) enum { yes, maybe, no } {
    if (a.all and b.all) {
        if (std.mem.eql(u8, a.spelled, b.spelled)) return .yes;
        if (a.integers.len == 1 and b.integers.len == 1 and std.mem.eql(u8, a.integers[0], b.integers[0])) return .yes;
    }
    if (a.unknown or b.unknown) return .maybe;
    for (a.integers) |x| for (b.integers) |y| if (std.mem.eql(u8, x, y)) return .maybe;
    return .no;
}

/// Which of a file's declarations at container level code outside the file may reach (by
/// declaration): a `pub` one in a place that is reached, and one a reached place names
/// (`pub const Link = Edge;`, a public signature's type). A test's names reach nothing.
fn reached(c: *Context, tree: *const Ast, model: *const Model) Context.Error![]const bool {
    const out = try c.allocator.alloc(bool, model.declarations.len);
    @memset(out, false);
    var changed = true;
    while (changed) {
        changed = false;
        for (model.declarations, 0..) |decl, index| {
            if (out[index] or !(decl.public or exported(tree, decl)) or !atContainerLevel(model, decl)) continue;
            if (model.parentOf(decl.node)) |parent| if (!try reachedFrom(c, tree, model, out, parent)) continue;
            out[index] = true;
            changed = true;
        }
        for (model.references) |reference| {
            const decl = reference.declaration orelse continue;
            if (out[@backingInt(decl)] or !atContainerLevel(model, model.declarations[@backingInt(decl)]) or c.inTest(reference.token)) continue;
            if (!try reachedFrom(c, tree, model, out, reference.node)) continue;
            out[@backingInt(decl)] = true;
            changed = true;
        }
    }
    return out;
}

/// Whether a declaration is an `export` one, which code outside the program reaches by its
/// symbol: a function or a variable.
fn exported(tree: *const Ast, decl: Model.Declaration) bool {
    var buffer: [1]Ast.Node.Index = undefined;
    const token = if (decl.kind == .function)
        (tree.fullFnProto(&buffer, decl.node) orelse return false).extern_export_inline_token
    else if (decl.kind == .variable)
        (tree.fullVarDecl(decl.node) orelse return false).extern_export_token
    else
        return false;
    return tree.tokenTag(token orelse return false) == .keyword_export;
}

/// Whether a declaration is a container's or the file's own: a constant, variable or function.
fn atContainerLevel(model: *const Model, decl: Model.Declaration) bool {
    if (decl.kind != .variable and decl.kind != .function) return false;
    const kind = model.scopes[@backingInt(decl.scope)].kind;
    return kind == .container or kind == .file;
}

/// Whether code outside the file may reach the place `node` is in: the declaration at container
/// level that holds it is reached (`reached`), and a function's body is passed only in a type
/// function, whose result is what it returns.
fn reachedFrom(c: *Context, tree: *const Ast, model: *const Model, out: []const bool, node: Ast.Node.Index) Context.Error!bool {
    var child = node;
    while (model.parentOf(child)) |parent| : (child = parent) {
        const name = switch (tree.nodeTag(parent)) {
            .fn_decl => name: {
                var buffer: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buffer, parent).?;
                if (tree.nodeData(parent).node_and_node[1] == child) {
                    const result = proto.ast.return_type.unwrap() orelse return false;
                    const value = try c.facts.resolve(c.file, result);
                    if (value != .primitive or !std.mem.eql(u8, value.primitive, "type")) return false;
                }
                break :name proto.name_token orelse continue;
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => tree.fullVarDecl(parent).?.ast.mut_token + 1,
            else => continue,
        };
        const decl = model.lookup(model.scopeOf(name), tree.tokenSlice(name), name) orelse continue;
        if (model.declarations[@backingInt(decl)].node != parent or !atContainerLevel(model, model.declarations[@backingInt(decl)])) continue;
        return out[@backingInt(decl)];
    }
    return true;
}

/// Whether a name says what it holds identifies something: `id`, `index`, `idx` or `handle`, in
/// any case alone, or as the last word: after `_` in lower or upper case (`node_id`,
/// `node_ID`, `NODE_ID`), or camelCase (`nodeIndex`, `nodeID`).
fn identifies(name: []const u8) bool {
    for ([_][]const u8{ "id", "index", "handle", "idx" }) |word| {
        if (std.ascii.eqlIgnoreCase(name, word)) return true;
        if (name.len <= word.len) continue;
        const head = name[0 .. name.len - word.len];
        const tail = name[name.len - word.len ..];
        if (head.len == 0) continue;
        const before = head[head.len - 1];
        if (before == '_' and (std.mem.eql(u8, tail, word) or (upper(tail) and std.ascii.eqlIgnoreCase(tail, word)))) return true;
        // camelCase: the word starts upper case, or is all upper case (`parentID`), after a
        // lower-case letter or digit.
        if (std.ascii.isUpper(tail[0]) and std.ascii.eqlIgnoreCase(tail, word) and (std.mem.eql(u8, tail[1..], word[1..]) or upper(tail)) and (std.ascii.isLower(before) or std.ascii.isDigit(before))) return true;
    }
    return false;
}

/// Whether every byte of a word is an upper-case letter.
fn upper(word: []const u8) bool {
    for (word) |byte| if (!std.ascii.isUpper(byte)) return false;
    return true;
}

/// The integer type a resolved value names, by its spelling in Zig (`u32`, `usize`, `c_uint`).
fn integer(value: Facts.Value) ?[]const u8 {
    const name = switch (value) {
        .primitive => |name| name,
        // Its callers read a choice part by part: a choice is no one integer type.
        .alternatives => return null,
        else => return null,
    };
    // By `Facts.integerType`, the one reading of a primitive integer: Zig's `uN`, `iN`,
    // `usize`, `isize` and C's (`c_uint`); `comptime_int` is no type a value is held in.
    return switch (Facts.integerType(value, 64)) {
        .int => name,
        .literal, .unknown => null,
    };
}

/// Whether a container is declared `pub` (`pub const S = struct { ... }`).
fn publicContainer(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    const parent = model.parentOf(node) orelse return true;
    const variable = tree.fullVarDecl(parent) orelse return false;
    return variable.visib_token != null;
}
