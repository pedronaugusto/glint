//! The danger rules that read a flow fact (Taint.zig; designs/aegis.md §7): where a value from
//! outside the program indexes, slices, bounds a loop, names a path (A009), is converted or
//! takes part in arithmetic that can fail (A010), sizes work (A012), where an error's name reaches a peer
//! (A018), and a loop on input that never lets its task be canceled (A020). A value the fact
//! holds as unknown makes its sink undecided.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Taint = @import("Taint.zig");
const Danger = @import("Danger.zig");
const Governed = @import("Governed.zig");
const Rule = @import("Rule.zig").Rule;
const Ast = std.zig.Ast;

/// A009: input that indexes, slices, bounds a loop or names a path before an aegis
/// `input.Untrusted` parser has refined it.
pub fn input(c: *Context, rule: Rule) Context.Error!void {
    const flow = try Taint.get(c, .input);
    const tree = &c.project.files[c.file.raw()].tree;
    // A read the program declares its own is listed at its escape, which is the declaration.
    for (try Taint.ownedIn(c.allocator, flow, c.file)) |token| try c.at(rule, token, "a read the program declares its own by its escape: no input starts here");
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // aegis: no-danger: the AST's node table indexes fit u32.
        if (!site(c, node)) continue;
        switch (tag) {
            // A position into input's own memory is data's to reach; an entry of the program's
            // own table a byte or a hash picks is the table's design, a number's to reach.
            .array_access => {
                const array, const index = tree.nodeData(node).node_and_node;
                const least: Taint.Level = if (try Taint.levelAt(c, flow, c.file, array) == .clean) .number else .data;
                try judged(c, rule, index, try Taint.levelAt(c, flow, c.file, index), least, "input indexes memory: a peer chooses the position; parse it into a refined type with aegis input.Untrusted");
            },
            .slice_open, .slice, .slice_sentinel => {
                const slice = tree.fullSlice(node) orelse continue;
                try sink(c, flow, rule, slice.ast.start, "input bounds a slice: a peer chooses its extent; parse it into a refined type with aegis input.Untrusted");
                if (slice.ast.end.unwrap()) |end| try sink(c, flow, rule, end, "input bounds a slice: a peer chooses its extent; parse it into a refined type with aegis input.Untrusted");
            },
            // A loop a byte bounds runs a byte's count at most: a number bounds one a peer's way.
            .for_range => if (tree.nodeData(node).node_and_opt_node[1].unwrap()) |end| try judged(c, rule, end, try Taint.levelAt(c, flow, c.file, end), .number, loop_message),
            .@"while", .while_simple, .while_cont => {
                const loop = tree.fullWhile(node) orelse continue;
                const condition = loop.ast.cond_expr;
                if (!comparison(tree.nodeTag(condition))) continue;
                const lhs, const rhs = tree.nodeData(condition).node_and_node;
                try judged(c, rule, lhs, try Taint.levelAt(c, flow, c.file, lhs), .number, loop_message);
                try judged(c, rule, rhs, try Taint.levelAt(c, flow, c.file, rhs), .number, loop_message);
            },
            else => {
                var buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buffer, node) orelse continue;
                const reached = try Taint.reached(c, flow, c.file, call);
                const decl = reached.decl orelse continue;
                const dir = Taint.directoryType(flow) orelse continue;
                if (decl.file.raw() != dir.file.raw()) continue;
                const names = try parameters(c, decl);
                for (reached.args, 0..) |arg, position| {
                    if (position >= names.len or std.mem.find(u8, names[position], "path") == null) continue;
                    try sink(c, flow, rule, arg, "input names a path: a peer chooses what file it reaches; validate it with airlock's path check as an aegis input.Untrusted parser");
                }
            },
        }
    }
}

const loop_message = "a number from input bounds a loop: a peer chooses how long it runs; parse it into a refined type with aegis input.Untrusted";

/// A010: integer conversions of input and arithmetic on a number from input, where a peer's
/// value that does not fit stops the program (a panic under the safe build every package
/// ships). Data's arithmetic stays within a byte's range of the program's own values; a
/// number (decoded, or grown by a shift or a product) is the peer's to choose. A conversion or
/// arithmetic on the program's own values is checked by that build and is no peer's to reach;
/// where the checks are off (`@setRuntimeSafety(false)`, ReleaseFast) the danger is A019's.
/// `@truncate` keeps the low bits by intent and is no conversion that fails.
pub fn integers(c: *Context, rule: Rule) Context.Error!void {
    const flow = try Taint.get(c, .input);
    const tree = &c.project.files[c.file.raw()].tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // aegis: no-danger: the AST's node table indexes fit u32.
        switch (tag) {
            // A sum, difference or product overflows on either operand; a quotient or a
            // remainder fails on its divisor (zero, or -1 under the minimum).
            .add, .mul, .assign_add, .assign_mul => {
                if (!site(c, node)) continue;
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                const level = (try Taint.levelAt(c, flow, c.file, lhs)).join(try Taint.levelAt(c, flow, c.file, rhs));
                try judged(c, rule, node, level, .number, "arithmetic on a number from input: a peer's value that overflows it stops the program; aegis int.Checked or Ranged returns the overflow");
            },
            // A difference underflows on what it takes away, a byte of input enough.
            .sub, .assign_sub => {
                if (!site(c, node)) continue;
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                const left = try Taint.levelAt(c, flow, c.file, lhs);
                const right = try Taint.levelAt(c, flow, c.file, rhs);
                const level: Taint.Level = if (right.reaches(.data) or left.reaches(.number)) .number else left.join(right);
                try judged(c, rule, node, level, .number, "a difference with input: a peer's value that underflows it stops the program; aegis int.Checked or Ranged returns the error");
            },
            .div, .mod, .assign_div, .assign_mod => {
                if (!site(c, node)) continue;
                const rhs = tree.nodeData(node).node_and_node[1];
                try judged(c, rule, node, try Taint.levelAt(c, flow, c.file, rhs), .data, "division by input: a peer's zero stops the program; aegis int.Checked returns the error");
            },
            .negation => {
                if (!site(c, node)) continue;
                try judged(c, rule, node, try Taint.levelAt(c, flow, c.file, tree.nodeData(node).node), .number, "negation of a number from input: a peer's minimum value overflows it and stops the program; aegis int.Checked returns the overflow");
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                var fallible = false;
                for ([_][]const u8{ "@intCast", "@intFromFloat", "@enumFromInt", "@fromBackingInt" }) |cast| fallible = fallible or std.mem.eql(u8, name, cast);
                if (!fallible or !site(c, node)) continue;
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, node, &buffer);
                if (args.len != 1) continue;
                try judged(c, rule, node, try Taint.levelAt(c, flow, c.file, args[0]), .data, try c.allocator.print("{s} of input: a peer's value that does not fit stops the program; aegis int.cast returns the error", .{name}));
            },
            else => {},
        }
    }
}

/// A012: work sized by a number from input without a stated limit: an allocation, a
/// container's growth or a read sized by one, and any read with `.unlimited`.
pub fn boundedWork(c: *Context, rule: Rule) Context.Error!void {
    const flow = try Taint.get(c, .input);
    const tree = &c.project.files[c.file.raw()].tree;
    const sizes = [_][]const u8{ "n", "len", "new_len", "new_n", "new_capacity", "additional_count", "num", "capacity", "count", "new_size", "size" };
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // aegis: no-danger: the AST's node table indexes fit u32.
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (!site(c, node)) continue;
        const reached = try Taint.reached(c, flow, c.file, call);
        const decl = reached.decl orelse continue;
        if (!reached.std) continue;
        const name = c.project.models[decl.file.raw()].declarations[decl.index].name;
        const from_reader = if (Taint.readerType(flow)) |r| r.file.raw() == decl.file.raw() else false;
        if (from_reader and std.mem.find(u8, name, "Unlimited") != null) {
            try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("{s}: a read with no limit, its size a peer's to choose; state the limit with aegis bounded.Limit", .{name}));
            continue;
        }
        for (call.ast.params) |arg| if (from_reader and tree.nodeTag(arg) == .enum_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(arg)), "unlimited")) {
            try c.at(rule, tree.nodeMainToken(arg), try c.allocator.print("{s}(.unlimited): a read with no limit, its size a peer's to choose; state the limit with aegis bounded.Limit", .{name}));
        };
        const names = try parameters(c, decl);
        for (reached.args, 0..) |arg, position| {
            if (position >= names.len) break;
            var sized = false;
            for (sizes) |size| sized = sized or std.mem.eql(u8, names[position], size);
            if (!sized) continue;
            try judged(c, rule, arg, try Taint.levelAt(c, flow, c.file, arg), .number, try c.allocator.print("{s} sized by a number from input: a peer chooses how much memory or work it takes; bound it with aegis bounded.Limit or Budget first", .{name}));
        }
    }
}

/// A018: an error's name written where a peer reads it: internal text crossing to the peer.
pub fn diagnostics(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.files[c.file.raw()].tree;
    var named = false;
    for (tree.nodes.items(.tag), 0..) |tag, i| switch (tag) {
        .builtin_call_two, .builtin_call_two_comma => {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // aegis: no-danger: the AST's node table indexes fit u32.
            named = named or std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@errorName");
        },
        else => {},
    };
    if (!named) return;
    const flow = try Taint.get(c, .peer);
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // aegis: no-danger: the AST's node table indexes fit u32.
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access or !site(c, node)) continue;
        var carries = false;
        for (call.ast.params) |arg| carries = carries or errorName(tree, arg);
        if (!carries) continue;
        const writer = tree.nodeData(call.ast.fn_expr).node_and_token[0];
        try judged(c, rule, node, try Taint.levelAt(c, flow, c.file, writer), .data, "an error's name written to a peer: internal text crossing to the peer; aegis err.PublicText says what the peer may read");
    }
}

/// Whether an argument is `@errorName(...)`, or a tuple or struct literal holding one.
fn errorName(tree: *const Ast, node: Ast.Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@errorName"),
        else => {},
    }
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, node)) |literal| for (literal.ast.fields) |field| if (errorName(tree, field)) return true;
    if (tree.fullArrayInit(&buffer, node)) |literal| for (literal.ast.elements) |element| if (errorName(tree, element)) return true;
    return false;
}

/// A020: a function given an `Io` whose loop runs unbounded (`while (true)`) or as long as input
/// says, and whose body gives that `Io` to nothing: no `checkCancel`, no cancelable call, so
/// the task cannot be canceled while it runs.
pub fn cancellation(c: *Context, rule: Rule) Context.Error!void {
    const io = (try Governed.declarations(c, "std", "Io")) orelse return;
    var container: ?Facts.Container = null;
    for (io) |decl| {
        const value = try c.facts.declaration((try c.facts.origin(decl)) orelse decl);
        if (value == .container) container = value.container;
    }
    const io_type = container orelse return;
    const flow = try Taint.get(c, .input);
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    for (model.declarations, 0..) |decl, d| {
        if (decl.kind != .parameter or c.inTest(decl.token)) continue;
        const value = try c.facts.resolve(c.file, decl.node);
        const held = switch (value) {
            .instance, .container => |k| k,
            else => continue,
        };
        if (held.file.raw() != io_type.file.raw() or held.scope != io_type.scope) continue;
        for (tree.nodes.items(.tag), 0..) |_, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // aegis: no-danger: the AST's node table indexes fit u32.
            const loop = tree.fullWhile(node) orelse continue;
            if (!within(c, node, decl.node) or !site(c, node)) continue;
            const cond = loop.ast.cond_expr;
            const unbounded = tree.nodeTag(cond) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(cond)), "true");
            var by_input = false;
            if (!unbounded and comparison(tree.nodeTag(cond))) {
                const lhs, const rhs = tree.nodeData(cond).node_and_node;
                by_input = (try Taint.levelAt(c, flow, c.file, lhs)).join(try Taint.levelAt(c, flow, c.file, rhs)).reaches(.number);
            }
            if (!unbounded and !by_input) continue;
            if (gives(c, loop.ast.then_expr, @intCast(d))) continue; // aegis: no-danger: a file's declaration table indexes fit u32.
            try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("a loop {s} that gives '{s}' to nothing: no cancellation point, so its task runs until the loop ends; call {s}.checkCancel() or a cancelable operation in it", .{ if (unbounded) "with no bound" else "bound by input", decl.name, decl.name }));
        }
    }
}

/// The `fn_decl` holding `node`.
fn functionOf(c: *Context, node: Ast.Node.Index) ?Ast.Node.Index {
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) { // safe: a node index indexes its own tree's parent table.
        if (tree.nodeTag(parent) == .fn_decl) return parent;
    }
    return null;
}

/// Whether `node` is in the body of the function whose parameter `param` is.
fn within(c: *Context, node: Ast.Node.Index, param: Ast.Node.Index) bool {
    const a = functionOf(c, node) orelse return false;
    const b = functionOf(c, param) orelse return false;
    return a == b;
}

/// Whether `body` names the declaration `d` anywhere: a call given it, a method called on it.
fn gives(c: *Context, body: Ast.Node.Index, d: u32) bool {
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // aegis: no-danger: the AST's node table indexes fit u32.
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        const ref = model.reference(node) orelse continue;
        if (ref.declaration == d) return true;
    }
    return false;
}

/// A sink in the checked file: a finding where the value is input, undecided where the fact
/// cannot tell.
fn sink(c: *Context, flow: *Taint.Flow, rule: Rule, node: Ast.Node.Index, comptime message: []const u8) Context.Error!void {
    try judged(c, rule, node, try Taint.levelAt(c, flow, c.file, node), .data, message);
}

/// A finding where the value is input at `least` (data, or only a number), undecided where the
/// fact cannot tell.
fn judged(c: *Context, rule: Rule, node: Ast.Node.Index, level: Taint.Level, least: Taint.Level, message: []const u8) Context.Error!void {
    const tree = &c.project.files[c.file.raw()].tree;
    if (level == .unknown) return c.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "a value that passed through a call that does not resolve may be input here");
    if (level.reaches(least)) try c.at(rule, tree.nodeMainToken(node), message);
}

/// Production code that runs with the program.
fn site(c: *Context, node: Ast.Node.Index) bool {
    const tree = &c.project.files[c.file.raw()].tree;
    return !c.inTest(tree.nodeMainToken(node)) and Danger.atRuntime(c, node);
}

fn comparison(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .less_than, .less_or_equal, .greater_than, .greater_or_equal, .equal_equal, .bang_equal => true,
        else => false,
    };
}

/// A function's parameter names in order, the receiver first.
fn parameters(c: *Context, decl: Facts.Decl) Context.Error![]const []const u8 {
    const tree = &c.project.files[decl.file.raw()].tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.models[decl.file.raw()].declarations[decl.index].node) orelse return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    var it = proto.iterate(tree);
    while (it.next()) |param| try names.append(c.allocator, if (param.name_token) |token| tree.tokenSlice(token) else "");
    return names.items;
}
