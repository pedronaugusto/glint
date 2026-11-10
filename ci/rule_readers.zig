//! RULE_READERS: a rule of glint's that reads a value, a write, a call or a type around the
//! shared queries (Facts.resolve, Facts.accesses, Facts.calls, Governed), by a name it spells or
//! by the syntax it is written in, misses what the queries see: an alias, a per-build choice, a
//! value parenthesized or held in a local. glint's own lint runs it over its rule files; the
//! shared queries' files are where reading syntax belongs, and are not given to it.
//!
//! A spelling read is a call of std's `mem.eql`, `mem.startsWith`, `mem.endsWith` or `mem.find`
//! with a name a declaration may have (a string literal, a `const` holding one, an enum literal,
//! a capture of a list of them written in place). A shape read is a node's syntax tag, as std's
//! `Ast.nodeTag` gives it, compared with or switched on a tag that writes a value (`.identifier`,
//! `.field_access`, a call, an assignment, a type written in place). Each callee is read by what
//! it resolves to, never by its spelling: one that may be std's function is undecided.
const std = @import("std");
const glint = @import("glint");
const cli = glint.cli;
const rule_readers: glint.Rule = @fromBackingInt(1000); // safe: this linter owns extension ID 1000, validated by glint.
pub const rules = ruled(&allowed) ++ tabled(&tables) ++ switched(&switches);
fn ruled(comptime list: []const Allowed) [1]glint.ProjectRule {
    return .{.{ .definition = .{ .id = rule_readers, .name = "RULE_READERS", .group = .family_policy, .purpose = "a rule reads values, writes, calls and types only through glint's shared queries" }, .check = struct {
        fn run(context: *glint.RuleContext) glint.RuleContext.Error!void {
            return check(context, list);
        }
    }.run }};
}

/// A function whose reads are syntactic by nature: its rule judges how code is written (a
/// style rule), not what it does, so it reads spelling or shape on purpose. `file` is the rule
/// file's path from glint's root, `function` the function by its name, inside the containers
/// that hold it (`Walk.escaping`). The guard reports none of its reads; an entry no read of its
/// file's is in is a finding itself, so the list holds only what is still read.
const Allowed = struct { file: []const u8, function: []const u8, reason: []const u8 };
/// The reads that stay syntactic, each with its reason. A session adds an entry for its rule
/// with the guard's owner.
const allowed = [_]Allowed{
    .{ .file = "src/DangerFlow.zig", .function = "namesCanceled", .reason = "Zig's error names are global identities, one `error.X` program-wide whatever set spells it: no declaration stands behind one" },
    .{ .file = "src/Discards.zig", .function = "refusal", .reason = "Zig's error names are global identities, one `error.X` program-wide whatever set spells it: no declaration stands behind one" },
    .{ .file = "src/Builtins.zig", .function = "unusedImports", .reason = "a member read is written `a.b` or `@field` (read apart by Facts.reflected); Facts.definition decides what each names" },
    .{ .file = "src/Builtins.zig", .function = "priorityRules", .reason = "picks the token a finding is reported at; Facts.calls and Facts.definition decide the callee" },
    .{ .file = "src/Builtins.zig", .function = "inert", .reason = "Zig has no getters or overloading: a name, member, literal or reading builtin as written has no effect" },
    .{ .file = "src/Builtins.zig", .function = "privateType", .reason = "Z012 judges a signature as written: a type written there is what callers must name; each name is decided by Facts.definition and Facts.resolve" },
    .{ .file = "src/Builtins.zig", .function = "exposedArgument", .reason = "Z012 judges a type function's argument as written in the signature; each name is decided by Facts.definition and Facts.resolve" },
    .{ .file = "src/Builtins.zig", .function = "selfNamed", .reason = "a literal written in a signature names itself: no declaration stands behind it" },
    .{ .file = "src/Builtins.zig", .function = "genericReads", .reason = "a generic reads its type parameter's member by name: Zig resolves `T.name` in whatever type T is" },
    .{ .file = "src/Metrics.zig", .function = "spelledLike", .reason = "the metric counts calls spelled like an assertion that no resolution decides: the spelling is what it reports" },
    .{ .file = "src/AegisRecursion.zig", .function = "monotone", .reason = "the compound assignment's operator is the step's direction; Zig's operators cannot be overloaded" },
    .{ .file = "src/AegisRecursion.zig", .function = "fieldStep", .reason = "the compound assignment's operator is the step's direction; Zig's operators cannot be overloaded" },
    .{ .file = "src/AegisRecursion.zig", .function = "hasReceiver", .reason = "Zig binds a receiver only in the method-call form `x.f(…)`; whether x is a value is read by Facts.resolve" },
    .{ .file = "src/Escapes.zig", .function = "Walk.enclosing", .reason = "the function a node runs in is the declaration its syntax sits in" },
    .{ .file = "src/Escapes.zig", .function = "Walk.escaping", .reason = "Zig makes a pointer into a frame only by `&` or slicing a local; a name for one is followed by Facts.givenTo" },
    .{ .file = "src/Danger.zig", .function = "insertAegis", .reason = "Zig's scoping is by name: the inserted declaration must not clash with or be shadowed by one already in the file" },
    .{ .file = "src/Danger.zig", .function = "secretName", .reason = "std's crypto names its secret types by convention: SecretKey, KeyPair, BlindSecretKey, BlindKeyPair" },
    .{ .file = "src/AegisPack.zig", .function = "Flow.moves", .reason = "`else null` is the language's null literal, which no declaration stands behind" },
    .{ .file = "src/AegisPack.zig", .function = "rawCall", .reason = "the callee is resolved through what names it to its declaration (Facts.definition, Facts.origin); one that does not resolve is read as Zig finds it, by name in the method-call form `s.raw()`" },
    .{ .file = "src/AegisPack.zig", .function = "refuted", .reason = "a slice's `len` and `ptr` are the language's own fields, which no declaration stands behind" },
    .{ .file = "src/AegisPack.zig", .function = "allocationUse", .reason = "a slice's `len` and `ptr` are the language's own fields, which no declaration stands behind" },
    .{ .file = "src/AegisPack.zig", .function = "Flow.decided", .reason = "Zig's `!` can't be overloaded: the node tag is the negation of the flag the walk knows" },
    .{ .file = "src/AegisPack.zig", .function = "Flow.repeat", .reason = "`while (true)` is the language's literal, which no declaration stands behind" },
    .{ .file = "src/Escapes.zig", .function = "compiledIn", .reason = "a literal as written is compiled into the program, never the frame's memory" },
    .{ .file = "src/DangerFlow.zig", .function = "input", .reason = "std's parameter name is part of std's declared contract (A012's size parameters are read the same way, docs/design.md), read only from the resolved std declaration, never from program code" },
};

/// VALUE_SWITCHES: a switch on a value Facts resolved (`Facts.Value`) that names no `.alternatives`
/// prong, anywhere in glint. A choice of values is read part by part (Facts.valueParts, its
/// answers joined by Facts.Join): a switch that names some tags and sends the rest to a default reads a choice of
/// them, or a tag it does not name, as that default, which skips or clears it. A switch is found
/// by what its operand resolves to (Facts.Value's own declaration), never by the tags it names; one
/// whose operand does not resolve is undecided.
/// A container as Facts names it: `Value.container`'s payload.
const ValueContainer = @FieldType(glint.Value, "container");
const value_switches: glint.Rule = @fromBackingInt(1002); // safe: this linter owns extension ID 1002, validated by glint.
fn switched(comptime list: []const Allowed) [1]glint.ProjectRule {
    return .{.{ .definition = .{ .id = value_switches, .name = "VALUE_SWITCHES", .group = .family_policy, .purpose = "glint reads a resolved value's choice of alternatives part by part, never through a default prong" }, .check = struct {
        fn run(context: *glint.RuleContext) glint.RuleContext.Error!void {
            return checkSwitches(context, list);
        }
    }.run }};
}

/// The switches still allowed, each by the function it is in: `pending: <owner>`, a site its
/// owner converts to Facts' part readers (the list only shrinks), or `conservative: <why>; row:
/// <test>`, a claim that its default is the safe answer for that function, proved by the row named.
const switches = [_]Allowed{};

fn checkSwitches(context: *glint.RuleContext, list: []const Allowed) glint.RuleContext.Error!void {
    const tree = try context.project.syntax(try context.source());
    const name = context.project.at(context.file).input.name;
    const value_type = (try valueType(context)) orelse return;
    var found: std.ArrayList(Found) = .empty;
    for (tree.nodes.items(.tag), 0..) |_, index| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(index));
        if (context.inTest(tree.nodeMainToken(node))) continue;
        const full = tree.fullSwitch(node) orelse continue;
        switch (try isValue(context, try context.facts.resolve(context.file, full.ast.condition), value_type)) {
            .no => continue,
            .unknown => |why| try found.append(context.allocator, .{ .node = node, .what = .{ .undecided = why } }),
            .yes => if (!namesAlternatives(tree, full)) try found.append(context.allocator, .{ .node = node, .what = .{ .read = "a switch on a resolved value names no `.alternatives` prong: a choice of values, or a tag it does not name, falls to its default; read it part by part (Facts.valueParts, joined by Facts.Join), or allow it with the row that proves its default is the safe answer" } }),
        }
    }
    const used = try context.allocator.alloc(bool, list.len);
    @memset(used, false);
    sites: for (found.items) |each| {
        const function = try enclosing(context, tree, each.node);
        for (list, used) |entry, *use| if (inFile(name, entry.file) and std.mem.eql(u8, entry.function, function)) {
            use.* = true;
            continue :sites;
        };
        switch (each.what) {
            .read => |message| try context.at(value_switches, tree.nodeMainToken(each.node), message),
            .undecided => |why| try context.unknown(value_switches, each.node, why),
        }
    }
    for (list, used) |entry, use| if (inFile(name, entry.file) and !use) {
        try context.at(value_switches, 0, try context.allocator.print("the allowed switches of {s} ({s}) are none of this file's: remove the entry", .{ entry.function, entry.reason }));
    };
}

/// Facts.Value's container, by its declaration in the run's src/Facts.zig; null where the run
/// holds no such file (a project that is not glint).
fn valueType(context: *glint.RuleContext) glint.RuleContext.Error!?ValueContainer {
    for (context.project.sources) |*source| {
        if (!inFile(source.input.name, "src/Facts.zig")) continue;
        const decl = context.facts.member(context.facts.rootOf(source.id), "Value") orelse return null;
        return switch (try context.facts.declaration(decl)) {
            .container => |container| container,
            else => null,
        };
    }
    return null;
}

/// Whether a resolved operand is a Facts.Value: an instance of its container, in each part of a
/// choice; not known where a part does not resolve.
fn isValue(context: *glint.RuleContext, value: glint.Value, value_type: ValueContainer) glint.RuleContext.Error!union(enum) { yes, no, unknown: glint.Unknown } {
    _ = context;
    const each: []const glint.Value = if (value == .alternatives) value.alternatives else &.{value};
    var unknown: ?glint.Unknown = null;
    for (each) |part| switch (part) {
        .instance => |container| if (container.file == value_type.file and container.scope == value_type.scope) return .yes,
        .unknown => |why| unknown = why,
        .alternatives => unreachable, // unreachable: choose never nests alternatives
        else => {},
    };
    return if (unknown) |why| .{ .unknown = why } else .no;
}

/// Whether a switch names `.alternatives` in a prong.
fn namesAlternatives(tree: *const std.zig.Ast, full: std.zig.Ast.full.Switch) bool {
    for (full.ast.cases) |case_node| {
        const case = tree.fullSwitchCase(case_node).?; // unreachable: a switch's cases are cases
        for (case.ast.values) |item| if (tree.nodeTag(item) == .enum_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(item)), "alternatives")) return true;
    }
    return false;
}

/// NAME_TABLES: a table keyed by text, anywhere in glint (the shared queries' files included). A
/// declaration found by its spelling in one misses what resolution sees, as a rule's comparison
/// does (`copiesBy`, a table of generics by name, answered a call through a parameter by any
/// function so spelled). A table of text that names no declaration (a path, a rule's id) is
/// allowed with its reason; one of declarations is keyed by the declaration (`Facts.Decl`).
const name_tables: glint.Rule = @fromBackingInt(1001); // safe: this linter owns extension ID 1001, validated by glint.
fn tabled(comptime list: []const Allowed) [1]glint.ProjectRule {
    return .{.{ .definition = .{ .id = name_tables, .name = "NAME_TABLES", .group = .family_policy, .purpose = "glint finds a declaration by what it resolves to, never by a table of its spelling" }, .check = struct {
        fn run(context: *glint.RuleContext) glint.RuleContext.Error!void {
            return checkTables(context, list);
        }
    }.run }};
}

/// std's maps keyed by text, by their declarations under std's root: the type functions, each
/// given the value's type alone, and the plain structs, made by `init`.
const text_maps = [_]struct { []const u8, usize }{ .{ "StringHashMapUnmanaged", 1 }, .{ "StringHashMap", 1 }, .{ "StringArrayHashMapUnmanaged", 1 }, .{ "StringArrayHashMap", 1 }, .{ "BufSet.init", 1 }, .{ "BufMap.init", 1 } };

/// The text tables that name no declaration, each with its reason, by the place that makes the
/// table (`place`). An entry no table of its file's is at is a finding itself.
const tables = [_]Allowed{
    .{ .file = "src/Discards.zig", .function = "refusal", .reason = "Zig's error names are global identities, one `error.X` program-wide whatever set spells it: no declaration stands behind one" },
    .{ .file = "src/Discards.zig", .function = "SystemNames.names", .reason = "Zig's error names are global identities, one `error.X` program-wide whatever set spells it: no declaration stands behind one" },
    .{ .file = "src/Discards.zig", .function = "systemNames", .reason = "Zig's error names are global identities, one `error.X` program-wide whatever set spells it: no declaration stands behind one" },
    .{ .file = "src/Discards.zig", .function = "setNames", .reason = "Zig's error names are global identities, one `error.X` program-wide whatever set spells it: no declaration stands behind one" },
    .{ .file = "src/Model.zig", .function = "Scope.names", .reason = "Zig's own scope lookup: the resolver itself finds a declaration by its name in its scope" },
    .{ .file = "src/cli.zig", .function = "Loader.paths", .reason = "file paths: a loaded file's canonical path is its identity" },
    .{ .file = "src/cli.zig", .function = "Loader.manifests", .reason = "directory paths: each package directory's manifest" },
    .{ .file = "src/Summary.zig", .function = "Names.files", .reason = "file names: the run's file under each name a summary writes" },
    .{ .file = "src/Summary.zig", .function = "Writer.strings", .reason = "the summary's own string table: the text is what is written" },
    .{ .file = "src/Runner.zig", .function = "emitted", .reason = "a finding's identity: its rule, span and message text" },
    .{ .file = "src/Token.zig", .function = "recoverShaped", .reason = "import spellings: the token-level import walk before any model exists" },
    .{ .file = "src/Token.zig", .function = "classify", .reason = "import spellings: the token-level import walk before any model exists" },
    .{ .file = "src/Governed.zig", .function = "Lookups.found", .reason = "a configured declaration path is the query, its answer a resolved declaration; program uses match by the declaration it resolves to" },
    .{ .file = "src/Facts.zig", .function = "Analysis.named", .reason = "Zig's member lookup on an unknown holder: the name is all the holder gives, as the compiler looks it up" },
    .{ .file = "src/Facts.zig", .function = "Analysis.Sites.by_name", .reason = "the sites a name is spelled at, an index only: each is read by resolution (reachedFromSite), none answered by its spelling" },
    .{ .file = "src/Facts.zig", .function = "member_uses", .reason = "the member accesses spelling a name, an index only: no consumer answers from the spelling, each reads every site by resolution (its receiver, definition or callee) before counting it" },
    .{ .file = "src/Facts.zig", .function = "comptime_fields", .reason = "a member of a holder of no known type: candidates by name, each read by declaration, joined over all of them: runtime, the answer that clears (scanCallSites, Facts.zig:11032), only where no field so named is comptime (comptimeField, 11638); a member that resolves is read by its declaration, and a holder whose type may be outside the run (holderOutside: a file it cannot parse, an unmapped or computed import, a handed-out generic's parameter) answers comptime" },
    .{ .file = "src/Facts.zig", .function = "OutsideCalls.by_name", .reason = "outside code's calls through a member on a receiver of no known type: candidates by name, each receiver read by resolution (mayBeProgram, Facts.zig:11372), joined over all of them: not called only where every receiver so named, and every computed @field, is excluded; a run holding a file it cannot parse answers called" },
    .{ .file = "src/Facts.zig", .function = "accesses.File.named", .reason = "members on holders of no known type: candidates by name, each a write of every field so named, joined over all of them (Each.sitesOf, Facts.zig:13380); a file the run cannot parse is unresolved memory (14229)" },
};

fn checkTables(context: *glint.RuleContext, list: []const Allowed) glint.RuleContext.Error!void {
    const tree = try context.project.syntax(try context.source());
    const name = context.project.at(context.file).input.name;
    const used = try context.allocator.alloc(bool, list.len);
    @memset(used, false);
    nodes: for (tree.nodes.items(.tag), 0..) |_, index| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(index));
        if (context.inTest(tree.nodeMainToken(node))) continue;
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        // A function a runtime value holds returns no type and makes no std struct of its own.
        const callee = try context.facts.resolve(context.file, call.ast.fn_expr);
        if (callee == .fn_type or (callee == .pointer and callee.pointer.child.* == .fn_type)) continue;
        const map = for (text_maps) |each| {
            if (call.ast.params.len != each[1]) continue;
            switch (try glint.stdCall(context, node, each[0])) {
                .no => {},
                .yes => break each[0],
                .unknown => |why| {
                    try context.unknown(name_tables, node, why);
                    continue :nodes;
                },
            }
        } else continue;
        const where = try place(context, tree, node);
        for (list, used) |entry, *use| if (inFile(name, entry.file) and std.mem.eql(u8, entry.function, where)) {
            use.* = true;
            continue :nodes;
        };
        try context.at(name_tables, tree.nodeMainToken(node), try context.allocator.print("std's {s} at {s} keys a table by text: a declaration found by its spelling misses an alias, a per-build choice or a call through a value; key it by the declaration (Facts.Decl), or, naming no declaration, allow it with its reason", .{ map, if (where.len == 0) "the file's level" else where }));
    }
    for (list, used) |entry, use| if (inFile(name, entry.file) and !use) {
        try context.at(name_tables, 0, try context.allocator.print("the allowed text table at {s} ({s}) is none of this file's: remove the entry", .{ entry.function, entry.reason }));
    };
}

/// Where `node` is made: its function (`enclosing`), or else the containers and the field or
/// constant that hold it (`Scope.names`, `copier_names`).
fn place(context: *glint.RuleContext, tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) glint.RuleContext.Error![]const u8 {
    const function = try enclosing(context, tree, node);
    if (function.len != 0) return function;
    const model = &context.project.at(context.file).model;
    var names: std.ArrayList([]const u8) = .empty;
    var at = model.parentOf(node);
    while (at) |each| : (at = model.parentOf(each)) {
        if (model.containerField(tree, each)) |field| {
            if (names.items.len == 0) try names.insert(context.allocator, 0, tree.tokenSlice(field.ast.main_token));
        } else if (tree.fullVarDecl(each)) |variable| {
            try names.insert(context.allocator, 0, tree.tokenSlice(variable.ast.mut_token + 1));
        }
    }
    return std.mem.join(context.allocator, ".", names.items);
}

/// std's functions that compare text: one given a declaration's name matches a declaration by it.
const comparisons = [_][]const u8{ "mem.eql", "mem.startsWith", "mem.endsWith", "mem.find" };

/// std's readings of syntax that the project model corrects, each with the reading to use: a rule
/// that calls one misreads what it reads, whatever the rule judges, so no entry allows it.
const corrected = [_]struct { []const u8, []const u8 }{
    .{ "zig.Ast.fullContainerField", "std's fullContainerField reads an enum's or union's tag with no type (`a,`, `a = 0`) as a tuple field typed by its own name: read a container field through Model.containerField" },
};

/// What a syntax tag writes, and the query that reads it by meaning.
const Read = enum {
    value,
    write,
    call,
    type,
    fn query(self: Read) []const u8 {
        return switch (self) {
            .value => "Facts.resolve or Facts.accesses",
            .write => "Facts.accesses",
            .call => "Facts.calls or Governed",
            .type => "Facts.resolve",
        };
    }
};
fn reads(tag: std.zig.Ast.Node.Tag) ?Read {
    return switch (tag) {
        .identifier, .field_access, .unwrap_optional, .deref, .array_access, .address_of, .slice_open, .slice, .slice_sentinel, .grouped_expression, .bool_and, .bool_or, .bool_not, .number_literal, .char_literal, .string_literal, .multiline_string_literal, .enum_literal, .error_value, .struct_init_one, .struct_init_one_comma, .struct_init_dot_two, .struct_init_dot_two_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init, .struct_init_comma, .array_init_one, .array_init_one_comma, .array_init_dot_two, .array_init_dot_two_comma, .array_init_dot, .array_init_dot_comma, .array_init, .array_init_comma => .value,
        .assign, .assign_destructure, .assign_mul, .assign_div, .assign_mod, .assign_add, .assign_sub, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_xor, .assign_bit_or, .assign_mul_wrap, .assign_add_wrap, .assign_sub_wrap, .assign_mul_sat, .assign_add_sat, .assign_sub_sat => .write,
        .call_one, .call_one_comma, .call, .call_comma, .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => .call,
        .optional_type, .error_union, .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range, .array_type, .array_type_sentinel => .type,
        else => null,
    };
}

/// A read found: its finding's message, or undecided and why.
const Found = struct { node: std.zig.Ast.Node.Index, what: union(enum) { read: []const u8, undecided: glint.Unknown } };

fn check(context: *glint.RuleContext, list: []const Allowed) glint.RuleContext.Error!void {
    const tree = try context.project.syntax(try context.source());
    const name = context.project.at(context.file).input.name;
    var found: std.ArrayList(Found) = .empty;
    var misread: std.ArrayList(Found) = .empty;
    for (tree.nodes.items(.tag), 0..) |_, index| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(index));
        if (context.inTest(tree.nodeMainToken(node))) continue;
        try spelling(context, tree, node, &found);
        try shape(context, tree, node, &found);
        try correction(context, tree, node, &misread);
    }
    for (misread.items) |each| switch (each.what) {
        .read => |message| try context.at(rule_readers, tree.nodeMainToken(each.node), message),
        .undecided => |why| try context.unknown(rule_readers, each.node, why),
    };
    const used = try context.allocator.alloc(bool, list.len);
    @memset(used, false);
    reads: for (found.items) |each| {
        const function = try enclosing(context, tree, each.node);
        for (list, used) |entry, *use| if (inFile(name, entry.file) and std.mem.eql(u8, entry.function, function)) {
            use.* = true;
            continue :reads;
        };
        switch (each.what) {
            .read => |message| try context.at(rule_readers, tree.nodeMainToken(each.node), message),
            .undecided => |why| try context.unknown(rule_readers, each.node, why),
        }
    }
    for (list, used) |entry, use| if (inFile(name, entry.file) and !use) {
        try context.at(rule_readers, 0, try context.allocator.print("the allowed reads of {s} ({s}) are none of this file's: remove the entry", .{ entry.function, entry.reason }));
    };
}

/// Whether the input `name` is the rule file at `path` from glint's root.
fn inFile(name: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, name, path) or (std.mem.endsWith(u8, name, path) and name[name.len - path.len - 1] == '/');
}

/// The function `node` is in, by its name inside the containers that hold it (`Walk.escaping`);
/// empty outside any function.
fn enclosing(context: *glint.RuleContext, tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) glint.RuleContext.Error![]const u8 {
    const model = &context.project.at(context.file).model;
    var names: std.ArrayList([]const u8) = .empty;
    var function = false;
    var at = model.parentOf(node);
    while (at) |each| : (at = model.parentOf(each)) {
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        if (tree.nodeTag(each) == .fn_decl) {
            const proto = tree.fullFnProto(&buffer, each).?; // unreachable: a function declaration has a prototype
            try names.insert(context.allocator, 0, tree.tokenSlice(proto.name_token orelse continue));
            function = true;
        } else if (tree.fullVarDecl(each)) |variable| {
            const init = variable.ast.init_node.unwrap() orelse continue;
            var members: [2]std.zig.Ast.Node.Index = undefined;
            if (tree.fullContainerDecl(&members, init) != null) try names.insert(context.allocator, 0, tree.tokenSlice(variable.ast.mut_token + 1));
        }
    }
    return if (function) std.mem.join(context.allocator, ".", names.items) else "";
}

/// A call of std's text comparison given a name a declaration may have.
fn spelling(context: *glint.RuleContext, tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index, out: *std.ArrayList(Found)) glint.RuleContext.Error!void {
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return;
    const name = for (call.ast.params) |argument| {
        if (try declarationName(context, argument)) |found| break found;
    } else return;
    for (comparisons) |path| switch (try glint.stdCall(context, node, path)) {
        .no => {},
        .yes => return out.append(context.allocator, .{ .node = node, .what = .{ .read = try context.allocator.print("std's {s} matches a declaration by its name \"{s}\": find it by what it resolves to (Facts.resolve, Facts.calls, Governed)", .{ path, name }) } }),
        .unknown => |why| return out.append(context.allocator, .{ .node = node, .what = .{ .undecided = why } }),
    };
}

/// A call of std's reading that the project model corrects (`corrected`).
fn correction(context: *glint.RuleContext, tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index, out: *std.ArrayList(Found)) glint.RuleContext.Error!void {
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    _ = tree.fullCall(&buffer, node) orelse return;
    for (corrected) |each| switch (try glint.stdCall(context, node, each[0])) {
        .no => {},
        .yes => return out.append(context.allocator, .{ .node = node, .what = .{ .read = each[1] } }),
        .unknown => |why| return out.append(context.allocator, .{ .node = node, .what = .{ .undecided = why } }),
    };
}

/// A name `node` spells that a declaration may have: a valid identifier, not `_` or a primitive
/// (`type`, `u8`, `true`, `null`), or a path of them (`debug.print`).
fn declarationName(context: *glint.RuleContext, node: std.zig.Ast.Node.Index) glint.RuleContext.Error!?[]const u8 {
    return switch (try context.facts.fieldName(context.file, node)) {
        .name => |name| if (namesDeclaration(name)) name else null,
        .names => |names| for (names) |name| {
            if (namesDeclaration(name)) break name;
        } else null,
        .each_of, .computed => null,
    };
}
fn namesDeclaration(name: []const u8) bool {
    var parts = std.mem.splitScalar(u8, name, '.');
    while (parts.next()) |part| {
        if (!std.zig.isValidId(part) or std.zig.isUnderscore(part) or std.zig.primitives.isPrimitive(part)) return false;
    }
    return true;
}

/// A node's syntax tag, as std's `Ast.nodeTag` gives it, compared with or switched on a tag
/// that writes a value.
fn shape(context: *glint.RuleContext, tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index, out: *std.ArrayList(Found)) glint.RuleContext.Error!void {
    var found: std.ArrayList([]const u8) = .empty;
    var read: std.EnumSet(Read) = .empty;
    const operand = operand: switch (tree.nodeTag(node)) {
        .equal_equal, .bang_equal => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            for ([_][2]std.zig.Ast.Node.Index{ .{ lhs, rhs }, .{ rhs, lhs } }) |pair| {
                if (try tagRead(context, tree, pair[1])) |each| {
                    try found.append(context.allocator, tree.tokenSlice(tree.nodeMainToken(pair[1])));
                    read.insert(each);
                    break :operand pair[0];
                }
            }
            return;
        },
        .@"switch", .switch_comma => {
            const full = tree.fullSwitch(node).?;
            for (full.ast.cases) |case| for (tree.fullSwitchCase(case).?.ast.values) |value| if (try tagRead(context, tree, value)) |each| {
                try found.append(context.allocator, tree.tokenSlice(tree.nodeMainToken(value)));
                read.insert(each);
            };
            if (found.items.len == 0) return;
            break :operand full.ast.condition;
        },
        else => return,
    };
    switch ((try nodeTagOf(context, tree, operand)) orelse return) {
        .no => {},
        .yes => {
            var queries: std.ArrayList([]const u8) = .empty;
            var each = read.iterator();
            while (each.next()) |kind| try queries.append(context.allocator, try context.allocator.print("a {s} through {s}", .{ @tagName(kind), kind.query() }));
            try out.append(context.allocator, .{ .node = node, .what = .{ .read = try context.allocator.print("a node's syntax tag reads by its shape (.{s}) what the shared queries read: {s}", .{ try std.mem.join(context.allocator, ", .", found.items), try std.mem.join(context.allocator, "; ", queries.items) }) } });
        },
        .unknown => |why| try out.append(context.allocator, .{ .node = node, .what = .{ .undecided = why } }),
    }
}

/// The tag an enum literal names, where it is one that writes a value.
fn tagRead(context: *glint.RuleContext, tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) glint.RuleContext.Error!?Read {
    if (tree.nodeTag(node) != .enum_literal) return null;
    const name = switch (try context.facts.fieldName(context.file, node)) {
        .name => |name| name,
        else => return null,
    };
    return reads(std.meta.stringToEnum(std.zig.Ast.Node.Tag, name) orelse return null);
}

/// Whether `node` is a node's syntax tag: what std's `Ast.nodeTag` returns, or an element of
/// the tag column std's `MultiArrayList.Slice.items` gives (`tree.nodes.items(.tag)`), a
/// `for`'s capture over it or it indexed; each call written in place or held in a `const`
/// local. Null where `node` has neither form.
fn nodeTagOf(context: *glint.RuleContext, tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) glint.RuleContext.Error!?glint.Is {
    if (try heldCall(context, tree, node)) |call| return try glint.stdCall(context, call, "zig.Ast.nodeTag");
    const column = (try columnOf(context, tree, node)) orelse return null;
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, column).?; // unreachable: heldCall gives calls
    if (call.ast.params.len != 1) return null;
    switch (try context.facts.fieldName(context.file, call.ast.params[0])) {
        .name => |name| if (!std.mem.eql(u8, name, "tag")) return null,
        .names, .each_of, .computed => return null,
    }
    return try glint.stdCall(context, column, "MultiArrayList.Slice.items");
}

/// The call whose column `node` is an element of: `column[i]`, or the capture at its position
/// of a `for` over it.
fn columnOf(context: *glint.RuleContext, tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) glint.RuleContext.Error!?std.zig.Ast.Node.Index {
    if (tree.nodeTag(node) == .array_access) return heldCall(context, tree, tree.nodeData(node).node_and_node[0]);
    const decl = switch (try context.facts.definition(context.file, node)) {
        .decl => |decl| decl,
        .none, .unknown => return null,
    };
    if (decl.file != context.file) return null;
    const record = context.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    if (record.kind != .capture) return null;
    const loop = tree.fullFor(record.node) orelse return null;
    var position: usize = 0;
    var token = loop.payload_token;
    while (token < record.token) : (token += 1) {
        if (tree.tokenTag(token) == .comma) position += 1;
    }
    if (position >= loop.ast.inputs.len) return null;
    return heldCall(context, tree, loop.ast.inputs[position]);
}

/// The call `node` is, or a `const` local it names holds.
fn heldCall(context: *glint.RuleContext, tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) glint.RuleContext.Error!?std.zig.Ast.Node.Index {
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    if (tree.fullCall(&buffer, node) != null) return node;
    const decl = switch (try context.facts.definition(context.file, node)) {
        .decl => |decl| decl,
        .none, .unknown => return null,
    };
    if (decl.file != context.file) return null;
    const record = context.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    if (record.kind != .variable) return null;
    const variable = tree.fullVarDecl(record.node) orelse return null;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
    const init = variable.ast.init_node.unwrap() orelse return null;
    return if (tree.fullCall(&buffer, init) != null) init else null;
}

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(2);
    var buffer: [4096]u8 = @splat(0);
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    var problems_buffer: [1024]u8 = @splat(0);
    var problems = std.Io.File.stderr().writer(init.io, &problems_buffer);
    const status = cli.executeConfigured(init.gpa, init.io, args, &output.interface, &problems.interface, &rules) catch |err| switch (err) {
        // A write that failed has its cause on its file's writer: a cancel in either ends main as one.
        error.WriteFailed => {
            if (output.err) |cause| if (cause == error.Canceled) return error.Canceled;
            if (problems.err) |cause| if (cause == error.Canceled) return error.Canceled;
            std.process.exit(2);
        },
        else => std.process.exit(2),
    };
    if (status != 0) std.process.exit(status);
}

/// A run of RULE_READERS on `root`, which imports a fixture std with text comparisons and a
/// syntax tree: its findings, and its undecided sites.
fn readers(root: []const u8) !struct { usize, usize } {
    return readersAllowing(root, &.{});
}
/// As `readers`, with the reads `list` allows.
fn readersAllowing(root: []const u8, comptime list: []const Allowed) !struct { usize, usize } {
    return judge(root, rule_readers, &ruled(list));
}
/// A run of NAME_TABLES on `root`, with the tables `list` allows: its findings, and its undecided sites.
fn tablesAllowing(root: []const u8, comptime list: []const Allowed) !struct { usize, usize } {
    return judge(root, name_tables, &tabled(list));
}
/// A run of `rule`, one of `with`, on `root` beside the fixture std.
fn judge(root: []const u8, rule: glint.Rule, with: []const glint.ProjectRule) !struct { usize, usize } {
    var project = try glint.Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = root },
        .{ .name = "standard", .bytes =
        \\pub const mem = struct {
        \\    pub fn eql(comptime T: type, a: []const T, b: []const T) bool { return a.len == b.len; }
        \\    pub fn startsWith(comptime T: type, a: []const T, b: []const T) bool { return a.len >= b.len; }
        \\    pub fn endsWith(comptime T: type, a: []const T, b: []const T) bool { return a.len >= b.len; }
        \\    pub fn find(comptime T: type, a: []const T, b: []const T) ?usize { return if (a.len >= b.len) 0 else null; }
        \\};
        \\pub fn StringHashMapUnmanaged(comptime V: type) type { return struct { value: ?V = null }; }
        \\pub fn AutoHashMapUnmanaged(comptime K: type, comptime V: type) type { return struct { key: ?K = null, value: ?V = null }; }
        \\pub fn MultiArrayList(comptime T: type) type {
        \\    return struct {
        \\        pub const Slice = struct {
        \\            tags: []const T,
        \\            pub fn items(self: Slice, comptime field: @TypeOf(.tag)) []const T { _ = field; return self.tags; }
        \\        };
        \\    };
        \\}
        \\pub const zig = struct {
        \\    pub const Ast = struct {
        \\        tags: []const Node.Tag,
        \\        nodes: MultiArrayList(Node.Tag).Slice,
        \\        pub const Node = struct { pub const Tag = enum { identifier, call_one, assign, @"catch", @"if" }; };
        \\        pub fn nodeTag(tree: Ast, node: usize) Node.Tag { return tree.tags[node]; }
        \\        pub fn fullContainerField(tree: Ast, node: usize) ?usize { return if (node < tree.tags.len) node else null; }
        \\        pub fn fullVarDecl(tree: Ast, node: usize) ?usize { return if (node < tree.tags.len) node else null; }
        \\    };
        \\};
        , .selected = false },
    }, &.{.{ .from = 0, .target = 1, .spelling = "std" }}, .{}); // safe: fixture constants fit the asserted integer widths.
    defer project.deinit();
    const config: glint.Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .report }} };
    var report = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = with });
    defer report.deinit();
    var undecided: usize = 0;
    for (report.coverage) |item| if (item.rule) |each| {
        if (each == rule) undecided += 1;
    };
    return .{ report.diagnostics.len, undecided };
}

test "a rule's text comparison with a declaration's name is a spelling read, found by what std's function is" {
    const head = "const std = @import(\"std\"); ";
    for ([_]struct { []const u8, usize, usize }{
        .{ "pub fn f(name: []const u8) bool { return std.mem.eql(u8, name, \"deinit\"); }", 1, 0 },
        .{ "pub fn f(name: []const u8) bool { return std.mem.endsWith(u8, name, \"debug.print\"); }", 1, 0 },
        // Through an alias, a `const` holding the name, a list of names a loop ranges over.
        .{ "const same = std.mem.eql; pub fn f(name: []const u8) bool { return same(u8, name, \"deinit\"); }", 1, 0 },
        .{ "const wanted = \"deinit\"; pub fn f(name: []const u8) bool { return std.mem.startsWith(u8, name, wanted); }", 1, 0 },
        .{ "pub fn f(name: []const u8) bool { for ([_][]const u8{ \"lock\", \"unlock\" }) |each| if (std.mem.find(u8, name, each) != null) return true; return false; }", 1, 0 },
        // Text no declaration is named, a value the language names, and a function of the program's own.
        .{ "pub fn f(name: []const u8) bool { return std.mem.eql(u8, name, \"a name\") or std.mem.eql(u8, name, \"null\") or std.mem.eql(u8, name, \"_\") or std.mem.eql(u8, name, \"type\"); }", 0, 0 },
        .{ "fn eql(comptime T: type, a: []const T, b: []const T) bool { return a.len == b.len; } pub fn f(name: []const u8) bool { return eql(u8, name, \"deinit\"); }", 0, 0 },
        // A test's comparisons are no rule's reads.
        .{ "test { _ = std.mem.eql(u8, \"x\", \"deinit\"); }", 0, 0 },
        // A callee that may be std's function: undecided.
        .{ "pub fn f(g: anytype, name: []const u8) bool { return g.eql(u8, name, \"deinit\"); }", 0, 1 },
    }) |case| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ head, case[0] });
        defer std.testing.allocator.free(source);
        const found, const undecided = try readers(source);
        try std.testing.expectEqual(case[1], found);
        try std.testing.expectEqual(case[2], undecided);
    }
}

test "a rule's test of a node's syntax tag against one that writes a value is a shape read" {
    const head = "const std = @import(\"std\"); const Ast = std.zig.Ast; ";
    for ([_]struct { []const u8, usize }{
        .{ "pub fn f(tree: Ast, n: usize) bool { return tree.nodeTag(n) == .identifier; }", 1 },
        .{ "pub fn f(tree: Ast, n: usize) bool { return .assign != tree.nodeTag(n); }", 1 },
        .{ "pub fn f(tree: Ast, n: usize) bool { const tag = tree.nodeTag(n); return tag == .call_one; }", 1 },
        .{ "pub fn f(tree: Ast, n: usize) u8 { return switch (tree.nodeTag(n)) { .@\"if\" => 0, .identifier => 1, else => 2 }; }", 1 },
        // The constructs a rule is about.
        .{ "pub fn f(tree: Ast, n: usize) bool { return tree.nodeTag(n) == .@\"catch\"; }", 0 },
        .{ "pub fn f(tree: Ast, n: usize) u8 { return switch (tree.nodeTag(n)) { .@\"if\", .@\"catch\" => 0, else => 2 }; }", 0 },
        // A tag read from the tree's tag column: a loop's capture over it, it indexed, the column held.
        .{ "pub fn f(tree: Ast) bool { for (tree.nodes.items(.tag)) |tag| if (tag == .identifier) return true; return false; }", 1 },
        .{ "pub fn f(tree: Ast, n: usize) bool { return tree.nodes.items(.tag)[n] == .assign; }", 1 },
        .{ "pub fn f(tree: Ast) u8 { const tags = tree.nodes.items(.tag); var n: u8 = 0; for (tags, 0..) |tag, i| { _ = i; switch (tag) { .call_one => n += 1, else => {} } } return n; }", 1 },
        .{ "pub fn f(tree: Ast) bool { for (0..1, tree.nodes.items(.tag)) |_, tag| if (tag == .identifier) return true; return false; }", 1 },
        // A loop's capture over something else, the index beside the column.
        .{ "pub fn f(tree: Ast, mine: []const Ast.Node.Tag) bool { for (tree.nodes.items(.tag), mine) |_, tag| if (tag == .identifier) return true; return false; }", 0 },
        // A tag no syntax tree gave.
        .{ "const Mine = enum { identifier, other }; pub fn f(m: Mine) bool { return m == .identifier; }", 0 },
    }) |case| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ head, case[0] });
        defer std.testing.allocator.free(source);
        const found, const undecided = try readers(source);
        try std.testing.expectEqual(case[1], found);
        try std.testing.expectEqual(@as(usize, 0), undecided);
    }
}

test "an allowed function's reads are not reported, and an entry no read is in is" {
    const source =
        \\const std = @import("std");
        \\const Ast = std.zig.Ast;
        \\const Walk = struct {
        \\    fn named(name: []const u8) bool { return std.mem.eql(u8, name, "deinit"); }
        \\};
        \\pub fn shaped(tree: Ast, n: usize) bool { return tree.nodeTag(n) == .identifier; }
        \\pub fn spelled(g: anytype, name: []const u8) bool { return g.eql(u8, name, "deinit"); }
    ;
    // Nothing allowed: two reads and one undecided.
    try std.testing.expectEqual(.{ 2, 1 }, try readers(source));
    // A function inside a container is named through it; an undecided site is allowed with its function's reads.
    try std.testing.expectEqual(.{ 1, 1 }, try readersAllowing(source, &.{.{ .file = "root", .function = "Walk.named", .reason = "a style rule's names" }}));
    try std.testing.expectEqual(.{ 2, 0 }, try readersAllowing(source, &.{.{ .file = "root", .function = "spelled", .reason = "a style rule's names" }}));
    // An entry naming a function with no read, one that is not there, or the container alone, is a finding.
    try std.testing.expectEqual(.{ 3, 1 }, try readersAllowing(source, &.{.{ .file = "root", .function = "Walk", .reason = "a style rule's names" }}));
    try std.testing.expectEqual(.{ 3, 1 }, try readersAllowing(source, &.{.{ .file = "root", .function = "gone", .reason = "a style rule's names" }}));
    // Another file's entry is that file's.
    try std.testing.expectEqual(.{ 2, 1 }, try readersAllowing(source, &.{.{ .file = "src/Other.zig", .function = "shaped", .reason = "a style rule's names" }}));
}

test "std's container field reading, which the model corrects, is a finding wherever a rule calls it, allowed or not" {
    const source =
        \\const std = @import("std");
        \\const Ast = std.zig.Ast;
        \\pub fn field(tree: Ast, n: usize) ?usize { return tree.fullContainerField(n); }
        \\pub fn variable(tree: Ast, n: usize) ?usize { return tree.fullVarDecl(n); }
        \\pub fn held(tree: Ast, n: usize) ?usize { const read = Ast.fullContainerField; return read(tree, n); }
    ;
    // The method call and the call through a held function are std's reading; another of std's
    // readings of syntax is none.
    try std.testing.expectEqual(.{ 2, 0 }, try readers(source));
    // No entry allows it: the reading stays a finding, and the entry, allowing nothing, is one too.
    try std.testing.expectEqual(.{ 3, 0 }, try readersAllowing(source, &.{.{ .file = "root", .function = "field", .reason = "a style rule's fields" }}));
}

test "a table keyed by text is found wherever glint makes it, by what std's map is, unless allowed by where it is made" {
    const source =
        \\const std = @import("std");
        \\const Map = std.StringHashMapUnmanaged;
        \\names: std.StringHashMapUnmanaged(u32) = .{},
        \\const Scope = struct { by_name: std.StringHashMapUnmanaged(u8) = .{} };
        \\pub fn index() void { var held: Map(bool) = .{}; _ = &held; }
        \\pub fn ids() void { var by_id: std.AutoHashMapUnmanaged(u32, u8) = .{}; _ = &by_id; }
        \\fn StringHashMapUnmanaged(comptime V: type) type { return struct { value: ?V = null }; }
        \\pub fn own() void { var mine: StringHashMapUnmanaged(u8) = .{}; _ = &mine; }
        \\pub fn through(m: anytype) void { var maybe: m.StringHashMapUnmanaged(u8) = .{}; _ = &maybe; }
        \\test { var t: std.StringHashMapUnmanaged(u8) = .{}; _ = &t; }
    ;
    // A field at the file's level, one in a container, one through an alias in a function; a map
    // keyed otherwise, the program's own function so spelled and a test's are none. A callee that
    // may be std's is undecided.
    try std.testing.expectEqual(.{ 3, 1 }, try tablesAllowing(source, &.{}));
    // Allowed where it is made: a field by its containers' path, a function by its name.
    try std.testing.expectEqual(.{ 1, 1 }, try tablesAllowing(source, &.{
        .{ .file = "root", .function = "Scope.by_name", .reason = "text is the identity" },
        .{ .file = "root", .function = "index", .reason = "text is the identity" },
    }));
    // An entry no table is at is a finding.
    try std.testing.expectEqual(.{ 4, 1 }, try tablesAllowing(source, &.{.{ .file = "root", .function = "gone", .reason = "text is the identity" }}));
}

/// A run of VALUE_SWITCHES on `root` (glint's src/Rule.zig) beside a fixture src/Facts.zig that
/// declares Value, with the switches `list` allows: its findings, and its undecided sites.
fn switchesAllowing(root: []const u8, comptime list: []const Allowed) !struct { usize, usize } {
    var project = try glint.Project.init(std.testing.allocator, &.{
        .{ .name = "src/Rule.zig", .bytes = root },
        .{ .name = "src/Facts.zig", .bytes = "pub const Value = union(enum) { unknown: u8, alternatives: []const Value, instance: u32, primitive: []const u8 };\n", .selected = false },
    }, &.{.{ .from = 0, .target = 1, .spelling = "Facts.zig" }}, .{}); // safe: fixture constants fit the asserted integer widths.
    defer project.deinit();
    const config: glint.Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = value_switches, .level = .report }} };
    var report = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = &switched(list) });
    defer report.deinit();
    var undecided: usize = 0;
    for (report.coverage) |item| if (item.rule) |each| {
        if (each == value_switches) undecided += 1;
    };
    return .{ report.diagnostics.len, undecided };
}

test "a switch on a resolved value with no alternatives prong is a finding, found by what its operand resolves to; one naming alternatives, one on another type, and an allowed one are not; one whose operand does not resolve is undecided" {
    const head = "const Facts = @import(\"Facts.zig\");\nconst missing = @import(\"missing\");\nconst Kind = enum { a, b };\n";
    inline for ([_]struct { []const u8, usize, usize }{
        .{ "pub fn f(v: Facts.Value) bool { return switch (v) { .instance => true, else => false }; }", 1, 0 },
        .{ "pub fn f(v: Facts.Value) bool { return switch (v) { .instance => true, .alternatives => |each| each.len != 0, else => false }; }", 0, 0 },
        .{ "pub fn f(k: Kind) bool { return switch (k) { .a => true, else => false }; }", 0, 0 },
        .{ "pub fn f() bool { return switch (missing.value) { .instance => true, else => false }; }", 0, 1 },
    }) |row| {
        const source, const findings, const undecided = row;
        const got = try switchesAllowing(head ++ source, &.{});
        try std.testing.expectEqual(findings, got[0]);
        try std.testing.expectEqual(undecided, got[1]);
    }
    // Allowed by its function: none; an entry no switch of its file is in: a finding itself.
    const allowed_site = try switchesAllowing(head ++ "pub fn f(v: Facts.Value) bool { return switch (v) { .instance => true, else => false }; }", &.{.{ .file = "src/Rule.zig", .function = "f", .reason = "pending: warp-fast" }});
    try std.testing.expectEqual(0, allowed_site[0]);
    const stale = try switchesAllowing(head ++ "pub fn f(k: Kind) bool { return k == .a; }", &.{.{ .file = "src/Rule.zig", .function = "f", .reason = "pending: warp-fast" }});
    try std.testing.expectEqual(1, stale[0]);
}
