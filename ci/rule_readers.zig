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
pub const rules = ruled(&allowed);
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
    .{ .file = "src/Escapes.zig", .function = "compiledIn", .reason = "a literal as written is compiled into the program, never the frame's memory" },
};

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
    var project = try glint.Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = root },
        .{ .name = "standard", .bytes =
        \\pub const mem = struct {
        \\    pub fn eql(comptime T: type, a: []const T, b: []const T) bool { return a.len == b.len; }
        \\    pub fn startsWith(comptime T: type, a: []const T, b: []const T) bool { return a.len >= b.len; }
        \\    pub fn endsWith(comptime T: type, a: []const T, b: []const T) bool { return a.len >= b.len; }
        \\    pub fn find(comptime T: type, a: []const T, b: []const T) ?usize { return if (a.len >= b.len) 0 else null; }
        \\};
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
    const config: glint.Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule_readers, .level = .report }} };
    const allowing = ruled(list);
    var report = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = &allowing });
    defer report.deinit();
    var undecided: usize = 0;
    for (report.coverage) |item| if (item.rule) |rule| {
        if (rule == rule_readers) undecided += 1;
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
