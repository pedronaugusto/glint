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
        if (!module) for (self.project.sources) |*each| if (std.mem.eql(u8, each.input.name, source)) {
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

    /// The declarations, or null for none and for unknown alike, as every caller read them
    /// before `Declared`: each use drops an unknown. Every use is to become a switch that makes
    /// `.unknown` undecided where it decides; `orNull_test` counts them, the count only falls,
    /// and at none this goes.
    pub fn orNull(self: Declared) ?[]const Facts.Decl {
        return switch (self) {
            .decls => |decls| decls,
            .none, .unknown => null,
        };
    }
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
/// reference that does not resolve but spells a name only a governed declaration has in the
/// program (`unique`) into `unread`, for the caller to judge: under a ban a finding, under hygiene
/// nothing. An enum literal and a literal's field name are no reference: unresolved, they spell
/// nothing.
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
                if (tag == .enum_literal or !try unique(self, governed, spelled)) continue;
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
    switch (try self.facts.literalDeclaration(self.file, literal, spelled)) {
        .unknown, .none => {},
        .decl => |decl| switch (try paired(self, decl)) {
            .pair => |pair| try append(self, governed, renamed, label, value, spelled, &pair, out),
            .unknown => |why| if (try unique(self, governed, spelled)) try leave(self, unread, value, why),
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
            if (value == .unknown) {
                if (try unique(self, governed, name)) try leave(self, unread, node, value.unknown);
                return;
            }
            var options: std.ArrayList(Facts.Container) = .empty;
            try containers(self, value, &options);
            for (options.items) |container| {
                const decl = self.facts.member(container, name) orelse continue;
                switch (try paired(self, decl)) {
                    .pair => |pair| try append(self, governed, renamed, site, node, name, &pair, out),
                    .unknown => |why| return if (try unique(self, governed, name)) leave(self, unread, node, why),
                }
            }
        };
    }
}

/// How many declarations of the run's program carry each name: every field, and every variable
/// and function of a file or container, std's included. A local is never a member.
const Names = struct {
    built: bool = false,
    counts: std.StringHashMapUnmanaged(u32) = .empty,
};

/// Whether `spelled` names no declaration of the program but a governed one: then a reference
/// spelling it that does not resolve identifies it. A name another declaration also has
/// (`read`, `init`, `run`) cannot be shown to be the governed one, and spells nothing.
fn unique(self: *Context, governed: []const Governed, spelled: []const u8) Context.Error!bool {
    const names = try self.facts.memo(Names);
    if (!names.built) {
        names.built = true;
        for (self.project.sources) |*source| {
            if (source.input.kind == .zon) continue;
            for (source.model.declarations) |decl| {
                switch (decl.kind) {
                    .field => {},
                    .variable, .function => switch (source.model.scopes[@backingInt(decl.scope)].kind) {
                        .file, .container => {},
                        else => continue,
                    },
                    .parameter, .capture => continue,
                }
                const entry = try names.counts.getOrPut(self.facts.gpa, decl.name);
                entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
            }
        }
    }
    const all = names.counts.get(spelled) orelse return true;
    var own: std.ArrayList(Facts.Decl) = .empty;
    for (governed) |g| for (g.decls) |decl| {
        if (!std.mem.eql(u8, self.project.at(decl.file).model.declarations[@backingInt(decl.index)].name, spelled)) continue;
        for (own.items) |known| {
            if (std.meta.eql(known, decl)) break;
        } else try own.append(self.allocator, decl);
    };
    return all <= own.items.len;
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
/// unknown, but for a generic's binding, judged where it is bound.
pub fn madeByCall(self: *Context, node: Ast.Node.Index, types: []const Facts.Container) Context.Error!Made {
    if (types.len == 0) return .no;
    const call = (try Facts.calls.at(self.facts, self.file, node)) orelse return .no;
    const callees: []const Facts.Decl = switch (call.callee) {
        .function => |function| &.{function},
        .choice => |each| each,
        .any => return .no,
    };
    var result: ?Facts.Value = null;
    for (callees) |callee| {
        if (try self.facts.program(callee.file)) continue;
        if (result == null) result = try self.facts.resolve(self.file, node);
        const made = madeType(result.?, types) orelse {
            if (result.? == .unknown and result.?.unknown != .generic and try makesFromData(self, callee)) return .{ .unknown = result.?.unknown };
            continue;
        };
        if (!reflectiveResult(self, callee) and try samePackage(self, callee.file, made.file)) continue;
        if (!try makesFromData(self, callee)) continue;
        // A copy of memory out of a value of the same type (`std.mem.bytesToValue(T,
        // std.mem.asBytes(&t))`, `Facts.accesses.copyAt`) makes it from its own bytes.
        if (try Facts.accesses.copyAt(self.facts, self.file, node)) |copy| if (madeType(try self.facts.resolve(self.file, copy.from.node()), types)) |from| {
            if (from.file == made.file and from.scope == made.scope) continue;
        };
        return .{ .yes = callee };
    }
    return .no;
}

/// Whether the call at `node` hands one of `types`, or a value of or pointer to one, to a
/// library function that reads it as untyped data: a callee outside the program and outside the
/// type's package that returns the value it is handed cast to another type, there or through a
/// call it hands it on to (`std.mem.asBytes(&t)`, `sliceAsBytes`, `toBytes(t)`:
/// `castsParameter`), or whose body applies a reflective builtin to the parameter it is handed
/// (`std.meta.fieldNames(T)`, `fieldInfo`, `tags`: `@typeInfo(T)`). A function that only holds
/// a type it is given (`std.ArrayList(T)`: `@sizeOf`, `@alignOf`), allocates or keeps storage
/// for it (`Allocator.alloc(T, n)`, `realloc`, whose bytes of the old memory never reach its
/// result), or copies a value (`std.mem.swap`) is none. The callee is given.
pub fn reflectedByCall(self: *Context, node: Ast.Node.Index, types: []const Facts.Container) Context.Error!?Facts.Decl {
    if (types.len == 0) return null;
    const call = (try Facts.calls.at(self.facts, self.file, node)) orelse return null;
    const args = switch (call.args) {
        .known => |known| known,
        .unknown => return null,
    };
    const callees: []const Facts.Decl = switch (call.callee) {
        .function => |function| &.{function},
        .choice => |each| each,
        .any => return null,
    };
    for (args, 0..) |arg, position| {
        const handed = madeType(try self.facts.resolve(self.file, arg), types) orelse continue;
        for (callees) |callee| {
            if (try self.facts.program(callee.file) or try samePackage(self, callee.file, handed.file)) continue;
            if (try castsParameter(self, callee, position, 0) or reflectsParameter(self, callee, position)) return callee;
        }
    }
    return null;
}

/// Whether a library function makes the value it returns from untyped data: it returns a cast
/// of bytes it is handed (`castsParameter` over any parameter that holds data), or applies a
/// reflective builtin to one of its parameters (`@typeInfo(T)`: `mem.zeroes`, `zeroInit`).
fn makesFromData(self: *Context, function: Facts.Decl) Context.Error!bool {
    if (try castsParameter(self, function, null, 0)) return true;
    const tree = &self.project.at(function.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, self.project.at(function.file).model.declarations[@backingInt(function.index)].node) orelse return false;
    var parameters = proto.iterate(tree);
    var position: usize = 0;
    while (parameters.next()) |_| : (position += 1) {
        if (reflectsParameter(self, function, position)) return true;
    }
    return false;
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
fn castsParameter(self: *Context, function: Facts.Decl, position: ?usize, depth: u8) Context.Error!bool {
    if (depth > 4) return false;
    const tree = &self.project.at(function.file).file.tree;
    const declaration = self.facts.scopeNode(function);
    if (tree.nodeTag(declaration) != .fn_decl) return false;
    const body = tree.nodeData(declaration).node_and_node[1];
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    for (tree.nodes.items(.tag), 0..) |tag, raw| {
        if (tag != .@"return") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const at = tree.nodeMainToken(node);
        if (at < first or at > last) continue;
        const operand = tree.nodeData(node).opt_node.unwrap() orelse continue;
        if (try returnsCast(self, function, operand, position, false, depth)) return true;
    }
    return false;
}

/// Whether the returned expression `node` is the parameter at `position` (or one holding data)
/// cast, through the forms that hand on a value: grouping, `.*`, a slice, `try`, `@as`, both
/// results of an `if`, `orelse` and `catch`, and a call it is handed to that returns it cast.
fn returnsCast(self: *Context, function: Facts.Decl, node: Ast.Node.Index, position: ?usize, cast: bool, depth: u8) Context.Error!bool {
    if (depth > 8) return false;
    const tree = &self.project.at(function.file).file.tree;
    switch (tree.nodeTag(node)) {
        .grouped_expression => return returnsCast(self, function, tree.nodeData(node).node_and_token[0], position, cast, depth + 1),
        .deref, .@"try", .address_of => return returnsCast(self, function, tree.nodeData(node).node, position, cast, depth + 1),
        .@"orelse", .@"catch" => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return try returnsCast(self, function, lhs, position, cast, depth + 1) or try returnsCast(self, function, rhs, position, cast, depth + 1);
        },
        .slice_open, .slice, .slice_sentinel => return returnsCast(self, function, (tree.fullSlice(node) orelse return false).ast.sliced, position, cast, depth + 1),
        .identifier => {
            const k = parameterAt(self, function, node) orelse return false;
            return cast and if (position) |p| k == p else holdsData(self, function, k);
        },
        else => {},
    }
    if (tree.fullIf(node)) |branch| {
        if (try returnsCast(self, function, branch.ast.then_expr, position, cast, depth + 1)) return true;
        const otherwise = branch.ast.else_expr.unwrap() orelse return false;
        return returnsCast(self, function, otherwise, position, cast, depth + 1);
    }
    if (Facts.builtinName(tree, node)) |name| {
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        if (std.mem.eql(u8, name, "@as") and args.len == 2) return returnsCast(self, function, args[1], position, cast, depth + 1);
        if (isBitCast(name) and args.len >= 1) return returnsCast(self, function, args[args.len - 1], position, true, depth + 1);
        return false;
    }
    // A call the parameter is handed to: the callee returns it cast, or it was cast here.
    const call = (try Facts.calls.at(self.facts, function.file, node)) orelse return false;
    const args = switch (call.args) {
        .known => |known| known,
        .unknown => return false,
    };
    const callees: []const Facts.Decl = switch (call.callee) {
        .function => |one| &.{one},
        .choice => |each| each,
        .any => return false,
    };
    for (args, 0..) |arg, i| {
        if (castWritten(self, function, arg) and try returnsCast(self, function, arg, position, false, depth + 1)) return true;
        const k = handedParameter(self, function, arg) orelse continue;
        if (if (position) |p| k != p else !holdsData(self, function, k)) continue;
        for (callees) |callee| if (try castsParameter(self, callee, i, depth + 1)) return true;
    }
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
            else => switch (try self.facts.origin(decl)) {
                .decl => |reached| try aliasOf(self, found, reached, decl, d.name),
                .none => {},
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
    if (tag == .enum_literal) switch (try self.facts.literalDeclaration(self.file, node, spelled)) {
        .unknown => |why| return .{ .unknown = why },
        .none => return .{ .decls = &.{} },
        .decl => |decl| return switch (try paired(self, decl)) {
            .pair => |pair| .{ .decls = try self.allocator.dupe(Facts.Decl, &pair) },
            .unknown => |why| .{ .unknown = why },
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
