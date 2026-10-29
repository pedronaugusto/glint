//! The aegis pack's danger rules whose predicates need no flow fact (designs/aegis.md §7): each
//! finds the sites where a danger exists and aegis's type is the answer, from what the code
//! resolves to, never from a name it merely spells. A site that stands raw carries the pack's
//! escape, `// aegis: <reason>(<rule>, ...): <why>`; one the rule cannot decide is undecided.
//!
//! Every rule reads production code only: test inputs and test blocks are not shipped. An
//! operation the program runs only as it compiles (in a `comptime` block, a function returning
//! `type`, a container-level declaration's value or a field's default) has none of these
//! dangers; a type a field or variable is declared with is the program's state at run time
//! wherever it is written.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Governed = @import("Governed.zig");
const Escapes = @import("Escapes.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Contract = @import("AegisContract.zig");
const Report = @import("Report.zig");
const Taint = @import("Taint.zig");
const Rule = @import("Rule.zig").Rule;
const Ast = std.zig.Ast;

/// A007: shared state outside aegis's guards. `Io.Event` is none: a signal set once, which
/// guards no data of its own (what it announces is judged where it is held).
pub fn sharedState(c: *Context, rule: Rule) Context.Error!void {
    const sync = [_][]const u8{ "Io.Mutex", "Io.RwLock", "Io.Condition", "Io.Semaphore", "atomic.Value", "atomic.Mutex" };
    const held = try governedHeld(c, rule, &sync, "{s}: raw synchronization; aegis Guarded, BlockingGuarded, RwGuarded, SpinRwGuarded, Condition, Atomic, Once or Lazy holds the data it guards");
    const tree = &c.project.files[c.file.raw()].tree;
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const name = builtinName(tree, node) orelse continue;
        for ([_][]const u8{ "@atomicLoad", "@atomicStore", "@atomicRmw", "@cmpxchgWeak", "@cmpxchgStrong" }) |atomic| if (std.mem.eql(u8, name, atomic)) {
            if (!c.inTest(tree.nodeMainToken(node)) and atRuntime(c, node)) try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("{s}: a raw atomic; aegis Atomic holds the cell", .{name}));
        };
    }
    const model = &c.project.models[c.file.raw()];
    for (model.declarations) |decl| {
        if (decl.kind != .variable) continue;
        const scope = model.scopes[decl.scope].kind;
        if (scope != .file and scope != .container) continue;
        const variable = tree.fullVarDecl(decl.node) orelse continue;
        if (tree.tokenTag(variable.ast.mut_token) != .keyword_var or variable.threadlocal_token != null) continue;
        // An `extern var` is the unsafe set's (A019): its storage is another program's.
        if (variable.extern_export_token) |token| if (tree.tokenTag(token) == .keyword_extern) continue;
        if (c.inTest(decl.token)) continue;
        // A variable of a synchronization type is that type's site, counted once; one of an
        // aegis type (`Atomic`, `Guarded`, `Once`, ...) is held by its answer.
        if (variable.ast.type_node.unwrap()) |kind| {
            if (within(tree, held, kind)) continue;
            if (try guards(c, try c.facts.resolve(c.file, kind))) continue;
        }
        try c.at(rule, decl.token, try c.allocator.print("container-level var '{s}': mutable state any thread may reach; aegis Guarded, Atomic, Once or Lazy holds it, or Confined checks its one owner", .{decl.name}));
    }
}

/// Whether a container variable's type holds its state under aegis: an aegis type, or a choice
/// the build makes (`if (builtin.is_test) aegis.Atomic(T) else void`) each of whose types is
/// one or `void`, which holds no state.
fn guards(c: *Context, value: Facts.Value) Context.Error!bool {
    switch (value) {
        .alternatives => |each| {
            for (each) |one| if (!try guards(c, one)) return false;
            return true;
        },
        .primitive => |name| return std.mem.eql(u8, name, "void"),
        else => return try c.role(Contract.library, value) != null,
    }
}

/// A008: secret material outside aegis's Secret and Choice.
pub fn secrets(c: *Context, rule: Rule) Context.Error!void {
    const calls = [_][]const u8{ "crypto.secureZero", "crypto.timing_safe.eql", "crypto.timing_safe.compare" };
    try governed(c, rule, &calls, true, "{s}: secret material handled by hand; aegis Secret and SecretBytes wipe it, Choice compares in constant time");
    const keys = try secretKeys(c);
    if (keys.len == 0) return;
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const site = switch (tag) {
            .identifier => tree.nodeMainToken(node),
            .field_access => tree.nodeData(node).node_and_token[1],
            else => continue,
        };
        const spelled = tree.tokenSlice(site);
        if (!std.mem.eql(u8, spelled, "SecretKey") and !std.mem.eql(u8, spelled, "KeyPair")) continue;
        if (c.inTest(site)) continue;
        const decl = (try c.facts.definition(c.file, node)) orelse continue;
        const origin = (try c.facts.origin(decl)) orelse decl;
        var secret = false;
        for (keys) |key| secret = secret or std.meta.eql(key, decl) or std.meta.eql(key, origin);
        if (!secret or (!std.meta.eql(decl, origin) and c.project.inputs[decl.file.raw()].selected)) continue;
        if (try borrowedOrSealed(c, node)) continue;
        // A secret type compared with another is named, not held.
        if (model.node_parents[@backingInt(node)]) |parent| switch (tree.nodeTag(parent)) { // safe: a node index indexes its own tree's parent table
            .equal_equal, .bang_equal => continue,
            else => {},
        };
        try c.at(rule, site, try c.allocator.print("std.crypto {s} held by value outside aegis Secret: its bytes are copied and never wiped", .{spelled}));
    }
}

/// The declarations of std's secret-key and key-pair types: those named `SecretKey` or
/// `KeyPair` in the files std's `crypto` namespace reaches through its own relative imports.
fn secretKeys(c: *Context) Context.Error![]const Facts.Decl {
    var roots: std.ArrayList(Project.FileId) = .empty;
    for (c.project.imports) |mapping| if (std.mem.eql(u8, mapping.spelling, "std")) {
        for (roots.items) |seen| {
            if (seen.eql(mapping.target)) break;
        } else try roots.append(c.allocator, mapping.target);
    };
    var files: std.ArrayList(Project.FileId) = .empty;
    for (roots.items) |root| {
        const crypto = c.facts.member(.{ .file = root, .scope = 0 }, "crypto") orelse continue;
        const value = try c.facts.declaration((try c.facts.origin(crypto)) orelse crypto);
        if (value != .container) continue;
        try files.append(c.allocator, value.container.file);
    }
    var next: usize = 0;
    while (next < files.items.len) : (next += 1) {
        const file = files.items[next];
        for (c.project.imports) |mapping| {
            if (!mapping.from.eql(file) or !std.mem.endsWith(u8, mapping.spelling, ".zig")) continue;
            for (files.items) |seen| {
                if (seen.eql(mapping.target)) break;
            } else try files.append(c.allocator, mapping.target);
        }
    }
    var keys: std.ArrayList(Facts.Decl) = .empty;
    for (files.items) |file| for (c.project.models[file.raw()].declarations, 0..) |decl, d| {
        if (decl.kind != .variable or !decl.public) continue;
        if (!std.mem.eql(u8, decl.name, "SecretKey") and !std.mem.eql(u8, decl.name, "KeyPair")) continue;
        try keys.append(c.allocator, .{ .file = file, .index = @intCast(d) });
    };
    return keys.items;
}

/// Whether a reference to a secret-key type stands behind a pointer (a borrow) or inside an
/// aegis `Secret` or `SecretBytes` instantiation (sealed), up to the declaration it is part of.
fn borrowedOrSealed(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) { // safe: a node index indexes its own tree's parent table
        switch (tree.nodeTag(parent)) {
            .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => return true,
            .fn_decl, .block, .block_semicolon, .block_two, .block_two_semicolon => return false,
            else => {},
        }
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buffer, parent)) |call| if (call.ast.fn_expr != at) {
            const kind = try c.role(Contract.library, try c.facts.resolve(c.file, call.ast.fn_expr));
            if (kind == .secret or kind == .bytes) return true;
        };
        if (tree.fullVarDecl(parent) != null or tree.fullContainerField(parent) != null) return false;
    }
    return false;
}

/// A011: time crossing to and from std as a raw integer.
pub fn units(c: *Context, rule: Rule) Context.Error!void {
    const doors = [_][]const u8{
        "Io.Duration.fromNanoseconds", "Io.Duration.fromMicroseconds", "Io.Duration.fromMilliseconds", "Io.Duration.fromSeconds",
        "Io.Duration.toNanoseconds",   "Io.Duration.toMicroseconds",   "Io.Duration.toMilliseconds",   "Io.Duration.toSeconds",
        "Io.Duration.nanoseconds",     "Io.Timestamp.fromNanoseconds", "Io.Timestamp.toNanoseconds",   "Io.Timestamp.toMicroseconds",
        "Io.Timestamp.toMilliseconds", "Io.Timestamp.toSeconds",       "Io.Timestamp.nanoseconds",
    };
    try rawTime(c, rule, &doors);
    const constants = [_][]const u8{
        "time.ns_per_us",  "time.ns_per_ms",   "time.ns_per_s",   "time.ns_per_min",  "time.ns_per_hour", "time.ns_per_day",  "time.ns_per_week",
        "time.us_per_ms",  "time.us_per_s",    "time.us_per_min", "time.us_per_hour", "time.us_per_day",  "time.us_per_week", "time.ms_per_s",
        "time.ms_per_min", "time.ms_per_hour", "time.ms_per_day", "time.ms_per_week", "time.s_per_min",   "time.s_per_hour",  "time.s_per_day",
        "time.s_per_week",
    };
    var targets: [constants.len]Governed.Target = undefined;
    var indexes: [constants.len]usize = undefined;
    for (constants, &targets, &indexes, 0..) |path, *target, *index, i| {
        target.* = .{ .source = "std", .declaration = path, .production = true };
        index.* = i;
    }
    const found = try Governed.resolve(c, rule, &targets, &indexes);
    var sites: std.ArrayList(Governed.Site) = .empty;
    try Governed.sites(c, rule, found, &sites);
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    for (sites.items) |site| {
        // A constant named through an alias a container declares is converted where the
        // alias is used: the alias itself is no arithmetic.
        if ((site.through_alias and !site.alias_declared) or c.inTest(site.token) or !atRuntime(c, site.node)) continue;
        const parent = model.node_parents[@backingInt(site.node)] orelse continue; // safe: a node index indexes its own tree's parent table
        if (!arithmetic(tree.nodeTag(parent))) continue;
        try c.at(rule, site.token, try c.allocator.print("std.{s} in arithmetic: a unit converted by hand; aegis units.Duration converts between units and checks the result", .{constants[site.index]}));
    }
}

/// A011's doors: each raw-integer crossing of std's time. Two raw nanosecond counts compared or
/// subtracted, or one compared with zero, keep their unit: no conversion happens there.
fn rawTime(c: *Context, rule: Rule, paths: []const []const u8) Context.Error!void {
    const targets = try c.allocator.alloc(Governed.Target, paths.len);
    const indexes = try c.allocator.alloc(usize, paths.len);
    for (paths, targets, indexes, 0..) |path, *target, *index, i| {
        target.* = .{ .source = "std", .declaration = path, .production = true };
        index.* = i;
    }
    const found = try Governed.resolve(c, rule, targets, indexes);
    var sites: std.ArrayList(Governed.Site) = .empty;
    try Governed.sites(c, rule, found, &sites);
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    for (sites.items) |site| {
        if ((site.through_alias and !site.alias_declared) or c.inTest(site.token) or !atRuntime(c, site.node)) continue;
        if (sameUnit(tree, model, site.node)) continue;
        try c.at(rule, site.token, try c.allocator.print("{s}: time as a raw integer; aegis units.Duration and Instant carry the unit and convert with toIoDuration and fromIoDuration", .{paths[site.index]}));
    }
}

/// Whether a raw `.nanoseconds` read meets only another one, or zero, in a comparison or a
/// difference.
fn sameUnit(tree: *const Ast, model: anytype, node: Ast.Node.Index) bool {
    if (!nanoseconds(tree, node)) return false;
    var parent = model.node_parents[@backingInt(node)] orelse return false; // safe: a node index indexes its own tree's parent table
    var at = node;
    // A difference of raw counts is one too: what it meets is what the read meets.
    while ((tree.nodeTag(parent) == .sub or tree.nodeTag(parent) == .sub_sat or tree.nodeTag(parent) == .grouped_expression) and nanoseconds(tree, parent)) {
        at = parent;
        parent = model.node_parents[@backingInt(parent)] orelse return false; // safe: a node index indexes its own tree's parent table
    }
    switch (tree.nodeTag(parent)) {
        .less_than, .less_or_equal, .greater_than, .greater_or_equal, .equal_equal, .bang_equal, .sub, .sub_sat => {},
        else => return false,
    }
    if (nanoseconds(tree, parent)) return true;
    const lhs, const rhs = tree.nodeData(parent).node_and_node;
    const other = if (lhs == at) rhs else lhs;
    if (nanoseconds(tree, other)) return true;
    return tree.nodeTag(other) == .number_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(other)), "0");
}

/// Whether a node is a raw nanosecond count: a `.nanoseconds` read, or a difference of two.
fn nanoseconds(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .field_access => std.mem.eql(u8, tree.tokenSlice(tree.nodeData(node).node_and_token[1]), "nanoseconds"),
        .sub, .sub_sat => nanoseconds(tree, tree.nodeData(node).node_and_node[0]) and nanoseconds(tree, tree.nodeData(node).node_and_node[1]),
        .grouped_expression => nanoseconds(tree, tree.nodeData(node).node_and_token[0]),
        else => false,
    };
}

/// A013: a contract a peer's input can reach: an `assert` whose condition holds input, an
/// `unreachable` on a branch input chooses, a `catch unreachable` or `orelse unreachable` on a
/// call that reads input or is given it. Input must meet an error, never a panic, or undefined
/// behaviour in a consumer's ReleaseFast build. An internal invariant no input reaches is the
/// program's to state, as Zig's own checks are; ReleaseFast is the consumer's choice.
pub fn contracts(c: *Context, rule: Rule) Context.Error!void {
    const flow = try Taint.get(c, .input);
    try asserts(c, rule, flow);
    const tree = &c.project.files[c.file.raw()].tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .unreachable_literal) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (c.inTest(token) or !atRuntime(c, node)) continue;
        switch (try chosenBy(c, flow, node)) {
            .clean => {},
            .unknown => try c.undecided(rule, tree.tokenStart(token), .unresolved, "a branch that passed through a call that does not resolve may be input's to choose"),
            .data, .number => try c.at(rule, token, "unreachable on a path input chooses: a peer reaches a panic, or undefined behaviour in a consumer's ReleaseFast build; return an error"),
        }
    }
}

/// How far input chooses the path to `node`: the conditions of the branches and loops it is
/// in, the operands of the switches whose prongs hold it, and a `catch` or `orelse` it is the
/// answer of, through the call before it (what the call reads and is given), up to its
/// function.
fn chosenBy(c: *Context, flow: *Taint.Flow, node: Ast.Node.Index) Context.Error!Taint.Level {
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    var out: Taint.Level = .clean;
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) { // safe: a node index indexes its own tree's parent table
        switch (tree.nodeTag(parent)) {
            .fn_decl => break,
            .@"catch", .@"orelse" => {
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                if (rhs == at) out = out.join(try failedBy(c, flow, lhs));
            },
            else => {},
        }
        if (tree.fullIf(parent)) |branch| {
            if (branch.ast.cond_expr != at) out = out.join(try Taint.conditionAt(c, flow, c.file, branch.ast.cond_expr));
        } else if (tree.fullWhile(parent)) |loop| {
            if (loop.ast.cond_expr != at) out = out.join(try Taint.conditionAt(c, flow, c.file, loop.ast.cond_expr));
        } else if (tree.fullSwitchCase(parent) != null) {
            const choice = model.node_parents[@backingInt(parent)] orelse continue; // safe: a node index indexes its own tree's parent table
            const whole = tree.fullSwitch(choice) orelse continue;
            out = out.join(try Taint.levelAt(c, flow, c.file, whole.ast.condition));
        }
    }
    return out;
}

/// How far input can make `expression` fail: what it holds, and what a call it makes reads
/// and is given.
fn failedBy(c: *Context, flow: *Taint.Flow, expression: Ast.Node.Index) Context.Error!Taint.Level {
    const tree = &c.project.files[c.file.raw()].tree;
    var out = try Taint.levelAt(c, flow, c.file, expression);
    var inner = expression;
    while (tree.nodeTag(inner) == .@"try" or tree.nodeTag(inner) == .grouped_expression) inner = if (tree.nodeTag(inner) == .@"try") tree.nodeData(inner).node else tree.nodeData(inner).node_and_token[0];
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, inner) orelse return out;
    const reached = try Taint.reached(c, flow, c.file, call);
    for (reached.args) |arg| out = out.join(try Taint.levelAt(c, flow, c.file, arg));
    if (try Taint.isRead(c, flow, c.file, call)) out = out.join(.data);
    return out;
}

/// A013's `std.debug.assert` sites whose condition holds input, each with its fix where the
/// file's code alone decides it: `std.debug.assert(c)`, or a call through a private alias,
/// becomes `aegis.assert.invariant(c, "c")`, the file importing aegis for it when it does not.
fn asserts(c: *Context, rule: Rule, flow: *Taint.Flow) Context.Error!void {
    const message = "std.debug.assert on input: a contract a peer can break, a panic or undefined behaviour in a consumer's ReleaseFast build; return an error, or aegis assert.invariant checks it in every build";
    var target: [1]Governed.Target = .{.{ .source = "std", .declaration = "debug.assert", .production = true }};
    var index: [1]usize = .{0};
    const found = try Governed.resolve(c, rule, &target, &index);
    var sites: std.ArrayList(Governed.Site) = .empty;
    try Governed.sites(c, rule, found, &sites);
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    var calls: std.ArrayList(Ast.Node.Index) = .empty;
    for (sites.items) |site| {
        if (site.through_alias or c.inTest(site.token)) continue;
        const parent = model.node_parents[@backingInt(site.node)] orelse continue; // safe: a node index indexes its own tree's parent table
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buffer, parent)) |call| if (call.ast.fn_expr == site.node) {
            try calls.append(c.allocator, parent);
            continue;
        };
        try aliasCalls(c, parent, &calls);
    }
    for (calls.items) |node| {
        if (c.inTest(tree.nodeMainToken(node)) or !atRuntime(c, node)) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node).?;
        if (call.ast.params.len != 1) continue;
        const token = tree.firstToken(node);
        switch (try Taint.conditionAt(c, flow, c.file, call.ast.params[0])) {
            .clean => {},
            .unknown => try c.undecided(rule, tree.tokenStart(token), .unresolved, "a condition that passed through a call that does not resolve may hold input"),
            .data, .number => {
                var edits: std.ArrayList(Report.Edit) = .empty;
                if (try invariant(c, node, &edits)) try c.fixedAt(rule, token, message, edits.items) else try c.at(rule, token, message);
            },
        }
    }
}

/// The calls through a private alias of std's assert (`const assert = std.debug.assert;`).
fn aliasCalls(c: *Context, value: Ast.Node.Index, calls: *std.ArrayList(Ast.Node.Index)) Context.Error!void {
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    const variable = tree.fullVarDecl(value) orelse return;
    if (variable.visib_token != null) return;
    var declared: ?u32 = null;
    for (model.declarations, 0..) |decl, d| if (decl.node == value and decl.kind == .variable) {
        declared = @intCast(d);
    };
    const alias = declared orelse return;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const ref = model.reference(node) orelse continue;
        if (ref.declaration != alias) continue;
        const parent = model.node_parents[@backingInt(node)] orelse continue; // safe: a node index indexes its own tree's parent table
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, parent) orelse continue;
        if (call.ast.fn_expr == node) try calls.append(c.allocator, parent);
    }
}

/// The edits that make the call at `node` (`f(c)`) `aegis.assert.invariant(c, "c")`, the
/// file's aegis import among them; false where the call is not that shape.
fn invariant(c: *Context, node: Ast.Node.Index, edits: *std.ArrayList(Report.Edit)) Context.Error!bool {
    const tree = &c.project.files[c.file.raw()].tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    if (call.ast.params.len != 1) return false;
    const aegis = (try aegisName(c, edits)) orelse return false;
    const condition = tree.getNodeSource(call.ast.params[0]);
    var said: std.Io.Writer.Allocating = .init(c.allocator);
    // The message is the condition as written, on one line.
    var words = std.mem.tokenizeAny(u8, condition, " \t\r\n");
    var first = true;
    while (words.next()) |word| {
        // An allocating writer fails only when memory does.
        if (!first) said.writer.writeByte(' ') catch return error.OutOfMemory;
        std.zig.stringEscape(word, &said.writer) catch return error.OutOfMemory;
        first = false;
    }
    const start = tree.tokenStart(tree.firstToken(node));
    const last = tree.lastToken(node);
    try edits.append(c.allocator, .{ .start = start, .end = tree.tokenStart(last) + @as(u32, @intCast(tree.tokenSlice(last).len)), .text = try c.allocator.print("{s}.assert.invariant({s}, \"{s}\")", .{ aegis, condition, said.written() }) });
    return true;
}

/// The name the file imports aegis by, an edit adding the import (after std's) when it has
/// none; null where `aegis` names something else.
fn aegisName(c: *Context, edits: *std.ArrayList(Report.Edit)) Context.Error!?[]const u8 {
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    const file = &c.project.files[c.file.raw()];
    var after_std: u32 = 0;
    for (model.declarations) |decl| {
        if (decl.kind != .variable or model.scopes[decl.scope].kind != .file) continue;
        const variable = tree.fullVarDecl(decl.node) orelse continue;
        const init = variable.ast.init_node.unwrap() orelse continue;
        const spelled = tree.getNodeSource(init);
        if (std.mem.eql(u8, spelled, "@import(\"aegis\")")) return decl.name;
        if (std.mem.eql(u8, decl.name, "aegis")) return null;
        if (std.mem.eql(u8, spelled, "@import(\"std\")")) {
            const line = file.line(tree.tokenStart(decl.token));
            after_std = if (line + 1 < file.lines.len) file.lines[line + 1] else @intCast(file.source.len);
        }
    }
    // With no std import the line goes after the file's doc comment, which stands first.
    if (after_std == 0) for (file.lines) |start| {
        if (!std.mem.startsWith(u8, file.source[start..], "//!")) {
            after_std = start;
            break;
        }
    };
    try edits.append(c.allocator, .{ .start = after_std, .end = after_std, .text = "const aegis = @import(\"aegis\");\n" });
    return "aegis";
}

/// A019: the operations Zig leaves unchecked.
pub fn unsafeSet(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.files[c.file.raw()].tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        switch (tag) {
            .asm_simple, .@"asm" => {
                if (!c.inTest(token) and atRuntime(c, node)) try c.at(rule, token, "inline assembly: no check of what it reads or writes; keep it behind the package's one seam with its reason");
                continue;
            },
            else => {},
        }
        const name = builtinName(tree, node) orelse continue;
        if (c.inTest(token) or !atRuntime(c, node)) continue;
        if (std.mem.eql(u8, name, "@setRuntimeSafety")) {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 1) continue;
            const literal = if (tree.nodeTag(args[0]) == .identifier) tree.tokenSlice(tree.nodeMainToken(args[0])) else "";
            if (std.mem.eql(u8, literal, "false")) {
                try c.at(rule, token, "@setRuntimeSafety(false): bounds, overflow and union checks off; only a measured hot loop validated at its boundary");
                continue;
            }
            // A condition on the build mode: off in the modes whose checks it turns off. A mode
            // that builds without them (fast, small) loses nothing to it.
            const on = (try Model.modes(c.allocator, tree, &c.project.models[c.file.raw()], args[0], 0)) orelse {
                try c.unknown(rule, node, .comptime_dependent);
                continue;
            };
            var off: Model.Modes = .initMany(&.{ .debug, .safe });
            off.setIntersection(on.complement());
            var it = off.iterator();
            const first = it.next() orelse continue;
            const names = if (it.next() != null) "debug and safe" else @tagName(first);
            try c.at(rule, token, try c.allocator.print("@setRuntimeSafety off in {s} builds: bounds, overflow and union checks off where the build keeps them; only a measured hot loop validated at its boundary", .{names}));
            continue;
        }
        // An address read out of a pointer (`@intFromPtr`) is never undefined behavior, and the
        // parent of an interface field (`@alignCast(@fieldParentPtr("interface", w))`, std's
        // own reader and writer pattern) is aligned by construction. Every other @alignCast is
        // a site: a consumer may build the package ReleaseFast, where nothing checks it.
        if (std.mem.eql(u8, name, "@alignCast") and parentOf(tree, node)) continue;
        for ([_][]const u8{ "@ptrCast", "@alignCast", "@constCast", "@volatileCast", "@ptrFromInt" }) |cast| if (std.mem.eql(u8, name, cast)) {
            try c.at(rule, token, try c.allocator.print("{s}: a pointer conversion no build checks", .{name}));
        };
    }
    const model = &c.project.models[c.file.raw()];
    for (model.declarations) |decl| {
        if (decl.kind != .variable and decl.kind != .function) continue;
        const token: ?Ast.TokenIndex = if (decl.kind == .function) blk: {
            var buffer: [1]Ast.Node.Index = undefined;
            break :blk (tree.fullFnProto(&buffer, decl.node) orelse continue).extern_export_inline_token;
        } else (tree.fullVarDecl(decl.node) orelse continue).extern_export_token;
        const keyword = token orelse continue;
        if (tree.tokenTag(keyword) != .keyword_extern or c.inTest(decl.token)) continue;
        try c.at(rule, keyword, try c.allocator.print("extern '{s}': a declaration whose definition Zig does not check; only the raw call, at the package's seam", .{decl.name}));
    }
}

/// Whether an `@alignCast` takes a `@fieldParentPtr`: the struct a field is in, aligned as that
/// struct is.
fn parentOf(tree: *const Ast, node: Ast.Node.Index) bool {
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len != 1) return false;
    var arg = args[0];
    while (tree.nodeTag(arg) == .grouped_expression) arg = tree.nodeData(arg).node_and_token[0];
    return switch (tree.nodeTag(arg)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(arg)), "@fieldParentPtr"),
        else => false,
    };
}

/// A014's frame escapes (Escapes.zig).
pub fn lifetimes(c: *Context, rule: Rule) Context.Error!void {
    try Escapes.check(c, rule);
}

/// A007's synchronization types: each place the program holds one (a field, a variable, a
/// value it makes), never a pointer that borrows one held elsewhere or a member named through
/// the type (`Io.Event.Error`). The sites' tokens, for the variables they type.
fn governedHeld(c: *Context, rule: Rule, paths: []const []const u8, comptime message: []const u8) Context.Error![]const Ast.TokenIndex {
    const targets = try c.allocator.alloc(Governed.Target, paths.len);
    const indexes = try c.allocator.alloc(usize, paths.len);
    for (paths, targets, indexes, 0..) |path, *target, *index, i| {
        target.* = .{ .source = "std", .declaration = path, .production = true };
        index.* = i;
    }
    const found = try Governed.resolve(c, rule, targets, indexes);
    var sites: std.ArrayList(Governed.Site) = .empty;
    try Governed.sites(c, rule, found, &sites);
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    var held: std.ArrayList(Ast.TokenIndex) = .empty;
    for (sites.items) |site| {
        if (site.through_alias or c.inTest(site.token)) continue;
        if (borrowed(tree, model, site.node)) continue;
        try held.append(c.allocator, site.token);
        try c.at(rule, site.token, try c.allocator.print(message, .{paths[site.index]}));
    }
    return held.items;
}

/// Whether a type named at `node` stands behind a pointer, names a member of the type, or is
/// only compared (`T == std.Io.Mutex`, a comptime check that refuses the type): none holds one.
fn borrowed(tree: *const Ast, model: anytype, node: Ast.Node.Index) bool {
    if (model.node_parents[@backingInt(node)]) |parent| { // safe: a node index indexes its own tree's parent table
        if (tree.nodeTag(parent) == .field_access and tree.nodeData(parent).node_and_token[0] == node) return true;
        // The type itself, or what its constructor makes (`std.atomic.Value(u32)`), compared.
        var compared = parent;
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buffer, parent)) |made| if (made.ast.fn_expr == node) {
            compared = model.node_parents[@backingInt(parent)] orelse parent; // safe: a node index indexes its own tree's parent table
        };
        if (tree.nodeTag(compared) == .equal_equal or tree.nodeTag(compared) == .bang_equal) return true;
    }
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) { // safe: a node index indexes its own tree's parent table
        switch (tree.nodeTag(parent)) {
            .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => return true,
            .fn_decl, .block, .block_semicolon, .block_two, .block_two_semicolon => return false,
            else => {},
        }
        if (tree.fullVarDecl(parent) != null or tree.fullContainerField(parent) != null) return false;
    }
    return false;
}

/// Whether one of `tokens` lies in `node`.
fn within(tree: *const Ast, tokens: []const Ast.TokenIndex, node: Ast.Node.Index) bool {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    for (tokens) |token| if (token >= first and token <= last) return true;
    return false;
}

/// Each site in production code that reaches one of std's `paths`, past an alias the program
/// declares (its value is the site), reported with `message` naming the path. An operation
/// (`operation`: a call, a conversion) is a site only where it runs with the program; a type is
/// the program's state wherever it is named.
fn governed(c: *Context, rule: Rule, paths: []const []const u8, operation: bool, comptime message: []const u8) Context.Error!void {
    const targets = try c.allocator.alloc(Governed.Target, paths.len);
    const indexes = try c.allocator.alloc(usize, paths.len);
    for (paths, targets, indexes, 0..) |path, *target, *index, i| {
        target.* = .{ .source = "std", .declaration = path, .production = true };
        index.* = i;
    }
    const found = try Governed.resolve(c, rule, targets, indexes);
    var sites: std.ArrayList(Governed.Site) = .empty;
    try Governed.sites(c, rule, found, &sites);
    for (sites.items) |site| {
        if (site.through_alias or c.inTest(site.token)) continue;
        // An operation is judged where it runs, or where a container's declaration names it
        // (`const eql = std.crypto.timing_safe.eql;`): the program takes it up there, whether
        // it calls it or binds it into a generic's context, whose call runs in that generic.
        if (operation and !atRuntime(c, site.node) and !declaredAs(c, site.node)) continue;
        try c.at(rule, site.token, try c.allocator.print(message, .{paths[site.index]}));
    }
}

/// Whether a reference is the whole value of a constant a file or container declares.
fn declaredAs(c: *const Context, node: Ast.Node.Index) bool {
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    const parent = model.node_parents[@backingInt(node)] orelse return false; // safe: a node index indexes its own tree's parent table
    const variable = tree.fullVarDecl(parent) orelse return false;
    if (variable.ast.init_node.unwrap() != node) return false;
    const holder = model.node_parents[@backingInt(parent)] orelse return true; // safe: a node index indexes its own tree's parent table
    var buffer: [2]Ast.Node.Index = undefined;
    return tree.fullContainerDecl(&buffer, holder) != null or tree.nodeTag(holder) == .root;
}

/// Whether the code at `node` runs when the program runs: inside a function's body that does
/// not return `type`, outside any `comptime` block and any container's declarations nested
/// there. A container-level value or a field's default is evaluated as the program compiles.
pub fn atRuntime(c: *const Context, node: Ast.Node.Index) bool {
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) { // safe: a node index indexes its own tree's parent table
        switch (tree.nodeTag(parent)) {
            .@"comptime" => return false,
            .test_decl => return true,
            .fn_decl => {
                var buffer: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buffer, tree.nodeData(parent).node_and_node[0]) orelse return true;
                const result = proto.ast.return_type.unwrap() orelse return true;
                return !(tree.nodeTag(result) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(result)), "type"));
            },
            else => {
                var buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullContainerDecl(&buffer, parent) != null) return false;
            },
        }
    }
    return false;
}

fn builtinName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => tree.tokenSlice(tree.nodeMainToken(node)),
        else => null,
    };
}

fn arithmetic(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .add, .sub, .mul, .div, .mod, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod => true,
        else => false,
    };
}
