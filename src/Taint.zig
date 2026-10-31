//! The flow facts the danger rules read (designs/aegis.md §7), each computed once for the whole
//! program: the input fact, which values come from outside it, and the peer fact, which writers
//! reach a peer.
//!
//! Input is what the program did not make: what a `std.Io.Reader` read gives or writes into the
//! caller's buffer (a peer's socket, a child's pipe, stdin, a file, an archive's or a
//! repository's content through the readers over them), what `Io.File` and `Io.Dir` read of a
//! file's contents, and the output `process.run` collects from a child. A reader `Reader.fixed`
//! makes over the program's own bytes carries their fact instead. An escape never makes a read
//! the program's own: it covers the findings its rules have on its line, and what the read
//! gives is input wherever it goes. Arguments and the environment are the operator's,
//! not a peer's, and what a file or directory handle answers of itself (a `stat`, the names a
//! directory lists) the system's. A peer writer is one a `net.Stream` gives.
//!
//! Input is data (bytes, and what the program computes from them) or a number: an integer a
//! peer chooses past a byte's range, which std decodes from data (`readInt`, `parseInt`,
//! `takeInt`) or the program assembles from it by a shift or a product. A position std finds in
//! data, a count a read returns, a slice's `.len` and `.ptr`, the least of a value and a clean
//! bound, a count of bits (`@ctz`, `@clz`, `@popCount`) and a comparison are clean: memory or
//! a width the program holds bounds them. What a decode of 16 bits or fewer gives, and a mask
//! or a remainder by the program's own value, stay in a range the program chose: data, never a
//! number. A truncation and wrapping arithmetic keep a number in their type's range, which a
//! wide type gives the peer: a sink reads them as data only where the value is shown small.
//!
//! The fact flows through locals, captures, indexing and slicing, field reads, arithmetic and
//! conversions; through a call outside the program given such a value (to its result, and to a
//! local receiver it adds it to); through the program's own calls, to the parameter in the
//! callee and back by the callee's summary, so a call made with clean arguments stays clean;
//! and through a store into the program's own field, which holds it everywhere by its
//! declaration. aegis's types are the answer to input: what aegis gives back (an
//! `input.Untrusted` and what its `parse` refines, a checked integer) is clean, but for an owner
//! or a loan (`own.Owned`, `own.OwnedIo`, `own.Lent`), which holds what it is given. The parser
//! is where input is answered, so it reads input: `readForParse` gives the peer's value, and the
//! parser `Untrusted.parse` is handed takes it as its value parameter, so its own checks are read
//! as any reader's are and a boundary hides none of them. A call whose
//! callee does not resolve, given input, gives an unknown value, which a sink reads as
//! undecided, never as passed.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Range = @import("Range.zig");
const Project = @import("Project.zig");
const Governed = @import("Governed.zig");
const Contract = @import("AegisContract.zig");
const Program = @import("Program.zig");
const Ast = std.zig.Ast;

/// How far a value is input's, each level holding the ones below it: clean; unknown, through a
/// call that does not resolve; data, bytes from outside; a number a peer chooses.
pub const Level = enum(u2) {
    clean,
    unknown,
    data,
    number,

    pub fn join(a: Level, b: Level) Level {
        return if (@backingInt(a) >= @backingInt(b)) a else b; // safe: two-bit levels.
    }
    /// Whether the value is input at `least` (data or number).
    pub fn reaches(a: Level, least: Level) bool {
        return a != .unknown and @backingInt(a) >= @backingInt(least); // safe: two-bit levels.
    }
};

/// What an expression holds, read inside one function: a level of its own, and the
/// parameters it depends on: fully; made a number (a parameter's data shifted or multiplied);
/// kept to a range the program chose (a parameter's number masked or truncated: data); or,
/// through a call that did not resolve, at most as unknown.
///
/// Memory also has a length, which is not what it holds: `out[0..n]` holds the program's
/// bytes in a length the peer chose. `length` and `lengths` are that length's level and the
/// slots it depends on (`lengthSlot`): a parameter's value as a bound, or a parameter's own
/// length. What the memory holds stays the program's; its `.len` is the peer's.
pub const Dep = struct {
    level: Level = .clean,
    params: u64 = 0,
    numbers: u64 = 0,
    ranged: u64 = 0,
    maybe: u64 = 0,
    length: Level = .clean,
    lengths: u64 = 0,

    pub fn join(a: Dep, b: Dep) Dep {
        return .{ .level = a.level.join(b.level), .params = a.params | b.params, .numbers = a.numbers | b.numbers, .ranged = a.ranged | b.ranged, .maybe = a.maybe | b.maybe, .length = a.length.join(b.length), .lengths = a.lengths | b.lengths };
    }
    fn lowered(a: Dep) Dep {
        return .{ .level = if (a.level == .clean) .clean else .unknown, .maybe = a.params | a.numbers | a.ranged | a.maybe, .length = a.length, .lengths = a.lengths };
    }
    /// Data made a number: a shift or a product of it, or what std decodes from it.
    fn widened(a: Dep) Dep {
        return .{ .level = if (a.level == .data) .number else a.level, .params = a.params, .numbers = a.numbers | a.params | a.ranged, .maybe = a.maybe, .length = a.length, .lengths = a.lengths };
    }
    /// A value kept to a range the program chose: a number is data there.
    fn narrowed(a: Dep) Dep {
        return .{ .level = if (a.level == .number) .data else a.level, .ranged = a.params | a.numbers | a.ranged, .maybe = a.maybe, .length = a.length, .lengths = a.lengths };
    }
    /// Its length read as a value (`.len`): within the memory, so data at most.
    fn measured(a: Dep) Dep {
        return .{ .level = if (a.length == .number) .data else a.length, .ranged = a.lengths };
    }
    /// Memory whose length is this value (a slice's bound): data at most.
    fn sizing(a: Dep) Dep {
        return .{ .length = if (a.level == .number) .data else a.level, .lengths = a.params | a.numbers | a.ranged | a.maybe };
    }
    /// What it holds, with no length.
    fn held(a: Dep) Dep {
        return .{ .level = a.level, .params = a.params, .numbers = a.numbers, .ranged = a.ranged, .maybe = a.maybe };
    }
    fn clean(a: Dep) bool {
        return a.level == .clean and a.params == 0 and a.numbers == 0 and a.ranged == 0 and a.maybe == 0 and a.length == .clean and a.lengths == 0;
    }
    fn eql(a: Dep, b: Dep) bool {
        return a.level == b.level and a.params == b.params and a.numbers == b.numbers and a.ranged == b.ranged and a.maybe == b.maybe and a.length == b.length and a.lengths == b.lengths;
    }
};

/// The slot of a parameter's length among a function's levels: past the 32 values' slots. A
/// function of more parameters shares a slot between a value and a length, each read as both.
fn lengthSlot(index: usize) usize {
    return if (index < 32) index + 32 else index;
}

/// How many levels a function of `n` parameters keeps: a value's and a length's for each.
fn slots(n: usize) usize {
    return if (n == 0) 0 else @max(n, 32 + @min(n, 32));
}

pub const Fact = enum { input, peer };

const Function = struct {
    file: Project.FileId,
    node: Ast.Node.Index,
    /// Its parameters' declarations in order, the receiver first; null for an unnamed one.
    params: []const ?Model.Declaration.Id,
    /// What its callers give each parameter, and the length of each (`lengthSlot`).
    levels: []Level,
    ret: Dep = .{},
    /// What it stores through each parameter, by position (`out.* = v`, `list.append(gpa, v)`,
    /// `self.part = buf[0..n]` of a field outside the program): a summary as `ret` is, which
    /// each call stores into its argument.
    writes: []Dep,
    /// The parameters it returns a pointer into, by position, and the fields and variables:
    /// what its caller then holds (`resultPlaces`).
    returned: u64 = 0,
    returned_globals: std.ArrayList(Facts.Decl) = .empty,
    /// Its comptime parameters: fixed when the program is compiled, so no input reaches them.
    fixed: u64 = 0,
    /// It is handed to aegis's `Untrusted.parse`: what it returns reaches the program refined
    /// where it shows the value's range.
    parser: bool = false,
    /// What a parse given it gives: the level of the values it returns without showing their
    /// range, which the parse refines nothing of.
    unrefined: Level = .clean,

    /// The position of the parameter `d` declares.
    fn position(f: Function, d: Model.Declaration.Id) ?usize {
        for (f.params, 0..) |param, i| if (param == d) return i;
        return null;
    }

    /// A function of the flow, made only as it is appended or by counting them.
    const Id = enum(u32) { _ };
};

pub const Flow = struct {
    solved: bool = false,
    fact: Fact = .input,
    functions: std.ArrayList(Function) = .empty,
    /// Per file, each node's nearest enclosing function, by its index in `functions`.
    owners: std.AutoHashMapUnmanaged(Project.FileId, []const ?Function.Id) = .empty,
    by_node: std.AutoHashMapUnmanaged(Facts.Key, Function.Id) = .empty,
    locals: std.AutoHashMapUnmanaged(Facts.Decl, Dep) = .empty,
    /// Fields and container-level variables, by declaration.
    globals: std.AutoHashMapUnmanaged(Facts.Decl, Level) = .empty,
    /// The lengths of the memory they hold, by declaration (`Dep.length`).
    lengths: std.AutoHashMapUnmanaged(Facts.Decl, Level) = .empty,
    /// The files that are the program (`Program`).
    program: *const Program = undefined,
    /// std's namespaces whose functions make data from data: what they give holds what they take.
    data_files: std.AutoHashMapUnmanaged(u32, void) = .empty,
    reader: ?Facts.Container = null,
    file: ?Facts.Container = null,
    dir: ?Facts.Container = null,
    stream: ?Facts.Container = null,
    /// The functions the configuration declares write to a peer.
    peer_writers: std.ArrayList(Facts.Decl) = .empty,
    /// Functions whose result is what they read: std's `process.run`, which holds a child's output,
    /// and aegis's whole-file reads, `own.readFile` and `own.readFileSentinel`.
    reads: std.ArrayList(Facts.Decl) = .empty,
    /// Where each pointer the program makes may be kept (`Link`).
    links: std.ArrayList(Link) = .empty,
    /// What decides how many passes each loop takes, read once per round (`passes`).
    loops: std.AutoHashMapUnmanaged(Facts.Key, Dep) = .empty,
    changed: bool = false,

    /// Whether a file is the program's (`Program`): what a file of the package the run did not
    /// select, or a dependency's, does with input is as much the program's.
    pub fn own(flow: *const Flow, file: Project.FileId) bool {
        return flow.program.own(file);
    }
};

/// A pointer to an owner's memory kept in a holder: a store through the holder later writes the
/// owner, which takes the holder's fact each round. The owner is a local (`&x`, `buf[0..]`, a
/// pointer local) or a parameter's memory in its callers (`self`, `out`), whose store is the
/// function's `writes`; the holder is a local, a field or a container-level variable by its
/// declaration, or somewhere the fact does not follow (`unknown`, or a parameter's memory in
/// its callers, read as undecided).
const Link = struct { function: Function.Id, owner: Place, holder: Place };

/// Both facts, kept for the run.
const Flows = struct { input: Flow = .{}, peer: Flow = .{} };

/// The program's `fact`, solved the first time a rule asks.
pub fn get(c: *Context, fact: Fact) Context.Error!*Flow {
    const flows = try c.facts.memo(Flows);
    const flow = switch (fact) {
        .input => &flows.input,
        .peer => &flows.peer,
    };
    if (!flow.solved) {
        flow.fact = fact;
        try solve(c, flow);
        flow.solved = true;
    }
    return flow;
}

fn solve(c: *Context, flow: *Flow) Context.Error!void {
    flow.program = try Program.get(c);
    try known(c, flow);
    for (c.project.sources) |*each| {
        if (each.input.classification == .@"test") continue;
        const file = each.id;
        if (!flow.own(file)) continue;
        // A file whose rules read neither fact (a tool the package develops with) is no part
        // of the program the facts describe.
        if (!reads(c.configOf(file), flow.fact)) continue;
        try functionsOf(c, flow, file);
    }
    try parsers(c, flow);
    try linksOf(c, flow);
    // Every step joins, and each level and set is finite: the rounds end when one changes
    // nothing, however long a chain of calls the fact runs through.
    while (true) {
        flow.changed = false;
        flow.loops.clearRetainingCapacity();
        for (flow.functions.items, 0..) |_, i| try bindings(c, flow, @fromBackingInt(@intCast(i)));
        try takeHeld(c, flow);
        if (!flow.changed) break;
    }
}

fn reads(config: @import("Rule.zig").Config, fact: Fact) bool {
    const pack = @import("AegisRules.zig");
    return switch (fact) {
        .input => config.has(pack.untrusted_input) or config.has(pack.integers) or config.has(pack.bounded_work) or config.has(pack.cancellation) or config.has(pack.contracts) or config.has(pack.recursion),
        .peer => config.has(pack.diagnostics),
    };
}

/// Marks each function the program hands to `Untrusted.parse`, before the rounds, so what its
/// returned literals hold is settled from the first round.
fn parsers(c: *Context, flow: *Flow) Context.Error!void {
    var files = flow.owners.iterator();
    while (files.next()) |entry| {
        const file = entry.key_ptr.*;
        const tree = &c.project.at(file).file.tree;
        for (entry.value_ptr.*, 0..) |own, i| {
            if (own == null) continue;
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, @fromBackingInt(@intCast(i))) orelse continue;
            const callee = try resolveCall(c, flow, file, call);
            if (callee.kind != .aegis) continue;
            if (try parserOf(c, flow, file, call, callee.decl.?)) |target| flow.functions.items[@backingInt(target)].parser = true;
        }
    }
}

/// The declarations the fact starts from and stops at: std's reader, file, directory and stream.
fn known(c: *Context, flow: *Flow) Context.Error!void {
    const paths = [_][]const u8{ "Io.Reader", "Io.File", "Io.Dir", "Io.net.Stream" };
    var found: [paths.len]?Facts.Container = @splat(null);
    for (paths, &found) |path, *slot| {
        for ((try Governed.declarations(c, "std", path)) orelse &.{}) |decl| {
            const value = try c.facts.declaration((try c.facts.origin(decl)) orelse decl);
            if (value == .container) slot.* = value.container;
        }
    }
    flow.reader, flow.file, flow.dir, flow.stream = found;
    for (c.config.peer_writers) |declared| {
        const found_writers = (try Governed.declarations(c, declared.module, declared.declaration)) orelse (try Governed.declarationsOfPackage(c, declared.module, declared.declaration)) orelse &.{};
        for (found_writers) |decl| try flow.peer_writers.append(c.allocator, (try c.facts.origin(decl)) orelse decl);
    }
    for ((try Governed.declarations(c, "std", "process.run")) orelse &.{}) |decl| try flow.reads.append(c.allocator, (try c.facts.origin(decl)) orelse decl);
    for ([_][]const u8{ "own.readFile", "own.readFileSentinel" }) |path| {
        for ((try Governed.declarations(c, "aegis", path)) orelse &.{}) |decl| try flow.reads.append(c.allocator, (try c.facts.origin(decl)) orelse decl);
    }
    for ([_][]const u8{ "mem", "fmt", "ascii", "unicode", "math", "base64" }) |namespace| {
        for ((try Governed.declarations(c, "std", namespace)) orelse &.{}) |decl| {
            const value = try c.facts.declaration((try c.facts.origin(decl)) orelse decl);
            if (value != .container) continue;
            // The namespace's own file and the files it reaches by its relative imports.
            try flow.data_files.put(c.allocator, @backingInt(value.container.file), {});
            var next = std.ArrayList(Project.FileId).empty;
            try next.append(c.allocator, value.container.file);
            while (next.pop()) |file| for (c.project.imports) |mapping| {
                if (mapping.from != file or !std.mem.endsWith(u8, mapping.spelling, ".zig")) continue;
                if ((try flow.data_files.getOrPut(c.allocator, @backingInt(mapping.target))).found_existing) continue;
                try next.append(c.allocator, mapping.target);
            };
        }
    }
}

/// The file's functions with a body, and each node's owner among them.
fn functionsOf(c: *Context, flow: *Flow, file: Project.FileId) Context.Error!void {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const owners = try c.allocator.alloc(?Function.Id, tree.nodes.len);
    @memset(owners, null);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .fn_decl) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(node).node_and_node[0]) orelse continue;
        var params: std.ArrayList(?Model.Declaration.Id) = .empty;
        var fixed: u64 = 0;
        var it = proto.iterate(tree);
        while (it.next()) |param| {
            if (param.comptime_noalias) |token| if (tree.tokenTag(token) == .keyword_comptime) {
                fixed |= bit(params.items.len);
            };
            const name = param.name_token orelse {
                try params.append(c.allocator, null);
                continue;
            };
            var found: ?Model.Declaration.Id = null;
            for (model.declarations, 0..) |decl, d| if (decl.kind == .parameter and decl.token == name) {
                found = @fromBackingInt(@intCast(d));
                break;
            };
            try params.append(c.allocator, found);
        }
        const levels = try c.allocator.alloc(Level, slots(params.items.len));
        @memset(levels, .clean);
        const writes = try c.allocator.alloc(Dep, params.items.len);
        @memset(writes, .{});
        try flow.functions.append(c.allocator, .{ .file = file, .node = node, .params = params.items, .levels = levels, .writes = writes, .fixed = fixed });
        try flow.by_node.put(c.allocator, .{ .file = file, .node = node }, @fromBackingInt(@intCast(flow.functions.items.len - 1)));
    }
    for (0..tree.nodes.len) |i| {
        var at: Ast.Node.Index = @fromBackingInt(@intCast(i));
        while (model.parentOf(at)) |parent| : (at = parent) {
            if (tree.nodeTag(parent) == .fn_decl) {
                owners[i] = flow.by_node.get(.{ .file = file, .node = parent });
                break;
            }
            var buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullContainerDecl(&buffer, parent) != null) break;
        }
    }
    try flow.owners.put(c.allocator, file, owners);
}

/// The function whose body holds `node`, if the fact reads it.
fn owner(flow: *const Flow, file: Project.FileId, node: Ast.Node.Index) ?Function.Id {
    const owners = flow.owners.get(file) orelse return null;
    const index = @backingInt(node);
    return if (index < owners.len) owners[index] else null;
}

/// One round over a function's bindings: what each local, field, parameter and result takes.
fn bindings(c: *Context, flow: *Flow, function: Function.Id) Context.Error!void {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    const owners = flow.owners.get(f.file).?;
    for (owners, 0..) |own, i| {
        if (own != function) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tree.nodeTag(node)) {
            .simple_var_decl, .local_var_decl, .aligned_var_decl, .global_var_decl => {
                const init = (tree.fullVarDecl(node) orelse continue).ast.init_node.unwrap() orelse continue;
                const d = declaredAt(model, node) orelse continue;
                try raiseLocal(c, flow, .{ .file = f.file, .index = d }, try dep(c, flow, function, init));
            },
            .assign, .assign_add, .assign_sub, .assign_div, .assign_mod, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_add_sat, .assign_sub_sat => {
                const target, const value = tree.nodeData(node).node_and_node;
                var held = (try dep(c, flow, function, value)).join(try control(c, flow, function, node, target));
                // A sum or a product that feeds its own target accumulates a number past any
                // range what it adds holds (`n = n * 10 + d`, `total += b`).
                switch (tree.nodeTag(node)) {
                    .assign => if (accumulates(tree, model, target, value)) {
                        held = held.widened();
                    },
                    .assign_add, .assign_add_wrap, .assign_add_sat => held = held.widened(),
                    else => {},
                }
                try store(c, flow, function, target, held);
            },
            .assign_mul, .assign_shl, .assign_mul_wrap, .assign_mul_sat, .assign_shl_sat => {
                const target, const value = tree.nodeData(node).node_and_node;
                try store(c, flow, function, target, (try dep(c, flow, function, target)).widened().join(try dep(c, flow, function, value)).join(try control(c, flow, function, node, target)));
            },
            .assign_destructure => {
                const parts = tree.assignDestructure(node);
                const all = try dep(c, flow, function, parts.ast.value_expr);
                // A literal of as many elements gives each variable its own (`x, y = .{ 5, n }`).
                var buffer: [2]Ast.Node.Index = undefined;
                const elements: ?[]const Ast.Node.Index = if (tree.fullArrayInit(&buffer, parts.ast.value_expr)) |literal| (if (literal.ast.elements.len == parts.ast.variables.len) literal.ast.elements else null) else null;
                for (parts.ast.variables, 0..) |variable, at| {
                    const value = (if (elements) |each| try dep(c, flow, function, each[at]) else all).join(try control(c, flow, function, node, variable));
                    if (declaredAt(model, variable)) |d| try raiseLocal(c, flow, .{ .file = f.file, .index = d }, value) else try store(c, flow, function, variable, value);
                }
            },
            .@"return" => {
                const value = tree.nodeData(node).opt_node.unwrap() orelse continue;
                const now = flow.functions.items[@backingInt(function)].ret.join(try dep(c, flow, function, value)).join(try control(c, flow, function, node, null));
                if (!now.eql(flow.functions.items[@backingInt(function)].ret)) {
                    flow.functions.items[@backingInt(function)].ret = now;
                    flow.changed = true;
                }
                if (f.parser) try unrefined(c, flow, function, value);
            },
            else => {
                var buffer: [1]Ast.Node.Index = undefined;
                if (tree.fullCall(&buffer, node)) |call| try effects(c, flow, function, call);
                var literal_buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullStructInit(&literal_buffer, node)) |literal| if (try literalFields(c, f.file, node, literal)) |fields| {
                    // A parser's result holds its numbers as its own value (`dep`): the parse
                    // refines them, a direct call gives them as they were read.
                    const refined = f.parser and returned(tree, model, node);
                    for (literal.ast.fields, fields) |value, field| {
                        // A number the parser shows the range of reaches the program as data
                        // held to that range, which a sink judges as it judges any value's.
                        const given = (try dep(c, flow, function, value)).join(try control(c, flow, function, node, null));
                        var level = concrete(flow, function, given);
                        if (refined and level == .number and try shownField(c, f.file, value, field)) level = .data;
                        try raiseGlobal(c, flow, field, level, concreteLength(flow, function, given));
                    }
                };
                if (isMemcpy(tree, node)) {
                    var args_buffer: [2]Ast.Node.Index = undefined;
                    const args = Facts.builtinArgs(tree, node, &args_buffer);
                    if (args.len == 2) try store(c, flow, function, args[0], try whole(c, flow, function, args[1]));
                }
            },
        }
    }
    // Captures take what they bind from.
    for (model.declarations, 0..) |decl, d| {
        if (decl.kind != .capture) continue;
        if (owner(flow, f.file, decl.node) != function) continue;
        const from = try captured(c, flow, function, decl);
        try raiseLocal(c, flow, .{ .file = f.file, .index = @fromBackingInt(@intCast(d)) }, from);
    }
}

fn isMemcpy(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@memcpy") or std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@memmove"),
        else => false,
    };
}

/// What a capture binds: an `if`'s or `while`'s payload its condition, a `switch` prong's the
/// switch's operand and the union field the prong names (each field, for `else` or a value
/// that is no tag), a `for` capture its input (a range's counter its bounds), a `catch`'s error
/// nothing.
fn captured(c: *Context, flow: *Flow, function: Function.Id, decl: Model.Declaration) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    const node = decl.node;
    if (tree.fullIf(node)) |branch| return if (branch.error_token == decl.token) .{} else dep(c, flow, function, branch.ast.cond_expr);
    if (tree.fullWhile(node)) |loop| return if (loop.error_token == decl.token) .{} else dep(c, flow, function, loop.ast.cond_expr);
    if (tree.fullSwitchCase(node) != null) {
        const parent = model.parentOf(node) orelse return .{};
        const choice = tree.fullSwitch(parent) orelse return .{};
        var out = try dep(c, flow, function, choice.ast.condition);
        for (try prongFields(c, f.file, choice.ast.condition, node)) |field| {
            out = out.join(.{ .level = flow.globals.get(field) orelse .clean, .length = flow.lengths.get(field) orelse .clean });
        }
        return out;
    }
    if (tree.fullFor(node)) |loop| {
        const position = Model.capturePosition(tree, loop, decl.token) orelse return .{};
        if (position >= loop.ast.inputs.len) return .{};
        const input = loop.ast.inputs[position];
        if (tree.nodeTag(input) == .for_range) {
            // A range's counter runs from its start to its end, or, open, as far as the other
            // inputs' lengths: a peer that chooses those chooses it.
            const start, const end = tree.nodeData(input).node_and_opt_node;
            var out = (try dep(c, flow, function, start)).held();
            if (end.unwrap()) |last| return out.join((try dep(c, flow, function, last)).held());
            for (loop.ast.inputs) |other| if (tree.nodeTag(other) != .for_range) {
                out = out.join((try dep(c, flow, function, other)).measured());
            };
            return out;
        }
        return dep(c, flow, function, input);
    }
    return .{};
}

/// The declaration a `var`/`const` node declares.
fn declaredAt(model: *const Model, node: Ast.Node.Index) ?Model.Declaration.Id {
    for (model.declarations, 0..) |decl, d| if (decl.node == node and decl.kind == .variable) return @fromBackingInt(@intCast(d));
    return null;
}

fn raiseLocal(c: *Context, flow: *Flow, decl: Facts.Decl, value: Dep) Context.Error!void {
    if (value.clean()) return;
    const entry = try flow.locals.getOrPut(c.allocator, decl);
    const before: Dep = if (entry.found_existing) entry.value_ptr.* else .{};
    const now = before.join(value);
    entry.value_ptr.* = now;
    if (!now.eql(before)) flow.changed = true;
}

/// A field or a container-level variable given a value of `level` in memory of `length`.
fn raiseGlobal(c: *Context, flow: *Flow, decl: Facts.Decl, level: Level, length: Level) Context.Error!void {
    for ([_]struct { *std.AutoHashMapUnmanaged(Facts.Decl, Level), Level }{ .{ &flow.globals, level }, .{ &flow.lengths, length } }) |each| {
        const map, const raised = each;
        if (raised == .clean) continue;
        const entry = try map.getOrPut(c.allocator, decl);
        const before: Level = if (entry.found_existing) entry.value_ptr.* else .clean;
        entry.value_ptr.* = before.join(raised);
        if (entry.value_ptr.* != before) flow.changed = true;
    }
}

/// A place a store reaches: a local, a parameter's memory in its callers (the function's
/// `writes`), a field or a container-level variable by its declaration, or memory the fact does
/// not name.
const Place = union(enum) { local: Model.Declaration.Id, param: usize, global: Facts.Decl, unknown };

/// The places a store into `target` writes, each once: a local, a container-level variable or
/// a field by its declaration; the local an element or part of it belongs to, and through a
/// local holding another's memory (`const p = &x; p.* = v`, `x[0..n]`, `[_][]u8{&x}`) that
/// other; through a capture what it binds (`for (items) |*item|`); through `@field` the field
/// it names (or, by a name computed as it compiles, each field of the holder's type); through a
/// call's result the memory the result may point into; or the memory a parameter points at.
fn places(c: *Context, flow: *Flow, function: Function.Id, target: Ast.Node.Index, out: *std.ArrayList(Place)) Context.Error!void {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    switch (tree.nodeTag(target)) {
        .identifier => {
            const ref = model.reference(target) orelse return;
            const d = ref.declaration orelse return;
            const decl = model.declarations[@backingInt(d)];
            // A parameter is never assigned: a store reaching one goes through it, into its
            // callers' memory.
            if (decl.kind == .parameter) {
                if (f.position(d)) |index| try addPlace(c, out, .{ .param = index }) else try addPlace(c, out, .unknown);
                return;
            }
            const scope = model.scopes[@backingInt(decl.scope)].kind;
            if (scope == .file or scope == .container) return addPlace(c, out, .{ .global = .{ .file = f.file, .index = d } });
            if (decl.kind != .variable and decl.kind != .capture) return;
            for (out.items) |each| if (std.meta.eql(each, Place{ .local = d })) return;
            try addPlace(c, out, .{ .local = d });
            if (decl.kind == .variable) if (tree.fullVarDecl(decl.node)) |variable| if (variable.ast.init_node.unwrap()) |init| {
                var buffer: [2]Ast.Node.Index = undefined;
                switch (tree.nodeTag(init)) {
                    .address_of, .slice_open, .slice, .slice_sentinel => try places(c, flow, function, init, out),
                    else => if (tree.fullArrayInit(&buffer, init) != null) try places(c, flow, function, init, out),
                }
            };
            if (decl.kind == .capture) if (try capturedFrom(c, f.file, decl)) |from| try places(c, flow, function, from, out);
        },
        .field_access => {
            // The program's own field holds the fact by its declaration; a field of a type
            // outside it (std's writer, a dependency's list) is every instance's everywhere, so
            // the store reaches only the value it belongs to.
            if (try c.facts.definition(f.file, target)) |decl| {
                if (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind == .field and flow.own(decl.file)) return addPlace(c, out, .{ .global = decl });
            }
            return places(c, flow, function, tree.nodeData(target).node_and_token[0], out);
        },
        .array_access => return places(c, flow, function, tree.nodeData(target).node_and_node[0], out),
        .deref, .address_of, .@"try" => return places(c, flow, function, tree.nodeData(target).node, out),
        .grouped_expression, .unwrap_optional => return places(c, flow, function, tree.nodeData(target).node_and_token[0], out),
        .slice_open, .slice, .slice_sentinel => return places(c, flow, function, (tree.fullSlice(target) orelse return).ast.sliced, out),
        // Many-item pointer arithmetic stays in the memory it starts from.
        .add, .sub, .add_wrap, .sub_wrap => return places(c, flow, function, tree.nodeData(target).node_and_node[0], out),
        .@"orelse", .@"catch" => {
            const lhs, const rhs = tree.nodeData(target).node_and_node;
            try places(c, flow, function, lhs, out);
            try places(c, flow, function, rhs, out);
        },
        .@"if", .if_simple => {
            const branch = tree.fullIf(target).?;
            try places(c, flow, function, branch.ast.then_expr, out);
            if (branch.ast.else_expr.unwrap()) |otherwise| try places(c, flow, function, otherwise, out);
        },
        .@"switch", .switch_comma => for (tree.fullSwitch(target).?.ast.cases) |case| {
            try places(c, flow, function, (tree.fullSwitchCase(case) orelse continue).ast.target_expr, out);
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(target));
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, target, &buffer);
            if (std.mem.eql(u8, name, "@field") and args.len == 2) {
                const fields = try namedFields(c, f.file, target);
                var any = false;
                for (fields) |field| if (flow.own(field.file)) {
                    try addPlace(c, out, .{ .global = field });
                    any = true;
                };
                if (!any) try places(c, flow, function, args[0], out);
                return;
            }
            // A pointer converted is the memory it was.
            for ([_][]const u8{ "@ptrCast", "@alignCast", "@constCast", "@volatileCast", "@as" }) |cast| if (std.mem.eql(u8, name, cast) and args.len > 0) {
                return places(c, flow, function, args[args.len - 1], out);
            };
            try addPlace(c, out, .unknown);
        },
        else => {
            var buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullArrayInit(&buffer, target)) |vector| {
                // A vector of buffers: each one it names, by address, part or pointer.
                for (vector.ast.elements) |element| switch (tree.nodeTag(element)) {
                    .address_of, .slice_open, .slice, .slice_sentinel => try places(c, flow, function, element, out),
                    else => if (try pointing(c, f.file, element)) try places(c, flow, function, element, out),
                };
                return;
            }
            var call_buffer: [1]Ast.Node.Index = undefined;
            if (tree.fullCall(&call_buffer, target)) |call| return resultPlaces(c, flow, function, call, out);
        },
    }
}

fn addPlace(c: *Context, out: *std.ArrayList(Place), place: Place) Context.Error!void {
    for (out.items) |each| if (std.meta.eql(each, place)) return;
    try out.append(c.allocator, place);
}

/// The memory a call's result may point into: for the program's callee, what it returns a
/// pointer into (`Function.returned`), each argument it returns a part of; for a function
/// outside the program, its receiver and each pointer it is given; for one that does not
/// resolve, memory the fact does not name.
fn resultPlaces(c: *Context, flow: *Flow, function: Function.Id, call: Ast.full.Call, out: *std.ArrayList(Place)) Context.Error!void {
    const f = flow.functions.items[@backingInt(function)];
    const callee = try resolveCall(c, flow, f.file, call);
    switch (callee.kind) {
        .program => |target| {
            const g = flow.functions.items[@backingInt(target)];
            for (callee.args.items, 0..) |arg, position| {
                if (g.returned & bit(position + callee.skip) != 0) try places(c, flow, function, arg, out);
            }
            for (g.returned_globals.items) |global| try addPlace(c, out, .{ .global = global });
        },
        .outside, .source, .aegis, .holder => for (callee.args.items) |arg| {
            if (try pointing(c, f.file, arg)) try places(c, flow, function, arg, out);
        },
        .none => try addPlace(c, out, .unknown),
    }
}

/// Whether an expression's value is a pointer, a slice or memory a pointer reaches, or one whose
/// type does not resolve.
fn pointing(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    return switch (try c.facts.resolve(file, node)) {
        .pointer, .unknown, .reified, .alternatives => true,
        .optional, .error_union => |inner| inner.* == .pointer or inner.* == .unknown,
        else => false,
    };
}

/// The fields `@field(holder, name)` names: the one a string literal spells, or each field of
/// the holder's type for a name computed as the program compiles.
pub fn namedFields(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error![]const Facts.Decl {
    const tree = &c.project.at(file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len != 2) return &.{};
    var holder = try c.facts.resolve(file, args[0]);
    while (true) holder = switch (holder) {
        .pointer, .optional => |inner| inner.*,
        else => break,
    };
    const container = switch (holder) {
        .instance, .container => |k| k,
        else => return &.{},
    };
    if (tree.nodeTag(args[1]) == .string_literal) {
        const text = tree.tokenSlice(tree.nodeMainToken(args[1]));
        if (text.len >= 2) {
            const decl = c.facts.member(container, text[1 .. text.len - 1]) orelse return &.{};
            if (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind != .field) return &.{};
            const one = try c.allocator.alloc(Facts.Decl, 1);
            one[0] = decl;
            return one;
        }
    }
    return fieldsOf(c, container);
}

/// The fields a container declares.
pub fn fieldsOf(c: *Context, container: Facts.Container) Context.Error![]const Facts.Decl {
    var out: std.ArrayList(Facts.Decl) = .empty;
    for (c.project.at(container.file).model.declarations, 0..) |decl, d| {
        if (decl.kind != .field or decl.scope != container.scope) continue;
        try out.append(c.allocator, .{ .file = container.file, .index = @fromBackingInt(@intCast(d)) });
    }
    return out.items;
}

/// A store of `value` into `target`, into each of its `places`.
fn store(c: *Context, flow: *Flow, function: Function.Id, target: Ast.Node.Index, value: Dep) Context.Error!void {
    var found: std.ArrayList(Place) = .empty;
    try places(c, flow, function, target, &found);
    for (found.items) |place| try raise(c, flow, function, place, value);
}

/// `value` into one place, read in `function`.
fn raise(c: *Context, flow: *Flow, function: Function.Id, place: Place, value: Dep) Context.Error!void {
    const f = flow.functions.items[@backingInt(function)];
    switch (place) {
        .local => |d| try raiseLocal(c, flow, .{ .file = f.file, .index = d }, value),
        .param => |index| {
            const now = f.writes[index].join(value);
            if (!now.eql(f.writes[index])) {
                f.writes[index] = now;
                flow.changed = true;
            }
        },
        .global => |decl| try raiseGlobal(c, flow, decl, concrete(flow, function, value), concreteLength(flow, function, value)),
        .unknown => {},
    }
}

/// What a capture binds from: an `if`'s or `while`'s condition, a `switch`'s operand, a `for`'s
/// input (none for a range's counter or an error's capture).
fn capturedFrom(c: *Context, file: Project.FileId, decl: Model.Declaration) Context.Error!?Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const node = decl.node;
    if (tree.fullIf(node)) |branch| return if (branch.error_token == decl.token) null else branch.ast.cond_expr;
    if (tree.fullWhile(node)) |loop| return if (loop.error_token == decl.token) null else loop.ast.cond_expr;
    if (tree.fullSwitchCase(node) != null) {
        const parent = model.parentOf(node) orelse return null;
        return (tree.fullSwitch(parent) orelse return null).ast.condition;
    }
    if (tree.fullFor(node)) |loop| {
        const position = Model.capturePosition(tree, loop, decl.token) orelse return null;
        if (position >= loop.ast.inputs.len) return null;
        const input = loop.ast.inputs[position];
        return if (tree.nodeTag(input) == .for_range) null else input;
    }
    return null;
}

/// A call's effects beyond its result: what it gives the program's own callee's parameters,
/// what a read fills, what a local receiver takes from what it is given.
fn effects(c: *Context, flow: *Flow, function: Function.Id, call: Ast.full.Call) Context.Error!void {
    const f = flow.functions.items[@backingInt(function)];
    const callee = try resolveCall(c, flow, f.file, call);
    switch (callee.kind) {
        .program => |target| {
            const g = flow.functions.items[@backingInt(target)];
            for (callee.args.items, 0..) |arg, position| {
                const index = position + callee.skip;
                if (index >= g.params.len) break;
                if (g.fixed & bit(index) != 0) continue;
                const given = try dep(c, flow, function, arg);
                for ([_]struct { usize, Level }{ .{ index, concrete(flow, function, given) }, .{ lengthSlot(index), concreteLength(flow, function, given) } }) |each| {
                    const slot, const level = each;
                    if (slot >= g.levels.len) continue;
                    if (level.join(g.levels[slot]) != g.levels[slot]) {
                        flow.functions.items[@backingInt(target)].levels[slot] = level.join(g.levels[slot]);
                        flow.changed = true;
                    }
                }
                if (!g.writes[index].clean()) try store(c, flow, function, arg, try summarized(c, flow, function, callee, g.writes[index]));
            }
        },
        .source => {
            if (try fixedClean(c, flow, function, call)) return;
            const buffers = try bufferParams(c, callee.decl.?);
            for (callee.args.items, 0..) |arg, position| if (buffers & bit(position) != 0) try fill(c, flow, function, arg);
        },
        .outside => {
            // What a function outside the program is given may go into any memory it is given
            // by a mutable pointer: a list appended to, a map put into, a hasher updated, a
            // writer written to, a destination copied into.
            const decl = callee.decl orelse return;
            var given: Dep = .{};
            for (callee.args.items) |arg| given = given.join(try whole(c, flow, function, arg));
            if (given.clean()) return;
            const writes = mutableParams(c, decl);
            for (callee.args.items, 0..) |arg, position| if (writes & bit(position) != 0) try store(c, flow, function, arg, given);
        },
        .aegis => try parsed(c, flow, f.file, call, callee.decl.?),
        // A call that does not resolve may write anything into the memory it is given.
        .none => for (callee.args.items) |arg| {
            if (try pointing(c, f.file, arg)) try store(c, flow, function, arg, .{ .level = .unknown });
        },
        .holder => {},
    }
}

/// `Untrusted.parse(context, parser)` calls the program's `parser(context, value)` with the
/// peer's value: the parser reads input, and its own checks are read as any reader's are. Only
/// what it returns, the refined result, is clean.
fn parsed(c: *Context, flow: *Flow, file: Project.FileId, call: Ast.full.Call, decl: Facts.Decl) Context.Error!void {
    const target = (try parserOf(c, flow, file, call, decl)) orelse return;
    const levels = flow.functions.items[@backingInt(target)].levels;
    if (levels.len < 2 or levels[1].join(.data) == levels[1]) return;
    levels[1] = levels[1].join(.data);
    flow.changed = true;
}

/// The program's function an `Untrusted.parse(context, parser)` call hands its value to.
fn parserOf(c: *Context, flow: *Flow, file: Project.FileId, call: Ast.full.Call, decl: Facts.Decl) Context.Error!?Function.Id {
    const origin = (try c.facts.origin(decl)) orelse decl;
    const record = c.project.at(origin.file).model.declarations[@backingInt(origin.index)];
    if (!std.mem.eql(u8, record.name, "parse") or call.ast.params.len == 0) return null;
    const container: Facts.Value = .{ .container = .{ .file = origin.file, .scope = record.scope } };
    if (try c.role(Contract.library, container) != .untrusted) return null;
    const parser = switch (try c.facts.resolve(file, call.ast.params[call.ast.params.len - 1])) {
        .function => |function| function,
        else => return null,
    };
    return flow.by_node.get(.{ .file = parser.file, .node = fnDecl(c, parser) orelse return null });
}

/// The parameters a function may write through, by position, the receiver first: each one a
/// mutable pointer or slice (`*List`, `[]u8`), or of a type the declaration does not spell
/// (`anytype`). An allocator's `print` takes its receiver by value and writes nothing of it.
fn mutableParams(c: *Context, decl: Facts.Decl) u64 {
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return 0;
    var out: u64 = 0;
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        const kind = param.type_expr orelse {
            out |= bit(position);
            continue;
        };
        var at = kind;
        if (tree.nodeTag(at) == .optional_type) at = tree.nodeData(at).node;
        const pointer = tree.fullPtrType(at) orelse continue;
        if (pointer.const_token == null) out |= bit(position);
    }
    return out;
}

/// The parameters a read writes its bytes into, by position, the receiver first: a mutable
/// byte slice (`[]u8`) or a list of them (`[][]u8`, `[]const []u8`). What else a read is given
/// (a path, an allocator, a limit) it does not fill.
fn bufferParams(c: *Context, decl: Facts.Decl) Context.Error!u64 {
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return 0;
    var out: u64 = 0;
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        const kind = param.type_expr orelse continue;
        const spelled = tree.getNodeSource(kind);
        for ([_][]const u8{ "[]u8", "[][]u8", "[]const []u8" }) |filled| if (std.mem.eql(u8, spelled, filled)) {
            out |= bit(position);
        };
    }
    return out;
}

/// A read fills `arg`'s memory with the fact: each place a store into it reaches, a vector's
/// buffers among them, and a parameter's memory in its callers.
fn fill(c: *Context, flow: *Flow, function: Function.Id, arg: Ast.Node.Index) Context.Error!void {
    try store(c, flow, function, arg, .{ .level = .data });
}

/// The buffers a vector given to a read names: a literal (`&.{ &buf, rest }`), or the literal
/// a local vector was made with (`var vec = [_][]u8{ &buf, rest }; read(&vec)`).
fn vectorOf(c: *Context, file: Project.FileId, buffer: *[2]Ast.Node.Index, arg: Ast.Node.Index) ?[]const Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = arg;
    var named = false;
    while (true) switch (tree.nodeTag(at)) {
        .address_of => at = tree.nodeData(at).node,
        .grouped_expression => at = tree.nodeData(at).node_and_token[0],
        .identifier => {
            if (named) return null;
            named = true;
            const d = (model.reference(at) orelse return null).declaration orelse return null;
            const decl = model.declarations[@backingInt(d)];
            if (decl.kind != .variable) return null;
            const variable = tree.fullVarDecl(decl.node) orelse return null;
            at = variable.ast.init_node.unwrap() orelse return null;
        },
        else => return (tree.fullArrayInit(buffer, at) orelse return null).ast.elements,
    };
}

fn bit(index: usize) u64 {
    return if (index < 64) @as(u64, 1) << @intCast(index) else 0;
}

/// A dependence read as a level, with what callers give the function's parameters.
fn concrete(flow: *const Flow, function: Function.Id, value: Dep) Level {
    var level = value.level;
    const f = flow.functions.items[@backingInt(function)];
    for (f.levels, 0..) |given, index| {
        if (value.params & bit(index) != 0) level = level.join(given);
        if (value.numbers & bit(index) != 0 and given == .data) level = level.join(.number);
        if (value.ranged & bit(index) != 0) level = level.join(if (given == .number) .data else given);
        if (value.maybe & bit(index) != 0 and given != .clean) level = level.join(.unknown);
    }
    return level;
}

/// The level of a dependence's length, with what callers give the function's parameters.
fn concreteLength(flow: *const Flow, function: Function.Id, value: Dep) Level {
    return concrete(flow, function, value.measured());
}

const Callee = struct {
    /// `holder`: a method of an aegis owner or loan (`own.Owned`, `own.OwnedIo`, `own.Lent`).
    kind: union(enum) { program: Function.Id, source, outside, aegis, holder, none },
    /// The arguments in order, the receiver of a method call first.
    args: std.ArrayList(Ast.Node.Index) = .empty,
    receiver: ?Ast.Node.Index = null,
    /// How many parameters precede the first argument (a method's receiver given by the call).
    skip: usize = 0,
    decl: ?Facts.Decl = null,
};

/// What a call reaches: the program's own function, a read, another function outside the
/// program, aegis, or nothing that resolves.
fn resolveCall(c: *Context, flow: *Flow, file: Project.FileId, call: Ast.full.Call) Context.Error!Callee {
    const tree = &c.project.at(file).file.tree;
    var out: Callee = .{ .kind = .none };
    var method = false;
    if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
        const receiver = tree.nodeData(call.ast.fn_expr).node_and_token[0];
        const value = try c.facts.resolve(file, receiver);
        method = switch (value) {
            .instance, .pointer, .optional => true,
            else => false,
        };
        if (method) {
            out.receiver = receiver;
            try out.args.append(c.allocator, receiver);
        }
    }
    try out.args.appendSlice(c.allocator, call.ast.params);
    const value = try c.facts.resolve(file, call.ast.fn_expr);
    const decl = switch (value) {
        .function => |decl| decl,
        else => return out,
    };
    out.decl = decl;
    if (flow.program.aegis_files.contains(@backingInt(decl.file))) {
        // aegis's whole-file reads give a file's bytes, as std's do.
        const origin = (try c.facts.origin(decl)) orelse decl;
        for (flow.reads.items) |read| if (std.meta.eql(read, origin)) {
            out.kind = .source;
            return out;
        };
        // An owner or a loan holds what it is given, no answer to input: a handle the program
        // opened from input is as much input's wrapped as it was bare.
        const container: Facts.Value = .{ .container = .{ .file = origin.file, .scope = c.project.at(origin.file).model.declarations[@backingInt(origin.index)].scope } };
        const role = try c.role(Contract.library, container);
        // What an `input.Untrusted` hands its parser is the peer's value itself: only what the
        // parser makes of it is the answer to input.
        if (role == .untrusted and std.mem.eql(u8, c.project.at(origin.file).model.declarations[@backingInt(origin.index)].name, "readForParse")) {
            out.kind = .source;
            return out;
        }
        out.kind = if (role) |k| switch (k) {
            .owned, .lent => .holder,
            else => .aegis,
        } else .aegis;
        return out;
    }
    const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    // A writer the configuration declares a peer's is one wherever it is declared, the
    // program's own among them: the declaration says where its bytes go, not its body.
    if (flow.fact == .peer) for (flow.peer_writers.items) |writer| if (std.meta.eql(writer, decl)) {
        out.kind = .source;
        return out;
    };
    if (flow.by_node.get(.{ .file = decl.file, .node = fnDecl(c, decl) orelse record.node })) |target| {
        out.kind = .{ .program = target };
        return out;
    }
    // A function of the program the fact does not read (one in a file whose rules read no
    // fact) gives what it does unread: undecided.
    if (flow.own(decl.file)) return out;
    out.kind = if (try source(c, flow, decl, record.name)) .source else .outside;
    return out;
}

/// The `fn_decl` node of a function declaration.
fn fnDecl(c: *Context, decl: Facts.Decl) ?Ast.Node.Index {
    const model = &c.project.at(decl.file).model;
    const tree = &c.project.at(decl.file).file.tree;
    const parent = model.parentOf(model.declarations[@backingInt(decl.index)].node) orelse return null;
    return if (tree.nodeTag(parent) == .fn_decl) parent else null;
}

/// Whether a function outside the program starts the fact: a read of input, or a peer writer.
fn source(c: *Context, flow: *Flow, decl: Facts.Decl, name: []const u8) Context.Error!bool {
    _ = c;
    const file = decl.file;
    switch (flow.fact) {
        .input => {
            for (flow.reads.items) |read| if (std.meta.eql(read, decl)) return true;
            if (flow.reader) |reader| if (reader.file == file) {
                for ([_][]const u8{ "take", "peek", "readSlice", "readVec", "readAlloc", "allocRemaining", "appendExact", "appendRemaining", "buffered" }) |prefix| if (std.mem.startsWith(u8, name, prefix)) return true;
            };
            if (flow.file) |handle| if (handle.file == file) {
                for ([_][]const u8{ "readStreaming", "readPositional", "readPositionalAll" }) |read| if (std.mem.eql(u8, name, read)) return true;
            };
            if (flow.dir) |dir| if (dir.file == file) {
                for ([_][]const u8{ "readFile", "readFileAlloc", "readFileAllocOptions", "readLink" }) |read| if (std.mem.eql(u8, name, read)) return true;
            };
            return false;
        },
        .peer => {
            for (flow.peer_writers.items) |writer| if (std.meta.eql(writer, decl)) return true;
            const stream = flow.stream orelse return false;
            return stream.file == file and std.mem.eql(u8, name, "writer");
        },
    }
}

/// Whether a read is from a reader std's `Reader.fixed` made over clean bytes (`fixedBytes`):
/// such a read carries the bytes' fact, not input's.
fn fixedClean(c: *Context, flow: *Flow, function: Function.Id, call: Ast.full.Call) Context.Error!bool {
    if (flow.fact != .input) return false;
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const bytes = (try fixedBytes(c, flow, f.file, tree.nodeData(call.ast.fn_expr).node_and_token[0])) orelse return false;
    return concrete(flow, function, try dep(c, flow, function, bytes)) == .clean;
}

/// The bytes a reader is made over, where it is a local of a function the fact reads that
/// std's `Io.Reader.fixed` makes, resolved by its declaration (`std.Io.Reader.fixed(bytes)`, or
/// `.fixed(bytes)` into a variable of std's reader type), and nothing in the function writes
/// it after: no assignment to it or a part of it, and no address of it handed on (`&rd`),
/// which would let another name make it the peer's reader.
pub fn fixedBytes(c: *Context, flow: *const Flow, file: Project.FileId, receiver: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const reader = flow.reader orelse return null;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    if (tree.nodeTag(receiver) != .identifier) return null;
    const function = owner(flow, file, receiver) orelse return null;
    const d = (model.reference(receiver) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(d)];
    if (record.kind != .variable or owner(flow, file, record.node) != function) return null;
    const variable = tree.fullVarDecl(record.node) orelse return null;
    const init = variable.ast.init_node.unwrap() orelse return null;
    var buffer: [1]Ast.Node.Index = undefined;
    const made = tree.fullCall(&buffer, init) orelse return null;
    if (made.ast.params.len != 1) return null;
    const fixed = c.facts.member(reader, "fixed") orelse return null;
    const by_std = switch (tree.nodeTag(made.ast.fn_expr)) {
        .enum_literal => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(made.ast.fn_expr)), "fixed") and switch (try c.facts.literalType(file, init)) {
            .container, .instance => |k| k.file == reader.file and k.scope == reader.scope,
            else => false,
        },
        else => switch (try c.facts.resolve(file, made.ast.fn_expr)) {
            .function => |decl| std.meta.eql((try c.facts.origin(decl)) orelse decl, fixed),
            else => false,
        },
    };
    if (!by_std) return null;
    const owners = flow.owners.get(file) orelse return null;
    for (owners, 0..) |own, i| {
        if (own != function) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tree.nodeTag(node)) {
            .assign, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat => {
                if (rootDecl(model, tree, tree.nodeData(node).node_and_node[0]) == d) return null;
            },
            .assign_destructure => for (tree.assignDestructure(node).ast.variables) |each| {
                if (rootDecl(model, tree, each) == d) return null;
            },
            .address_of => {
                if (rootDecl(model, tree, tree.nodeData(node).node) != d) continue;
                // An address discarded (`_ = &rd;`) reaches nothing.
                const parent = model.parentOf(node) orelse return null;
                if (tree.nodeTag(parent) != .assign) return null;
                const target, const value = tree.nodeData(parent).node_and_node;
                if (value != node or tree.nodeTag(target) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_")) return null;
            },
            else => {},
        }
    }
    return made.ast.params[0];
}

/// Whether `value` adds to, multiplies or shifts the local `target` names: an assignment that
/// grows it.
fn accumulates(tree: *const Ast, model: *const Model, target: Ast.Node.Index, value: Ast.Node.Index) bool {
    if (tree.nodeTag(target) != .identifier) return false;
    const declared = (model.reference(target) orelse return false).declaration orelse return false;
    const first = tree.firstToken(value);
    const last = tree.lastToken(value);
    for (tree.nodes.items(.tag), 0..) |tag, i| switch (tag) {
        .mul, .mul_wrap, .mul_sat, .shl, .shl_sat, .add, .add_wrap, .add_sat => {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const token = tree.nodeMainToken(node);
            if (token < first or token > last) continue;
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            for ([_]Ast.Node.Index{ lhs, rhs }) |operand| {
                if (tree.nodeTag(operand) != .identifier) continue;
                const ref = model.reference(operand) orelse continue;
                if (ref.declaration == declared) return true;
            }
        },
        else => {},
    };
    return false;
}

/// Whether a node is a slice's or an array's `.len`.
fn isLen(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .field_access and std.mem.eql(u8, tree.tokenSlice(tree.nodeData(node).node_and_token[1]), "len");
}

/// What an expression holds, read in `function`.
fn dep(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    switch (tree.nodeTag(node)) {
        .identifier => {
            const ref = model.reference(node) orelse return .{};
            const d = ref.declaration orelse return .{};
            if (f.position(d)) |index| return .{ .params = bit(index), .lengths = bit(lengthSlot(index)) };
            const decl = model.declarations[@backingInt(d)];
            if (decl.kind == .variable or decl.kind == .capture) {
                const scope = model.scopes[@backingInt(decl.scope)].kind;
                if (scope == .file or scope == .container) return .{ .level = flow.globals.get(.{ .file = f.file, .index = d }) orelse .clean, .length = flow.lengths.get(.{ .file = f.file, .index = d }) orelse .clean };
                return flow.locals.get(.{ .file = f.file, .index = d }) orelse .{};
            }
            return .{};
        },
        .field_access => {
            const receiver, const name = tree.nodeData(node).node_and_token;
            // An address is no number a peer chooses; a length is one within the memory the
            // program holds: data, which a sink judges against what it reaches.
            if (std.mem.eql(u8, tree.tokenSlice(name), "ptr")) return .{};
            if (std.mem.eql(u8, tree.tokenSlice(name), "len")) {
                const memory = try dep(c, flow, function, receiver);
                return memory.held().narrowed().join(memory.measured());
            }
            var out = try dep(c, flow, function, receiver);
            if (try c.facts.definition(f.file, node)) |decl| {
                if (flow.globals.get(decl)) |level| out = out.join(.{ .level = level });
                if (flow.lengths.get(decl)) |length| out = out.join(.{ .length = length });
                if (try stdIs(c, decl, &zig_text)) out = out.join(.{ .level = .data });
                // A function or a type named through a value is no part of its data.
                const kind = c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind;
                if (kind == .function) return .{};
            } else out = out.join(.{ .level = try alternativeFields(c, flow, f.file, receiver, tree.tokenSlice(name)) });
            return out;
        },
        .array_access => return dep(c, flow, function, tree.nodeData(node).node_and_node[0]),
        // A slice holds what it slices, in a length its bounds set: past its start to its end,
        // or to the end of what it slices.
        .slice_open, .slice, .slice_sentinel => {
            const slice = tree.fullSlice(node) orelse return .{};
            const memory = try dep(c, flow, function, slice.ast.sliced);
            var out = memory.held().join((try dep(c, flow, function, slice.ast.start)).sizing());
            if (slice.ast.end.unwrap()) |end| {
                out = out.join((try dep(c, flow, function, end)).sizing());
            } else out = out.join(.{ .length = memory.length, .lengths = memory.lengths });
            return out;
        },
        .grouped_expression, .unwrap_optional => return dep(c, flow, function, tree.nodeData(node).node_and_token[0]),
        .deref, .address_of, .@"try", .negation, .negation_wrap, .bit_not => return dep(c, flow, function, tree.nodeData(node).node),
        // What is left of a length (`buf.len - at`) is bounded by it; a mask or a remainder by
        // the program's own value is bounded by it, a peer's value within that range: data.
        .sub, .sub_sat => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const out = (try dep(c, flow, function, lhs)).join(try dep(c, flow, function, rhs));
            return if (isLen(tree, lhs)) out.narrowed() else out;
        },
        .bit_and, .mod => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const left = try dep(c, flow, function, lhs);
            const right = try dep(c, flow, function, rhs);
            if (left.clean() or right.clean()) return left.join(right).narrowed();
            return left.join(right);
        },
        // Wrapping arithmetic stays in its type's range, which is the peer's to choose in a wide
        // type: a sink reads it as data only where the result is shown small (a hash shifted to
        // a table's bits).
        .add_wrap, .sub_wrap, .mul_wrap, .add, .div, .shr, .bit_or, .bit_xor, .add_sat, .array_cat, .@"orelse", .@"catch" => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return (try dep(c, flow, function, lhs)).join(try dep(c, flow, function, rhs));
        },
        .mul, .mul_sat => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return (try dep(c, flow, function, lhs)).join(try dep(c, flow, function, rhs));
        },
        // Bytes shifted into place assemble a number; a clean value shifted by data is a mask.
        .shl, .shl_sat => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return (try dep(c, flow, function, lhs)).widened().join(try dep(c, flow, function, rhs));
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => return builtinDep(c, flow, function, node),
        .@"if", .if_simple => {
            const branch = tree.fullIf(node).?;
            // Which branch gives the value is the condition's choice.
            var out = (try dep(c, flow, function, branch.ast.cond_expr)).held().narrowed();
            out = out.join(try dep(c, flow, function, branch.ast.then_expr));
            if (branch.ast.else_expr.unwrap()) |e| out = out.join(try dep(c, flow, function, e));
            return out;
        },
        .@"switch", .switch_comma => {
            var out = (try dep(c, flow, function, tree.fullSwitch(node).?.ast.condition)).held().narrowed();
            for (tree.fullSwitch(node).?.ast.cases) |case| out = out.join(try dep(c, flow, function, (tree.fullSwitchCase(case) orelse continue).ast.target_expr));
            return out;
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => return labeled(c, flow, function, node),
        // A comparison's truth is input's choice where what it compares is: a bool, data.
        .less_than, .less_or_equal, .greater_than, .greater_or_equal, .equal_equal, .bang_equal, .bool_and, .bool_or => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return (try dep(c, flow, function, lhs)).join(try dep(c, flow, function, rhs)).narrowed();
        },
        .bool_not => return (try dep(c, flow, function, tree.nodeData(node).node)).narrowed(),
        else => {},
    }
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, node)) |literal| {
        // A literal of a known type holds its fields' facts by their declarations; a tuple or
        // a literal whose type does not resolve holds what it is given. A parser's result
        // holds its numbers itself: clean through the parse, input through a direct call.
        if (try literalFields(c, f.file, node, literal)) |fields| {
            if (!f.parser or !returned(tree, model, node)) return .{};
            var out: Dep = .{};
            for (literal.ast.fields, fields) |value, field| if (try shownField(c, f.file, value, field)) {
                out = out.join(try dep(c, flow, function, value));
            };
            return out;
        }
        var out: Dep = .{};
        for (literal.ast.fields) |field| out = out.join(try dep(c, flow, function, field));
        return out;
    }
    if (tree.fullArrayInit(&buffer, node)) |literal| {
        var out: Dep = .{};
        for (literal.ast.elements) |element| out = out.join(try dep(c, flow, function, element));
        return out;
    }
    var call_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&call_buffer, node)) |call| return result(c, flow, function, call);
    return composed(c, flow, function, node);
}

/// What a builtin's result holds: nothing for one the program fixes as it compiles (a size, a
/// type, a name), what its operands hold for any other.
fn builtinDep(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!Dep {
    const tree = &c.project.at(flow.functions.items[@backingInt(function)].file).file.tree;
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    for ([_][]const u8{ "@sizeOf", "@alignOf", "@bitSizeOf", "@TypeOf", "@typeInfo", "@errorName", "@tagName", "@typeName", "@import", "@This", "@src", "@hasDecl", "@hasField" }) |clean| if (std.mem.eql(u8, name, clean)) return .{};
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    // A field `@field` names is read by its declaration, as `x.name` is.
    if (std.mem.eql(u8, name, "@field") and args.len == 2) {
        var out = try dep(c, flow, function, args[0]);
        for (try namedFields(c, flow.functions.items[@backingInt(function)].file, node)) |field| {
            out = out.join(.{ .level = flow.globals.get(field) orelse .clean, .length = flow.lengths.get(field) orelse .clean });
        }
        return out;
    }
    var out: Dep = .{};
    var bounded = false;
    for (args) |arg| {
        // A builtin reads its operand whole: `@bitCast` and `@ptrCast` reinterpret its bytes.
        const each = try whole(c, flow, function, arg);
        // The least of a value and a clean bound is held to it.
        if (std.mem.eql(u8, name, "@min") and each.clean()) bounded = true;
        out = out.join(each);
    }
    // A count of bits, a bool's integer and a least under a clean bound stay in a range
    // the program chose: data, which a sink judges against what it reaches. A
    // truncation keeps the bits its type holds, a peer's choice in a wide one: a sink
    // reads it as data only where the type is shown small.
    for ([_][]const u8{ "@intFromBool", "@ctz", "@clz", "@popCount" }) |count| bounded = bounded or std.mem.eql(u8, name, count);
    return if (bounded) out.narrowed() else out;
}

/// What any other expression holds: what its parts hold (`a ** n`, an `asm`'s inputs, a loop's
/// value), but for one the program fixes as it compiles: a type, a declaration, a `comptime`
/// block, a literal.
fn composed(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    switch (tree.nodeTag(node)) {
        .@"comptime", .fn_decl, .fn_proto, .fn_proto_one, .fn_proto_simple, .fn_proto_multi, .test_decl, .ptr_type, .ptr_type_aligned, .ptr_type_bit_range, .ptr_type_sentinel, .array_type, .array_type_sentinel, .optional_type, .error_union, .error_set_decl, .merge_error_sets, .anyframe_type, .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing, .container_decl_arg, .container_decl_arg_trailing, .tagged_union, .tagged_union_trailing, .tagged_union_two, .tagged_union_two_trailing, .tagged_union_enum_tag, .tagged_union_enum_tag_trailing => return .{},
        else => {},
    }
    var out: Dep = .{};
    for (try children(c, f.file, node)) |part| out = out.join(try dep(c, flow, function, part));
    return out;
}

/// A field read through a value whose type is one of several (a generic's result over each
/// of its instantiations, `Untrusted.parse` over each parser): what the program stores in the
/// field of that name in each of them.
fn alternativeFields(c: *Context, flow: *Flow, file: Project.FileId, receiver: Ast.Node.Index, name: []const u8) Context.Error!Level {
    var out: Level = .clean;
    const value = try c.facts.resolve(file, receiver);
    for (if (value == .alternatives) value.alternatives else &.{value}) |each| {
        var held = each;
        while (true) held = switch (held) {
            .pointer, .optional, .error_union => |inner| inner.*,
            else => break,
        };
        const container = switch (held) {
            .container, .instance => |k| k,
            else => continue,
        };
        const decl = c.facts.member(container, name) orelse continue;
        if (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind != .field) continue;
        out = out.join(flow.globals.get(decl) orelse .clean);
    }
    return out;
}

/// The field declarations a struct literal's values initialize, in order, when its type
/// resolves and names each of them.
fn literalFields(c: *Context, file: Project.FileId, node: Ast.Node.Index, literal: Ast.full.StructInit) Context.Error!?[]const Facts.Decl {
    if (literal.ast.fields.len == 0) return null;
    var holder = try c.facts.literalType(file, node);
    while (true) holder = switch (holder) {
        .optional, .error_union, .pointer => |inner| inner.*,
        else => break,
    };
    const container = switch (holder) {
        .container, .instance => |k| k,
        else => return null,
    };
    const tree = &c.project.at(file).file.tree;
    const fields = try c.allocator.alloc(Facts.Decl, literal.ast.fields.len);
    for (literal.ast.fields, fields) |value, *field| {
        const name = try Model.identifier(c.allocator, tree.tokenSlice(Model.initName(tree, value) orelse return null));
        const decl = c.facts.member(container, name) orelse return null;
        if (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind != .field) return null;
        field.* = decl;
    }
    return fields;
}

/// Whether a literal is what its function returns: a `return`'s operand, or an arm of an `if`
/// or a `switch` that is.
fn returned(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            .@"return" => return true,
            .grouped_expression => {},
            .@"if", .if_simple => {
                const branch = tree.fullIf(parent).?;
                if (at != branch.ast.then_expr and at.toOptional() != branch.ast.else_expr) return false;
            },
            .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => if (at != tree.fullSwitchCase(parent).?.ast.target_expr) return false,
            .@"switch", .switch_comma => if (at == tree.fullSwitch(parent).?.ast.condition) return false,
            else => return false,
        }
    }
    return false;
}

/// Whether a parser's result field holds a value it showed the range of: a number or a `bool`
/// by its declared type, no memory a peer's bytes could stand behind, given a value narrower
/// than that type (`Range.shown`).
fn shownField(c: *Context, file: Project.FileId, value: Ast.Node.Index, decl: Facts.Decl) Context.Error!bool {
    const tree = &c.project.at(decl.file).file.tree;
    const field = tree.fullContainerField(c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return false;
    const declared = field.ast.type_expr.unwrap() orelse return false;
    if (tree.nodeTag(declared) != .identifier or !Model.primitive(tree.tokenSlice(tree.nodeMainToken(declared)))) return false;
    return Range.shown(c, file, value, decl.file, declared);
}

/// A parser's return of a number it shows no range of, other than in a literal of its result
/// type (whose fields are read one by one): what a parse given it gives is that number's
/// input.
fn unrefined(c: *Context, flow: *Flow, function: Function.Id, value: Ast.Node.Index) Context.Error!void {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    // Each arm a branch returns is read as returned.
    if (tree.fullIf(value)) |branch| {
        try unrefined(c, flow, function, branch.ast.then_expr);
        if (branch.ast.else_expr.unwrap()) |otherwise| try unrefined(c, flow, function, otherwise);
        return;
    }
    if (tree.fullSwitch(value)) |choice| {
        for (choice.ast.cases) |case| try unrefined(c, flow, function, tree.fullSwitchCase(case).?.ast.target_expr);
        return;
    }
    if (tree.nodeTag(value) == .grouped_expression) return unrefined(c, flow, function, tree.nodeData(value).node_and_token[0]);
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, value)) |literal| if (try literalFields(c, f.file, value, literal) != null) return;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buffer, tree.nodeData(f.node).node_and_node[0]) orelse return;
    var payload = proto.ast.return_type.unwrap() orelse return;
    if (tree.nodeTag(payload) == .error_union) payload = tree.nodeData(payload).node_and_node[1];
    // A tuple's numbers are read one by one, each against its field's type; a tuple the parser
    // holds in a value of its own gives every number it holds.
    var container_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_buffer, payload)) |container| {
        var elements_buffer: [2]Ast.Node.Index = undefined;
        const elements: ?[]const Ast.Node.Index = if (tree.fullArrayInit(&elements_buffer, value)) |literal| literal.ast.elements else null;
        var position: usize = 0;
        for (container.ast.members) |member| {
            const field = tree.fullContainerField(member) orelse continue;
            if (!field.ast.tuple_like) continue;
            defer position += 1;
            const declared = field.ast.type_expr.unwrap() orelse continue;
            if (!try Range.integral(c, f.file, declared)) continue;
            const given = if (elements) |each| (if (position < each.len) each[position] else continue) else value;
            try unrefinedBy(c, flow, function, given, elements != null and try Range.shown(c, f.file, given, f.file, declared));
        }
        return;
    }
    // A result that is no number (a checked path, a name, a list) is the parser's refinement.
    if (!try Range.integral(c, f.file, payload)) return;
    try unrefinedBy(c, flow, function, value, try Range.shown(c, f.file, value, f.file, payload));
}

/// A parser's result holds `value`'s input as given: a number whose range it shows (`shown`)
/// as data held to that range.
fn unrefinedBy(c: *Context, flow: *Flow, function: Function.Id, value: Ast.Node.Index, shown: bool) Context.Error!void {
    var level = concrete(flow, function, try dep(c, flow, function, value));
    if (shown and level == .number) level = .data;
    const now = flow.functions.items[@backingInt(function)].unrefined.join(level);
    if (now != flow.functions.items[@backingInt(function)].unrefined) {
        flow.functions.items[@backingInt(function)].unrefined = now;
        flow.changed = true;
    }
}

/// A labeled block's value: what its `break`s give it.
fn labeled(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const lbrace = tree.nodeMainToken(node);
    if (lbrace < 2 or tree.tokenTag(lbrace - 1) != .colon) return .{};
    const label = tree.tokenSlice(lbrace - 2);
    var out: Dep = .{};
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"break") continue;
        const brk: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(brk);
        if (token < first or token > last) continue;
        const target, const value = tree.nodeData(brk).opt_token_and_opt_node;
        const named = target.unwrap() orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(named), label)) continue;
        if (value.unwrap()) |v| out = out.join(try dep(c, flow, function, v));
        // Which `break` runs is the conditions' choice.
        out = out.join(try controlWithin(c, flow, function, brk, node));
    }
    return out;
}

/// A summary of the program's callee (what it returns, or what it stores through a parameter),
/// read at a call with its arguments: an argument's value in its slot, and its length in the
/// length's, each as the summary holds it, as a value or as a length. Past 32 parameters the
/// two slots are one, which holds both.
fn summarized(c: *Context, flow: *Flow, function: Function.Id, callee: Callee, summary: Dep) Context.Error!Dep {
    var out: Dep = .{ .level = summary.level, .length = summary.length };
    for (callee.args.items, 0..) |arg, position| {
        const index = position + callee.skip;
        const given = try dep(c, flow, function, arg);
        for ([_]struct { usize, Dep }{ .{ index, given }, .{ lengthSlot(index), given.measured() } }) |each| {
            const slot, const held_there = each;
            const there = bit(slot);
            if (summary.params & there != 0) out = out.join(held_there);
            if (summary.numbers & there != 0) out = out.join(held_there.widened());
            if (summary.ranged & there != 0) out = out.join(held_there.narrowed());
            if (summary.maybe & there != 0) out = out.join(held_there.lowered());
            if (summary.lengths & there != 0) out = out.join(held_there.sizing());
        }
    }
    return out;
}

/// What a function outside the program may make of an argument: what it holds, and its length,
/// which a search's position or a count is within (`std.mem.indexOfScalar(u8, buf[0..n], 0)`).
fn outsideArg(c: *Context, flow: *Flow, function: Function.Id, arg: Ast.Node.Index) Context.Error!Dep {
    const value = try whole(c, flow, function, arg);
    return value.join(value.measured());
}

/// A call's result: the program's callee's summary read with these arguments, a read's input,
/// what a function outside the program makes of what it is given, aegis's answer clean, and
/// unknown from a callee that does not resolve.
fn result(c: *Context, flow: *Flow, function: Function.Id, call: Ast.full.Call) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const callee = try resolveCall(c, flow, f.file, call);
    switch (callee.kind) {
        // A parse gives what its parser returns refined, but for the values it showed no range
        // of. aegis's other functions give what they are given: a conversion (`int.cast`), a
        // checked sum or an id's `raw` holds the peer's choice as much as its operand did,
        // though the checks the conversion makes are aegis's.
        .aegis => {
            if (try parserOf(c, flow, f.file, call, callee.decl.?)) |target| return .{ .level = flow.functions.items[@backingInt(target)].unrefined };
            var out: Dep = .{};
            for (callee.args.items) |arg| out = out.join(try outsideArg(c, flow, function, arg));
            return out;
        },
        // What it holds: `init`'s value, the receiver of `lend`, `get`, `borrow` and `move`.
        .holder => {
            var out: Dep = .{};
            for (callee.args.items) |arg| out = out.join(try dep(c, flow, function, arg));
            return out;
        },
        .program => |target| {
            return summarized(c, flow, function, callee, flow.functions.items[@backingInt(target)].ret);
        },
        .source => {
            if (try fixedClean(c, flow, function, call)) return .{};
            const decl = callee.decl.?;
            // A read into the caller's buffer returns how much it read: a count the buffer
            // bounds, a peer's within it.
            if (try bufferParams(c, decl) != 0 and returnsCount(c, decl)) return .{ .level = .data };
            if (flow.fact == .input and decodes(c, decl)) return .{ .level = if (narrow(c, f.file, call)) .data else .number };
            return .{ .level = .data };
        },
        .outside => {
            // What std's file and directory handles answer that is no read of a file's contents
            // (a `stat`, the names an iteration gives, a handle they open) is the operating
            // system's, never a peer's: a handle a peer's path opened holds the path's fact, not
            // what the system says of it.
            if (callee.decl) |decl| if (callee.receiver != null and systemAnswer(c, flow, decl)) return .{};
            if (callee.decl) |decl| {
                // std's Zig parser, called by a parser the program hands to input.Untrusted.parse,
                // is that parse's check: each node, token and extra index of the tree it gives
                // indexes the tree's own tables. The text the tree carries stays input.
                if (f.parser and try stdIs(c, decl, &.{"zig.Ast.parse"})) return .{};
                if (try stdIs(c, decl, &zig_text)) return .{ .level = .data };
            }
            // A function outside the program gives what it is given, its receiver among it.
            var out: Dep = .{};
            for (callee.args.items) |arg| out = out.join(try outsideArg(c, flow, function, arg));
            const decl = callee.decl orelse return out;
            if (!flow.program.std_files.contains(@backingInt(decl.file))) return out;
            // A std function that answers a `usize` (a container's `count`, a position it finds
            // in data) answers a count of memory the program holds: a peer's within it.
            if (returnsCount(c, decl)) return out.narrowed();
            // A std function outside its data namespaces (`mem`, `fmt`, `ascii`, `unicode`,
            // `math`, `base64`), or one of them that decodes an integer, may make any number of
            // what it is given (`std.json` parsing a struct, a hash of the bytes). A decode of 16
            // bits or fewer stays in their range.
            if (callee.receiver == null and (!flow.data_files.contains(@backingInt(decl.file)) or decodes(c, decl))) return if (narrow(c, f.file, call)) out else out.widened();
            // A value clamped between the program's own bounds is held to them.
            if (std.mem.eql(u8, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].name, "clamp") and call.ast.params.len == 3) {
                if ((try dep(c, flow, function, call.ast.params[1])).clean() and (try dep(c, flow, function, call.ast.params[2])).clean()) return out.narrowed();
            }
            return out;
        },
        .none => {
            var out: Dep = .{};
            for (callee.args.items) |arg| out = out.join(try outsideArg(c, flow, function, arg));
            return out.lowered();
        },
    }
}

/// Whether a function's result is a count or a position: its declared result is `usize`, or
/// an optional or error union of one.
fn returnsCount(c: *Context, decl: Facts.Decl) bool {
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return false;
    const result_type = proto.ast.return_type.unwrap() orelse return false;
    return std.mem.endsWith(u8, tree.getNodeSource(result_type), "usize");
}

/// Whether a decode's spelled type (its first argument, `readInt(u16, ...)`) is at most 16 bits
/// wide: what it gives stays in a range no wider sum or product of it overflows.
fn narrow(c: *Context, file: Project.FileId, call: Ast.full.Call) bool {
    if (call.ast.params.len == 0) return false;
    const tree = &c.project.at(file).file.tree;
    const spelled = tree.getNodeSource(call.ast.params[0]);
    if (spelled.len < 2 or (spelled[0] != 'u' and spelled[0] != 'i')) return false;
    const bits = std.fmt.parseUnsigned(u16, spelled[1..], 10) catch return false;
    return bits <= 16;
}

/// Whether a std function decodes an integer from bytes or text: `readInt` and its forms,
/// `parseInt`, `parseUnsigned`, a reader's `takeInt`, `peekInt`, `takeVarInt`, `takeLeb128`,
/// `takeEnum`.
fn decodes(c: *Context, decl: Facts.Decl) bool {
    const name = c.project.at(decl.file).model.declarations[@backingInt(decl.index)].name;
    for ([_][]const u8{ "readInt", "readVarInt", "readPackedInt", "parseInt", "parseUnsigned", "takeInt", "peekInt", "takeVarInt", "takeLeb128", "takeEnum" }) |decoder| {
        if (std.mem.startsWith(u8, name, decoder)) return true;
    }
    return false;
}

/// The level of `node` in its file as the solved fact reads it, or clean outside the functions
/// it reads.
pub fn levelAt(c: *Context, flow: *Flow, file: Project.FileId, node: Ast.Node.Index) Context.Error!Level {
    const function = owner(flow, file, node) orelse return .clean;
    return concrete(flow, function, try dep(c, flow, function, node));
}

/// The level of a counter `loop` steps, as it decides how many passes the loop takes: what it
/// holds on entry (each assignment outside the loop, under its own conditions) and what each
/// pass steps it by. Whether a pass steps it is the loop's to decide, which its bound answers.
/// Null where `operand` names no local the loop assigns.
pub fn counterLevel(c: *Context, flow: *Flow, file: Project.FileId, loop: Ast.Node.Index, operand: Ast.Node.Index) Context.Error!?Level {
    const function = owner(flow, file, operand) orelse return null;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    if (tree.nodeTag(operand) != .identifier) return null;
    const d = (model.reference(operand) orelse return null).declaration orelse return null;
    const decl = model.declarations[@backingInt(d)];
    if (decl.kind != .variable) return null;
    switch (model.scopes[@backingInt(decl.scope)].kind) {
        .file, .container => return null,
        else => {},
    }
    const first = tree.firstToken(loop);
    const last = tree.lastToken(loop);
    var out: Dep = .{};
    var stepped = false;
    if (tree.fullVarDecl(decl.node)) |variable| if (variable.ast.init_node.unwrap()) |init| {
        out = out.join(try dep(c, flow, function, init)).join(try control(c, flow, function, decl.node, null));
    };
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .assign, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const target, const value = tree.nodeData(node).node_and_node;
        if (tree.nodeTag(target) != .identifier) continue;
        const ref = model.reference(target) orelse continue;
        if (ref.declaration != d) continue;
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) {
            out = out.join(try dep(c, flow, function, value)).join(try control(c, flow, function, node, target));
            continue;
        }
        stepped = true;
        out = out.join(try dep(c, flow, function, stepOf(tree, model, d, tag, value)));
    }
    if (!stepped) return null;
    return concrete(flow, function, out);
}

/// What an assignment in a loop steps a counter by: a compound assignment's operand, the other
/// side of a sum or a difference with the counter itself (`i = i + 2`), or else all it assigns.
fn stepOf(tree: *const Ast, model: *const Model, counter: Model.Declaration.Id, tag: Ast.Node.Tag, value: Ast.Node.Index) Ast.Node.Index {
    if (tag != .assign) return value;
    switch (tree.nodeTag(value)) {
        .add, .add_wrap, .add_sat, .sub, .sub_wrap, .sub_sat => {
            const lhs, const rhs = tree.nodeData(value).node_and_node;
            if (namesDeclaration(tree, model, lhs, counter)) return rhs;
            const sum = switch (tree.nodeTag(value)) {
                .add, .add_wrap, .add_sat => true,
                else => false,
            };
            if (sum and namesDeclaration(tree, model, rhs, counter)) return lhs;
        },
        else => {},
    }
    return value;
}

fn namesDeclaration(tree: *const Ast, model: *const Model, node: Ast.Node.Index, d: Model.Declaration.Id) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    const ref = model.reference(node) orelse return false;
    return ref.declaration == d;
}

/// The program's call or the function outside it that a call reaches, for a sink reading its
/// arguments by the callee's parameters.
pub const Reached = struct { decl: ?Facts.Decl, args: []const Ast.Node.Index, skip: usize, std: bool, method: bool };
pub fn reached(c: *Context, flow: *Flow, file: Project.FileId, call: Ast.full.Call) Context.Error!Reached {
    const callee = try resolveCall(c, flow, file, call);
    const decl = callee.decl;
    const in_std = if (decl) |d| flow.program.std_files.contains(@backingInt(d.file)) else false;
    return .{ .decl = decl, .args = callee.args.items, .skip = callee.skip, .std = in_std, .method = callee.receiver != null };
}

/// The level of what a condition reads: its comparisons' and its logic's operands, each as
/// the fact reads it (a comparison's own result is clean; what it compares is not).
pub fn conditionAt(c: *Context, flow: *Flow, file: Project.FileId, node: Ast.Node.Index) Context.Error!Level {
    const tree = &c.project.at(file).file.tree;
    switch (tree.nodeTag(node)) {
        .less_than, .less_or_equal, .greater_than, .greater_or_equal, .equal_equal, .bang_equal, .bool_and, .bool_or => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return (try conditionAt(c, flow, file, lhs)).join(try conditionAt(c, flow, file, rhs));
        },
        .bool_not, .grouped_expression => return conditionAt(c, flow, file, if (tree.nodeTag(node) == .bool_not) tree.nodeData(node).node else tree.nodeData(node).node_and_token[0]),
        else => return levelAt(c, flow, file, node),
    }
}

/// Whether a call reads input: a read the fact starts at.
pub fn isRead(c: *Context, flow: *Flow, file: Project.FileId, call: Ast.full.Call) Context.Error!bool {
    return (try resolveCall(c, flow, file, call)).kind == .source;
}

/// Whether a function is declared in std's `Io.File` or `Io.Dir`, or a container inside one
/// (`Dir.Iterator`): one that reads contents is a source, found before this.
fn systemAnswer(c: *Context, flow: *const Flow, decl: Facts.Decl) bool {
    const model = &c.project.at(decl.file).model;
    for ([_]?Facts.Container{ flow.file, flow.dir }) |each| {
        const handle = each orelse continue;
        if (handle.file != decl.file) continue;
        var scope: ?Model.Scope.Id = model.declarations[@backingInt(decl.index)].scope;
        while (scope) |s| : (scope = model.scopes[@backingInt(s)].parent) if (s == handle.scope) return true;
    }
    return false;
}

/// What std's Zig tree and its lowering give of the file's text: a peer's bytes, wherever the
/// tree's structure is the parse's.
const zig_text = [_][]const u8{ "zig.Ast.source", "zig.Ast.tokenSlice", "zig.Ast.getNodeSource", "zig.Zir.string_bytes", "zig.Zir.nullTerminatedString" };

/// Whether `decl` is std's declaration at one of `paths`.
fn stdIs(c: *Context, decl: Facts.Decl, paths: []const []const u8) Context.Error!bool {
    for (paths) |path| for ((try Governed.declarations(c, "std", path)) orelse &.{}) |each| {
        if (std.meta.eql(each, decl)) return true;
    };
    return false;
}

/// Whether a function outside the program is one of std's.
pub fn inStd(flow: *const Flow, decl: Facts.Decl) bool {
    return flow.program.std_files.contains(decl.file.raw());
}

/// The container a fact recognizes std's reader, file, directory and stream by.
pub fn readerType(flow: *const Flow) ?Facts.Container {
    return flow.reader;
}
pub fn directoryType(flow: *const Flow) ?Facts.Container {
    return flow.dir;
}

/// Where input that reaches a node was read: a read call the program makes, and, where the read
/// is inside a function the walk entered through its result, the call of that function (`via`):
/// the caller of a file reader the program wraps, where that caller's parser belongs.
pub const Origin = struct { file: Project.FileId, node: Ast.Node.Index, via: ?Site = null };
pub const Site = struct { file: Project.FileId, node: Ast.Node.Index };

/// The read that input reaching `node` comes from, found by walking back from it: through the
/// parts of its expression that carry input, a local's initializer, its assignments and the
/// reads that fill it, the program's callees' returns and the arguments a parameter's callers
/// give it. The first read found, or null where the walk ends without one (a field the program
/// stores elsewhere, a walk too long). Read only to name a finding's source.
pub fn sourceOf(c: *Context, flow: *Flow, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Origin {
    const function = owner(flow, file, node) orelse return null;
    var walk: Walk = .{ .c = c, .flow = flow };
    return walk.from(function, node, 0);
}

const Walk = struct {
    c: *Context,
    flow: *Flow,
    seen: std.AutoHashMapUnmanaged(struct { Function.Id, Ast.Node.Index }, void) = .empty,
    steps: u32 = 0,

    const step_limit = 4000;

    fn carries(w: *Walk, function: Function.Id, node: Ast.Node.Index) Context.Error!bool {
        return concrete(w.flow, function, try dep(w.c, w.flow, function, node)) != .clean;
    }

    fn from(w: *Walk, function: Function.Id, node: Ast.Node.Index, depth: u8) Context.Error!?Origin {
        if (depth > 48 or w.steps >= step_limit) return null;
        w.steps += 1;
        if ((try w.seen.getOrPut(w.c.allocator, .{ function, node })).found_existing) return null;
        const f = w.flow.functions.items[@backingInt(function)];
        const tree = &w.c.project.at(f.file).file.tree;
        const model = &w.c.project.at(f.file).model;
        var call_buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&call_buffer, node)) |made| return w.throughCall(function, node, made, depth);
        if (tree.nodeTag(node) == .identifier) {
            const ref = model.reference(node) orelse return null;
            const d = ref.declaration orelse return null;
            if (f.position(d)) |index| return w.callers(function, index, depth);
            const decl = model.declarations[@backingInt(d)];
            const scope = model.scopes[@backingInt(decl.scope)].kind;
            if (scope == .file or scope == .container) return w.stored(.{ .file = f.file, .index = d }, depth);
            return w.local(function, d, depth);
        }
        // A field holds what the program stores in it anywhere, by its declaration.
        if (tree.nodeTag(node) == .field_access) if (try w.c.facts.definition(f.file, node)) |decl| {
            if ((w.flow.globals.get(decl) orelse .clean) != .clean) if (try w.stored(decl, depth)) |found| return found;
        };
        for (try children(w.c, f.file, node)) |child| {
            if (!try w.carries(function, child)) continue;
            if (try w.from(function, child, depth + 1)) |found| return found;
        }
        return null;
    }

    fn throughCall(w: *Walk, function: Function.Id, node: Ast.Node.Index, at: Ast.full.Call, depth: u8) Context.Error!?Origin {
        const f = w.flow.functions.items[@backingInt(function)];
        const callee = try resolveCall(w.c, w.flow, f.file, at);
        switch (callee.kind) {
            .source => return .{ .file = f.file, .node = node },
            .aegis => if (try parserOf(w.c, w.flow, f.file, at, callee.decl.?) != null) return null,
            .program => |target| {
                const g = w.flow.functions.items[@backingInt(target)];
                const tree = &w.c.project.at(g.file).file.tree;
                for (try children(w.c, g.file, g.node)) |part| if (try w.returned(target, tree, part, depth)) |found| {
                    // The innermost call into the function that holds the read names it.
                    var named = found;
                    if (named.via == null) named.via = .{ .file = f.file, .node = node };
                    return named;
                };
            },
            .holder, .outside, .none => {},
        }
        for (callee.args.items) |arg| {
            if (!try w.carries(function, arg)) continue;
            if (try w.from(function, arg, depth + 1)) |found| return found;
        }
        return null;
    }

    /// The `return`s within `node` of `function`'s own body, walked back.
    fn returned(w: *Walk, function: Function.Id, tree: *const Ast, node: Ast.Node.Index, depth: u8) Context.Error!?Origin {
        if (w.steps >= step_limit) return null;
        w.steps += 1;
        if (tree.nodeTag(node) == .fn_decl or tree.nodeTag(node) == .fn_proto or tree.nodeTag(node) == .fn_proto_one or tree.nodeTag(node) == .fn_proto_simple or tree.nodeTag(node) == .fn_proto_multi) return null;
        if (tree.nodeTag(node) == .@"return") {
            const value = tree.nodeData(node).opt_node.unwrap() orelse return null;
            if (!try w.carries(function, value)) return null;
            return w.from(function, value, depth + 1);
        }
        const g = w.flow.functions.items[@backingInt(function)];
        for (try children(w.c, g.file, node)) |part| if (try w.returned(function, tree, part, depth)) |found| return found;
        return null;
    }

    /// A local's initializer, what is assigned to it and the reads that fill it.
    fn local(w: *Walk, function: Function.Id, d: Model.Declaration.Id, depth: u8) Context.Error!?Origin {
        const f = w.flow.functions.items[@backingInt(function)];
        const tree = &w.c.project.at(f.file).file.tree;
        const model = &w.c.project.at(f.file).model;
        const decl = model.declarations[@backingInt(d)];
        const scope = model.scopes[@backingInt(decl.scope)].kind;
        if (scope == .file or scope == .container) return null;
        if (try w.from(function, decl.node, depth + 1)) |found| return found;
        const owners = w.flow.owners.get(f.file) orelse return null;
        for (owners, 0..) |own, i| {
            if (own != function) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (tree.nodeTag(node) == .assign) {
                const target, const value = tree.nodeData(node).node_and_node;
                if (rootDecl(model, tree, target) != d or !try w.carries(function, value)) continue;
                if (try w.from(function, value, depth + 1)) |found| return found;
                continue;
            }
            var buffer: [1]Ast.Node.Index = undefined;
            const made = tree.fullCall(&buffer, node) orelse continue;
            for (made.ast.params) |arg| if (rootDecl(model, tree, arg) == d) {
                const callee = try resolveCall(w.c, w.flow, f.file, made);
                if (callee.kind == .source) return .{ .file = f.file, .node = node };
            };
        }
        return null;
    }

    /// What the program stores in a field or a container-level variable: a value assigned or
    /// given in a literal, or a read that fills it.
    fn stored(w: *Walk, decl: Facts.Decl, depth: u8) Context.Error!?Origin {
        const stores = try storeSites(w.c, w.flow);
        for ((stores.map.get(decl) orelse return null).items) |site| {
            const f = w.flow.functions.items[@backingInt(site.function)];
            if (site.read) return .{ .file = f.file, .node = site.node };
            if (!try w.carries(site.function, site.node)) continue;
            if (try w.from(site.function, site.node, depth + 1)) |found| return found;
        }
        return null;
    }

    /// What the program's callers of `function` give its parameter `index`.
    fn callers(w: *Walk, function: Function.Id, index: usize, depth: u8) Context.Error!?Origin {
        const sites = try callSites(w.c, w.flow);
        for ((sites.map.get(function) orelse return null).items) |site| {
            const f = w.flow.functions.items[@backingInt(site.caller)];
            const tree = &w.c.project.at(f.file).file.tree;
            var buffer: [1]Ast.Node.Index = undefined;
            const made = tree.fullCall(&buffer, site.node) orelse continue;
            const callee = try resolveCall(w.c, w.flow, f.file, made);
            if (index < callee.skip) continue;
            const position = index - callee.skip;
            if (position >= callee.args.items.len) continue;
            const arg = callee.args.items[position];
            if (!try w.carries(site.caller, arg)) continue;
            if (try w.from(site.caller, arg, depth + 1)) |found| return found;
        }
        return null;
    }
};

/// The declaration an expression is rooted at: `x`, `x.field`, `x[i]`, `&x`, `x[a..b]`.
fn rootDecl(model: *const Model, tree: *const Ast, node: Ast.Node.Index) ?Model.Declaration.Id {
    var at = node;
    while (true) switch (tree.nodeTag(at)) {
        .identifier => return (model.reference(at) orelse return null).declaration,
        .field_access, .unwrap_optional, .grouped_expression => at = tree.nodeData(at).node_and_token[0],
        .array_access => at = tree.nodeData(at).node_and_node[0],
        .address_of, .deref => at = tree.nodeData(at).node,
        .slice_open, .slice, .slice_sentinel => at = (tree.fullSlice(at) orelse return null).ast.sliced,
        else => return null,
    };
}

/// Each node's children, by file, built once from the parent table.
const Children = struct { map: std.AutoHashMapUnmanaged(Project.FileId, []const []const Ast.Node.Index) = .empty };

fn children(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error![]const Ast.Node.Index {
    const memo = try c.facts.memo(Children);
    const all = memo.map.get(file) orelse blk: {
        const model = &c.project.at(file).model;
        const lists = try c.allocator.alloc(std.ArrayList(Ast.Node.Index), model.node_parents.len);
        @memset(lists, .empty);
        for (model.node_parents, 0..) |parent, i| if (parent) |p| try lists[@backingInt(p)].append(c.allocator, @fromBackingInt(@intCast(i)));
        const out = try c.allocator.alloc([]const Ast.Node.Index, lists.len);
        for (lists, out) |list, *each| each.* = list.items;
        try memo.map.put(c.allocator, file, out);
        break :blk out;
    };
    const index = @backingInt(node);
    return if (index < all.len) all[index] else &.{};
}

/// The program's calls of each of its functions, by callee, built once per flow.
const CallSites = struct {
    built: bool = false,
    map: std.AutoHashMapUnmanaged(Function.Id, std.ArrayList(struct { caller: Function.Id, node: Ast.Node.Index })) = .empty,
};

fn callSites(c: *Context, flow: *Flow) Context.Error!*CallSites {
    const memo = try c.facts.memo(CallSites);
    if (memo.built) return memo;
    memo.built = true;
    var files = flow.owners.iterator();
    while (files.next()) |entry| {
        const file = entry.key_ptr.*;
        const tree = &c.project.at(file).file.tree;
        for (entry.value_ptr.*, 0..) |own, i| {
            const caller = own orelse continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            var buffer: [1]Ast.Node.Index = undefined;
            const made = tree.fullCall(&buffer, node) orelse continue;
            const callee = try resolveCall(c, flow, file, made);
            const target = switch (callee.kind) {
                .program => |t| t,
                else => continue,
            };
            const list = try memo.map.getOrPut(c.allocator, target);
            if (!list.found_existing) list.value_ptr.* = .empty;
            try list.value_ptr.append(c.allocator, .{ .caller = caller, .node = node });
        }
    }
    return memo;
}

/// Where the program stores into each field and container-level variable, by declaration: the
/// value it assigns or gives in a literal, or the read that fills it. Built once per flow.
const StoreSites = struct {
    built: bool = false,
    map: std.AutoHashMapUnmanaged(Facts.Decl, std.ArrayList(StoreSite)) = .empty,
};
const StoreSite = struct { function: Function.Id, node: Ast.Node.Index, read: bool };

fn storeSites(c: *Context, flow: *Flow) Context.Error!*StoreSites {
    const memo = try c.facts.memo(StoreSites);
    if (memo.built) return memo;
    memo.built = true;
    var files = flow.owners.iterator();
    while (files.next()) |entry| {
        const file = entry.key_ptr.*;
        const tree = &c.project.at(file).file.tree;
        for (entry.value_ptr.*, 0..) |own, i| {
            const function = own orelse continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (tree.nodeTag(node) == .assign) {
                const target, const value = tree.nodeData(node).node_and_node;
                const decl = (try storedDecl(c, file, target)) orelse continue;
                try addStore(c, memo, decl, .{ .function = function, .node = value, .read = false });
                continue;
            }
            var buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullStructInit(&buffer, node)) |literal| {
                const fields = (try literalFields(c, file, node, literal)) orelse continue;
                for (fields, literal.ast.fields) |decl, value| try addStore(c, memo, decl, .{ .function = function, .node = value, .read = false });
                continue;
            }
            var call_buffer: [1]Ast.Node.Index = undefined;
            const made = tree.fullCall(&call_buffer, node) orelse continue;
            if ((try resolveCall(c, flow, file, made)).kind != .source) continue;
            for (made.ast.params) |arg| {
                var vector_buffer: [2]Ast.Node.Index = undefined;
                const elements = vectorOf(c, file, &vector_buffer, arg) orelse &.{};
                for (elements) |element| if (try storedDecl(c, file, element)) |decl| try addStore(c, memo, decl, .{ .function = function, .node = node, .read = true });
                if (try storedDecl(c, file, arg)) |decl| try addStore(c, memo, decl, .{ .function = function, .node = node, .read = true });
            }
        }
    }
    return memo;
}

fn addStore(c: *Context, memo: *StoreSites, decl: Facts.Decl, site: StoreSite) Context.Error!void {
    const list = try memo.map.getOrPut(c.allocator, decl);
    if (!list.found_existing) list.value_ptr.* = .empty;
    try list.value_ptr.append(c.allocator, site);
}

/// The field or container-level variable an expression stores into: `x.field`, `x.field[i]`,
/// `&x.field`, `global`.
fn storedDecl(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Facts.Decl {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = node;
    while (true) switch (tree.nodeTag(at)) {
        .field_access => {
            const decl = (try c.facts.definition(file, at)) orelse return null;
            const kind = c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind;
            return if (kind == .field or kind == .variable) decl else null;
        },
        .identifier => {
            const d = (model.reference(at) orelse return null).declaration orelse return null;
            const decl = model.declarations[@backingInt(d)];
            const scope = model.scopes[@backingInt(decl.scope)].kind;
            return if (decl.kind == .variable and (scope == .file or scope == .container)) .{ .file = file, .index = d } else null;
        },
        .array_access => at = tree.nodeData(at).node_and_node[0],
        .address_of, .deref => at = tree.nodeData(at).node,
        .slice_open, .slice, .slice_sentinel => at = (tree.fullSlice(at) orelse return null).ast.sliced,
        else => return null,
    };
}

/// The union fields a `switch` prong's capture binds: the one each tag it names declares, or
/// every field of the union for `else` or a value that is no tag.
fn prongFields(c: *Context, file: Project.FileId, operand: Ast.Node.Index, case_node: Ast.Node.Index) Context.Error![]const Facts.Decl {
    const tree = &c.project.at(file).file.tree;
    var held_value = try c.facts.resolve(file, operand);
    while (true) held_value = switch (held_value) {
        .pointer, .optional => |inner| inner.*,
        else => break,
    };
    const container = switch (held_value) {
        .instance, .container => |k| k,
        else => return &.{},
    };
    const case = tree.fullSwitchCase(case_node) orelse return &.{};
    var out: std.ArrayList(Facts.Decl) = .empty;
    if (case.ast.values.len == 0) return fieldsOf(c, container);
    for (case.ast.values) |item| {
        if (tree.nodeTag(item) != .enum_literal) return fieldsOf(c, container);
        const decl = c.facts.member(container, tree.tokenSlice(tree.nodeMainToken(item))) orelse return fieldsOf(c, container);
        if (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind != .field) continue;
        try out.append(c.allocator, decl);
    }
    return out.items;
}

/// Every `Link` the program makes: each pointer-valued expression kept somewhere, by the places
/// it points into and the places it is kept in. What each function returns a pointer into
/// (`Function.returned`) is found with them, until none changes.
fn linksOf(c: *Context, flow: *Flow) Context.Error!void {
    while (true) {
        flow.links.clearRetainingCapacity();
        var changed = false;
        for (flow.functions.items, 0..) |f, i| {
            const function: Function.Id = @fromBackingInt(@intCast(i));
            const tree = &c.project.at(f.file).file.tree;
            const model = &c.project.at(f.file).model;
            for (flow.owners.get(f.file).?, 0..) |own, n| {
                if (own != function) continue;
                const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
                const parent = model.parentOf(node) orelse continue;
                if (!keeps(tree, parent, node)) continue;
                if (!try pointing(c, f.file, node)) continue;
                var owners: std.ArrayList(Place) = .empty;
                try places(c, flow, function, node, &owners);
                if (owners.items.len == 0) continue;
                if (try hold(c, flow, function, owners.items, node)) changed = true;
            }
        }
        if (!changed) return;
    }
}

/// Whether `parent` keeps the value of its operand `node` somewhere, or passes it on as its own
/// (`hold` reads where): no use that only reads through it (`p.*`, `p[i]`, `p.len`, a
/// comparison), and no operand `places` already reads through (a branch, a cast).
fn keeps(tree: *const Ast, parent: Ast.Node.Index, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(parent)) {
        .simple_var_decl, .local_var_decl, .aligned_var_decl, .global_var_decl => true,
        .assign => tree.nodeData(parent).node_and_node[1] == node,
        .assign_destructure, .@"return", .@"break" => true,
        .call_one, .call_one_comma, .call, .call_comma => true,
        .struct_init_one, .struct_init_one_comma, .struct_init_dot_two, .struct_init_dot_two_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init, .struct_init_comma => true,
        .array_init_one, .array_init_one_comma, .array_init_dot_two, .array_init_dot_two_comma, .array_init_dot, .array_init_dot_comma, .array_init, .array_init_comma => true,
        else => false,
    };
}

/// Links `owners` to where `node`'s value is kept, walking up through what passes it on.
/// Returns whether what the function returns a pointer into grew.
fn hold(c: *Context, flow: *Flow, function: Function.Id, owners: []const Place, node: Ast.Node.Index) Context.Error!bool {
    const f = &flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    const parent = model.parentOf(node) orelse return false;
    var holders: std.ArrayList(Place) = .empty;
    var grew = false;
    switch (tree.nodeTag(parent)) {
        .simple_var_decl, .local_var_decl, .aligned_var_decl, .global_var_decl => {
            const d = declaredAt(model, parent) orelse return false;
            const scope = model.scopes[@backingInt(model.declarations[@backingInt(d)].scope)].kind;
            try holders.append(c.allocator, if (scope == .file or scope == .container) .{ .global = .{ .file = f.file, .index = d } } else .{ .local = d });
        },
        .assign => {
            const target, const value = tree.nodeData(parent).node_and_node;
            if (value != node) return false;
            try places(c, flow, function, target, &holders);
        },
        .@"return" => for (owners) |place| switch (place) {
            .param => |index| if (f.returned & bit(index) == 0) {
                f.returned |= bit(index);
                grew = true;
            },
            .global => |decl| if (!for (f.returned_globals.items) |each| {
                if (std.meta.eql(each, decl)) break true;
            } else false) {
                try f.returned_globals.append(c.allocator, decl);
                grew = true;
            },
            // A local's own memory is gone once the function returns.
            .local, .unknown => {},
        },
        .@"break" => {
            const target = breakTarget(tree, model, parent) orelse {
                try holders.append(c.allocator, .unknown);
                try link(c, flow, function, owners, holders.items);
                return false;
            };
            return hold(c, flow, function, owners, target);
        },
        .grouped_expression, .unwrap_optional, .@"try", .@"orelse", .@"catch", .@"if", .if_simple, .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline, .@"switch", .switch_comma => {
            // A switch's operand or a branch's condition is read, not passed on.
            if (tree.fullIf(parent)) |branch| if (branch.ast.cond_expr == node) return false;
            if (tree.fullSwitch(parent)) |choice| if (choice.ast.condition == node) return false;
            const up = if (tree.fullSwitchCase(parent) != null) model.parentOf(parent) orelse return false else parent;
            return hold(c, flow, function, owners, up);
        },
        else => {
            var call_buffer: [1]Ast.Node.Index = undefined;
            var literal_buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullCall(&call_buffer, parent)) |call| {
                if (call.ast.fn_expr == node) return false;
                const callee = try resolveCall(c, flow, f.file, call);
                switch (callee.kind) {
                    // The program's callee keeps what it is given where its own links say: in
                    // its callers' memory (`writes`), or in what it returns (`returned`).
                    .program => return false,
                    // A function outside the program may keep a pointer in what it returns
                    // and in the other memory it is given (`map.put(gpa, &key, v)`).
                    .outside, .source, .aegis, .holder => {
                        for (callee.args.items) |arg| if (arg != node and try pointing(c, f.file, arg)) try places(c, flow, function, arg, &holders);
                        grew = try hold(c, flow, function, owners, parent);
                    },
                    .none => try holders.append(c.allocator, .unknown),
                }
            } else if (tree.fullStructInit(&literal_buffer, parent)) |literal| {
                if (literal.ast.type_expr.unwrap() == node) return false;
                if (try literalFields(c, f.file, parent, literal)) |fields| {
                    for (literal.ast.fields, fields) |value, field| if (value == node) try holders.append(c.allocator, .{ .global = field });
                } else return hold(c, flow, function, owners, parent);
            } else if (tree.fullArrayInit(&literal_buffer, parent)) |literal| {
                if (literal.ast.type_expr.unwrap() == node) return false;
                return hold(c, flow, function, owners, parent);
            } else if (tree.nodeTag(parent) == .assign_destructure) {
                try holders.append(c.allocator, .unknown);
            } else switch (tree.nodeTag(parent)) {
                // A use that reads through it keeps nothing.
                .field_access, .array_access, .deref, .slice, .slice_open, .slice_sentinel, .equal_equal, .bang_equal, .less_than, .less_or_equal, .greater_than, .greater_or_equal, .for_simple, .@"for", .@"while", .while_simple, .while_cont, .@"defer", .@"errdefer", .block, .block_semicolon, .block_two, .block_two_semicolon => {},
                .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                    const name = tree.tokenSlice(tree.nodeMainToken(parent));
                    for ([_][]const u8{ "@ptrCast", "@alignCast", "@constCast", "@volatileCast", "@as", "@ptrFromInt", "@intFromPtr" }) |cast| if (std.mem.eql(u8, name, cast)) {
                        return hold(c, flow, function, owners, parent);
                    };
                    // `@memcpy` and friends read through it; any other builtin passes nothing on.
                },
                else => try holders.append(c.allocator, .unknown),
            }
        },
    }
    try link(c, flow, function, owners, holders.items);
    return grew;
}

fn link(c: *Context, flow: *Flow, function: Function.Id, owners: []const Place, holders: []const Place) Context.Error!void {
    for (owners) |owner_place| {
        if (owner_place == .unknown) continue;
        for (holders) |holder| {
            if (std.meta.eql(owner_place, holder)) continue;
            try flow.links.append(c.allocator, .{ .function = function, .owner = owner_place, .holder = holder });
        }
    }
    return;
}

/// The labeled block or loop a `break` gives its value to.
fn breakTarget(tree: *const Ast, model: *const Model, node: Ast.Node.Index) ?Ast.Node.Index {
    const label = tree.nodeData(node).opt_token_and_opt_node[0].unwrap();
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                const named = label orelse continue;
                const lbrace = tree.nodeMainToken(parent);
                if (lbrace >= 2 and tree.tokenTag(lbrace - 1) == .colon and std.mem.eql(u8, tree.tokenSlice(lbrace - 2), tree.tokenSlice(named))) return parent;
            },
            .@"while", .while_simple, .while_cont, .@"for", .for_simple => {
                const named = label orelse return parent;
                const first = tree.firstToken(parent);
                if (first >= 2 and tree.tokenTag(first + 1) == .colon and std.mem.eql(u8, tree.tokenSlice(first), tree.tokenSlice(named))) return parent;
                if (tree.tokenTag(first) == .keyword_inline and tree.tokenTag(first + 2) == .colon and std.mem.eql(u8, tree.tokenSlice(first + 1), tree.tokenSlice(named))) return parent;
            },
            .fn_decl => return null,
            else => {},
        }
    }
    return null;
}

/// Each round, every owner takes what its holders hold: a store through the holder wrote it.
fn takeHeld(c: *Context, flow: *Flow) Context.Error!void {
    for (flow.links.items) |each| {
        const f = flow.functions.items[@backingInt(each.function)];
        const value: Dep = switch (each.holder) {
            .local => |d| flow.locals.get(.{ .file = f.file, .index = d }) orelse continue,
            .global => |decl| .{ .level = flow.globals.get(decl) orelse .clean, .length = flow.lengths.get(decl) orelse .clean },
            .param, .unknown => .{ .level = .unknown },
        };
        // What a store through the holder writes is what the owner holds, not its length.
        try raise(c, flow, each.function, each.owner, value.held());
    }
}

/// What a value read whole holds (its bytes reinterpreted, a copy handed outside the program):
/// what it holds itself, and what each field of its type holds by declaration, through the
/// fields of those fields' types in turn. A value whose type does not resolve may hold any
/// field's: undecided.
fn whole(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!Dep {
    var out = try dep(c, flow, function, node);
    const file = flow.functions.items[@backingInt(function)].file;
    const fields = (try wholeFields(c, try c.facts.resolve(file, node))) orelse {
        // An integer holds no fields.
        if (try Range.intOf(c, file, node, 64) != null) return out;
        return out.join(.{ .level = .unknown });
    };
    for (fields) |field| out = out.join(.{ .level = flow.globals.get(field) orelse .clean, .length = flow.lengths.get(field) orelse .clean });
    return out;
}

/// The fields a value of a type holds, through its fields' types in turn, found once per type;
/// null where the type does not resolve.
const Wholes = struct { map: std.AutoHashMapUnmanaged(Facts.Container, []const Facts.Decl) = .empty };

pub fn wholeFields(c: *Context, value: Facts.Value) Context.Error!?[]const Facts.Decl {
    var roots: std.ArrayList(Facts.Container) = .empty;
    if (!try containersOf(c, value, &roots)) return null;
    if (roots.items.len == 0) return &.{};
    const memo = try c.facts.memo(Wholes);
    if (roots.items.len == 1) if (memo.map.get(roots.items[0])) |found| return found;
    var seen: std.AutoHashMapUnmanaged(Facts.Container, void) = .empty;
    var out: std.ArrayList(Facts.Decl) = .empty;
    var stack: std.ArrayList(Facts.Container) = .empty;
    try stack.appendSlice(c.allocator, roots.items);
    while (stack.pop()) |container| {
        if ((try seen.getOrPut(c.allocator, container)).found_existing) continue;
        for (try fieldsOf(c, container)) |field| {
            try out.append(c.allocator, field);
            _ = try containersOf(c, try c.facts.declaration(field), &stack);
        }
    }
    if (roots.items.len == 1) try memo.map.put(c.allocator, roots.items[0], out.items);
    return out.items;
}

/// The containers a value's type is or holds (through pointers, optionals, error unions,
/// arrays and choices); false where the type does not resolve.
fn containersOf(c: *Context, value: Facts.Value, out: *std.ArrayList(Facts.Container)) Context.Error!bool {
    switch (value) {
        .instance => |k| try out.append(c.allocator, k),
        .pointer, .optional, .error_union, .array => |inner| return containersOf(c, inner.*, out),
        .alternatives => |each| for (each) |one| {
            if (!try containersOf(c, one, out)) return false;
        },
        .unknown, .reified => return false,
        else => {},
    }
    return true;
}

/// What chose whether, and how often, the assignment `node` ran, so what it gives (implicit
/// flow): the conditions of the branches it is in (an `if`'s, a `switch`'s subject, a `catch`'s
/// or `orelse`'s operand) and what decides each enclosing loop's passes (`passes`), up to where
/// the variable `target` stores into is declared. A variable declared inside the branch is
/// the same whichever way it ran; a field, a global or a parameter's memory take every
/// condition up to the function.
fn control(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index, target: ?Ast.Node.Index) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    var bound: ?Ast.TokenIndex = null;
    if (target) |assigned| {
        var root = assigned;
        while (true) root = switch (tree.nodeTag(root)) {
            .field_access, .unwrap_optional, .grouped_expression => tree.nodeData(root).node_and_token[0],
            .array_access => tree.nodeData(root).node_and_node[0],
            else => break,
        };
        if (tree.nodeTag(root) == .identifier) if (model.reference(root)) |ref| if (ref.declaration) |d| {
            const decl = model.declarations[@backingInt(d)];
            const scope = model.scopes[@backingInt(decl.scope)].kind;
            if ((decl.kind == .variable or decl.kind == .capture) and scope != .file and scope != .container) bound = decl.token;
        };
    }
    return controlUpTo(c, flow, function, node, bound);
}

/// `control` of a `break` up to the labeled block it leaves.
fn controlWithin(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index, block: Ast.Node.Index) Context.Error!Dep {
    const tree = &c.project.at(flow.functions.items[@backingInt(function)].file).file.tree;
    return controlUpTo(c, flow, function, node, tree.firstToken(block));
}

fn controlUpTo(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index, bound: ?Ast.TokenIndex) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    var out: Dep = .{};
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (bound) |token| if (token >= tree.firstToken(parent) and token <= tree.lastToken(parent)) break;
        switch (tree.nodeTag(parent)) {
            .fn_decl => break,
            .@"if", .if_simple => {
                const branch = tree.fullIf(parent).?; // unreachable: the tag is an if's
                if (at != branch.ast.cond_expr) out = out.join((try dep(c, flow, function, branch.ast.cond_expr)).held().narrowed());
            },
            .@"switch", .switch_comma => {
                const choice = tree.fullSwitch(parent).?; // unreachable: the tag is a switch's
                if (at != choice.ast.condition) out = out.join((try dep(c, flow, function, choice.ast.condition)).held().narrowed());
            },
            .@"catch", .@"orelse" => {
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                if (at == rhs) out = out.join((try dep(c, flow, function, lhs)).held().narrowed());
            },
            .@"while", .while_simple, .while_cont, .@"for", .for_simple => out = out.join(try passes(c, flow, function, parent)),
            else => {},
        }
    }
    return out;
}

/// What decides how many passes a loop takes, and so how far what it steps goes: its
/// condition's operands or its inputs' bounds and lengths, and every condition inside it, any
/// of which may end a pass or the loop. Read once per round.
fn passes(c: *Context, flow: *Flow, function: Function.Id, loop: Ast.Node.Index) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const key: Facts.Key = .{ .file = f.file, .node = loop };
    if (flow.loops.get(key)) |known_dep| return known_dep;
    // A loop read while it is being read gives what is known so far; the rounds settle it.
    try flow.loops.put(c.allocator, key, .{});
    const tree = &c.project.at(f.file).file.tree;
    var out: Dep = .{};
    if (tree.fullWhile(loop)) |w| out = out.join(try operands(c, flow, function, w.ast.cond_expr));
    if (tree.fullFor(loop)) |l| for (l.ast.inputs) |input| {
        if (tree.nodeTag(input) == .for_range) {
            const start, const end = tree.nodeData(input).node_and_opt_node;
            out = out.join((try dep(c, flow, function, start)).held());
            if (end.unwrap()) |last| out = out.join((try dep(c, flow, function, last)).held());
        } else out = out.join((try dep(c, flow, function, input)).measured());
    };
    const first = tree.firstToken(loop);
    const last = tree.lastToken(loop);
    const owners = flow.owners.get(f.file).?; // unreachable: the function's file is read
    for (owners, 0..) |own, i| {
        if (own != function) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last or node == loop) continue;
        switch (tree.nodeTag(node)) {
            .@"if", .if_simple => out = out.join(try operands(c, flow, function, tree.fullIf(node).?.ast.cond_expr)),
            .@"while", .while_simple, .while_cont => out = out.join(try operands(c, flow, function, tree.fullWhile(node).?.ast.cond_expr)),
            .@"switch", .switch_comma => out = out.join((try dep(c, flow, function, tree.fullSwitch(node).?.ast.condition)).held()),
            .@"catch", .@"orelse" => out = out.join((try dep(c, flow, function, tree.nodeData(node).node_and_node[0])).held().narrowed()),
            else => {},
        }
    }
    try flow.loops.put(c.allocator, key, out);
    return out;
}

/// A condition's operands as they are: a counter compared with a bound runs as far as the bound.
fn operands(c: *Context, flow: *Flow, function: Function.Id, condition: Ast.Node.Index) Context.Error!Dep {
    const tree = &c.project.at(flow.functions.items[@backingInt(function)].file).file.tree;
    switch (tree.nodeTag(condition)) {
        .grouped_expression => return operands(c, flow, function, tree.nodeData(condition).node_and_token[0]),
        .bool_not => return operands(c, flow, function, tree.nodeData(condition).node),
        .bool_and, .bool_or, .less_than, .less_or_equal, .greater_than, .greater_or_equal, .equal_equal, .bang_equal => {
            const lhs, const rhs = tree.nodeData(condition).node_and_node;
            return (try operands(c, flow, function, lhs)).join(try operands(c, flow, function, rhs));
        },
        else => return (try dep(c, flow, function, condition)).held(),
    }
}
