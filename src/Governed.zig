//! Declarations a rule governs, named by a path from a module as programs import it (`std`'s
//! `posix.fdatasync`), from a project input, or as an external symbol, and the sites that reach
//! them. A reference is governed when it resolves to one: an identifier or member access
//! through aliases, a member of every alternative of a per-build choice, `@field` with a written
//! name. Any reference to a declaration spells its name, and an alias spells it where it is
//! made, so only sites spelling a governed name are resolved; one that does not resolve is
//! the caller's to judge, never passed. P006 reads a project's policy through it; the aegis pack's danger
//! rules read the std declarations their predicates name.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Rule = @import("Rule.zig").Rule;
const samePath = @import("Rule.zig").samePath;
const Ast = std.zig.Ast;

/// A declaration as a rule names it. Null `source` names an external function by its symbol:
/// every `extern fn` of that symbol, std's or the program's own, is the one the linker binds.
pub const Target = struct {
    source: ?[]const u8 = null,
    declaration: []const u8,
    /// Test code (tests and test blocks) is not governed.
    production: bool = false,
};

/// One target as this run reads it.
pub const Governed = struct {
    target: Target,
    /// The target's index in what the caller gave.
    index: usize,
    /// The last name of its path, or its symbol: what every reference to it spells.
    name: []const u8,
    decls: []const Facts.Decl,
    symbol: ?[]const u8,
};

/// A reference that reaches a governed declaration.
pub const Site = struct {
    token: Ast.TokenIndex,
    node: Ast.Node.Index,
    /// The target's index in what the caller gave.
    index: usize,
    decl: Facts.Decl,
    /// Reached through an alias the program declares: the alias is a site where it is made.
    through_alias: bool,
    /// The alias is a container's declaration, evaluated as the program compiles: it is no
    /// site where the program runs, so a rule on what runs reads this use as the site.
    alias_declared: bool = false,
};

/// Each target's declarations in this project. A source nothing names, or a path that does not
/// resolve, stops the run (`RuleContext.refuse`): a policy that cannot be read is not a policy
/// that passed. A module no file imports is one nothing here can reach.
pub fn resolve(self: *Context, rule: Rule, targets: []const Target, indexes: []const usize) Context.Error![]const Governed {
    var kept: std.ArrayList(Governed) = .empty;
    for (targets, indexes) |target, index| {
        const g = try kept.addOne(self.allocator);
        const last = if (std.mem.findScalarLast(u8, target.declaration, '.')) |dot| target.declaration[dot + 1 ..] else target.declaration;
        g.* = .{ .target = target, .index = index, .name = last, .decls = &.{}, .symbol = null };
        const source = target.source orelse {
            g.symbol = target.declaration;
            continue;
        };
        // As `@import` reads its operand: a path ending in `.zig` is a file, anything else a module.
        const module = !std.mem.endsWith(u8, source, ".zig");
        var roots: std.ArrayList(Project.FileId) = .empty;
        if (module) try roots.appendSlice(self.allocator, try moduleRoots(self, source));
        if (!module) for (self.project.sources) |*each| if (samePath(each.input.name, source)) {
            try roots.append(self.allocator, each.id);
        };
        if (roots.items.len == 0) {
            if (!module) try self.refuse(try self.allocator.print("{s}: a declaration the configuration names in `{s}`, which is no input of the run", .{ @tagName(rule), source }));
            continue;
        }
        g.decls = switch (try walk(self, roots.items, target.declaration, module)) {
            .decls => |decls| decls,
            .none, .unknown => {
                try self.refuse(try self.allocator.print("{s}: `{s}.{s}`, which the configuration names, does not resolve", .{ @tagName(rule), source, target.declaration }));
                continue;
            },
        };
        for (g.decls) |decl| if (externSymbol(self.project, decl)) |symbol| {
            g.symbol = symbol;
        };
    }
    return kept.items;
}

/// What `declarations` finds: the declarations, none (no root imports the module, or the path
/// names nothing), or unknown (the fact budget ran out on the walk, which may have missed one).
pub const Declared = union(enum) {
    decls: []const Facts.Decl,
    none,
    unknown: Facts.Unknown,
};

/// The declarations `path` names from module `source`, without reporting. For facts that
/// recognize a declaration and leave its absence to the rules that read them. The answer is the
/// project's, read once per run for each source and path: a fact asks it at every place it
/// reads, every round.
pub fn declarations(self: *Context, source: []const u8, path: []const u8) Context.Error!Declared {
    // What it keeps in its memo stays for the run.
    const rule_memory = self.keep();
    defer self.allocator = rule_memory;
    const memo = try self.facts.memo(Lookups);
    memo.asked += 1;
    if (memo.found.getPtr(source)) |paths| if (paths.get(path)) |known| return known;
    const found = try lookup(self, source, path);
    // A walk the fact budget cut short may have missed a declaration: it is unknown, and asked
    // again.
    if (found != .decls and self.facts.budgetSpent()) return .{ .unknown = .budget };
    const answer = found;
    const paths = try memo.found.getOrPut(self.allocator, source);
    if (!paths.found_existing) {
        paths.key_ptr.* = try self.allocator.dupe(u8, source);
        paths.value_ptr.* = .empty;
    }
    try paths.value_ptr.put(self.allocator, try self.allocator.dupe(u8, path), answer);
    return answer;
}

/// Each `declarations` answer by its source, then its path, and how many times one was asked.
pub const Lookups = struct {
    found: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(Declared)) = .empty,
    asked: usize = 0,
};

fn lookup(self: *Context, source: []const u8, path: []const u8) Context.Error!Declared {
    const roots = try moduleRoots(self, source);
    if (roots.len == 0) return .none;
    return walk(self, roots, path, true);
}

/// The files the program's imports of module `source` reach. A governed declaration is a
/// library's, and a library's modules are the program's: a build script's import of the same
/// name is that dependency's build script, as the build runner names it.
fn moduleRoots(self: *Context, source: []const u8) Context.Error![]const Project.FileId {
    var roots: std.ArrayList(Project.FileId) = .empty;
    for (self.project.imports) |mapping| {
        if (!std.mem.eql(u8, mapping.spelling, source) or !mapping.in.inProgram()) continue;
        if (std.mem.findScalar(Project.FileId, roots.items, mapping.target) == null) try roots.append(self.allocator, mapping.target);
    }
    return roots.items;
}

/// A reference spelling a governed name that does not resolve, and why.
pub const Unread = struct { node: Ast.Node.Index, why: Facts.Unknown };

/// Every reference in the checked file that reaches a governed declaration, into `out`; a
/// reference spelling a governed name that does not resolve (a member access, a decl literal, a
/// literal's field, a builtin's field name) into `unread`, with why, for the caller to judge:
/// under a ban no pass (`Context.unknownAt`), under hygiene nothing.
pub fn sitesLeaving(self: *Context, governed: []const Governed, out: *std.ArrayList(Site), unread: *std.ArrayList(Unread)) Context.Error!void {
    if (governed.len == 0) return;
    // What each target is also called, by an alias whose own site this run does not report.
    const renamed = try self.allocator.alloc([]const []const u8, governed.len);
    for (governed, renamed) |g, *names| {
        var found: std.ArrayList([]const u8) = .empty;
        try aliasNames(self, .unreported, g.decls, g.symbol, &found);
        names.* = found.items;
    }
    const tree = &self.project.at(self.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const site: Ast.TokenIndex, const spelled: []const u8 = switch (tag) {
            .identifier => blk: {
                // An enum's or a union's tag written with no type names itself.
                if (self.project.at(self.file).model.tagName(tree, node)) continue;
                break :blk .{ tree.nodeMainToken(node), try Model.identifier(self.allocator, tree.tokenSlice(tree.nodeMainToken(node))) };
            },
            .field_access => blk: {
                const member = tree.nodeData(node).node_and_token[1];
                break :blk .{ member, try Model.identifier(self.allocator, tree.tokenSlice(member)) };
            },
            .builtin_call_two, .builtin_call_two_comma => blk: {
                // Every builtin that names a field by a string (`fieldBuiltin`) is a member
                // reference to it.
                const by = fieldBuiltin(tree, node) orelse continue;
                const named = try self.facts.fieldName(self.file, by.name);
                switch (named) {
                    // `@field(h, "f")`, `@offsetOf(T, "f")`: the member its holder has, as a
                    // member access reaches it (`reach`).
                    .name => |name| if (by.holder != null) break :blk .{ tree.nodeMainToken(node), name },
                    .each_of, .names, .computed => {},
                }
                // A name it ranges over or computes, or a holder only its result names
                // (`@fieldParentPtr`): each governed name it may be.
                try fieldSites(self, governed, renamed, node, by, named, out, unread);
                continue;
            },
            // A decl literal (`.fromMilliseconds(ms)`, `.zero`): a member of the type its place
            // gives it.
            .enum_literal => .{ tree.nodeMainToken(node), try Model.identifier(self.allocator, tree.tokenSlice(tree.nodeMainToken(node))) },
            else => {
                // A literal's field (`.{ .nanoseconds = x }`): the member of the type it makes.
                var buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullStructInit(&buffer, node)) |literal| for (literal.ast.fields) |value| {
                    const label = Model.initName(tree, value) orelse continue;
                    try literalSite(self, governed, renamed, node, value, label, out, unread);
                };
                continue;
            },
        };
        var applies = false;
        const testing = self.inTest(site);
        for (governed, renamed) |g, names| if (spells(g, names, spelled) and !(testing and g.target.production)) {
            applies = true;
        };
        if (!applies) continue;
        const reached = try reach(self, node, tag, spelled, governed);
        const decls = switch (reached) {
            .unknown => |why| {
                // A method called on a value whose type a generic's binding gives
                // (`s.context.eql(a, b)` in `Interner(T, Context)`) is that type's. Where every
                // governed declaration of that name is a free function, no type has it as a
                // method of its own: the binding reaches one only through an alias its type
                // declares, which is that alias's site.
                if (why == .generic and tag == .field_access and methodCall(self, node) and free(self, governed, spelled)) continue;
                try unread.append(self.allocator, .{ .node = node, .why = why });
                continue;
            },
            .decls => |decls| decls,
        };
        // `reach` gives a definition first and its origin second.
        try append(self, governed, renamed, site, node, spelled, decls, out);
    }
}

/// A reference that does not resolve, for the caller to judge.
fn leave(self: *Context, unread: *std.ArrayList(Unread), node: Ast.Node.Index, why: Facts.Unknown) Context.Error!void {
    return unread.append(self.allocator, .{ .node = node, .why = why });
}

/// A literal field's name spelling a governed member: a site where the literal's type has it.
fn literalSite(self: *Context, governed: []const Governed, renamed: []const []const []const u8, literal: Ast.Node.Index, value: Ast.Node.Index, label: Ast.TokenIndex, out: *std.ArrayList(Site), unread: *std.ArrayList(Unread)) Context.Error!void {
    const tree = &self.project.at(self.file).file.tree;
    const spelled = try Model.identifier(self.allocator, tree.tokenSlice(label));
    if (!spelledAny(self, governed, renamed, spelled, label)) return;
    switch (try self.facts.literalDeclarations(self.file, literal, spelled)) {
        .unknown => |why| try leave(self, unread, value, why),
        // One per part of a place a build picks, each with its origin: one site at most.
        .decls => |found| {
            var pairs: std.ArrayList(Facts.Decl) = .empty;
            for (found) |decl| switch (try paired(self, decl)) {
                .pair => |pair| try pairs.appendSlice(self.allocator, &pair),
                .unknown => |why| return leave(self, unread, value, why),
            };
            try append(self, governed, renamed, label, value, spelled, pairs.items, out);
        },
    }
}

/// A builtin that names a field by a string: `@field(holder, name)`, `@offsetOf(T, name)`,
/// `@bitOffsetOf(T, name)`, and `@fieldParentPtr(name, field)`, whose holder is the type its
/// result points at (null `holder`). `@hasField` and `@FieldType` name one too, but read no
/// value and make none: they answer of the type alone.
pub const FieldBuiltin = struct { name: Ast.Node.Index, holder: ?Ast.Node.Index };
pub fn fieldBuiltin(tree: *const Ast, node: Ast.Node.Index) ?FieldBuiltin {
    const builtin = Facts.builtinName(tree, node) orelse return null;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len != 2) return null;
    for ([_][]const u8{ "@field", "@offsetOf", "@bitOffsetOf" }) |each| if (std.mem.eql(u8, builtin, each)) return .{ .name = args[1], .holder = args[0] };
    if (std.mem.eql(u8, builtin, "@fieldParentPtr")) return .{ .name = args[0], .holder = null };
    return null;
}

/// What a field builtin's holder is: its holder's value, or for `@fieldParentPtr` what the
/// pointer its place gives it points at (`Facts.castTypeIn`).
pub fn fieldHolder(self: *Context, node: Ast.Node.Index, by: FieldBuiltin) Context.Error!Facts.Value {
    if (by.holder) |holder| return self.facts.resolve(self.file, holder);
    const made = try self.facts.castTypeIn(null, self.file, node);
    return if (made == .pointer) made.pointer.child.* else made;
}

/// A field builtin by a name it ranges over or computes, or by any name where only its result
/// names its holder: each governed member its holder has that the name may be is a site; a
/// holder that does not resolve is the caller's to judge where a governed name may be named.
fn fieldSites(self: *Context, governed: []const Governed, renamed: []const []const []const u8, node: Ast.Node.Index, by: FieldBuiltin, named: Facts.FieldName, out: *std.ArrayList(Site), unread: *std.ArrayList(Unread)) Context.Error!void {
    // A computed name spells nothing. Reflection over a governed type is the governed ban's own
    // site (`GovernedState`), one finding whatever the name.
    if (named == .computed) return;
    // A name of the fields or tags of the very type the holder is, or holds, is a field's or a
    // tag's: Zig forbids a declaration of one name with them in a container, so it reaches no
    // declaration, but it does reach a governed field among them.
    const own = if (by.holder) |holder| try self.facts.fieldNameOwn(self.file, holder, by.name) else false;
    if (own) for (governed) |g| {
        if (isField(self, g)) break;
    } else return;
    const tree = &self.project.at(self.file).file.tree;
    const site = tree.nodeMainToken(node);
    const value = try fieldHolder(self, node, by);
    for (governed, renamed) |g, names| {
        if (own and !isField(self, g)) continue;
        // An alias names a declaration, never a field.
        const aliases: []const []const u8 = if (own) &.{} else names;
        for ([_][]const []const u8{ &.{g.name}, aliases }) |list| for (list) |name| {
            if (!self.facts.mayName(named, name) or (self.inTest(site) and g.target.production)) continue;
            if (value == .unknown) return leave(self, unread, node, value.unknown);
            var options: std.ArrayList(Facts.Container) = .empty;
            try containers(self, value, &options);
            for (options.items) |container| {
                const decl = self.facts.member(container, name) orelse continue;
                switch (try paired(self, decl)) {
                    .pair => |pair| try append(self, governed, renamed, site, node, name, &pair, out),
                    .unknown => |why| return leave(self, unread, node, why),
                }
            }
        };
    }
}

/// Whether a governed target is a field of its container.
fn isField(self: *Context, g: Governed) bool {
    for (g.decls) |decl| if (self.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind == .field) return true;
    return false;
}

/// Whether a value of one of `types` is made other than by its own code, and by what callee.
pub const Made = union(enum) { no, yes: ?Facts.Decl, unknown: Facts.Unknown };

/// Whether the call at `node` makes a value of one of `types` (or a pointer to one, through
/// optionals and error unions) outside its type's own code: its callee is outside the program
/// (the program's own is judged by its body) and makes it from untyped data (`makesFromData`):
/// a value or pointer of the type out of bytes the caller hands it (`mem.bytesToValue(T, b)`,
/// `bytesAsValue`, `bytesAsSlice`), or a value built by reading the type's fields
/// (`mem.zeroes(T)`, `zeroInit`: `@typeInfo(T)`). A typed pointer to storage the callee
/// allocates or keeps is neither (`Allocator.alloc(T, n)`, a map's `get`): that memory is
/// undefined until a value of the type is written to it. A type's makers are functions of its
/// own package with a result of that type: those of its package are judged only where generic,
/// their result written in terms of their own parameter. The callee is given (`yes`) for the
/// caller to weigh its own library; one that makes from data whose result does not resolve is
/// unknown, but for a generic's binding, judged where it is bound. A callee no reading resolves
/// is unknown where its result may be one of `types`: one, or unknown itself.
pub fn madeByCall(self: *Context, node: Ast.Node.Index, types: []const Facts.Container) Context.Error!Made {
    if (types.len == 0) return .no;
    const call = (try Facts.calls.at(self.facts, self.file, node)) orelse return .no;
    const callees: []const Facts.Decl = switch (call.callee) {
        .function => |function| &.{function},
        .choice => |each| each,
        .any => |why| return if (try reachable(self, node, call, types, why)) |unknown| .{ .unknown = unknown } else .no,
    };
    var result: ?Facts.Value = null;
    var unknown: ?Facts.Unknown = null;
    for (callees) |callee| {
        if (try self.facts.program(callee.file)) continue;
        if (result == null) result = try self.facts.resolve(self.file, node);
        const made = madeType(result.?, types) orelse {
            if (result.? == .unknown and result.?.unknown != .generic) switch (try makesFromData(self, callee)) {
                .yes => return .{ .unknown = result.?.unknown },
                .no => {},
                .unknown => |why| unknown = why,
            };
            continue;
        };
        if (!reflectiveResult(self, callee) and try samePackage(self, callee.file, made.file)) continue;
        switch (try makesFromData(self, callee)) {
            .yes => {},
            .no => continue,
            .unknown => |why| {
                unknown = why;
                continue;
            },
        }
        // A copy of memory out of a value of the same type (`std.mem.bytesToValue(T,
        // std.mem.asBytes(&t))`, `Facts.accesses.copyAt`) makes it from its own bytes.
        if (try Facts.accesses.copyAt(self.facts, self.file, node)) |copy| if (madeType(try self.facts.resolve(self.file, copy.from.node()), types)) |from| {
            if (from.file == made.file and from.scope == made.scope) continue;
        };
        return .{ .yes = callee };
    }
    return if (unknown) |why| .{ .unknown = why } else .no;
}

/// Whether the call at `node` hands one of `types`, or a value of or pointer to one, to a
/// library function that reads it as untyped data: a callee outside the program and outside the
/// type's package that returns the value it is handed cast to another type, there or through a
/// call it hands it on to (`std.mem.asBytes(&t)`, `sliceAsBytes`, `toBytes(t)`:
/// `castsParameter`), or whose body applies a reflective builtin to the parameter it is handed
/// (`std.meta.fieldNames(T)`, `fieldInfo`, `tags`: `@typeInfo(T)`). A function that only holds
/// a type it is given (`std.ArrayList(T)`: `@sizeOf`, `@alignOf`), allocates or keeps storage
/// for it (`Allocator.alloc(T, n)`, `realloc`, whose bytes of the old memory never reach its
/// result), or copies a value (`std.mem.swap`) is none. The callee is given. Unknown where an
/// argument that may be one of `types` (one, or unknown itself) goes to a callee or a parameter
/// no reading resolves, or where what a library callee does with it is unknown.
pub const Reflected = union(enum) { no, yes: Facts.Decl, unknown: Facts.Unknown };
pub fn reflectedByCall(self: *Context, node: Ast.Node.Index, types: []const Facts.Container) Context.Error!Reflected {
    if (types.len == 0) return .no;
    const call = (try Facts.calls.at(self.facts, self.file, node)) orelse return .no;
    const callees: []const Facts.Decl = switch (call.callee) {
        .function => |function| &.{function},
        .choice => |each| each,
        .any => |why| return if (try reachable(self, node, call, types, why)) |unknown| .{ .unknown = unknown } else .no,
    };
    const args = switch (call.args) {
        .known => |known| known,
        .unknown => |why| return .{ .unknown = why },
    };
    var unknown: ?Facts.Unknown = null;
    // A library function of the format convention: what its literal format places.
    for (callees) |callee| {
        if (try self.facts.program(callee.file)) continue;
        const params = formatParams(self, callee) orelse continue;
        switch (try formatReads(self, self.file, args, params, .{ .types = types })) {
            .yes => return .{ .yes = callee },
            .no => {},
            .unknown => |why| unknown = why,
        }
    }
    for (args, 0..) |arg, position| {
        const value = try self.facts.resolve(self.file, arg);
        // An argument whose type is unknown may be one of them where a library callee reads it.
        const handed = madeType(value, types);
        const unread = if (handed == null) unknownIn(value) else null;
        if (handed == null and unread == null) continue;
        for (callees) |callee| {
            if (try self.facts.program(callee.file)) continue;
            if (handed) |made| if (try samePackage(self, callee.file, made.file)) continue;
            // The value itself, not a pointer to it: its type is the governed type.
            const by_value = handed != null and value != .pointer;
            const reads: Is = either(try reflectsDeep(self, callee, position, by_value, 0), try castsParameter(self, callee, position));
            switch (reads) {
                .no => {},
                .yes => if (handed != null) return .{ .yes = callee } else {
                    unknown = unread;
                },
                .unknown => |why| unknown = why,
            }
        }
    }
    return if (unknown) |why| .{ .unknown = why } else .no;
}

/// Whether a call whose callee no reading resolves (`why`) may make or read one of `types`: only
/// through what it is handed, its receiver as written and its arguments, or through the type
/// its place gives its result (`std.mem.zeroes(T)` is handed `T`; `const s: S = f(b)` is placed in
/// `S`). Each of them known and none of `types`: no (null). Otherwise why it is unknown: `why`
/// where one of them is governed, its own unknown where one is unknown. A result the program
/// discards (a statement, `_ =`) is no value kept, so it has no place to read.
fn reachable(self: *Context, node: Ast.Node.Index, call: Facts.calls.Call, types: []const Facts.Container, why: Facts.Unknown) Context.Error!?Facts.Unknown {
    const tree = &self.project.at(self.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const full = tree.fullCall(&buffer, node) orelse return why;
    var holder: [1]Ast.Node.Index = undefined;
    const receiver: []const Ast.Node.Index = if (tree.nodeTag(call.callee_expr) == .field_access) blk: {
        holder[0] = tree.nodeData(call.callee_expr).node_and_token[0];
        break :blk &holder;
    } else &.{};
    for ([_][]const Ast.Node.Index{ receiver, full.ast.params }) |list| for (list) |arg| {
        const value = try self.facts.resolve(self.file, arg);
        if (madeType(value, types) != null) return why;
        if (unknownIn(value)) |unknown| return unknown;
    };
    if (discarded(self, node)) return null;
    const place = try self.facts.literalTypeIn(null, self.file, node);
    // No type written for the result (`const v = f(b)`): the callee's result is its type.
    if (place == .scalar) return why;
    if (madeType(place, types) != null) return why;
    return unknownIn(place);
}

/// Whether the call at `node` is a statement of its own, or assigned to `_`, past `try`,
/// parentheses, and a `catch` or `orelse` it is the left side of.
fn discarded(self: *Context, node: Ast.Node.Index) bool {
    const tree = &self.project.at(self.file).file.tree;
    const model = &self.project.at(self.file).model;
    var at = node;
    var parent = model.parentOf(at) orelse return false;
    while (switch (tree.nodeTag(parent)) {
        .@"try", .grouped_expression => true,
        .@"catch", .@"orelse" => tree.nodeData(parent).node_and_node[0] == at,
        // A prong's or a branch's value is the switch's or the `if`'s.
        .switch_case, .switch_case_one, .switch_case_inline, .switch_case_inline_one => tree.fullSwitchCase(parent).?.ast.target_expr == at, // safe: the tag is a case's
        .@"switch", .switch_comma => tree.fullSwitch(parent).?.ast.condition != at, // safe: the tag is a switch's
        .@"if", .if_simple => if (tree.fullIf(parent)) |branch| branch.ast.cond_expr != at else false,
        else => false,
    }) {
        at = parent;
        parent = model.parentOf(at) orelse return false;
    }
    switch (tree.nodeTag(parent)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => return true,
        .@"defer", .@"errdefer" => return true,
        // A loop's body: its value is no loop's result.
        .@"while", .while_simple, .while_cont, .@"for", .for_simple => {
            if (tree.fullWhile(parent)) |loop| return loop.ast.then_expr == at;
            if (tree.fullFor(parent)) |loop| return loop.ast.then_expr == at;
            return false;
        },
        .assign => {
            const lhs, const rhs = tree.nodeData(parent).node_and_node;
            return rhs == at and tree.nodeTag(lhs) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(lhs)), "_");
        },
        else => return false,
    }
}

/// Whether a library function makes the value it returns from untyped data: it returns a cast
/// of bytes it is handed (`castsParameter` over any parameter that holds data), or applies a
/// reflective builtin to one of its parameters (`@typeInfo(T)`: `mem.zeroes`, `zeroInit`).
fn makesFromData(self: *Context, function: Facts.Decl) Context.Error!Is {
    const casts = try castsParameter(self, function, null);
    if (casts == .yes) return .yes;
    const tree = &self.project.at(function.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, self.project.at(function.file).model.declarations[@backingInt(function.index)].node) orelse return casts;
    var parameters = proto.iterate(tree);
    var position: usize = 0;
    while (parameters.next()) |_| : (position += 1) {
        if (reflectsParameter(self, function, position)) return .yes;
    }
    return casts;
}

/// Yes where either is, else unknown where either is, else no.
fn either(a: Is, b: Is) Is {
    if (a == .yes or b == .yes) return .yes;
    if (a == .unknown) return a;
    return b;
}

/// The casts that carry a value to another type and keep its bits.
const bit_casts = [_][]const u8{ "@ptrCast", "@alignCast", "@constCast", "@volatileCast", "@bitCast" };

fn isBitCast(name: []const u8) bool {
    for (bit_casts) |each| if (std.mem.eql(u8, each, name)) return true;
    return false;
}

/// Whether `function` returns its parameter at `position` cast to another type, there or
/// through a call it hands the parameter to that does (`toBytes(v)` returning
/// `asBytes(&v).*`, `bytesToValue(T, b)` returning `bytesAsValue(T, b).*`). With no position,
/// any parameter that holds data the caller hands it: written `anytype`, or bytes (`[]const
/// u8`, `*[n]u8`, `[*]u8`). Its own allocation or storage it keeps (`self.metadata`) is no
/// parameter, so a cast of either is none: what it reads is what a value of the type wrote.
///
/// Read once per function and position for the run (`Casts`). A function the reading meets
/// again while it is still being read (`addOne` calling `addOneAssumeCapacity` calling back)
/// returns no cast by that path: a cast it returns is one some path that ends returns, the
/// least answer the calls agree on. An answer that took such a function as `no` holds only once
/// that function's own is known, so it is kept only where it is `yes`.
fn castsParameter(self: *Context, function: Facts.Decl, position: ?usize) Context.Error!Is {
    // What it keeps in its memo stays for the run.
    const rule_memory = self.keep();
    defer self.allocator = rule_memory;
    const memo = try self.facts.memo(Casts);
    const key: Casts.Key = .{ .function = function, .position = position orelse Casts.any };
    if (memo.found.get(key)) |known| return known;
    if (memo.active.contains(key)) {
        memo.assumed += 1;
        return .no;
    }
    try memo.active.put(self.allocator, key, {});
    const assumed = memo.assumed;
    const found = try castsParameterRead(self, function, position);
    _ = memo.active.remove(key);
    // Taken as `no` below by none still being read: final.
    if (found == .yes or memo.assumed == assumed) try memo.found.put(self.allocator, key, found);
    // Its own reading met this function again: the answer is this function's, and those met
    // within it are answered now.
    if (memo.active.count() == 0) memo.assumed = 0;
    return found;
}

/// The answers `castsParameter` read, by function and position, and those it is reading.
pub const Casts = struct {
    pub const Key = struct { function: Facts.Decl, position: usize };
    /// A position that stands for any parameter holding data.
    pub const any = std.math.maxInt(usize);
    found: std.AutoHashMapUnmanaged(Key, Is) = .empty,
    active: std.AutoHashMapUnmanaged(Key, void) = .empty,
    /// How many times a reading met a function still being read, which it took as `no`.
    assumed: usize = 0,
};

fn castsParameterRead(self: *Context, function: Facts.Decl, position: ?usize) Context.Error!Is {
    const tree = &self.project.at(function.file).file.tree;
    const declaration = self.facts.scopeNode(function);
    if (tree.nodeTag(declaration) != .fn_decl) return .no;
    const body = tree.nodeData(declaration).node_and_node[1];
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    var found: Is = .no;
    for (tree.nodes.items(.tag), 0..) |tag, raw| {
        if (tag != .@"return") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const at = tree.nodeMainToken(node);
        if (at < first or at > last) continue;
        const operand = tree.nodeData(node).opt_node.unwrap() orelse continue;
        found = either(found, try returnsCast(self, function, operand, position, false));
        if (found == .yes) return .yes;
    }
    return found;
}

/// Whether the returned expression `node` is the parameter at `position` (or one holding data)
/// cast, through the forms that hand on a value: grouping, `.*`, a slice, `try`, `@as`, both
/// results of an `if`, `orelse` and `catch`, and a call it is handed to that returns it cast.
fn returnsCast(self: *Context, function: Facts.Decl, node: Ast.Node.Index, position: ?usize, cast: bool) Context.Error!Is {
    const tree = &self.project.at(function.file).file.tree;
    switch (tree.nodeTag(node)) {
        .grouped_expression => return returnsCast(self, function, tree.nodeData(node).node_and_token[0], position, cast),
        .deref, .@"try", .address_of => return returnsCast(self, function, tree.nodeData(node).node, position, cast),
        .@"orelse", .@"catch" => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return either(try returnsCast(self, function, lhs, position, cast), try returnsCast(self, function, rhs, position, cast));
        },
        .slice_open, .slice, .slice_sentinel => return returnsCast(self, function, (tree.fullSlice(node) orelse return .no).ast.sliced, position, cast),
        .identifier => {
            const k = parameterAt(self, function, node) orelse return .no;
            return if (cast and if (position) |p| k == p else holdsData(self, function, k)) .yes else .no;
        },
        else => {},
    }
    if (tree.fullIf(node)) |branch| {
        const then = try returnsCast(self, function, branch.ast.then_expr, position, cast);
        const otherwise = branch.ast.else_expr.unwrap() orelse return then;
        return either(then, try returnsCast(self, function, otherwise, position, cast));
    }
    if (Facts.builtinName(tree, node)) |name| {
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        if (std.mem.eql(u8, name, "@as") and args.len == 2) return returnsCast(self, function, args[1], position, cast);
        if (isBitCast(name) and args.len >= 1) return returnsCast(self, function, args[args.len - 1], position, true);
        return .no;
    }
    // A call the parameter is handed to: the callee returns it cast, or it was cast here.
    const call = (try Facts.calls.at(self.facts, function.file, node)) orelse return .no;
    const args = switch (call.args) {
        .known => |known| known,
        .unknown => |why| return if (handsParameter(self, function, tree, node, position)) .{ .unknown = why } else .no,
    };
    var found: Is = .no;
    for (args, 0..) |arg, i| {
        if (castWritten(self, function, arg)) {
            found = either(found, try returnsCast(self, function, arg, position, false));
            if (found == .yes) return .yes;
        }
        const k = handedParameter(self, function, arg) orelse continue;
        if (if (position) |p| k != p else !holdsData(self, function, k)) continue;
        const callees: []const Facts.Decl = switch (call.callee) {
            .function => |one| &.{one},
            .choice => |each| each,
            .any => |why| {
                found = either(found, .{ .unknown = why });
                continue;
            },
        };
        for (callees) |callee| {
            found = either(found, try castsParameter(self, callee, i));
            if (found == .yes) return .yes;
        }
    }
    return found;
}

/// Whether the call at `node` in `function` is handed the parameter at `position` (or one holding
/// data) among its arguments as written, its receiver included.
fn handsParameter(self: *Context, function: Facts.Decl, tree: *const Ast, node: Ast.Node.Index, position: ?usize) bool {
    var buffer: [1]Ast.Node.Index = undefined;
    const full = tree.fullCall(&buffer, node) orelse return false;
    var written: [1]Ast.Node.Index = undefined;
    const receiver: []const Ast.Node.Index = if (tree.nodeTag(full.ast.fn_expr) == .field_access) blk: {
        written[0] = tree.nodeData(full.ast.fn_expr).node_and_token[0];
        break :blk &written;
    } else &.{};
    for ([_][]const Ast.Node.Index{ full.ast.params, receiver }) |list| for (list) |arg| {
        const k = handedParameter(self, function, arg) orelse continue;
        if (if (position) |p| k == p else holdsData(self, function, k)) return true;
    };
    return false;
}

/// Whether the argument `arg` is itself a cast written here, not only the parameter handed on.
fn castWritten(self: *Context, function: Facts.Decl, arg: Ast.Node.Index) bool {
    const tree = &self.project.at(function.file).file.tree;
    var at = arg;
    while (true) switch (tree.nodeTag(at)) {
        .grouped_expression => at = tree.nodeData(at).node_and_token[0],
        .address_of => at = tree.nodeData(at).node,
        else => break,
    };
    const name = Facts.builtinName(tree, at) orelse return false;
    return isBitCast(name);
}

/// The position of the parameter an argument hands on as it is (`b`, `&v`, `(b)`), if any.
fn handedParameter(self: *Context, function: Facts.Decl, arg: Ast.Node.Index) ?usize {
    const tree = &self.project.at(function.file).file.tree;
    var at = arg;
    while (true) switch (tree.nodeTag(at)) {
        .grouped_expression => at = tree.nodeData(at).node_and_token[0],
        .address_of => at = tree.nodeData(at).node,
        else => break,
    };
    if (tree.nodeTag(at) != .identifier) return null;
    return parameterAt(self, function, at);
}

/// The position among `function`'s parameters of the one the identifier `node` names.
fn parameterAt(self: *Context, function: Facts.Decl, node: Ast.Node.Index) ?usize {
    const tree = &self.project.at(function.file).file.tree;
    const model = &self.project.at(function.file).model;
    const index = (model.reference(node) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(index)];
    if (record.kind != .parameter) return null;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, model.declarations[@backingInt(function.index)].node) orelse return null;
    var parameters = proto.iterate(tree);
    var k: usize = 0;
    while (parameters.next()) |parameter| : (k += 1) {
        if (parameter.name_token == record.token) return k;
    }
    return null;
}

/// Whether `function`'s parameter at `position` holds data the caller hands it: written
/// `anytype`, or bytes (`[]const u8`, `*[n]u8`, `[*]u8`).
fn holdsData(self: *Context, function: Facts.Decl, position: usize) bool {
    const tree = &self.project.at(function.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, self.project.at(function.file).model.declarations[@backingInt(function.index)].node) orelse return false;
    var parameters = proto.iterate(tree);
    var k: usize = 0;
    while (parameters.next()) |parameter| : (k += 1) {
        if (k != position) continue;
        if (parameter.anytype_ellipsis3) |token| return tree.tokenTag(token) == .keyword_anytype;
        const written = parameter.type_expr orelse return false;
        const pointer = tree.fullPtrType(written) orelse return false;
        var child = pointer.ast.child_type;
        if (tree.fullArrayType(child)) |array| child = array.ast.elem_type;
        return tree.nodeTag(child) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(child)), "u8");
    }
    return false;
}

/// The builtins that read a type's fields, layout or tags by reflection.
const reflective = [_][]const u8{ "@typeInfo", "@field", "@FieldType", "@hasField", "@offsetOf", "@bitOffsetOf", "@tagName" };

/// Whether `function`'s body applies a reflective builtin to its parameter at `position`, as
/// its first operand (`@typeInfo(T)`, `@field(value, name)`).
fn reflectsParameter(self: *Context, function: Facts.Decl, position: usize) bool {
    const tree = &self.project.at(function.file).file.tree;
    const model = &self.project.at(function.file).model;
    const record = model.declarations[@backingInt(function.index)];
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, record.node) orelse return false;
    var parameters = proto.iterate(tree);
    var index: usize = 0;
    const name = while (parameters.next()) |parameter| : (index += 1) {
        if (index == position) break parameter.name_token orelse return false;
    } else return false;
    // By its name: Zig refuses a name in the body that shadows a parameter, so an identifier
    // spelling it there is it.
    const spelled = tree.tokenSlice(name);
    // A function's record holds its prototype; the body is the declaration's around it.
    const declaration = self.facts.scopeNode(function);
    if (tree.nodeTag(declaration) != .fn_decl) return false;
    const body = tree.nodeData(declaration).node_and_node[1];
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    for (tree.nodes.items(.tag), 0..) |_, raw| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const builtin = Facts.builtinName(tree, node) orelse continue;
        const at = tree.nodeMainToken(node);
        if (at < first or at > last) continue;
        const is = for (reflective) |each| {
            if (std.mem.eql(u8, each, builtin)) break true;
        } else false;
        if (!is) continue;
        var arguments: [2]Ast.Node.Index = undefined;
        const operands = Facts.builtinArgs(tree, node, &arguments);
        if (operands.len == 0 or tree.nodeTag(operands[0]) != .identifier) continue;
        if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(operands[0])), spelled)) return true;
    }
    return false;
}

/// The builtins that read a type's fields, by name or place.
const field_reading = [_][]const u8{ "@field", "@FieldType", "@hasField", "@offsetOf", "@bitOffsetOf" };

/// How deep `reflectsDeep` follows a parameter handed on: past it, a named refusal.
const reflection_depth = 8;

/// Whether a library function reads its parameter at `position` by reflection, there or through
/// what it hands it on to: a reflective builtin applied to the parameter (`reflectsParameter`)
/// or to its type (`@TypeOf(key)`, or a constant holding either: `const Key = @TypeOf(key)`),
/// or a call handing either on to a function that reads it so (std's `autoHash(h, key)`, whose
/// `typeContainsSlice(Key)` reads `@typeInfo`; json's `value(v, ...)`, whose `s.write(v)` does),
/// a function of the format convention read by its placeholders (`formatReads`). Unknown where
/// such a call's callee or arguments no reading resolves, or past `reflection_depth` calls deep
/// (`budget`): never a pass. Memoized as `castsParameter` is, a function met again while it is
/// read taken as `no` until its own reading ends. Its type is the governed type only where the
/// parameter holds the value itself (`by_value`): a pointer's or a slice's type is read by
/// `@typeInfo(@TypeOf(slice))` (`Allocator.realloc`), never the type it points at, so there only
/// a reflective builtin given the parameter itself counts.
fn reflectsDeep(self: *Context, function: Facts.Decl, position: usize, by_value: bool, depth: usize) Context.Error!Is {
    if (depth > reflection_depth) return .{ .unknown = .budget };
    const rule_memory = self.keep();
    defer self.allocator = rule_memory;
    const memo = try self.facts.memo(Reflects);
    const key: Casts.Key = .{ .function = function, .position = position * 2 + @intFromBool(by_value) };
    if (memo.found.get(key)) |known| return known;
    if (memo.active.contains(key)) {
        memo.assumed += 1;
        return .no;
    }
    try memo.active.put(self.allocator, key, {});
    const assumed = memo.assumed;
    const found = try reflectsDeepRead(self, function, position, by_value, depth);
    _ = memo.active.remove(key);
    if (found == .yes or memo.assumed == assumed) try memo.found.put(self.allocator, key, found);
    if (memo.active.count() == 0) memo.assumed = 0;
    return found;
}

/// The answers `reflectsDeep` read, as `Casts` keeps `castsParameter`'s.
pub const Reflects = struct {
    found: std.AutoHashMapUnmanaged(Casts.Key, Is) = .empty,
    active: std.AutoHashMapUnmanaged(Casts.Key, void) = .empty,
    assumed: usize = 0,
};

fn reflectsDeepRead(self: *Context, function: Facts.Decl, position: usize, by_value: bool, depth: usize) Context.Error!Is {
    // The function the program calls: any reflective builtin given the parameter, as before.
    // Past it, only a builtin that reads the type's fields (`field_reading`): a generic asking
    // what kind of type it was handed (`findScalarPos`'s `@typeInfo(T)`, a sort's) reads none.
    if (depth == 0 and reflectsParameter(self, function, position)) return .yes;
    const tree = &self.project.at(function.file).file.tree;
    const model = &self.project.at(function.file).model;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, model.declarations[@backingInt(function.index)].node) orelse return .no;
    var parameters = proto.iterate(tree);
    var index: usize = 0;
    const name = while (parameters.next()) |parameter| : (index += 1) {
        if (index == position) break parameter.name_token orelse return .no;
    } else return .no;
    const declaration = self.facts.scopeNode(function);
    if (tree.nodeTag(declaration) != .fn_decl) return .no;
    const body = tree.nodeData(declaration).node_and_node[1];
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    // The names that hold the parameter or its type: it, and, by value, each constant given
    // either.
    var names: std.ArrayList([]const u8) = .empty;
    try names.append(self.allocator, tree.tokenSlice(name));
    var grew = by_value;
    while (grew) {
        grew = false;
        for (tree.nodes.items(.tag), 0..) |_, raw| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
            const at = tree.nodeMainToken(node);
            if (at < first or at > last) continue;
            const variable = tree.fullVarDecl(node) orelse continue;
            if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) continue;
            const init = variable.ast.init_node.unwrap() orelse continue;
            if (!namesSubject(tree, init, names.items, by_value)) continue;
            const held = tree.tokenSlice(variable.ast.mut_token + 1);
            if (amongNames(names.items, held)) continue;
            try names.append(self.allocator, held);
            grew = true;
        }
    }
    var unknown: ?Facts.Unknown = null;
    for (tree.nodes.items(.tag), 0..) |_, raw| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const at = tree.nodeMainToken(node);
        if (at < first or at > last) continue;
        // A reflective builtin applied to one of the names.
        if (Facts.builtinName(tree, node)) |builtin| {
            if (!amongNames(&field_reading, builtin)) continue;
            var arguments: [2]Ast.Node.Index = undefined;
            const operands = Facts.builtinArgs(tree, node, &arguments);
            if (operands.len != 0 and namesSubject(tree, operands[0], names.items, by_value)) return .yes;
            continue;
        }
        // A call handing one of them on.
        if (!Facts.calls.written(tree, node)) continue;
        const call = (try Facts.calls.at(self.facts, function.file, node)) orelse continue;
        var full_buffer: [1]Ast.Node.Index = undefined;
        const full = tree.fullCall(&full_buffer, node) orelse continue;
        var hands = false;
        for (full.ast.params) |param| hands = hands or namesSubject(tree, param, names.items, by_value) or holdsSubject(tree, param, names.items, by_value);
        if (tree.nodeTag(full.ast.fn_expr) == .field_access) hands = hands or namesSubject(tree, tree.nodeData(full.ast.fn_expr).node_and_token[0], names.items, by_value);
        if (!hands) continue;
        const args = switch (call.args) {
            .known => |known| known,
            .unknown => |why| {
                unknown = why;
                continue;
            },
        };
        const callees: []const Facts.Decl = switch (call.callee) {
            .function => |one| &.{one},
            .choice => |each| each,
            .any => |why| {
                unknown = why;
                continue;
            },
        };
        for (callees) |callee| {
            const reads: Is = if (formatParams(self, callee)) |params|
                try formatReads(self, function.file, args, params, .{ .names = .{ .list = names.items, .by_value = by_value } })
            else reads: {
                var each: Is = .no;
                for (args, 0..) |arg, handed| {
                    if (!namesSubject(tree, arg, names.items, by_value)) continue;
                    each = either(each, try reflectsDeep(self, callee, handed, by_value, depth + 1));
                }
                break :reads each;
            };
            switch (reads) {
                .yes => return .yes,
                .no => {},
                .unknown => |why| unknown = why,
            }
        }
    }
    return if (unknown) |why| .{ .unknown = why } else .no;
}

fn amongNames(list: []const []const u8, name: []const u8) bool {
    for (list) |each| if (std.mem.eql(u8, each, name)) return true;
    return false;
}

/// Whether `node`, parentheses aside, is one of `names`, or, `by_value`, `@TypeOf` of one.
fn namesSubject(tree: *const Ast, node: Ast.Node.Index, names: []const []const u8, by_value: bool) bool {
    var at = node;
    while (tree.nodeTag(at) == .grouped_expression) at = tree.nodeData(at).node_and_token[0];
    if (tree.nodeTag(at) == .identifier) return amongNames(names, tree.tokenSlice(tree.nodeMainToken(at)));
    if (!by_value) return false;
    const builtin = Facts.builtinName(tree, at) orelse return false;
    if (!std.mem.eql(u8, builtin, "@TypeOf")) return false;
    var arguments: [2]Ast.Node.Index = undefined;
    const operands = Facts.builtinArgs(tree, at, &arguments);
    return operands.len == 1 and namesSubject(tree, operands[0], names, by_value);
}

/// Whether `node` is a tuple or struct literal one of whose elements is one of `names`.
fn holdsSubject(tree: *const Ast, node: Ast.Node.Index, names: []const []const u8, by_value: bool) bool {
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullArrayInit(&buffer, node)) |init| {
        for (init.ast.elements) |element| if (namesSubject(tree, element, names, by_value)) return true;
    } else if (tree.fullStructInit(&buffer, node)) |init| {
        for (init.ast.fields) |field| if (namesSubject(tree, field, names, by_value)) return true;
    }
    return false;
}

/// A library function's format convention, std's print family (`Writer.print`, `debug.print`,
/// `log.err`, `fmt.allocPrint`, `debug.panic`): a `comptime` parameter named `fmt` or `format`
/// whose next parameter is `anytype`, the arguments its placeholders place.
const FormatParams = struct { format: usize, args: usize };

fn formatParams(self: *Context, function: Facts.Decl) ?FormatParams {
    const tree = &self.project.at(function.file).file.tree;
    const record = self.project.at(function.file).model.declarations[@backingInt(function.index)];
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, record.node) orelse return null;
    var parameters = proto.iterate(tree);
    var index: usize = 0;
    var format: ?usize = null;
    while (parameters.next()) |parameter| : (index += 1) {
        if (format) |at| {
            const untyped = if (parameter.anytype_ellipsis3) |token| tree.tokenTag(token) == .keyword_anytype else false;
            return if (untyped) .{ .format = at, .args = index } else null;
        }
        const name = parameter.name_token orelse continue;
        const fixed = if (parameter.comptime_noalias) |token| tree.tokenTag(token) == .keyword_comptime else false;
        const spelled = tree.tokenSlice(name);
        if (fixed and (std.mem.eql(u8, spelled, "fmt") or std.mem.eql(u8, spelled, "format"))) format = index;
    }
    return null;
}

/// Where a format-convention call's arguments hold the subject: a governed value (`types`, at
/// the program's call) or a name a library function reads it by (`names`).
const Subject = union(enum) { types: []const Facts.Container, names: struct { list: []const []const u8, by_value: bool } };

/// Whether a call of the format convention (`params`) reads the subject by reflection, by its
/// literal format's placeholders: an argument holding it placed as `{f}` (the type's own
/// `format`) or `{*}` (its address) is not read; placed any other way (`{any}`, `{}`, `{s}`)
/// std's `printValue` walks its fields. `args` are the call's arguments in its callee's
/// parameter order. A format no literal writes, where an argument holds the subject, is refused
/// (`unsupported`): no reading here says what it places; never a pass.
fn formatReads(self: *Context, file: Project.FileId, args: []const Ast.Node.Index, params: FormatParams, subject: Subject) Context.Error!Is {
    if (params.args >= args.len or params.format >= args.len) return .no;
    const tree = &self.project.at(file).file.tree;
    var at = args[params.args];
    while (tree.nodeTag(at) == .grouped_expression) at = tree.nodeData(at).node_and_token[0];
    // Each argument the format can place, by position or by name, and whether it holds the subject.
    var holds: std.ArrayList(struct { name: ?[]const u8, is: Is }) = .empty;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullArrayInit(&buffer, at)) |init| {
        for (init.ast.elements) |element| try holds.append(self.allocator, .{ .name = null, .is = try subjectIn(self, file, element, subject) });
    } else if (tree.fullStructInit(&buffer, at)) |init| {
        for (init.ast.fields) |field| try holds.append(self.allocator, .{
            .name = if (Model.initName(tree, field)) |token| tree.tokenSlice(token) else null,
            .is = try subjectIn(self, file, field, subject),
        });
    } else return .no;
    var any: Is = .no;
    for (holds.items) |one| any = either(any, one.is);
    if (any == .no) return .no;
    const format = args[params.format];
    if (tree.nodeTag(format) != .string_literal) return .{ .unknown = .unsupported };
    const raw = tree.tokenSlice(tree.nodeMainToken(format));
    const text = raw[1 .. raw.len - 1];
    var next: usize = 0;
    var i: usize = 0;
    var found: Is = .no;
    while (i < text.len) : (i += 1) {
        if (text[i] == '}') {
            if (i + 1 < text.len and text[i + 1] == '}') i += 1;
            continue;
        }
        if (text[i] != '{') continue;
        if (i + 1 < text.len and text[i + 1] == '{') {
            i += 1;
            continue;
        }
        const close = std.mem.findScalarPos(u8, text, i, '}') orelse return .{ .unknown = .unsupported };
        var inner = text[i + 1 .. close];
        i = close;
        // `{[name]...}`, `{2...}`, or the next argument.
        var placed: ?Is = null;
        if (inner.len != 0 and inner[0] == '[') {
            const end = std.mem.findScalar(u8, inner, ']') orelse return .{ .unknown = .unsupported };
            const wanted = inner[1..end];
            inner = inner[end + 1 ..];
            for (holds.items) |one| if (one.name) |named| if (std.mem.eql(u8, named, wanted)) {
                placed = one.is;
            };
        } else {
            var digits: usize = 0;
            while (digits < inner.len and std.ascii.isDigit(inner[digits])) digits += 1;
            const position = if (digits != 0) std.fmt.parseInt(usize, inner[0..digits], 10) catch return .{ .unknown = .unsupported } else blk: {
                next += 1;
                break :blk next - 1;
            };
            inner = inner[digits..];
            if (position < holds.items.len) placed = holds.items[position].is;
        }
        const is = placed orelse continue;
        const specifier = inner[0 .. std.mem.findScalar(u8, inner, ':') orelse inner.len];
        if (!walksFields(specifier)) continue;
        found = either(found, is);
        if (found == .yes) return found;
    }
    return found;
}

/// Whether std's `printValue` walks a struct's fields placed by `specifier`: `{any}`, `{}`, and
/// an optional's or an error union's (`{?}`, `{!}`) payload so placed. `{f}` calls the type's
/// own `format`, `{d}`, `{x}`, `{e}`, `{B}` its own `formatNumber` or `formatByteSize`, `{*}`
/// writes the address; `{s}` and `{c}` do not compile on a struct.
fn walksFields(specifier: []const u8) bool {
    var rest = specifier;
    while (rest.len != 0 and (rest[0] == '?' or rest[0] == '!')) rest = rest[1..];
    return rest.len == 0 or std.mem.eql(u8, rest, "any");
}

/// Whether the argument at `node` holds the subject: a value of a governed type or a pointer to
/// one (`types`), unknown where its type is; or a name of it (`names`).
fn subjectIn(self: *Context, file: Project.FileId, node: Ast.Node.Index, subject: Subject) Context.Error!Is {
    return switch (subject) {
        .names => |names| if (namesSubject(&self.project.at(file).file.tree, node, names.list, names.by_value)) .yes else .no,
        .types => |types| blk: {
            const value = try self.facts.resolve(file, node);
            if (madeType(value, types) != null) break :blk .yes;
            break :blk if (unknownIn(value)) |why| .{ .unknown = why } else .no;
        },
    };
}

/// The one of `types` a value is, or points at, through optionals and error unions; of a
/// choice, the first a part of it is (the build that takes that part makes it).
fn madeType(value: Facts.Value, types: []const Facts.Container) ?Facts.Container {
    var at = value;
    while (true) at = switch (at) {
        .pointer => |inner| inner.child.*,
        .optional, .error_union => |inner| inner.*,
        .alternatives => |each| {
            for (each) |one| if (madeType(one, types)) |found| return found;
            return null;
        },
        else => break,
    };
    const found = switch (at) {
        .instance, .container => |found| found,
        .alternatives => return null, // unreachable: a choice is read above
        else => return null,
    };
    for (types) |t| if (t.file == found.file and t.scope == found.scope) return t;
    return null;
}

/// Why a value is unknown, read through pointers, optionals and error unions as `madeType` reads
/// it: null where it is known (a choice holds no unknown).
pub fn unknownIn(value: Facts.Value) ?Facts.Unknown {
    var at = value;
    while (true) at = switch (at) {
        .pointer => |inner| inner.child.*,
        .optional, .error_union => |inner| inner.*,
        .unknown => |why| return why,
        else => return null,
    };
}

/// Whether two files are of one package: both std's, or both of one package their caller names.
fn samePackage(self: *Context, a: Project.FileId, b: Project.FileId) Context.Error!bool {
    if (try self.facts.standard(a) and try self.facts.standard(b)) return true;
    const left = self.project.at(a).input.package;
    return left.len != 0 and std.mem.eql(u8, left, self.project.at(b).input.package);
}

/// Whether a function's result is written in terms of its own parameter (`T`, `?T`, `E!T`,
/// `*T`, `[]T`, `@TypeOf(x)`): a name in its result type whose declaration is one of the
/// function's own parameters (a made container's method returning its type function's `T`
/// returns what the container holds, and is none).
fn reflectiveResult(self: *Context, function: Facts.Decl) bool {
    const tree = &self.project.at(function.file).file.tree;
    const model = &self.project.at(function.file).model;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, model.declarations[@backingInt(function.index)].node) orelse return false;
    const result = proto.ast.return_type.unwrap() orelse return false;
    return refersToParameter(tree, model, proto, result);
}

/// Whether a type expression refers to one of `proto`'s parameters, by its declaration (`T`,
/// `?T`, `E!*T`, `[]const T`, `[@sizeOf(T)]u8`, `@TypeOf(x)`, `Made(T)`, `T.Elem`). A form not
/// read here refers to none.
pub fn refersToParameter(tree: *const Ast, model: *const Model, proto: Ast.full.FnProto, written: Ast.Node.Index) bool {
    return parameterIn(tree, model, proto, written, 0);
}

fn parameterIn(tree: *const Ast, model: *const Model, proto: Ast.full.FnProto, node: Ast.Node.Index, depth: usize) bool {
    if (depth == 16) return false;
    if (tree.fullPtrType(node)) |ptr| return parameterIn(tree, model, proto, ptr.ast.child_type, depth + 1);
    if (tree.fullArrayType(node)) |array| return parameterIn(tree, model, proto, array.ast.elem_type, depth + 1) or parameterIn(tree, model, proto, array.ast.elem_count, depth + 1);
    switch (tree.nodeTag(node)) {
        .identifier => {
            const index = (model.reference(node) orelse return false).declaration orelse return false;
            const record = model.declarations[@backingInt(index)];
            if (record.kind != .parameter) return false;
            var parameters = proto.iterate(tree);
            while (parameters.next()) |parameter| if (parameter.name_token == record.token) return true;
            return false;
        },
        .grouped_expression => return parameterIn(tree, model, proto, tree.nodeData(node).node_and_token[0], depth + 1),
        .optional_type => return parameterIn(tree, model, proto, tree.nodeData(node).node, depth + 1),
        .error_union => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return parameterIn(tree, model, proto, lhs, depth + 1) or parameterIn(tree, model, proto, rhs, depth + 1);
        },
        .field_access => return parameterIn(tree, model, proto, tree.nodeData(node).node_and_token[0], depth + 1),
        else => {},
    }
    var buffer: [2]Ast.Node.Index = undefined;
    if (Facts.builtinName(tree, node) != null) {
        for (Facts.builtinArgs(tree, node, &buffer)) |arg| if (parameterIn(tree, model, proto, arg, depth + 1)) return true;
        return false;
    }
    var call_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&call_buffer, node)) |call| {
        for (call.ast.params) |arg| if (parameterIn(tree, model, proto, arg, depth + 1)) return true;
    }
    return false;
}

/// Whether a governed declaration is spelled `spelled` where `site` is.
fn spelledAny(self: *Context, governed: []const Governed, renamed: []const []const []const u8, spelled: []const u8, site: Ast.TokenIndex) bool {
    const testing = self.inTest(site);
    for (governed, renamed) |g, names| if (spells(g, names, spelled) and !(testing and g.target.production)) return true;
    return false;
}

/// The site at `site` for the first governed declaration among `decls`, a definition and its
/// origin in pairs (`reach`).
fn append(self: *Context, governed: []const Governed, renamed: []const []const []const u8, site: Ast.TokenIndex, node: Ast.Node.Index, spelled: []const u8, decls: []const Facts.Decl, out: *std.ArrayList(Site)) Context.Error!void {
    const testing = self.inTest(site);
    for (decls, 0..) |decl, d| for (governed, renamed) |g, names| {
        if (!spells(g, names, spelled) or (testing and g.target.production) or !matches(self, g, decl)) continue;
        // A match on the origin of a different declaration came through the program's alias.
        const alias = d % 2 == 1 and !std.meta.eql(decls[d - 1], decl) and self.project.at(decls[d - 1].file).input.selected;
        const declared = alias and switch (self.project.at(decls[d - 1].file).model.scopes[@backingInt(self.project.at(decls[d - 1].file).model.declarations[@backingInt(decls[d - 1].index)].scope)].kind) {
            .file, .container => true,
            else => false,
        };
        try out.append(self.allocator, .{ .token = site, .node = node, .index = g.index, .decl = decl, .through_alias = alias, .alias_declared = declared });
        return;
    };
}

/// Whether `spelled` names `g`: its own name, or one of `names`, its aliases'.
fn spells(g: Governed, names: []const []const u8, spelled: []const u8) bool {
    if (std.mem.eql(u8, g.name, spelled)) return true;
    for (names) |name| if (std.mem.eql(u8, name, spelled)) return true;
    return false;
}

/// Which aliases `aliasNames` gives: those in the program's files the run does not select, whose
/// own site this run does not report (`.unreported`: a rule that reports what a reference
/// reaches reports an alias where it spells the declaration, so a use of it is no second site),
/// or every alias in the program (`.program`: what a call may reach, whatever reports it).
pub const AliasScope = enum { unreported, program };

/// The names the program's files (those `among` names) give `decls` (or a function of the
/// extern `symbol`) under another name: `pub const zero = std.crypto.secureZero;`. A use that
/// spells one reaches the declaration. Each alias is found once, by the declaration its value reaches. One
/// whose value does not resolve reaches what the name it spells last may (`h.sync`, `T.sync`):
/// it is also called so where that name is a declaration's or its aliases' (a use of it is
/// then unknown, `paired`); a name `@field` computes may be any.
pub fn aliasNames(self: *Context, comptime among: AliasScope, decls: []const Facts.Decl, symbol: ?[]const u8, out: *std.ArrayList([]const u8)) Context.Error!void {
    // What it keeps in its memo stays for the run.
    const rule_memory = self.keep();
    defer self.allocator = rule_memory;
    const found = try self.facts.memo(Aliases(among));
    if (!found.built) {
        found.built = true;
        for (self.project.sources) |*source| {
            if (source.file.status != .parsed or !try self.facts.program(source.id)) continue;
            if (among == .unreported and source.input.selected) continue;
            try aliasesIn(self, among, found, source);
        }
    }
    // std's own aliases of a std target (`ArrayListUnmanaged = ArrayList`, `ArrayListAligned =
    // array_list.Aligned`): in the target's file, or a std file that imports it, each once.
    for (decls) |decl| {
        if (!try self.facts.standard(decl.file)) continue;
        try stdAliasesIn(self, among, found, decl.file);
        for (self.project.imports) |edge| if (edge.target == decl.file and try self.facts.standard(edge.from)) try stdAliasesIn(self, among, found, edge.from);
    }
    const start = out.items.len;
    for (decls) |decl| if (found.by_origin.get(decl)) |names| try out.appendSlice(self.allocator, names.items);
    if (symbol) |wanted| {
        var each = found.by_origin.iterator();
        while (each.next()) |entry| if (externSymbol(self.project, entry.key_ptr.*)) |own| if (std.mem.eql(u8, own, wanted)) {
            try out.appendSlice(self.allocator, entry.value_ptr.items);
        };
    }
    // The aliases whose value does not resolve that spell one of these names, or of theirs.
    var spelled: std.ArrayList([]const u8) = .empty;
    for (decls) |decl| try spelled.append(self.allocator, self.project.at(decl.file).model.declarations[@backingInt(decl.index)].name);
    if (symbol) |wanted| try spelled.append(self.allocator, wanted);
    try spelled.appendSlice(self.allocator, out.items[start..]);
    var grew = true;
    while (grew) {
        grew = false;
        for (found.unknown.items) |alias| {
            const named = for (spelled.items) |name| {
                if (std.mem.eql(u8, name, alias.name)) break true;
            } else false;
            if (named) continue;
            const reaches = if (alias.spells) |last| for (spelled.items) |name| {
                if (std.mem.eql(u8, name, last)) break true;
            } else false else true;
            if (!reaches) continue;
            try spelled.append(self.allocator, alias.name);
            try out.append(self.allocator, alias.name);
            grew = true;
        }
    }
}
/// The aliases one file declares, into the memo.
fn aliasesIn(self: *Context, comptime among: AliasScope, found: *Aliases(among), source: anytype) Context.Error!void {
    const tree = &source.file.tree;
    for (source.model.declarations, 0..) |d, i| {
        if (d.kind != .variable) continue;
        // A function's own constant is named only in its body: an alias another file
        // cannot spell, so one only where the run reads that file (shakedown's
        // `const call = @field(IoCall, name);` names nothing a `.call` elsewhere reaches).
        const scope = source.model.scopes[@backingInt(d.scope)].kind;
        if (scope != .file and scope != .container and !source.input.selected) continue;
        const variable = tree.fullVarDecl(d.node) orelse continue;
        const init = variable.ast.init_node.unwrap() orelse continue;
        // An alias is written as a declaration's path, or a comptime choice among them:
        // each value its initializer may give names a declaration (`std.debug.print`,
        // `@field(ns, "print")`, `if (debug) std.debug.print else quiet`). A call's result
        // or a literal is a value of its own, never an alias, and is not resolved here.
        const leaves = switch (try Facts.accesses.valuesOf(self.facts, source.id, init)) {
            .leaves => |each| each,
            .unknown => continue,
        };
        if (leaves.len == 0) continue;
        const spelled = try self.allocator.alloc(?[]const u8, leaves.len);
        var named = true;
        for (leaves, spelled) |leaf, *name| {
            const path = try Facts.accesses.pathOf(self.facts, source.id, leaf);
            named = path.root != .none;
            for (path.steps) |step| named = named and (step.kind == .field or step.kind == .root);
            if (!named) break;
            // The name it spells last (null: `@field`'s computed name, which may be any).
            const last = path.steps[0];
            name.* = if (last.kind == .field) last.name else try Model.identifier(self.allocator, tree.tokenSlice(tree.nodeMainToken(last.node)));
        }
        if (!named) continue;
        const decl: Facts.Decl = .{ .file = source.id, .index = @fromBackingInt(@intCast(i)) };
        // A function the value is, or one a comptime choice may give in the build that
        // takes it, is what the alias calls; any other declaration it names (a type's, a
        // constant's) is reached by its origin.
        var unknown = false;
        switch (try self.facts.declaration(decl)) {
            .function => |function| try aliasOf(self, found, function, decl, d.name),
            .alternatives => |each| for (each) |one| switch (one) {
                .function => |function| try aliasOf(self, found, function, decl, d.name),
                // A choice, which a choice never holds, is read as one not known.
                .unknown, .alternatives => unknown = true,
                else => {},
            },
            .unknown => unknown = true,
            // Each declaration it may name, through a choice of holders a build decides.
            else => switch (try self.facts.origins(decl)) {
                .decls => |reached| for (reached) |each| try aliasOf(self, found, each, decl, d.name),
                .unknown => unknown = true,
            },
        }
        // A value that does not resolve may be what each name it spells last is.
        if (unknown) for (spelled) |name| try found.unknown.append(self.allocator, .{ .name = d.name, .spells = name });
    }
}

/// std's own aliases in `file`, once a run.
fn stdAliasesIn(self: *Context, comptime among: AliasScope, found: *Aliases(among), file: Project.FileId) Context.Error!void {
    const source = self.project.at(file);
    if (source.file.status != .parsed) return;
    if ((try found.std_files.getOrPut(self.facts.gpa, file)).found_existing) return;
    try aliasesIn(self, among, found, source);
}

/// `name`, an alias `decl` declares, as a name of `reached`.
fn aliasOf(self: *Context, found: anytype, reached: Facts.Decl, decl: Facts.Decl, name: []const u8) Context.Error!void {
    if (std.meta.eql(reached, decl)) return;
    const entry = try found.by_origin.getOrPut(self.allocator, reached);
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    try entry.value_ptr.append(self.allocator, name);
}
fn Aliases(comptime among: AliasScope) type {
    return struct {
        /// Which files' aliases: one memo per scope.
        pub const scope = among;
        built: bool = false,
        by_origin: std.AutoHashMapUnmanaged(Facts.Decl, std.ArrayList([]const u8)) = .empty,
        /// The aliases whose value does not resolve: each name, and the name its value spells
        /// last (null for `@field`'s, which may be any).
        unknown: std.ArrayList(struct { name: []const u8, spells: ?[]const u8 }) = .empty,
        /// The std files whose aliases are in it.
        std_files: std.AutoHashMapUnmanaged(Project.FileId, void) = .empty,
    };
}

/// Whether every governed declaration named `name` is a function of a namespace: a container
/// with no fields, so no value's method.
fn free(self: *Context, governed: []const Governed, name: []const u8) bool {
    for (governed) |g| {
        if (!std.mem.eql(u8, g.name, name)) continue;
        for (g.decls) |decl| {
            const model = &self.project.at(decl.file).model;
            const scope = model.declarations[@backingInt(decl.index)].scope;
            if (model.declarations[@backingInt(decl.index)].kind != .function) return false;
            for (model.declarations) |other| if (other.kind == .field and other.scope == scope) return false;
        }
    }
    return true;
}

/// Whether a member access is the callee of a call.
fn methodCall(self: *Context, member: Ast.Node.Index) bool {
    const tree = &self.project.at(self.file).file.tree;
    const parent = self.project.at(self.file).model.parentOf(member) orelse return false;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, parent) orelse return false;
    return call.ast.fn_expr == member;
}

fn matches(self: *Context, g: Governed, decl: Facts.Decl) bool {
    for (g.decls) |target| if (std.meta.eql(target, decl)) return true;
    const symbol = g.symbol orelse return false;
    const own = externSymbol(self.project, decl) orelse return false;
    return std.mem.eql(u8, own, symbol);
}

/// The declarations a path names from its roots: through every alternative of a per-build
/// choice (`c.F` is a different struct per target), public ones only from a module, each through
/// its aliases. None when no alternative has it; unknown where an alias on the way does not
/// resolve.
fn walk(self: *Context, roots: []const Project.FileId, path: []const u8, public_only: bool) Context.Error!Declared {
    var current: std.ArrayList(Facts.Container) = .empty;
    for (roots) |root| try current.append(self.allocator, self.facts.rootOf(root));
    var found: std.ArrayList(Facts.Decl) = .empty;
    var names = std.mem.splitScalar(u8, path, '.');
    while (names.next()) |name| {
        found.clearRetainingCapacity();
        for (current.items) |container| {
            const decl = self.facts.member(container, name) orelse continue;
            // A field has no `pub`: every field of a container a program reaches is its to name.
            const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
            if (public_only and !record.public and record.kind != .field) continue;
            try found.append(self.allocator, switch (try self.facts.origin(decl)) {
                .decl => |origin| origin,
                .none => decl,
                .unknown => |why| return .{ .unknown = why },
            });
        }
        if (found.items.len == 0) return .none;
        if (names.peek() == null) break;
        current.clearRetainingCapacity();
        for (found.items) |decl| try containers(self, try self.facts.declaration(decl), &current);
    }
    return .{ .decls = try found.toOwnedSlice(self.allocator) };
}

/// The containers a value names, each alternative of a choice its own.
fn containers(self: *Context, value: Facts.Value, out: *std.ArrayList(Facts.Container)) Context.Error!void {
    switch (value) {
        .container, .instance => |c| try out.append(self.allocator, c),
        .pointer => |inner| try containers(self, inner.child.*, out),
        .alternatives => |each| for (each) |one| try containers(self, one, out),
        .function => |decl| if (try self.facts.template(decl)) |made| try containers(self, made, out),
        else => {},
    }
}

const Reached = union(enum) { decls: []const Facts.Decl, unknown: Facts.Unknown };

/// What a site refers to: its declaration through aliases, or the member of each container its
/// receiver may be.
fn reach(self: *Context, node: Ast.Node.Index, tag: Ast.Node.Tag, spelled: []const u8, governed: []const Governed) Context.Error!Reached {
    if (tag == .enum_literal) switch (try self.facts.literalDeclarations(self.file, node, spelled)) {
        .unknown => |why| return .{ .unknown = why },
        // One per part of a place a build picks, each with its origin.
        .decls => |found| {
            var decls: std.ArrayList(Facts.Decl) = .empty;
            for (found) |decl| switch (try paired(self, decl)) {
                .pair => |pair| try decls.appendSlice(self.allocator, &pair),
                .unknown => |why| return .{ .unknown = why },
            };
            return .{ .decls = decls.items };
        },
    };
    const definition = if (tag == .identifier or tag == .field_access) try self.facts.definition(self.file, node) else try self.facts.reflected(self.file, node);
    switch (definition) {
        .decl => |decl| return switch (try paired(self, decl)) {
            .pair => |pair| .{ .decls = try self.allocator.dupe(Facts.Decl, &pair) },
            .unknown => |why| .{ .unknown = why },
        },
        // Named by no declaration, or by one not known: read by the value and the receiver below.
        .none, .unknown => {},
    }
    if (tag == .identifier) {
        const value = try self.facts.resolve(self.file, node);
        return if (value == .unknown) .{ .unknown = value.unknown } else .{ .decls = &.{} };
    }
    const tree = &self.project.at(self.file).file.tree;
    const receiver_node = if (tag == .field_access) tree.nodeData(node).node_and_token[0] else blk: {
        var buffer: [2]Ast.Node.Index = undefined;
        break :blk Facts.builtinArgs(tree, node, &buffer)[0];
    };
    const receiver = try self.facts.resolve(self.file, receiver_node);
    if (receiver == .unknown) return if (try refuted(self, node, tag, spelled, governed)) .{ .decls = &.{} } else .{ .unknown = receiver.unknown };
    var options: std.ArrayList(Facts.Container) = .empty;
    try containers(self, receiver, &options);
    var decls: std.ArrayList(Facts.Decl) = .empty;
    for (options.items) |container| {
        const decl = self.facts.member(container, spelled) orelse continue;
        switch (try paired(self, decl)) {
            .pair => |pair| try decls.appendSlice(self.allocator, &pair),
            .unknown => |why| return .{ .unknown = why },
        }
    }
    return .{ .decls = decls.items };
}

/// A declaration and its origin, the pair `append` reads. An alias in a selected file whose
/// value does not resolve is its own site: its value is a site of its own where it is written.
/// One in a file the run does not check is unknown: what it names is checked nowhere.
fn paired(self: *Context, decl: Facts.Decl) Context.Error!union(enum) { pair: [2]Facts.Decl, unknown: Facts.Unknown } {
    return switch (try self.facts.origin(decl)) {
        .decl => |origin| .{ .pair = .{ decl, origin } },
        .none => .{ .pair = .{ decl, decl } },
        .unknown => |why| if (self.project.at(decl.file).input.selected) .{ .pair = .{ decl, decl } } else .{ .unknown = why },
    };
}

/// The symbol an `extern` function binds: its name.
fn externSymbol(project: *const Project, decl: Facts.Decl) ?[]const u8 {
    const record = project.at(decl.file).model.declarations[@backingInt(decl.index)];
    if (record.kind != .function) return null;
    const tree = &project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const token = (tree.fullFnProto(&buffer, record.node) orelse return null).extern_export_inline_token orelse return null;
    if (tree.tokenTag(token) != .keyword_extern) return null;
    return record.name;
}

/// Whether no governed declaration spelled `spelled` can be what a member access with an
/// unresolved receiver reaches, by what Zig allows there. Called, every candidate's parameters
/// refuse the arguments, as a method (the receiver first) and as a namespace's function
/// (`RuleContext.accepts`). Not called, its value is a declaration's
/// that the file uses as a receiver of members, which no function and no number has. An
/// external symbol is a function whose parameters are unknown.
fn refuted(self: *Context, node: Ast.Node.Index, tag: Ast.Node.Tag, spelled: []const u8, governed: []const Governed) Context.Error!bool {
    if (tag != .field_access) return false;
    const model = &self.project.at(self.file).model;
    const tree = &self.project.at(self.file).file.tree;
    const parent = model.parentOf(node) orelse return false;
    var call_buffer: [1]Ast.Node.Index = undefined;
    const called: ?Ast.full.Call = if (tree.fullCall(&call_buffer, parent)) |call| (if (call.ast.fn_expr == node) call else null) else null;
    if (called == null and !try usedAsReceiver(self, parent, node)) return false;
    for (governed) |g| {
        if (!std.mem.eql(u8, g.name, spelled)) continue;
        if (g.symbol != null and g.decls.len == 0) {
            if (called != null) return false;
            continue;
        }
        for (g.decls) |decl| {
            const value = try self.facts.declaration(decl);
            if (value != .function and value != .scalar and value != .primitive) return false;
            const call = called orelse continue;
            if (value != .function) return false;
            if (try self.accepts(decl, call, 1) or try self.accepts(decl, call, 0)) return false;
        }
    }
    return true;
}

/// Whether `node` is the value of a declaration that the file uses as a receiver of a member.
fn usedAsReceiver(self: *Context, parent: Ast.Node.Index, node: Ast.Node.Index) Context.Error!bool {
    const model = &self.project.at(self.file).model;
    const tree = &self.project.at(self.file).file.tree;
    const variable = tree.fullVarDecl(parent) orelse return false;
    if (variable.ast.init_node.unwrap() != node) return false;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .field_access) continue;
        const access: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const receiver = tree.nodeData(access).node_and_token[0];
        if (tree.nodeTag(receiver) != .identifier) continue;
        const ref = model.reference(receiver) orelse continue;
        const index = ref.declaration orelse continue;
        if (model.declarations[@backingInt(index)].node == parent) return true;
    }
    return false;
}

/// Whether something is so: yes, no, or unknown and why (`Facts.Is`).
pub const Is = Facts.Is;

/// Whether `function` is std's declaration at `path` (`mem.Allocator.free`), through aliases.
pub fn isStd(c: *Context, function: Facts.Decl, path: []const u8) Context.Error!Is {
    const decls = switch (try declarations(c, "std", path)) {
        .decls => |decls| decls,
        .none => return .no,
        .unknown => |why| return .{ .unknown = why },
    };
    for (decls) |decl| if (std.meta.eql(decl, function)) return .yes;
    return .no;
}

/// Whether the call at `node` calls std's declaration at `path` (`mem.asBytes`): yes where
/// every function it may call is that one, no where none is. A callee that does not resolve is
/// unknown, unless it cannot be that declaration by what Zig allows: its name (as written)
/// spells neither the declaration's nor an alias's of it, or its parameters refuse the
/// arguments.
pub fn stdCall(c: *Context, node: Ast.Node.Index, path: []const u8) Context.Error!Is {
    return switch (try stdCallees(c, node, path)) {
        .none => .no,
        .every => .yes,
        // One of them only: the call may be it or another.
        .some => .{ .unknown = .unsupported },
        .unknown => |why| .{ .unknown = why },
    };
}

/// Whether the call at `node` may call std's declaration at `path` (`debug.print`): yes where
/// some function it may call is that one, as a per-build choice among them is in the build that
/// takes it; no where none is. A callee that does not resolve is read as `stdCall` reads it.
pub fn mayCallStd(c: *Context, node: Ast.Node.Index, path: []const u8) Context.Error!Is {
    return switch (try stdCallees(c, node, path)) {
        .none => .no,
        .every, .some => .yes,
        .unknown => |why| .{ .unknown = why },
    };
}

/// How many of the functions the call at `node` may call are std's declaration at `path`.
const Callees = union(enum) { none, some, every, unknown: Facts.Unknown };

fn stdCallees(c: *Context, node: Ast.Node.Index, path: []const u8) Context.Error!Callees {
    const call = (try Facts.calls.at(c.facts, c.file, node)) orelse return .none;
    const decls = switch (try declarations(c, "std", path)) {
        .decls => |decls| decls,
        .none => return .none,
        .unknown => |why| return .{ .unknown = why },
    };
    const callees: []const Facts.Decl = switch (call.callee) {
        .function => |function| &.{function},
        .choice => |each| each,
        .any => |why| return if (try notCalled(c, call, decls, path)) .none else .{ .unknown = why },
    };
    var found: usize = 0;
    for (callees) |callee| for (decls) |decl| {
        if (std.meta.eql(decl, callee)) {
            found += 1;
            break;
        }
    };
    if (found == 0) return .none;
    return if (found == callees.len) .every else .some;
}

/// Whether a call whose callee does not resolve cannot call any of `decls`: none takes its
/// arguments, as a method or as a namespace's function; or it calls a member whose name spells
/// neither theirs (`path`'s last) nor an alias's in the program (`aliasNames`). A local's name
/// says nothing: it may hold any of them.
fn notCalled(c: *Context, call: Facts.calls.Call, decls: []const Facts.Decl, path: []const u8) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    var full_buffer: [1]Ast.Node.Index = undefined;
    const full = tree.fullCall(&full_buffer, call.node) orelse return false;
    var takes = false;
    for (decls) |decl| takes = takes or try c.accepts(decl, full, 1) or try c.accepts(decl, full, 0);
    if (!takes) return true;
    if (tree.nodeTag(call.callee_expr) != .field_access) return false;
    const spelled = try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(call.callee_expr).node_and_token[1]));
    var names: std.ArrayList([]const u8) = .empty;
    try names.append(c.allocator, if (std.mem.findScalarLast(u8, path, '.')) |dot| path[dot + 1 ..] else path);
    try aliasNames(c, .program, decls, null, &names);
    for (names.items) |name| if (std.mem.eql(u8, name, spelled)) return false;
    return true;
}
