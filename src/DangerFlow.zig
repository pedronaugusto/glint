//! The danger rules that read a flow fact (Taint.zig; designs/aegis.md §7): where a value from
//! outside the program indexes, slices, bounds a loop, names a path (A009), is converted or
//! takes part in arithmetic that can fail (A010), sizes work (A012), where an error's name reaches a peer
//! (A018), and a loop on input that never lets its task be canceled (A020). A value the fact
//! holds as unknown makes its sink undecided.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Taint = @import("Taint.zig");
const Program = @import("Program.zig");
const Range = @import("Range.zig");
const Danger = @import("Danger.zig");
const Governed = @import("Governed.zig");
const Rule = @import("Rule.zig").Rule;
const Ast = std.zig.Ast;

/// A009: input that indexes, slices, bounds a loop or names a path before an aegis
/// `input.Untrusted` parser has refined it.
pub fn input(c: *Context, rule: Rule) Context.Error!void {
    const flow = try Taint.get(c, .input);
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (!site(c, node)) continue;
        switch (tag) {
            // A position input reaches is a finding unless it is shown within the memory: a
            // table the program sized to the index's range (`[256]` by a byte) holds every
            // value, a shorter or unknown one not.
            .array_access => {
                const array, const index = tree.nodeData(node).node_and_node;
                if (try Range.within(c, c.file, index, array, false)) continue;
                try judged(c, flow, rule, index, try Taint.levelAt(c, flow, c.file, index), .data, "input indexes memory: a peer chooses the position; parse it into a refined type with aegis input.Untrusted");
            },
            .slice_open, .slice, .slice_sentinel => {
                const slice = tree.fullSlice(node) orelse continue;
                // A bound the program checked against the memory's length is its own. With an
                // end, the start must be at most it, which puts the start within the memory
                // wherever the end is; two bounds each within the memory may still be out of
                // order (`b[i..n]`), and a peer choosing either chooses that.
                const extent = "input bounds a slice: a peer chooses its extent; parse it into a refined type with aegis input.Untrusted";
                if (slice.ast.end.unwrap()) |end| {
                    const end_within = try Range.within(c, c.file, end, slice.ast.sliced, true);
                    if (!end_within) try sink(c, flow, rule, end, extent);
                    if (!try Range.notAfter(c, c.file, slice.ast.start, end, slice.ast.sliced)) {
                        try sink(c, flow, rule, slice.ast.start, extent);
                        if (end_within) try sink(c, flow, rule, end, extent);
                    }
                } else if (!try Range.within(c, c.file, slice.ast.start, slice.ast.sliced, true)) try sink(c, flow, rule, slice.ast.start, extent);
            },
            // A pointer moved by input reaches the address a peer chooses: no length checks it,
            // unless its offset is shown within the memory it came from (`x.ptr + o`, `o < x.len`).
            .add, .sub, .add_wrap, .sub_wrap, .assign_add, .assign_sub, .assign_add_wrap, .assign_sub_wrap => {
                if (!try Range.addresses(c, c.file, node) or try Range.movedWithin(c, c.file, node)) continue;
                const offset = tree.nodeData(node).node_and_node[1];
                try judged(c, flow, rule, offset, try ranged(c, flow, offset), .data, "input moves a pointer: a peer chooses the address it reaches; parse it into a refined type with aegis input.Untrusted");
            },
            // A loop a byte bounds runs a byte's count at most: a number bounds one a peer's way.
            .for_range => if (tree.nodeData(node).node_and_opt_node[1].unwrap()) |end| {
                const parent = c.project.at(c.file).model.parentOf(node) orelse continue;
                const loop = tree.fullFor(parent) orelse continue;
                if (try consumes(c, flow, loop.ast.then_expr)) continue;
                try judged(c, flow, rule, end, try passesBy(c, flow, end), .number, loop_message);
            },
            // Each comparison of the condition, joined by `and`, `or` and `!` as it may be.
            .@"while", .while_simple, .while_cont => {
                const loop = tree.fullWhile(node) orelse continue;
                if (try consumes(c, flow, loop.ast.then_expr)) continue;
                var compared: std.ArrayList(Ast.Node.Index) = .empty;
                try comparisons(c, loop.ast.cond_expr, &compared);
                for (compared.items) |condition| {
                    if (clears(c, condition, loop.ast.then_expr)) continue;
                    const lhs, const rhs = tree.nodeData(condition).node_and_node;
                    const left = try passesBy(c, flow, lhs);
                    const right = try passesBy(c, flow, rhs);
                    // A counter the loop steps toward a peer's bound is the peer's by that bound
                    // alone: the bound is the finding.
                    const skip_left = right.reaches(.number) and assignedIn(c, node, lhs);
                    const skip_right = !skip_left and left.reaches(.number) and assignedIn(c, node, rhs);
                    if (!skip_left) try judged(c, flow, rule, lhs, left, .number, loop_message);
                    if (!skip_right) try judged(c, flow, rule, rhs, right, .number, loop_message);
                }
            },
            // A table trusts its own ids to name its entries (Range.ownId): one made from an
            // integer is a finding unless it counts the table's entries, whatever the
            // integer's fact. Where the type it makes does not resolve and the program declares
            // such ids, it may be one.
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                if (!std.mem.eql(u8, name, "@fromBackingInt") and !std.mem.eql(u8, name, "@enumFromInt")) continue;
                switch (try Range.madeId(c, c.file, node)) {
                    .other => {},
                    .unknown => if (try Range.declaresIds(c)) try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "a conversion whose type does not resolve may make a table's own id"),
                    .id => |owner| if (!try Range.countsEntries(c, c.file, node, owner)) try c.at(rule, tree.nodeMainToken(node), "a table's own id made from an integer: its table trusts the id to name an entry; make ids only by counting its entries (`for (t, 0..) |_, i|`, `t.len - 1` after an append)"),
                }
            },
            else => {
                var buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buffer, node) orelse continue;
                const reached = try Taint.reached(c, flow, c.file, call);
                const decl = reached.decl orelse continue;
                const dir = Taint.directoryType(flow) orelse continue;
                if (decl.file != dir.file) continue;
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

/// A010: integer conversions of input and arithmetic on input, where a peer's value that does
/// not fit stops the program (a panic under the safe build every package ships): each one
/// unless its operands' ranges show it fits (Range.zig), a byte's as much as a decoded
/// number's. A conversion or arithmetic on the program's own values is checked by that build
/// and is no peer's to reach;
/// where the checks are off (`@setRuntimeSafety(false)`, ReleaseFast) the danger is A019's.
/// `@truncate` keeps the low bits by intent and is no conversion that fails. Float arithmetic
/// gives an infinity or a NaN where an integer's would stop, so it is none of A010's.
pub fn integers(c: *Context, rule: Rule) Context.Error!void {
    const flow = try Taint.get(c, .input);
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tag) {
            // A sum, difference or product overflows on either operand; a quotient or a
            // remainder fails on its divisor (zero, or -1 under the minimum).
            .add, .mul, .assign_add, .assign_mul => {
                if (!site(c, node) or try Range.floating(c, c.file, node)) continue;
                // An address moved by input reaches memory, A009's; no overflow check stops it.
                if (tag == .add and try Range.addresses(c, c.file, node)) continue;
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                const level = (try Taint.levelAt(c, flow, c.file, lhs)).join(try Taint.levelAt(c, flow, c.file, rhs));
                if (level.reaches(.data) and try Range.fits(c, c.file, node)) continue;
                try judged(c, flow, rule, node, level, .data, "arithmetic on a number from input: a peer's value that overflows it stops the program; aegis int.Checked or Ranged returns the overflow");
            },
            // A difference underflows on what it takes away, a byte of input enough.
            .sub, .assign_sub => {
                if (!site(c, node) or try Range.floating(c, c.file, node)) continue;
                if (tag == .sub and try Range.addresses(c, c.file, node)) continue;
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                const level = (try Taint.levelAt(c, flow, c.file, lhs)).join(try Taint.levelAt(c, flow, c.file, rhs));
                if (level.reaches(.data) and try Range.fits(c, c.file, node)) continue;
                try judged(c, flow, rule, node, level, .data, "a difference with input: a peer's value that underflows it stops the program; aegis int.Checked or Ranged returns the error");
            },
            .div, .mod, .assign_div, .assign_mod => {
                if (!site(c, node) or try Range.floating(c, c.file, node)) continue;
                const rhs = tree.nodeData(node).node_and_node[1];
                if (try Range.nonzero(c, c.file, rhs)) continue;
                var level = try Taint.levelAt(c, flow, c.file, rhs);
                // The length of memory a peer sized is the peer's to make zero (`x % buf.len`
                // over an empty read), though a length is no peer's number.
                var divisor = rhs;
                while (tree.nodeTag(divisor) == .grouped_expression) divisor = tree.nodeData(divisor).node_and_token[0];
                if (tree.nodeTag(divisor) == .field_access and std.mem.eql(u8, tree.tokenSlice(tree.nodeData(divisor).node_and_token[1]), "len")) {
                    if ((try Taint.levelAt(c, flow, c.file, tree.nodeData(divisor).node_and_token[0])).reaches(.data)) level = level.join(.data);
                }
                try judged(c, flow, rule, node, level, .data, "division by input: a peer's zero stops the program; aegis int.Checked returns the error");
            },
            .negation => {
                if (!site(c, node) or try Range.negates(c, c.file, tree.nodeData(node).node)) continue;
                try judged(c, flow, rule, node, try Taint.levelAt(c, flow, c.file, tree.nodeData(node).node), .data, "negation of a number from input: a peer's minimum value overflows it and stops the program; aegis int.Checked returns the overflow");
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                var fallible = false;
                for ([_][]const u8{ "@intCast", "@intFromFloat", "@enumFromInt", "@fromBackingInt" }) |cast| fallible = fallible or std.mem.eql(u8, name, cast);
                if (!fallible or !site(c, node)) continue;
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, node, &buffer);
                if (args.len != 1) continue;
                const level = try Taint.levelAt(c, flow, c.file, args[0]);
                if (level.reaches(.data) and std.mem.eql(u8, name, "@intCast") and try Range.converts(c, c.file, node, args[0])) continue;
                // A type whose values are each of its backing integers, or the operand's
                // range among the tags it names, holds whatever the operand is.
                if (level.reaches(.data) and !std.mem.eql(u8, name, "@intCast") and !std.mem.eql(u8, name, "@intFromFloat") and try Range.fills(c, c.file, node, args[0])) continue;
                try judged(c, flow, rule, node, level, .data, try c.allocator.print("{s} of input: a peer's value that does not fit stops the program; aegis int.cast returns the error", .{name}));
            },
            else => {},
        }
    }
}

/// A012: work sized by a number from input without a stated limit: an allocation, a
/// container's growth or a read sized by one, and any read with `.unlimited`.
pub fn boundedWork(c: *Context, rule: Rule) Context.Error!void {
    const flow = try Taint.get(c, .input);
    const tree = &c.project.at(c.file).file.tree;
    const sizes = [_][]const u8{ "n", "len", "new_len", "new_n", "new_capacity", "additional_count", "num", "capacity", "count", "new_size", "size" };
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (!site(c, node)) continue;
        const reached = try Taint.reached(c, flow, c.file, call);
        const decl = reached.decl orelse continue;
        if (!reached.std) continue;
        const name = c.project.at(decl.file).model.declarations[@backingInt(decl.index)].name;
        const from_reader = if (Taint.readerType(flow)) |r| r.file == decl.file else false;
        // A reader over the program's own bytes (`Reader.fixed`) reads no peer's size.
        const own = from_reader and tree.nodeTag(call.ast.fn_expr) == .field_access and try Taint.fixedBytes(c, flow, c.file, tree.nodeData(call.ast.fn_expr).node_and_token[0]) != null;
        if (from_reader and !own and std.mem.find(u8, name, "Unlimited") != null) {
            try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("{s}: a read with no limit, its size a peer's to choose; state the limit with aegis bounded.Limit", .{name}));
            continue;
        }
        for (call.ast.params) |arg| if (from_reader and !own and tree.nodeTag(arg) == .enum_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(arg)), "unlimited")) {
            try c.at(rule, tree.nodeMainToken(arg), try c.allocator.print("{s}(.unlimited): a read with no limit, its size a peer's to choose; state the limit with aegis bounded.Limit", .{name}));
        };
        const names = try parameters(c, decl);
        // A fixed reader's take, peek or discard views or skips bytes the program already
        // holds and fails past them: no work a peer sizes, unless the read allocates.
        if (own and !try allocates(c, decl)) continue;
        for (reached.args, 0..) |arg, position| {
            if (position >= names.len) break;
            var sized = false;
            for (sizes) |size| sized = sized or std.mem.eql(u8, names[position], size);
            if (!sized) continue;
            // A size checked against the program's own limit (`if (size > max) return`) is
            // bounded by it.
            if (try capped(c, flow, arg)) continue;
            // A size the callee only moves a position by (`Reader.toss`) takes no work.
            if (try constant(c, decl, position)) continue;
            try judged(c, flow, rule, arg, try ranged(c, flow, arg), .number, try c.allocator.print("{s} sized by a number from input: a peer chooses how much memory or work it takes; bound it with aegis bounded.Limit or Budget first", .{name}));
        }
    }
}

/// A018: an error's name written where a peer reads it: internal text crossing to the peer.
pub fn diagnostics(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    var named = false;
    for (tree.nodes.items(.tag), 0..) |tag, i| switch (tag) {
        .builtin_call_two, .builtin_call_two_comma => {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            named = named or std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@errorName");
        },
        else => {},
    };
    if (!named) return;
    const flow = try Taint.get(c, .peer);
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access or !site(c, node)) continue;
        var carries = false;
        for (call.ast.params) |arg| carries = carries or errorName(tree, arg);
        if (!carries) continue;
        const writer = tree.nodeData(call.ast.fn_expr).node_and_token[0];
        try judged(c, null, rule, node, try Taint.levelAt(c, flow, c.file, writer), .data, "an error's name written to a peer: internal text crossing to the peer; aegis err.PublicText says what the peer may read");
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
/// says, and whose body gives that `Io` to nothing: no `checkCancel`, no cancelable call, no
/// read through a reader (whose refill is one), so the task cannot be canceled while it runs.
pub fn cancellation(c: *Context, rule: Rule) Context.Error!void {
    const io = (try Governed.declarations(c, "std", "Io")) orelse return;
    var container: ?Facts.Container = null;
    for (io) |decl| {
        const value = try c.facts.declaration((try c.facts.origin(decl)) orelse decl);
        if (value == .container) container = value.container;
    }
    const io_type = container orelse return;
    const flow = try Taint.get(c, .input);
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (model.declarations) |decl| {
        if (decl.kind != .parameter or c.inTest(decl.token)) continue;
        const value = try c.facts.resolve(c.file, decl.node);
        const held = switch (value) {
            .instance, .container => |k| k,
            else => continue,
        };
        if (held.file != io_type.file or held.scope != io_type.scope) continue;
        for (tree.nodes.items(.tag), 0..) |_, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const loop = tree.fullWhile(node) orelse continue;
            if (!within(c, node, decl.node) or !site(c, node)) continue;
            const cond = loop.ast.cond_expr;
            const unbounded = tree.nodeTag(cond) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(cond)), "true");
            var by_input = false;
            if (!unbounded and comparison(tree.nodeTag(cond))) {
                const lhs, const rhs = tree.nodeData(cond).node_and_node;
                by_input = (try passesBy(c, flow, lhs)).join(try passesBy(c, flow, rhs)).reaches(.number);
            }
            if (!unbounded and !by_input) continue;
            if (try cancels(c, c.file, loop.ast.then_expr, 0)) continue;
            try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("a loop {s} with no cancellation point: nothing it calls returns error.Canceled to it, so its task runs until the loop ends; call {s}.checkCancel() or a cancelable operation in it and pass the error on", .{ if (unbounded) "with no bound" else "bound by input", decl.name }));
        }
    }
}

/// Whether a body reaches a cancellation point on every pass: a call that can return
/// `error.Canceled` and passes it on (`passedOn`), on no path some pass skips (`always`), but
/// in the loop judged, behind one of two periodic forms (`periodic`). A function of the project
/// can return it where its body reaches one so; another (std's `checkCancel`, an `Io`
/// operation's `Cancelable`) by its declared error set. A call is none for being given an `Io`
/// (`Clock.now(io)` cannot cancel), nor for its name. A callee chosen per target (`const wait =
/// if (windows) waitWindows else waitPosix`, or a method of a type so chosen) is one where every
/// choice is; a pointer to a function, or a vtable's, is none.
fn cancels(c: *Context, file: Project.FileId, body: Ast.Node.Index, depth: u8) Context.Error!bool {
    if (depth > 16) return false;
    const tree = &c.project.at(file).file.tree;
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (!try passedOn(c, file, node)) continue;
        if (!always(c, file, node, body, depth == 0)) continue;
        const callee = try c.facts.resolve(file, call.ast.fn_expr);
        const choices: []const Facts.Value = if (callee == .alternatives) callee.alternatives else &.{callee};
        const every = for (choices) |choice| {
            if (choice != .function or !try callCancels(c, choice.function, depth)) break false;
        } else true;
        if (every) return true;
    }
    return false;
}

const Cancels = struct { map: std.AutoHashMapUnmanaged(Facts.Decl, bool) = .empty };

/// Whether a call of `callee` is a cancellation point: a function of the program where its body
/// reaches one, whatever its error set declares (`error{Canceled}!void {}` cancels nothing);
/// another where its declared error set holds `error.Canceled`.
fn callCancels(c: *Context, callee: Facts.Decl, depth: u8) Context.Error!bool {
    const callee_tree = &c.project.at(callee.file).file.tree;
    const callee_model = &c.project.at(callee.file).model;
    if (try Program.owns(c, callee.file)) if (callee_model.parentOf(callee_model.declarations[@backingInt(callee.index)].node)) |parent| if (callee_tree.nodeTag(parent) == .fn_decl) {
        const memo = try c.facts.memo(Cancels);
        if (memo.map.get(callee)) |known| return known;
        // A function that reaches itself is no cancellation point while it is being read.
        try memo.map.put(c.allocator, callee, false);
        const out = try cancels(c, callee.file, callee_tree.nodeData(parent).node_and_node[1], depth + 1);
        try memo.map.put(c.allocator, callee, out);
        return out;
    };
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = callee_tree.fullFnProto(&proto_buffer, callee_model.declarations[@backingInt(callee.index)].node) orelse return false;
    return canceling(c, callee.file, proto.ast.return_type.unwrap() orelse return false, 0);
}

/// Whether a call passes on the `error.Canceled` it returns: under a `try`, returned, or caught
/// (`catch`, or an `if`'s `else |err|`) by a handler whose path for it (`handled`) returns it.
/// A handler that drops it (`catch {}`, `error.Canceled => continue`), ends the loop without it
/// (`catch break`, `catch return`), turns it into a value or another error (`catch return
/// false`, `return isFatal(e)`) or re-arms it for a later point (`io.recancel()`) lets the
/// task run on.
fn passedOn(c: *Context, file: Project.FileId, call: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = call;
    while (model.parentOf(at)) |parent| : (at = parent) switch (tree.nodeTag(parent)) {
        .grouped_expression => {},
        .@"try", .@"return" => return true,
        .@"catch" => {
            const caught, const handler = tree.nodeData(parent).node_and_node;
            if (caught != at) return false;
            const catch_token = tree.nodeMainToken(parent);
            return handled(c, file, parent, handler, if (tree.tokenTag(catch_token + 1) == .pipe) catch_token + 2 else null);
        },
        // `if (call) |v| ... else |err| ...`: the else branch is its handler.
        .@"if", .if_simple => {
            const branch = tree.fullIf(parent).?;
            if (branch.ast.cond_expr != at) return false;
            const capture = branch.error_token orelse return false;
            return handled(c, file, parent, branch.ast.else_expr.unwrap() orelse return false, capture);
        },
        else => return false,
    };
    return false;
}

/// Whether the path `error.Canceled` takes through a call's handler passes it on: the prong
/// it takes where the handler switches on it (the one naming it, or `else`), or the whole
/// handler, either returns it itself (`return e`, `return error.Canceled`, as its last
/// statement with nothing before it that may leave) from a function whose result is an error
/// union, or is it as its value where the whole (`whole`, the `catch` or `if`) is returned or
/// tried (`return f() catch |e| switch (e) { error.Canceled => error.Canceled, ... }`).
fn handled(c: *Context, file: Project.FileId, whole: Ast.Node.Index, handler: Ast.Node.Index, capture: ?Ast.TokenIndex) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const prong: Ast.Node.Index, const payload: ?Ast.TokenIndex = taken: {
        const name = capture orelse break :taken .{ handler, null };
        const chosen = tree.fullSwitch(handler) orelse break :taken .{ handler, null };
        if (tree.nodeTag(chosen.ast.condition) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(chosen.ast.condition)), tree.tokenSlice(name))) break :taken .{ handler, null };
        var otherwise: ?Ast.full.SwitchCase = null;
        for (chosen.ast.cases) |case_node| {
            const case = tree.fullSwitchCase(case_node).?;
            if (case.ast.values.len == 0) otherwise = case;
            for (case.ast.values) |value| if (namesCanceled(tree, value)) break :taken .{ case.ast.target_expr, case.payload_token };
        }
        const chosen_prong = otherwise orelse return false;
        break :taken .{ chosen_prong.ast.target_expr, chosen_prong.payload_token };
    };
    const names = [_]?Ast.TokenIndex{ capture, payload };
    if (try returnsIt(c, file, prong, &names)) return true;
    // The prong's value is the error, and the whole is returned or tried.
    if (!isIt(tree, prong, &names)) return false;
    var at = whole;
    while (model.parentOf(at)) |parent| : (at = parent) switch (tree.nodeTag(parent)) {
        .grouped_expression => {},
        .@"try" => return true,
        .@"return" => return try errorResult(c, file, parent),
        else => return false,
    };
    return false;
}

/// Whether a handler's path returns what it caught itself: `return x` with `x` the error
/// (`isIt`), alone or as a block's last statement with nothing before it that may leave, from
/// a function whose result is an error union, where the error goes on as one.
fn returnsIt(c: *Context, file: Project.FileId, path: Ast.Node.Index, names: []const ?Ast.TokenIndex) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    var at = path;
    while (tree.nodeTag(at) == .grouped_expression) at = tree.nodeData(at).node_and_token[0];
    switch (tree.nodeTag(at)) {
        .@"return" => {
            const value = tree.nodeData(at).opt_node.unwrap() orelse return false;
            return isIt(tree, value, names) and try errorResult(c, file, at);
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, at).?;
            if (statements.len == 0) return false;
            for (statements[0 .. statements.len - 1]) |statement| if (leavesIn(tree, statement)) return false;
            return try returnsIt(c, file, statements[statements.len - 1], names);
        },
        else => return false,
    }
}

/// Whether a value is the error caught: a name it was captured by, or `error.Canceled`.
fn isIt(tree: *const Ast, node: Ast.Node.Index, names: []const ?Ast.TokenIndex) bool {
    var value = node;
    while (tree.nodeTag(value) == .grouped_expression) value = tree.nodeData(value).node_and_token[0];
    return switch (tree.nodeTag(value)) {
        .error_value => namesCanceled(tree, value),
        .identifier => for (names) |name| {
            const n = name orelse continue;
            if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), tree.tokenSlice(n))) break true;
        } else false,
        else => false,
    };
}

/// Whether the function holding `node` returns an error union (`!T`, `E!T`) whose payload holds
/// no error (`anyerror`, an error set, or one behind an optional or pointer could take it as a
/// value): what it returns of an error type goes on as an error.
fn errorResult(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = node;
    const function = while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl) break parent;
    } else return false;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(function).node_and_node[0]) orelse return false;
    const result = proto.ast.return_type.unwrap() orelse return false;
    if (tree.nodeTag(result) == .error_union) return holdsNoError(try c.facts.resolve(file, tree.nodeData(result).node_and_node[1]));
    const before = tree.firstToken(result);
    if (before == 0 or tree.tokenTag(before - 1) != .bang) return false;
    return holdsNoError(try c.facts.resolve(file, result));
}

/// Whether a type is known to hold no error value: a primitive other than `anyerror`, a
/// struct, enum or union, or memory or an optional of one.
fn holdsNoError(t: Facts.Value) bool {
    return switch (t) {
        .primitive => |name| !std.mem.eql(u8, name, "anyerror"),
        .container => true,
        .pointer, .array, .optional => |inner| holdsNoError(inner.*),
        else => false,
    };
}

/// Whether `node` runs on every pass of the body `body` (a loop's, or a function's): on no
/// branch, prong, inner loop or right side of an `and`, `or`, `orelse` or `catch`, and after no
/// statement that may end the pass while what runs it goes on: in a function's body any that may
/// leave it (`leavesIn`), in a loop's one that may skip to the next pass (`skipsIn`), as a
/// `return` or `try` there ends the loop too. Where `periodic`, a branch in one of the two
/// periodic forms (`periodic`) runs on a pass in turn.
fn always(c: *Context, file: Project.FileId, node: Ast.Node.Index, body: Ast.Node.Index, every_so_often: bool) bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const function = if (model.parentOf(body)) |holder| tree.nodeTag(holder) == .fn_decl else true;
    var at = node;
    while (at != body) {
        const parent = model.parentOf(at) orelse return false;
        switch (tree.nodeTag(parent)) {
            .bool_and, .bool_or, .@"orelse", .@"catch" => if (tree.nodeData(parent).node_and_node[0] != at) return false,
            .@"switch", .switch_comma => if (tree.nodeData(parent).node_and_extra[0] != at) return false,
            .fn_decl, .@"defer", .@"errdefer" => return false,
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                var buffer: [2]Ast.Node.Index = undefined;
                for (tree.blockStatements(&buffer, parent).?) |statement| {
                    if (statement == at) break;
                    if (if (function) leavesIn(tree, statement) else skipsIn(tree, statement)) return false;
                }
            },
            else => if (tree.fullIf(parent)) |branch| {
                if (branch.ast.cond_expr != at and !(every_so_often and at == branch.ast.then_expr and periodic(c, file, branch, body))) return false;
            } else if (tree.fullWhile(parent)) |loop| {
                if (loop.ast.cond_expr != at) return false;
            } else if (tree.fullFor(parent)) |loop| {
                if (std.mem.findScalar(Ast.Node.Index, loop.ast.inputs, at) == null) return false;
            },
        }
        at = parent;
    }
    return true;
}

/// Whether a branch in a loop's body runs every so many passes: `if (x % k == 0)` with `k` a
/// constant other than zero and `x` stepped by one every pass, or a countdown `if (x == 0)`
/// that sets `x` to a constant other than zero on every path through the branch, with `x`
/// stepped down every pass. Any other condition may hold once, or never.
fn periodic(c: *Context, file: Project.FileId, branch: Ast.full.If, body: Ast.Node.Index) bool {
    const tree = &c.project.at(file).file.tree;
    var condition = branch.ast.cond_expr;
    while (tree.nodeTag(condition) == .grouped_expression) condition = tree.nodeData(condition).node_and_token[0];
    if (tree.nodeTag(condition) != .equal_equal) return false;
    const lhs, const rhs = tree.nodeData(condition).node_and_node;
    const compared = if (isZero(tree, rhs)) lhs else if (isZero(tree, lhs)) rhs else return false;
    var value = compared;
    while (tree.nodeTag(value) == .grouped_expression) value = tree.nodeData(value).node_and_token[0];
    if (tree.nodeTag(value) == .mod) {
        const counter, const by = tree.nodeData(value).node_and_node;
        if (tree.nodeTag(counter) != .identifier or tree.nodeTag(by) != .number_literal or isZero(tree, by)) return false;
        return stepped(c, file, counter, body, .assign_add, null);
    }
    if (tree.nodeTag(value) != .identifier) return false;
    return stepped(c, file, value, body, .assign_sub, branch.ast.then_expr);
}

/// Whether `counter` is stepped by `step` (`+= 1`, `-= 1`) every pass of the loop whose body is
/// `body`, by its continue expression or a statement on every pass, and nothing else in the
/// loop assigns it but, where `reset` is given, a constant other than zero set on every path
/// through that branch.
fn stepped(c: *Context, file: Project.FileId, counter: Ast.Node.Index, body: Ast.Node.Index, step: Ast.Node.Tag, reset: ?Ast.Node.Index) bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const declared = (model.reference(counter) orelse return false).declaration orelse return false;
    const loop_node = model.parentOf(body) orelse return false;
    const cont: ?Ast.Node.Index = if (tree.fullWhile(loop_node)) |loop| loop.ast.cont_expr.unwrap() else null;
    var steps = false;
    var resets = false;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tag) {
            .assign, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat => {},
            else => continue,
        }
        const token = tree.nodeMainToken(node);
        if (token < tree.firstToken(loop_node) or token > tree.lastToken(loop_node)) continue;
        const target, const value = tree.nodeData(node).node_and_node;
        if (tree.nodeTag(target) != .identifier) continue;
        if ((model.reference(target) orelse continue).declaration != declared) continue;
        const one = tree.nodeTag(value) == .number_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "1");
        if (tag == step and one and (node == cont or always(c, file, node, body, false))) {
            if (steps) return false;
            steps = true;
            continue;
        }
        if (reset) |branch| if (tag == .assign and tree.nodeTag(value) == .number_literal and !isZero(tree, value) and always(c, file, node, branch, false)) {
            resets = true;
            continue;
        };
        return false;
    }
    return steps and (reset == null or resets);
}

fn isZero(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .number_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "0");
}

fn namesCanceled(tree: *const Ast, node: Ast.Node.Index) bool {
    for (tree.firstToken(node)..tree.lastToken(node) + 1) |token| {
        if (tree.tokenTag(@intCast(token)) == .identifier and std.mem.eql(u8, tree.tokenSlice(@intCast(token)), "Canceled")) return true;
    }
    return false;
}

/// Whether a result type's error set holds `error.Canceled`: a set literal naming it, a merge
/// with one that does, or a declaration whose value is such a set (`Io.Cancelable`).
fn canceling(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!bool {
    if (depth > 8) return false;
    const tree = &c.project.at(file).file.tree;
    switch (tree.nodeTag(node)) {
        .error_union => return canceling(c, file, tree.nodeData(node).node_and_node[0], depth + 1),
        .merge_error_sets => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return try canceling(c, file, lhs, depth + 1) or try canceling(c, file, rhs, depth + 1);
        },
        .grouped_expression => return canceling(c, file, tree.nodeData(node).node_and_token[0], depth + 1),
        .error_set_decl => {
            for (tree.firstToken(node)..tree.lastToken(node) + 1) |token| {
                if (tree.tokenTag(@intCast(token)) == .identifier and std.mem.eql(u8, tree.tokenSlice(@intCast(token)), "Canceled")) return true;
            }
            return false;
        },
        .identifier, .field_access => {
            const decl: Facts.Decl = if (tree.nodeTag(node) == .identifier) .{ .file = file, .index = ((c.project.at(file).model.reference(node) orelse return false).declaration orelse return false) } else (try c.facts.definition(file, node)) orelse return false;
            const declared = &c.project.at(decl.file).file.tree;
            const variable = declared.fullVarDecl(c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return false;
            return canceling(c, decl.file, variable.ast.init_node.unwrap() orelse return false, depth + 1);
        },
        else => return false,
    }
}

/// The `fn_decl` holding `node`.
fn functionOf(c: *Context, node: Ast.Node.Index) ?Ast.Node.Index {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
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

/// A sink in the checked file: a finding where the value is input, undecided where the fact
/// cannot tell.
fn sink(c: *Context, flow: *Taint.Flow, rule: Rule, node: Ast.Node.Index, comptime message: []const u8) Context.Error!void {
    try judged(c, flow, rule, node, try Taint.levelAt(c, flow, c.file, node), .data, message);
}

/// Per std function and parameter, whether the work it does stays the same whatever the
/// parameter's value.
const Constant = struct { map: std.AutoHashMapUnmanaged(struct { Facts.Decl, usize }, bool) = .empty };

/// Whether std's function `decl` does the same work whatever its parameter at `position`: the
/// parameter is only added to a field or compared (`r.seek += n; assert(r.seek <= r.end)`), and
/// never passed to a call, made a loop's bound, held in a local or returned, where it could size
/// work. A function without a body (a pointer's, a vtable's) may do anything.
fn constant(c: *Context, decl: Facts.Decl, position: usize) Context.Error!bool {
    const memo = try c.facts.memo(Constant);
    if (memo.map.get(.{ decl, position })) |known| return known;
    const tree = &c.project.at(decl.file).file.tree;
    const model = &c.project.at(decl.file).model;
    const names = try parameters(c, decl);
    const result = done: {
        if (position >= names.len or names[position].len == 0) break :done false;
        const function = model.parentOf(model.declarations[@backingInt(decl.index)].node) orelse break :done false;
        if (tree.nodeTag(function) != .fn_decl) break :done false;
        const body = tree.nodeData(function).node_and_node[1];
        const first = tree.firstToken(body);
        const last = tree.lastToken(body);
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const token = tree.nodeMainToken(node);
            if (token < first or token > last or !std.mem.eql(u8, tree.tokenSlice(token), names[position])) continue;
            if (grows(tree, model, node, body)) break :done false;
        }
        break :done true;
    };
    try memo.map.put(c.allocator, .{ decl, position }, result);
    return result;
}

/// Whether the use `node` of a parameter can size work before the walk up reaches `body`: an
/// argument of a call (not `assert`'s) or a builtin, a loop's bound, a local's value or what
/// the function returns.
fn grows(tree: *const Ast, model: *const Model, node: Ast.Node.Index, body: Ast.Node.Index) bool {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (at == body) return false;
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buffer, parent)) |call| {
            if (at == call.ast.fn_expr) continue;
            const callee = tree.nodeMainToken(call.ast.fn_expr);
            const name = if (tree.nodeTag(call.ast.fn_expr) == .field_access) tree.tokenSlice(callee + 1) else tree.tokenSlice(callee);
            return !std.mem.eql(u8, name, "assert");
        }
        if (tree.fullWhile(parent)) |loop| if (at == loop.ast.cond_expr) return true;
        if (tree.fullFor(parent)) |loop| for (loop.ast.inputs) |each| if (at == each) return true;
        if (tree.fullVarDecl(parent)) |local| if (local.ast.init_node.unwrap() == at) return true;
        switch (tree.nodeTag(parent)) {
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma, .@"return" => return true,
            .assign, .assign_mul, .assign_div, .assign_mod, .assign_add, .assign_sub, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_xor, .assign_bit_or, .assign_mul_wrap, .assign_add_wrap, .assign_sub_wrap, .assign_mul_sat, .assign_add_sat, .assign_sub_sat => {
                const target = tree.nodeData(parent).node_and_node[0];
                if (at != target and tree.nodeTag(target) == .identifier and !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_")) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Whether a comparison holding where `node` is read puts it at most a clean value.
fn capped(c: *Context, flow: *Taint.Flow, node: Ast.Node.Index) Context.Error!bool {
    for (try Range.ceilings(c, c.file, node)) |limit| if (try Taint.levelAt(c, flow, c.file, limit) == .clean) return true;
    return false;
}

/// The level of `node`, a number held to 16 bits read as data: a count a short holds, as a
/// decode of 16 bits gives (Range.zig).
fn ranged(c: *Context, flow: *Taint.Flow, node: Ast.Node.Index) Context.Error!Taint.Level {
    const level = try Taint.levelAt(c, flow, c.file, node);
    if (level == .number and try Range.small(c, c.file, node)) return .data;
    return level;
}

/// A loop bound's level: data where it counts no more passes than a short or the memory the
/// function holds (Range.counts).
fn passesBy(c: *Context, flow: *Taint.Flow, node: Ast.Node.Index) Context.Error!Taint.Level {
    const level = try Taint.levelAt(c, flow, c.file, node);
    if (level == .number and try Range.counts(c, c.file, node)) return .data;
    return level;
}

/// A finding where the value is input at `least` (data, or only a number), undecided where the
/// fact cannot tell.
/// Reports `node` where its level reaches `least`, naming the read its input came from where
/// `flow` is the input fact and the walk back finds one (`input from src/config.zig:683
/// `file.readAll``), so a package fixes each source once at its parser.
fn judged(c: *Context, flow: ?*Taint.Flow, rule: Rule, node: Ast.Node.Index, level: Taint.Level, least: Taint.Level, message: []const u8) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    if (level == .unknown) return c.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "a value that passed through a call that does not resolve may be input here");
    if (!level.reaches(least)) return;
    const fact = flow orelse return c.at(rule, tree.nodeMainToken(node), message);
    const from = (try Taint.sourceOf(c, fact, c.file, node)) orelse return c.at(rule, tree.nodeMainToken(node), message);
    const read = try callSite(c, .{ .file = from.file, .node = from.node });
    const text = if (from.via) |via|
        try c.allocator.print("{s} (input from {s} via {s})", .{ message, read, try callSite(c, via) })
    else
        try c.allocator.print("{s} (input from {s})", .{ message, read });
    try c.at(rule, tree.nodeMainToken(node), text);
}

/// A call as `file:line `callee``, the callee as written on one line: a chain split over lines
/// is joined without its breaks.
fn callSite(c: *Context, at: Taint.Site) Context.Error![]const u8 {
    const file = &c.project.at(at.file).file;
    var buffer: [1]Ast.Node.Index = undefined;
    const made = file.tree.fullCall(&buffer, at.node).?;
    const line = file.line(file.tree.tokenStart(file.tree.firstToken(at.node))) + 1;
    var spelled: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, file.tree.getNodeSource(made.ast.fn_expr), " \t\r\n");
    while (it.next()) |part| try spelled.appendSlice(c.allocator, part);
    return c.allocator.print("{s}:{d} `{s}`", .{ c.project.at(at.file).input.name, line, spelled.items });
}

/// The comparisons a condition joins by `and`, `or` and `!`.
fn comparisons(c: *Context, condition: Ast.Node.Index, out: *std.ArrayList(Ast.Node.Index)) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    switch (tree.nodeTag(condition)) {
        .bool_and, .bool_or => {
            const lhs, const rhs = tree.nodeData(condition).node_and_node;
            try comparisons(c, lhs, out);
            try comparisons(c, rhs, out);
        },
        .bool_not => try comparisons(c, tree.nodeData(condition).node, out),
        .grouped_expression => try comparisons(c, tree.nodeData(condition).node_and_token[0], out),
        else => if (comparison(tree.nodeTag(condition))) try out.append(c.allocator, condition),
    }
}

/// Whether every pass of a loop's body consumes input or lets its task be canceled, so a peer's
/// count runs it no longer than the data it sent or the caller allows: on every pass (`always`)
/// the body takes at least a byte from a reader (`takeByte`, `takeInt`, or a take, discard or
/// read of a count shown above zero), advances a slice past a part shown above zero (`cp =
/// cp[slash + 1 ..]`), or checks for cancelation and passes it on (`try io.checkCancel()`). A
/// peek, a read whose count may be zero, and one on a branch some pass skips consume nothing.
fn consumes(c: *Context, flow: *Taint.Flow, body: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        if (tag == .assign) {
            const target, const value = tree.nodeData(node).node_and_node;
            if (tree.nodeTag(value) != .slice_open) continue;
            const slice = tree.fullSlice(value).?;
            if (!std.mem.eql(u8, tree.getNodeSource(slice.ast.sliced), tree.getNodeSource(target))) continue;
            if (try Range.nonzero(c, c.file, slice.ast.start) and always(c, c.file, node, body, false)) return true;
            continue;
        }
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) continue;
        const name = tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]);
        const counted = std.mem.eql(u8, name, "take") or std.mem.eql(u8, name, "discard") or std.mem.eql(u8, name, "toss") or std.mem.eql(u8, name, "readSliceAll");
        const whole = std.mem.eql(u8, name, "takeByte") or std.mem.eql(u8, name, "takeByteSigned") or std.mem.eql(u8, name, "takeInt") or std.mem.eql(u8, name, "takeVarInt") or std.mem.eql(u8, name, "takeLeb128") or std.mem.eql(u8, name, "takeEnum");
        const taken = if (whole) true else if (counted and call.ast.params.len == 1) try Range.nonzero(c, c.file, call.ast.params[0]) else false;
        if (taken and try Taint.isRead(c, flow, c.file, call) and always(c, c.file, node, body, false)) return true;
        if (std.mem.eql(u8, name, "checkCancel") and try passedOn(c, c.file, node) and always(c, c.file, node, body, false)) return true;
    }
    return false;
}

/// Whether a statement may leave the path it is on: a `continue`, `break`, `return` or `try`.
fn leavesIn(tree: *const Ast, statement: Ast.Node.Index) bool {
    const first = tree.firstToken(statement);
    const last = tree.lastToken(statement);
    for (first..last + 1) |token| switch (tree.tokenTag(@intCast(token))) {
        .keyword_continue, .keyword_break, .keyword_return, .keyword_try => return true,
        else => {},
    };
    return false;
}

/// Whether a statement may end a loop's pass while the loop goes on: a `continue`, or a `break`
/// that may be a labeled block's. A `return` or `try` ends the loop with the pass, which bounds
/// it no less.
fn skipsIn(tree: *const Ast, statement: Ast.Node.Index) bool {
    const first = tree.firstToken(statement);
    const last = tree.lastToken(statement);
    for (first..last + 1) |token| switch (tree.tokenTag(@intCast(token))) {
        .keyword_continue, .keyword_break => return true,
        else => {},
    };
    return false;
}

/// Whether `while (x != 0)` clears a bit of `x` (`x &= x - 1`) or shifts it right (`x >>= k`,
/// `k` above zero) on every pass: it runs at most `x`'s width of times.
fn clears(c: *Context, condition: Ast.Node.Index, body: Ast.Node.Index) bool {
    const tree = &c.project.at(c.file).file.tree;
    if (tree.nodeTag(condition) != .bang_equal) return false;
    const value, const zero = tree.nodeData(condition).node_and_node;
    if (tree.nodeTag(zero) != .number_literal or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(zero)), "0")) return false;
    const name = tree.getNodeSource(value);
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, body) orelse return false;
    for (statements) |statement| {
        // A statement before that may end the pass leaves the bit set.
        if (skipsIn(tree, statement)) return false;
        const target, const operand = switch (tree.nodeTag(statement)) {
            .assign_bit_and, .assign_shr => tree.nodeData(statement).node_and_node,
            else => continue,
        };
        if (!std.mem.eql(u8, tree.getNodeSource(target), name)) continue;
        if (tree.nodeTag(statement) == .assign_shr) {
            if (tree.nodeTag(operand) != .number_literal or std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(operand)), "0")) continue;
            return true;
        }
        if (tree.nodeTag(operand) != .sub) continue;
        const minuend, const one = tree.nodeData(operand).node_and_node;
        if (std.mem.eql(u8, tree.getNodeSource(minuend), name) and std.mem.eql(u8, tree.getNodeSource(one), "1")) return true;
    }
    return false;
}

/// Whether `operand` names a local the loop `loop` assigns: a counter it steps.
fn assignedIn(c: *Context, loop: Ast.Node.Index, operand: Ast.Node.Index) bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    if (tree.nodeTag(operand) != .identifier) return false;
    const d = (model.reference(operand) orelse return false).declaration orelse return false;
    const first = tree.firstToken(loop);
    const last = tree.lastToken(loop);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const inner: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(inner);
        if (token < first or token > last) continue;
        switch (tag) {
            .assign, .assign_add, .assign_add_wrap, .assign_add_sat, .assign_sub, .assign_sub_wrap, .assign_sub_sat, .assign_mul, .assign_mul_wrap, .assign_mul_sat, .assign_div, .assign_mod, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor => {},
            else => continue,
        }
        const target = tree.nodeData(inner).node_and_node[0];
        if (tree.nodeTag(target) != .identifier) continue;
        const reference = model.reference(target) orelse continue;
        if (reference.declaration == d) return true;
    }
    return false;
}

fn site(c: *Context, node: Ast.Node.Index) bool {
    const tree = &c.project.at(c.file).file.tree;
    return !c.inTest(tree.nodeMainToken(node)) and Danger.atRuntime(c, node);
}

fn comparison(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .less_than, .less_or_equal, .greater_than, .greater_or_equal, .equal_equal, .bang_equal => true,
        else => false,
    };
}

/// Whether a read may allocate: it takes a `std.mem.Allocator`, by value or pointer, or a
/// parameter whose type the reading cannot tell is none (`anytype`, a type that does not
/// resolve). Decided by the parameter's type, never its name.
fn allocates(c: *Context, decl: Facts.Decl) Context.Error!bool {
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return true;
    const allocators = (try Governed.declarations(c, "std", "mem.Allocator")) orelse &.{};
    var it = proto.iterate(tree);
    while (it.next()) |param| {
        const declared = param.type_expr orelse return true;
        var value = try c.facts.resolve(decl.file, declared);
        if (value == .pointer) value = value.pointer.*;
        const k = switch (value) {
            .container, .instance => |k| k,
            .unknown, .alternatives => return true,
            else => continue,
        };
        for (allocators) |each| {
            const allocator_type = try c.facts.declaration((try c.facts.origin(each)) orelse each);
            if (allocator_type == .container and allocator_type.container.file == k.file and allocator_type.container.scope == k.scope) return true;
        }
    }
    return false;
}

/// A function's parameter names in order, the receiver first.
fn parameters(c: *Context, decl: Facts.Decl) Context.Error![]const []const u8 {
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    var it = proto.iterate(tree);
    while (it.next()) |param| try names.append(c.allocator, if (param.name_token) |token| tree.tokenSlice(token) else "");
    return names.items;
}
