//! The flow facts the danger rules read (designs/aegis.md §7), each computed once for the whole
//! program: the input fact, which values come from outside it, and the peer fact, which writers
//! reach a peer.
//!
//! Input is what the program did not make: what a `std.Io.Reader` read gives or writes into the
//! caller's buffer (a peer's socket, a child's pipe, stdin, a file, an archive's or a
//! repository's content through the readers over them), what `Io.File` and `Io.Dir` read of a
//! file's contents, and the output `process.run` collects from a child. A reader `Reader.fixed`
//! makes over the program's own bytes carries their fact instead, and a read on a line carrying
//! an aegis escape is one the program declares its own (a file it wrote itself): no input
//! starts there, and the escape lists it. Arguments and the environment are the operator's,
//! not a peer's. A peer writer is one a `net.Stream` gives.
//!
//! Input is data (bytes, and what the program computes from them) or a number: an integer a
//! peer chooses past a byte's range, which std decodes from data (`readInt`, `parseInt`,
//! `takeInt`) or the program assembles from it by a shift or a product. A position std finds in
//! data, a count a read returns, a slice's `.len` and `.ptr`, the least of a value and a clean
//! bound, a count of bits (`@ctz`, `@clz`, `@popCount`) and a comparison are clean: memory or
//! a width the program holds bounds them. What a decode of 16 bits or fewer gives, a mask or a
//! remainder by the program's own value, a truncation and wrapping arithmetic stay in a range
//! the program chose: data, never a number.
//!
//! The fact flows through locals, captures, indexing and slicing, field reads, arithmetic and
//! conversions; through a call outside the program given such a value (to its result, and to a
//! local receiver it adds it to); through the program's own calls, to the parameter in the
//! callee and back by the callee's summary, so a call made with clean arguments stays clean;
//! and through a store into the program's own field, which holds it everywhere by its
//! declaration. aegis's types are the answer to input: what aegis gives back (an
//! `input.Untrusted` and what its `parse` refines, a checked integer) is clean. A call whose
//! callee does not resolve, given input, gives an unknown value, which a sink reads as
//! undecided, never as passed.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Governed = @import("Governed.zig");
const Contract = @import("AegisContract.zig");
const Suppression = @import("Suppression.zig");
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
pub const Dep = struct {
    level: Level = .clean,
    params: u64 = 0,
    numbers: u64 = 0,
    ranged: u64 = 0,
    maybe: u64 = 0,

    pub fn join(a: Dep, b: Dep) Dep {
        return .{ .level = a.level.join(b.level), .params = a.params | b.params, .numbers = a.numbers | b.numbers, .ranged = a.ranged | b.ranged, .maybe = a.maybe | b.maybe };
    }
    fn lowered(a: Dep) Dep {
        return .{ .level = if (a.level == .clean) .clean else .unknown, .maybe = a.params | a.numbers | a.ranged | a.maybe };
    }
    /// Data made a number: a shift or a product of it, or what std decodes from it.
    fn widened(a: Dep) Dep {
        return .{ .level = if (a.level == .data) .number else a.level, .params = a.params, .numbers = a.numbers | a.params | a.ranged, .maybe = a.maybe };
    }
    /// A value kept to a range the program chose: a number is data there.
    fn narrowed(a: Dep) Dep {
        return .{ .level = if (a.level == .number) .data else a.level, .ranged = a.params | a.numbers | a.ranged, .maybe = a.maybe };
    }
    fn clean(a: Dep) bool {
        return a.level == .clean and a.params == 0 and a.numbers == 0 and a.ranged == 0 and a.maybe == 0;
    }
    fn eql(a: Dep, b: Dep) bool {
        return a.level == b.level and a.params == b.params and a.numbers == b.numbers and a.ranged == b.ranged and a.maybe == b.maybe;
    }
};

pub const Fact = enum { input, peer };

pub const Owned = struct { file: Project.FileId, token: Ast.TokenIndex };

const Function = struct {
    file: Project.FileId,
    node: Ast.Node.Index,
    /// Its parameters' declarations in order, the receiver first.
    params: []const u32,
    /// What its callers give each parameter.
    levels: []Level,
    ret: Dep = .{},
    /// The parameters whose memory it fills with the fact (a buffer it reads into).
    fills: u64 = 0,
};

pub const Flow = struct {
    solved: bool = false,
    fact: Fact = .input,
    functions: std.ArrayList(Function) = .empty,
    /// Per file, each node's nearest enclosing function, by its index in `functions`.
    owners: std.AutoHashMapUnmanaged(u32, []const ?u32) = .empty,
    by_node: std.AutoHashMapUnmanaged(Facts.Key, u32) = .empty,
    locals: std.AutoHashMapUnmanaged(Facts.Decl, Dep) = .empty,
    /// Fields and container-level variables, by declaration.
    globals: std.AutoHashMapUnmanaged(Facts.Decl, Level) = .empty,
    std_files: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// std's namespaces whose functions make data from data: what they give holds what they take.
    data_files: std.AutoHashMapUnmanaged(u32, void) = .empty,
    aegis_files: std.AutoHashMapUnmanaged(u32, void) = .empty,
    reader: ?Facts.Container = null,
    file: ?Facts.Container = null,
    dir: ?Facts.Container = null,
    stream: ?Facts.Container = null,
    /// The functions the configuration declares write to a peer.
    peer_writers: std.ArrayList(Facts.Decl) = .empty,
    /// std's `process.run`, whose result holds a child's output.
    run: std.ArrayList(Facts.Decl) = .empty,
    /// Reads the program declares its own by an escape on their line, as file and token.
    owned: std.AutoArrayHashMapUnmanaged(Owned, void) = .empty,
    /// Per file, the lines an aegis escape stands on.
    escaped: std.AutoHashMapUnmanaged(u32, []const u32) = .empty,
    changed: bool = false,
};

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
    try known(c, flow);
    for (c.project.inputs, 0..) |input, f| {
        if (!input.selected or input.classification == .@"test") continue;
        const file = Project.FileId.fromRaw(@intCast(f));
        // A file whose rules read neither fact (a tool the package develops with) is no part
        // of the program the facts describe.
        if (!reads(c.configOf(file), flow.fact)) continue;
        try functionsOf(c, flow, file);
    }
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        flow.changed = false;
        for (flow.functions.items, 0..) |_, i| try bindings(c, flow, @intCast(i));
        if (!flow.changed) break;
    }
}

fn reads(config: @import("Rule.zig").Config, fact: Fact) bool {
    const pack = @import("AegisRules.zig");
    return switch (fact) {
        .input => config.has(pack.untrusted_input) or config.has(pack.integers) or config.has(pack.bounded_work) or config.has(pack.cancellation) or config.has(pack.contracts),
        .peer => config.has(pack.diagnostics),
    };
}

/// The declarations the fact starts from and stops at: std's reader, file, directory and stream,
/// std's and aegis's files.
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
    for ((try Governed.declarations(c, "std", "process.run")) orelse &.{}) |decl| try flow.run.append(c.allocator, (try c.facts.origin(decl)) orelse decl);
    for (c.project.imports) |mapping| if (std.mem.eql(u8, mapping.spelling, "std")) try reach(c, &flow.std_files, mapping.target);
    for ([_][]const u8{ "mem", "fmt", "ascii", "unicode", "math", "base64" }) |namespace| {
        for ((try Governed.declarations(c, "std", namespace)) orelse &.{}) |decl| {
            const value = try c.facts.declaration((try c.facts.origin(decl)) orelse decl);
            if (value != .container) continue;
            // The namespace's own file and the files it reaches by its relative imports.
            try flow.data_files.put(c.allocator, value.container.file.raw(), {});
            var next = std.ArrayList(Project.FileId).empty;
            try next.append(c.allocator, value.container.file);
            while (next.pop()) |file| for (c.project.imports) |mapping| {
                if (!mapping.from.eql(file) or !std.mem.endsWith(u8, mapping.spelling, ".zig")) continue;
                if ((try flow.data_files.getOrPut(c.allocator, mapping.target.raw())).found_existing) continue;
                try next.append(c.allocator, mapping.target);
            };
        }
    }
    const aegis = try c.facts.publication(Contract.library);
    for (aegis.files) |file| try flow.aegis_files.put(c.allocator, file.raw(), {});
}

/// Every file `root` reaches through its own imports.
fn reach(c: *Context, set: *std.AutoHashMapUnmanaged(u32, void), root: Project.FileId) Context.Error!void {
    if ((try set.getOrPut(c.allocator, root.raw())).found_existing) return;
    var stack: std.ArrayList(Project.FileId) = .empty;
    try stack.append(c.allocator, root);
    while (stack.pop()) |file| for (c.project.imports) |mapping| {
        if (!mapping.from.eql(file)) continue;
        if ((try set.getOrPut(c.allocator, mapping.target.raw())).found_existing) continue;
        try stack.append(c.allocator, mapping.target);
    };
}

/// The file's functions with a body, and each node's owner among them.
fn functionsOf(c: *Context, flow: *Flow, file: Project.FileId) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    const owners = try c.allocator.alloc(?u32, tree.nodes.len);
    @memset(owners, null);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .fn_decl) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(node).node_and_node[0]) orelse continue;
        var params: std.ArrayList(u32) = .empty;
        var it = proto.iterate(tree);
        while (it.next()) |param| {
            const name = param.name_token orelse {
                try params.append(c.allocator, std.math.maxInt(u32));
                continue;
            };
            var found: u32 = std.math.maxInt(u32);
            for (model.declarations, 0..) |decl, d| if (decl.kind == .parameter and decl.token == name) {
                found = @intCast(d);
                break;
            };
            try params.append(c.allocator, found);
        }
        const levels = try c.allocator.alloc(Level, params.items.len);
        @memset(levels, .clean);
        try flow.by_node.put(c.allocator, .{ .file = file, .node = node }, @intCast(flow.functions.items.len));
        try flow.functions.append(c.allocator, .{ .file = file, .node = node, .params = params.items, .levels = levels });
    }
    for (0..tree.nodes.len) |i| {
        var at: Ast.Node.Index = @fromBackingInt(@intCast(i));
        while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) { // safe: a node index indexes its own tree's parent table.
            if (tree.nodeTag(parent) == .fn_decl) {
                owners[i] = flow.by_node.get(.{ .file = file, .node = parent });
                break;
            }
            var buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullContainerDecl(&buffer, parent) != null) break;
        }
    }
    try flow.owners.put(c.allocator, file.raw(), owners);
}

/// The function whose body holds `node`, if the fact reads it.
pub fn owner(flow: *const Flow, file: Project.FileId, node: Ast.Node.Index) ?u32 {
    const owners = flow.owners.get(file.raw()) orelse return null;
    return owners[@backingInt(node)]; // safe: a node index indexes its own tree's table.
}

/// One round over a function's bindings: what each local, field, parameter and result takes.
fn bindings(c: *Context, flow: *Flow, function: u32) Context.Error!void {
    const f = flow.functions.items[function];
    const tree = &c.project.files[f.file.raw()].tree;
    const model = &c.project.models[f.file.raw()];
    const owners = flow.owners.get(f.file.raw()).?;
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
                var held = try dep(c, flow, function, value);
                // A product that feeds its own target accumulates a number (`n = n * 10 + d`).
                if (tree.nodeTag(node) == .assign and accumulates(tree, model, target, value)) held = held.widened();
                try store(c, flow, function, target, held);
            },
            .assign_mul, .assign_shl, .assign_mul_wrap, .assign_mul_sat, .assign_shl_sat => {
                const target, const value = tree.nodeData(node).node_and_node;
                try store(c, flow, function, target, (try dep(c, flow, function, target)).widened().join(try dep(c, flow, function, value)));
            },
            .assign_destructure => {
                const parts = tree.assignDestructure(node);
                const value = try dep(c, flow, function, parts.ast.value_expr);
                for (parts.ast.variables) |variable| {
                    if (declaredAt(model, variable)) |d| try raiseLocal(c, flow, .{ .file = f.file, .index = d }, value) else try store(c, flow, function, variable, value);
                }
            },
            .@"return" => {
                const value = tree.nodeData(node).opt_node.unwrap() orelse continue;
                const now = flow.functions.items[function].ret.join(try dep(c, flow, function, value));
                if (!now.eql(flow.functions.items[function].ret)) {
                    flow.functions.items[function].ret = now;
                    flow.changed = true;
                }
            },
            else => {
                var buffer: [1]Ast.Node.Index = undefined;
                if (tree.fullCall(&buffer, node)) |call| try effects(c, flow, function, call);
                var literal_buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullStructInit(&literal_buffer, node)) |literal| if (try literalFields(c, f.file, node, literal)) |fields| {
                    for (literal.ast.fields, fields) |value, field| try raiseGlobal(c, flow, field, concrete(flow, function, try dep(c, flow, function, value)));
                };
                if (isMemcpy(tree, node)) {
                    var args_buffer: [2]Ast.Node.Index = undefined;
                    const args = Facts.builtinArgs(tree, node, &args_buffer);
                    if (args.len == 2) try store(c, flow, function, args[0], try dep(c, flow, function, args[1]));
                }
            },
        }
    }
    // Captures take what they bind from.
    for (model.declarations, 0..) |decl, d| {
        if (decl.kind != .capture) continue;
        if (owner(flow, f.file, decl.node) != function) continue;
        const from = try captured(c, flow, function, decl, @intCast(d));
        try raiseLocal(c, flow, .{ .file = f.file, .index = @intCast(d) }, from);
    }
}

fn isMemcpy(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@memcpy") or std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@memmove"),
        else => false,
    };
}

/// What a capture binds: an `if`'s or `while`'s payload its condition, a `switch` prong's the
/// switch's operand, a `for` capture its input (a range's counter is clean), a `catch`'s error
/// nothing.
fn captured(c: *Context, flow: *Flow, function: u32, decl: Model.Declaration, d: u32) Context.Error!Dep {
    const f = flow.functions.items[function];
    const tree = &c.project.files[f.file.raw()].tree;
    const model = &c.project.models[f.file.raw()];
    const node = decl.node;
    if (tree.fullIf(node)) |branch| return if (branch.error_token == decl.token) .{} else dep(c, flow, function, branch.ast.cond_expr);
    if (tree.fullWhile(node)) |loop| return if (loop.error_token == decl.token) .{} else dep(c, flow, function, loop.ast.cond_expr);
    if (tree.fullSwitchCase(node) != null) {
        const parent = model.node_parents[@backingInt(node)] orelse return .{}; // safe: a node index indexes its own tree's parent table.
        const choice = tree.fullSwitch(parent) orelse return .{};
        return dep(c, flow, function, choice.ast.condition);
    }
    if (tree.fullFor(node)) |loop| {
        var position: usize = 0;
        for (model.declarations[0..d]) |earlier| if (earlier.kind == .capture and earlier.node == node) {
            position += 1;
        };
        if (position >= loop.ast.inputs.len) return .{};
        const input = loop.ast.inputs[position];
        if (tree.nodeTag(input) == .for_range) return .{};
        return dep(c, flow, function, input);
    }
    return .{};
}

/// The declaration a `var`/`const` node declares.
fn declaredAt(model: *const Model, node: Ast.Node.Index) ?u32 {
    for (model.declarations, 0..) |decl, d| if (decl.node == node and decl.kind == .variable) return @intCast(d);
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

fn raiseGlobal(c: *Context, flow: *Flow, decl: Facts.Decl, level: Level) Context.Error!void {
    if (level == .clean) return;
    const entry = try flow.globals.getOrPut(c.allocator, decl);
    const before: Level = if (entry.found_existing) entry.value_ptr.* else .clean;
    entry.value_ptr.* = before.join(level);
    if (entry.value_ptr.* != before) flow.changed = true;
}

/// A store of `value` into `target`: a local, a container-level variable or a field by its
/// declaration, the local an element or part of it belongs to, or the memory a parameter
/// points at (the function then fills it).
fn store(c: *Context, flow: *Flow, function: u32, target: Ast.Node.Index, value: Dep) Context.Error!void {
    const f = flow.functions.items[function];
    const tree = &c.project.files[f.file.raw()].tree;
    const model = &c.project.models[f.file.raw()];
    switch (tree.nodeTag(target)) {
        .identifier => {
            const ref = model.reference(target) orelse return;
            const d = ref.declaration orelse return;
            const decl = model.declarations[d];
            if (decl.kind == .parameter) return;
            const scope = model.scopes[decl.scope].kind;
            if (scope == .file or scope == .container) return raiseGlobal(c, flow, .{ .file = f.file, .index = d }, concrete(flow, function, value));
            return raiseLocal(c, flow, .{ .file = f.file, .index = d }, value);
        },
        .field_access => {
            // The program's own field holds the fact by its declaration; a field of a type
            // outside it (std's writer, a dependency's list) is every instance's everywhere, so
            // the store reaches only the value it belongs to.
            if (try c.facts.definition(f.file, target)) |decl| {
                if (c.project.models[decl.file.raw()].declarations[decl.index].kind == .field and c.project.inputs[decl.file.raw()].selected) return raiseGlobal(c, flow, decl, concrete(flow, function, value));
            }
            return store(c, flow, function, tree.nodeData(target).node_and_token[0], value);
        },
        .array_access => return store(c, flow, function, tree.nodeData(target).node_and_node[0], value),
        .deref, .address_of => return store(c, flow, function, tree.nodeData(target).node, value),
        .grouped_expression, .unwrap_optional => return store(c, flow, function, tree.nodeData(target).node_and_token[0], value),
        .slice_open, .slice, .slice_sentinel => return store(c, flow, function, (tree.fullSlice(target) orelse return).ast.sliced, value),
        else => {},
    }
}

/// What a parameter's root a store reaches: the parameter's index, when the target is rooted
/// at one.
fn rootParam(c: *Context, flow: *Flow, function: u32, target: Ast.Node.Index) ?usize {
    const f = flow.functions.items[function];
    const tree = &c.project.files[f.file.raw()].tree;
    const model = &c.project.models[f.file.raw()];
    var at = target;
    while (true) switch (tree.nodeTag(at)) {
        .identifier => {
            const ref = model.reference(at) orelse return null;
            const d = ref.declaration orelse return null;
            return std.mem.findScalar(u32, f.params, d);
        },
        .field_access, .grouped_expression, .unwrap_optional => at = tree.nodeData(at).node_and_token[0],
        .array_access => at = tree.nodeData(at).node_and_node[0],
        .deref, .address_of => at = tree.nodeData(at).node,
        .slice_open, .slice, .slice_sentinel => at = (tree.fullSlice(at) orelse return null).ast.sliced,
        else => return null,
    };
}

/// A call's effects beyond its result: what it gives the program's own callee's parameters,
/// what a read fills, what a local receiver takes from what it is given.
fn effects(c: *Context, flow: *Flow, function: u32, call: Ast.full.Call) Context.Error!void {
    const f = flow.functions.items[function];
    const callee = try resolveCall(c, flow, f.file, call);
    switch (callee.kind) {
        .program => |target| {
            const g = flow.functions.items[target];
            for (callee.args.items, 0..) |arg, position| {
                const index = position + callee.skip;
                if (index >= g.levels.len) break;
                const level = concrete(flow, function, try dep(c, flow, function, arg));
                if (level.join(g.levels[index]) != g.levels[index]) {
                    flow.functions.items[target].levels[index] = level.join(g.levels[index]);
                    flow.changed = true;
                }
                if (g.fills & bit(index) != 0) try fill(c, flow, function, arg);
            }
        },
        .source => {
            if (try fixedClean(c, flow, function, call) or try declaredOwn(c, flow, f.file, call)) return;
            const buffers = try bufferParams(c, callee.decl.?);
            for (callee.args.items, 0..) |arg, position| if (buffers & bit(position) != 0) try fill(c, flow, function, arg);
        },
        .outside => {
            // A receiver takes what a method adds to it: a list appended to, a map put into, a
            // writer written to; nothing else a method is given becomes its data.
            if (callee.receiver) |receiver| if (adds(c, callee.decl)) {
                var given: Dep = .{};
                for (callee.args.items[1..]) |arg| given = given.join(try dep(c, flow, function, arg));
                if (given.level != .clean or given.params != 0) try store(c, flow, function, receiver, given);
            };
        },
        .aegis, .none => {},
    }
}

/// Whether a method adds what it is given to its receiver's data: it takes its receiver by
/// mutable pointer, and its name is `append`, `insert`, `put`, `push`, `add`, `write` or `print`
/// or a form of one. An allocator's `print` takes its receiver by value and adds nothing to it.
fn adds(c: *Context, decl: ?Facts.Decl) bool {
    const d = decl orelse return false;
    const name = c.project.models[d.file.raw()].declarations[d.index].name;
    var named = false;
    for ([_][]const u8{ "append", "insert", "put", "push", "add", "write", "print" }) |prefix| named = named or std.mem.startsWith(u8, name, prefix);
    if (!named) return false;
    const tree = &c.project.files[d.file.raw()].tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.models[d.file.raw()].declarations[d.index].node) orelse return false;
    var it = proto.iterate(tree);
    const receiver = it.next() orelse return false;
    const kind = receiver.type_expr orelse return false;
    const pointer = tree.fullPtrType(kind) orelse return false;
    return pointer.const_token == null;
}

/// The parameters a read writes its bytes into, by position, the receiver first: a mutable
/// byte slice (`[]u8`) or a list of them (`[][]u8`, `[]const []u8`). What else a read is given
/// (a path, an allocator, a limit) it does not fill.
fn bufferParams(c: *Context, decl: Facts.Decl) Context.Error!u64 {
    const tree = &c.project.files[decl.file.raw()].tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.models[decl.file.raw()].declarations[decl.index].node) orelse return 0;
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

/// Whether a read stands on a line an aegis escape covers: the program declares the bytes its
/// own (a file it wrote itself), so the read starts no input, and A009 lists it at the escape.
fn declaredOwn(c: *Context, flow: *Flow, file: Project.FileId, call: Ast.full.Call) Context.Error!bool {
    if (flow.fact != .input) return false;
    const source_file = &c.project.files[file.raw()];
    const lines = flow.escaped.get(file.raw()) orelse lines: {
        var malformed: std.ArrayList(Suppression.Malformed) = .empty;
        var found: std.ArrayList(u32) = .empty;
        for (try Suppression.parseConfigured(c.allocator, source_file, c.definitions, &malformed)) |suppression| {
            if (suppression.escape != null) try found.append(c.allocator, suppression.line);
        }
        try flow.escaped.put(c.allocator, file.raw(), found.items);
        break :lines found.items;
    };
    const token = source_file.tree.nodeMainToken(call.ast.fn_expr);
    const line = source_file.line(source_file.tree.tokenStart(token));
    if (std.mem.findScalar(u32, lines, line) == null) return false;
    try flow.owned.put(c.allocator, .{ .file = file, .token = token }, {});
    return true;
}

/// A read fills `arg`'s memory with the fact: the local it is rooted at, or the parameter's
/// memory it points into (the function then fills that parameter for its callers).
fn fill(c: *Context, flow: *Flow, function: u32, arg: Ast.Node.Index) Context.Error!void {
    if (rootParam(c, flow, function, arg)) |index| {
        if (flow.functions.items[function].fills & bit(index) == 0) {
            flow.functions.items[function].fills |= bit(index);
            flow.changed = true;
        }
        return;
    }
    try store(c, flow, function, arg, .{ .level = .data });
}

fn bit(index: usize) u64 {
    return if (index < 64) @as(u64, 1) << @intCast(index) else 0;
}

/// A dependence read as a level, with what callers give the function's parameters.
pub fn concrete(flow: *const Flow, function: u32, value: Dep) Level {
    var level = value.level;
    const f = flow.functions.items[function];
    for (f.levels, 0..) |given, index| {
        if (value.params & bit(index) != 0) level = level.join(given);
        if (value.numbers & bit(index) != 0 and given == .data) level = level.join(.number);
        if (value.ranged & bit(index) != 0) level = level.join(if (given == .number) .data else given);
        if (value.maybe & bit(index) != 0 and given != .clean) level = level.join(.unknown);
    }
    return level;
}

const Callee = struct {
    kind: union(enum) { program: u32, source, outside, aegis, none },
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
    const tree = &c.project.files[file.raw()].tree;
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
    if (flow.aegis_files.contains(decl.file.raw())) {
        out.kind = .aegis;
        return out;
    }
    const record = c.project.models[decl.file.raw()].declarations[decl.index];
    if (flow.by_node.get(.{ .file = decl.file, .node = fnDecl(c, decl) orelse record.node })) |target| {
        if (c.project.inputs[decl.file.raw()].selected) {
            out.kind = .{ .program = target };
            return out;
        }
    }
    out.kind = if (try source(c, flow, decl, record.name)) .source else .outside;
    return out;
}

/// The `fn_decl` node of a function declaration.
fn fnDecl(c: *Context, decl: Facts.Decl) ?Ast.Node.Index {
    const model = &c.project.models[decl.file.raw()];
    const tree = &c.project.files[decl.file.raw()].tree;
    const parent = model.node_parents[@backingInt(model.declarations[decl.index].node)] orelse return null; // safe: a node index indexes its own tree's parent table.
    return if (tree.nodeTag(parent) == .fn_decl) parent else null;
}

/// Whether a function outside the program starts the fact: a read of input, or a peer writer.
fn source(c: *Context, flow: *Flow, decl: Facts.Decl, name: []const u8) Context.Error!bool {
    _ = c;
    const file = decl.file;
    switch (flow.fact) {
        .input => {
            for (flow.run.items) |run| if (std.meta.eql(run, decl)) return true;
            if (flow.reader) |reader| if (reader.file.eql(file)) {
                for ([_][]const u8{ "take", "peek", "readSlice", "readVec", "readAlloc", "allocRemaining", "appendExact", "appendRemaining", "buffered" }) |prefix| if (std.mem.startsWith(u8, name, prefix)) return true;
            };
            if (flow.file) |handle| if (handle.file.eql(file)) {
                for ([_][]const u8{ "readStreaming", "readPositional", "readPositionalAll" }) |read| if (std.mem.eql(u8, name, read)) return true;
            };
            if (flow.dir) |dir| if (dir.file.eql(file)) {
                for ([_][]const u8{ "readFile", "readFileAlloc", "readFileAllocOptions", "readLink" }) |read| if (std.mem.eql(u8, name, read)) return true;
            };
            return false;
        },
        .peer => {
            for (flow.peer_writers.items) |writer| if (std.meta.eql(writer, decl)) return true;
            const stream = flow.stream orelse return false;
            return stream.file.eql(file) and std.mem.eql(u8, name, "writer");
        },
    }
}

/// Whether a read is from a reader `Reader.fixed` made over clean bytes, as a local of the
/// function: such a read carries the bytes' fact, not input's.
fn fixedClean(c: *Context, flow: *Flow, function: u32, call: Ast.full.Call) Context.Error!bool {
    if (flow.fact != .input) return false;
    const f = flow.functions.items[function];
    const tree = &c.project.files[f.file.raw()].tree;
    const model = &c.project.models[f.file.raw()];
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return false;
    var receiver = tree.nodeData(call.ast.fn_expr).node_and_token[0];
    while (true) switch (tree.nodeTag(receiver)) {
        .address_of => receiver = tree.nodeData(receiver).node,
        .field_access => receiver = tree.nodeData(receiver).node_and_token[0],
        else => break,
    };
    if (tree.nodeTag(receiver) != .identifier) return false;
    const ref = model.reference(receiver) orelse return false;
    const d = ref.declaration orelse return false;
    const variable = tree.fullVarDecl(model.declarations[d].node) orelse return false;
    const init = variable.ast.init_node.unwrap() orelse return false;
    var buffer: [1]Ast.Node.Index = undefined;
    const made = tree.fullCall(&buffer, init) orelse return false;
    const callee = switch (tree.nodeTag(made.ast.fn_expr)) {
        .field_access => tree.tokenSlice(tree.nodeData(made.ast.fn_expr).node_and_token[1]),
        .enum_literal => tree.tokenSlice(tree.nodeMainToken(made.ast.fn_expr)),
        else => return false,
    };
    if (!std.mem.eql(u8, callee, "fixed") or made.ast.params.len != 1) return false;
    return concrete(flow, function, try dep(c, flow, function, made.ast.params[0])) == .clean;
}

/// Whether `value` multiplies or shifts the local `target` names: an assignment that grows it.
fn accumulates(tree: *const Ast, model: *const Model, target: Ast.Node.Index, value: Ast.Node.Index) bool {
    if (tree.nodeTag(target) != .identifier) return false;
    const declared = (model.reference(target) orelse return false).declaration orelse return false;
    const first = tree.firstToken(value);
    const last = tree.lastToken(value);
    for (tree.nodes.items(.tag), 0..) |tag, i| switch (tag) {
        .mul, .mul_wrap, .mul_sat, .shl, .shl_sat => {
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
pub fn dep(c: *Context, flow: *Flow, function: u32, node: Ast.Node.Index) Context.Error!Dep {
    const f = flow.functions.items[function];
    const tree = &c.project.files[f.file.raw()].tree;
    const model = &c.project.models[f.file.raw()];
    switch (tree.nodeTag(node)) {
        .identifier => {
            const ref = model.reference(node) orelse return .{};
            const d = ref.declaration orelse return .{};
            if (std.mem.findScalar(u32, f.params, d)) |index| return .{ .params = bit(index) };
            const decl = model.declarations[d];
            if (decl.kind == .variable or decl.kind == .capture) {
                const scope = model.scopes[decl.scope].kind;
                if (scope == .file or scope == .container) return .{ .level = flow.globals.get(.{ .file = f.file, .index = d }) orelse .clean };
                return flow.locals.get(.{ .file = f.file, .index = d }) orelse .{};
            }
            return .{};
        },
        .field_access => {
            const receiver, const name = tree.nodeData(node).node_and_token;
            if (std.mem.eql(u8, tree.tokenSlice(name), "len") or std.mem.eql(u8, tree.tokenSlice(name), "ptr")) return .{};
            var out = try dep(c, flow, function, receiver);
            if (try c.facts.definition(f.file, node)) |decl| {
                if (flow.globals.get(decl)) |level| out = out.join(.{ .level = level });
                // A function or a type named through a value is no part of its data.
                const kind = c.project.models[decl.file.raw()].declarations[decl.index].kind;
                if (kind == .function) return .{};
            }
            return out;
        },
        .array_access => return dep(c, flow, function, tree.nodeData(node).node_and_node[0]),
        .slice_open, .slice, .slice_sentinel => return dep(c, flow, function, (tree.fullSlice(node) orelse return .{}).ast.sliced),
        .grouped_expression, .unwrap_optional => return dep(c, flow, function, tree.nodeData(node).node_and_token[0]),
        .deref, .address_of, .@"try", .negation, .negation_wrap, .bit_not => return dep(c, flow, function, tree.nodeData(node).node),
        // What is left of a length (`buf.len - at`) is bounded by it; a mask or a remainder by
        // the program's own value is bounded by it, a peer's value within that range: data.
        .sub, .sub_sat => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            if (isLen(tree, lhs)) return .{};
            return (try dep(c, flow, function, lhs)).join(try dep(c, flow, function, rhs));
        },
        .bit_and, .mod => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const left = try dep(c, flow, function, lhs);
            const right = try dep(c, flow, function, rhs);
            if (left.clean() or right.clean()) return left.join(right).narrowed();
            return left.join(right);
        },
        // Wrapping arithmetic stays in its type's range by intent (a hash, a checksum): data.
        .add_wrap, .sub_wrap, .mul_wrap => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return (try dep(c, flow, function, lhs)).join(try dep(c, flow, function, rhs)).narrowed();
        },
        .add, .div, .shr, .bit_or, .bit_xor, .add_sat, .array_cat, .@"orelse", .@"catch" => {
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
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            for ([_][]const u8{ "@sizeOf", "@alignOf", "@bitSizeOf", "@TypeOf", "@typeInfo", "@errorName", "@tagName", "@typeName", "@import", "@This", "@src", "@hasDecl", "@hasField", "@intFromBool", "@ctz", "@clz", "@popCount" }) |clean| if (std.mem.eql(u8, name, clean)) return .{};
            var buffer: [2]Ast.Node.Index = undefined;
            var out: Dep = .{};
            for (Facts.builtinArgs(tree, node, &buffer)) |arg| {
                const each = try dep(c, flow, function, arg);
                // The least of a value and a clean bound is bounded by it.
                if (std.mem.eql(u8, name, "@min") and each.clean()) return .{};
                out = out.join(each);
            }
            // A truncation keeps the bits a narrower type holds: a peer's value in its range.
            if (std.mem.eql(u8, name, "@truncate")) return out.narrowed();
            return out;
        },
        .@"if", .if_simple => {
            const branch = tree.fullIf(node).?;
            var out = try dep(c, flow, function, branch.ast.then_expr);
            if (branch.ast.else_expr.unwrap()) |e| out = out.join(try dep(c, flow, function, e));
            return out;
        },
        .@"switch", .switch_comma => {
            var out: Dep = .{};
            for (tree.fullSwitch(node).?.ast.cases) |case| out = out.join(try dep(c, flow, function, (tree.fullSwitchCase(case) orelse continue).ast.target_expr));
            return out;
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => return labeled(c, flow, function, node),
        else => {},
    }
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, node)) |literal| {
        // A literal of a known type holds its fields' facts by their declarations; a tuple or
        // a literal whose type does not resolve holds what it is given.
        if (try literalFields(c, f.file, node, literal) != null) return .{};
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
    return .{};
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
    const tree = &c.project.files[file.raw()].tree;
    const fields = try c.allocator.alloc(Facts.Decl, literal.ast.fields.len);
    for (literal.ast.fields, fields) |value, *field| {
        const name = try Model.identifier(c.allocator, tree.tokenSlice(tree.firstToken(value) - 2));
        const decl = c.facts.member(container, name) orelse return null;
        if (c.project.models[decl.file.raw()].declarations[decl.index].kind != .field) return null;
        field.* = decl;
    }
    return fields;
}

/// A labeled block's value: what its `break`s give it.
fn labeled(c: *Context, flow: *Flow, function: u32, node: Ast.Node.Index) Context.Error!Dep {
    const f = flow.functions.items[function];
    const tree = &c.project.files[f.file.raw()].tree;
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
    }
    return out;
}

/// A call's result: the program's callee's summary read with these arguments, a read's input,
/// what a function outside the program makes of what it is given, aegis's answer clean, and
/// unknown from a callee that does not resolve.
fn result(c: *Context, flow: *Flow, function: u32, call: Ast.full.Call) Context.Error!Dep {
    const f = flow.functions.items[function];
    const callee = try resolveCall(c, flow, f.file, call);
    switch (callee.kind) {
        .aegis => return .{},
        .program => |target| {
            const g = flow.functions.items[target];
            var out: Dep = .{ .level = g.ret.level };
            for (callee.args.items, 0..) |arg, position| {
                const index = position + callee.skip;
                if (g.ret.params & bit(index) != 0) out = out.join(try dep(c, flow, function, arg));
                if (g.ret.numbers & bit(index) != 0) out = out.join((try dep(c, flow, function, arg)).widened());
                if (g.ret.ranged & bit(index) != 0) out = out.join((try dep(c, flow, function, arg)).narrowed());
                if (g.ret.maybe & bit(index) != 0) out = out.join((try dep(c, flow, function, arg)).lowered());
            }
            return out;
        },
        .source => {
            if (try fixedClean(c, flow, function, call) or try declaredOwn(c, flow, f.file, call)) return .{};
            const decl = callee.decl.?;
            // A read into the caller's buffer returns how much it read: a count the buffer bounds.
            if (try bufferParams(c, decl) != 0 and returnsCount(c, decl)) return .{};
            if (flow.fact == .input and decodes(c, decl)) return .{ .level = if (narrow(c, f.file, call)) .data else .number };
            return .{ .level = .data };
        },
        .outside => {
            // A method gives what its receiver holds; a function outside std, or std's data
            // functions (`mem`, `fmt`, `ascii`, `unicode`, `math`, `base64`), what it is given:
            // a position or a count std finds in data is clean, an integer it decodes a number.
            if (callee.receiver) |receiver| return dep(c, flow, function, receiver);
            var data_function = false;
            if (callee.decl) |decl| if (flow.std_files.contains(decl.file.raw())) {
                if (!flow.data_files.contains(decl.file.raw())) return .{};
                if (returnsCount(c, decl)) return .{};
                data_function = true;
            };
            var out: Dep = .{};
            for (callee.args.items) |arg| out = out.join(try dep(c, flow, function, arg));
            if (data_function and decodes(c, callee.decl.?)) return if (narrow(c, f.file, call)) out else out.widened();
            // A value clamped between the program's own bounds is bounded by them.
            if (data_function and std.mem.eql(u8, c.project.models[callee.decl.?.file.raw()].declarations[callee.decl.?.index].name, "clamp") and call.ast.params.len == 3) {
                if ((try dep(c, flow, function, call.ast.params[1])).clean() and (try dep(c, flow, function, call.ast.params[2])).clean()) return .{};
            }
            return out;
        },
        .none => {
            var out: Dep = .{};
            for (callee.args.items) |arg| out = out.join(try dep(c, flow, function, arg));
            return out.lowered();
        },
    }
}

/// Whether a function's result is a count or a position: its declared result is `usize`, or
/// an optional or error union of one.
fn returnsCount(c: *Context, decl: Facts.Decl) bool {
    const tree = &c.project.files[decl.file.raw()].tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.models[decl.file.raw()].declarations[decl.index].node) orelse return false;
    const result_type = proto.ast.return_type.unwrap() orelse return false;
    return std.mem.endsWith(u8, tree.getNodeSource(result_type), "usize");
}

/// Whether a decode's spelled type (its first argument, `readInt(u16, ...)`) is at most 16 bits
/// wide: what it gives stays in a range no wider sum or product of it overflows.
fn narrow(c: *Context, file: Project.FileId, call: Ast.full.Call) bool {
    if (call.ast.params.len == 0) return false;
    const tree = &c.project.files[file.raw()].tree;
    const spelled = tree.getNodeSource(call.ast.params[0]);
    if (spelled.len < 2 or (spelled[0] != 'u' and spelled[0] != 'i')) return false;
    const bits = std.fmt.parseUnsigned(u16, spelled[1..], 10) catch return false;
    return bits <= 16;
}

/// Whether a std function decodes an integer from bytes or text: `readInt` and its forms,
/// `parseInt`, `parseUnsigned`, a reader's `takeInt`, `peekInt`, `takeVarInt`, `takeLeb128`,
/// `takeEnum`.
fn decodes(c: *Context, decl: Facts.Decl) bool {
    const name = c.project.models[decl.file.raw()].declarations[decl.index].name;
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

/// The program's call or the function outside it that a call reaches, for a sink reading its
/// arguments by the callee's parameters.
pub const Reached = struct { decl: ?Facts.Decl, args: []const Ast.Node.Index, skip: usize, std: bool, method: bool };
pub fn reached(c: *Context, flow: *Flow, file: Project.FileId, call: Ast.full.Call) Context.Error!Reached {
    const callee = try resolveCall(c, flow, file, call);
    const decl = callee.decl;
    const in_std = if (decl) |d| flow.std_files.contains(d.file.raw()) else false;
    return .{ .decl = decl, .args = callee.args.items, .skip = callee.skip, .std = in_std, .method = callee.receiver != null };
}

/// The level of what a condition reads: its comparisons' and its logic's operands, each as
/// the fact reads it (a comparison's own result is clean; what it compares is not).
pub fn conditionAt(c: *Context, flow: *Flow, file: Project.FileId, node: Ast.Node.Index) Context.Error!Level {
    const tree = &c.project.files[file.raw()].tree;
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

/// Whether a function outside the program is one of std's.
pub fn inStd(flow: *const Flow, decl: Facts.Decl) bool {
    return flow.std_files.contains(decl.file.raw());
}

/// The container a fact recognizes std's reader, file, directory and stream by.
pub fn readerType(flow: *const Flow) ?Facts.Container {
    return flow.reader;
}
pub fn directoryType(flow: *const Flow) ?Facts.Container {
    return flow.dir;
}

/// The reads in `file` the program declares its own, by their callee's token.
pub fn ownedIn(a: std.mem.Allocator, flow: *const Flow, file: Project.FileId) error{OutOfMemory}![]const Ast.TokenIndex {
    var out: std.ArrayList(Ast.TokenIndex) = .empty;
    for (flow.owned.keys()) |read| if (read.file.eql(file)) try out.append(a, read.token);
    return out.items;
}
