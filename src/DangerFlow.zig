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
const Proof = @import("Proof.zig");
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
                if (try Proof.within(c, c.file, index, array, false)) continue;
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
                    const end_within = try Proof.within(c, c.file, end, slice.ast.sliced, true);
                    if (!end_within) try sink(c, flow, rule, end, extent);
                    if (!try Proof.notAfter(c, c.file, slice.ast.start, end, slice.ast.sliced)) {
                        try sink(c, flow, rule, slice.ast.start, extent);
                        if (end_within) try sink(c, flow, rule, end, extent);
                    }
                } else if (!try Proof.within(c, c.file, slice.ast.start, slice.ast.sliced, true)) try sink(c, flow, rule, slice.ast.start, extent);
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
                try judged(c, flow, rule, end, try loopOperand(c, flow, parent, end), .number, loop_message);
            },
            // What decides the condition (`decides`): each comparison it joins by `and`, `or` and
            // `!`, a local's each value, a payload's leaf. A truth bounds no number: A020's.
            .@"while", .while_simple, .while_cont => {
                const loop = tree.fullWhile(node) orelse continue;
                if (try consumes(c, flow, loop.ast.then_expr)) continue;
                var decided: Decided = .{};
                try decides(c, loop.ast.cond_expr, loop.payload_token != null, &decided, 0);
                for (decided.compared.items) |condition| {
                    if (clears(c, condition, loop.ast.then_expr)) continue;
                    const lhs, const rhs = tree.nodeData(condition).node_and_node;
                    try judged(c, flow, rule, lhs, try loopOperand(c, flow, node, lhs), .number, loop_message);
                    try judged(c, flow, rule, rhs, try loopOperand(c, flow, node, rhs), .number, loop_message);
                }
                for (decided.leaves.items) |leaf| try judged(c, flow, rule, leaf, try loopOperand(c, flow, node, leaf), .number, loop_message);
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
                if (level.reaches(.data) and try Proof.fits(c, c.file, node)) continue;
                try judged(c, flow, rule, node, level, .data, "arithmetic on a number from input: a peer's value that overflows it stops the program; aegis int.Checked or Ranged returns the overflow");
            },
            // A difference underflows on what it takes away, a byte of input enough.
            .sub, .assign_sub => {
                if (!site(c, node) or try Range.floating(c, c.file, node)) continue;
                if (tag == .sub and try Range.addresses(c, c.file, node)) continue;
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                const level = (try Taint.levelAt(c, flow, c.file, lhs)).join(try Taint.levelAt(c, flow, c.file, rhs));
                if (level.reaches(.data) and try Proof.fits(c, c.file, node)) continue;
                try judged(c, flow, rule, node, level, .data, "a difference with input: a peer's value that underflows it stops the program; aegis int.Checked or Ranged returns the error");
            },
            .div, .mod, .assign_div, .assign_mod => {
                if (!site(c, node) or try Range.floating(c, c.file, node)) continue;
                const rhs = tree.nodeData(node).node_and_node[1];
                if (try Proof.nonzero(c, c.file, rhs)) continue;
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
                if (level.reaches(.data) and std.mem.eql(u8, name, "@intCast") and try Proof.converts(c, c.file, node, args[0])) continue;
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

/// A020: a function given an `Io`, by a parameter or a field of one (`self.io`), whose loop runs
/// unbounded (`while (true)`, a labeled switch that continues itself) or as long as input says,
/// and whose body gives that `Io` to nothing: no `checkCancel`, no cancelable call, no read
/// through a reader (whose refill is one), so the task cannot be canceled while it runs.
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
    // Each function once, by the first parameter that holds its `Io`.
    var given: std.AutoHashMapUnmanaged(Ast.Node.Index, void) = .empty;
    for (model.declarations) |decl| {
        if (decl.kind != .parameter or c.inTest(decl.token)) continue;
        const through = (try heldIo(c, try c.facts.resolve(c.file, decl.node), io_type)) orelse continue;
        if ((try given.getOrPut(c.allocator, functionOf(c, decl.node) orelse continue)).found_existing) continue;
        const holder = if (through.len == 0) decl.name else try c.allocator.print("{s}.{s}", .{ decl.name, through });
        for (tree.nodes.items(.tag), 0..) |_, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (tree.fullSwitch(node)) |choice| {
                if (choice.label_token == null or !within(c, node, decl.node) or !site(c, node)) continue;
                // A labeled switch that continues itself is a loop with no bound, each prong that
                // goes on with it a pass: its point must come before every way on, read as a
                // function's body is (no periodic form; a callee leaves before its point by no error).
                var goes_on = false;
                const every = for (choice.ast.cases) |case_node| {
                    const prong = tree.fullSwitchCase(case_node).?.ast.target_expr; // unreachable: a switch's cases are cases
                    if (!continuesTo(c, prong, node)) continue;
                    goes_on = true;
                    if (!try cancels(c, c.file, prong, 1, false)) break false;
                } else true;
                if (!goes_on or every) continue;
                try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("a labeled switch that continues itself with no cancellation point on a prong that goes on: nothing it calls returns error.Canceled to it, so its task runs until the switch ends; call {s}.checkCancel() or a cancelable operation in each such prong and pass the error on", .{holder}));
                continue;
            }
            // A `while` by what decides its condition (`decides`), or as `while (true)` where
            // nothing in it can change that (`invariant`); a `for` by each range's end.
            var decided: Decided = .{};
            var unbounded = false;
            const body = if (tree.fullWhile(node)) |loop| body: {
                unbounded = forever(tree, loop.ast.cond_expr) or invariant(c, loop.ast.cond_expr, node);
                if (!unbounded) try decides(c, loop.ast.cond_expr, loop.payload_token != null, &decided, 0);
                break :body loop.ast.then_expr;
            } else if (tree.fullFor(node)) |loop| body: {
                for (loop.ast.inputs) |each| if (tree.nodeTag(each) == .for_range) if (tree.nodeData(each).node_and_opt_node[1].unwrap()) |end| try decided.leaves.append(c.allocator, end);
                break :body loop.ast.then_expr;
            } else continue;
            if (!within(c, node, decl.node) or !site(c, node)) continue;
            var by_input = false;
            var unknown = false;
            for (try decided.bounds(c)) |bound| {
                const level = try loopOperand(c, flow, node, bound);
                by_input = by_input or level.reaches(.number);
                unknown = unknown or level == .unknown;
            }
            for (decided.truths.items) |truth| {
                const level = try Taint.levelAt(c, flow, c.file, truth);
                by_input = by_input or level.reaches(.data);
                unknown = unknown or level == .unknown;
            }
            if (!unbounded and !by_input and !unknown) continue;
            if (try cancels(c, c.file, body, 0, false)) continue;
            // A bound the input fact cannot read may be one a peer sets: never cleared.
            if (!unbounded and !by_input) {
                try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), .unresolved, "a loop bounded by a value that passed through a call that does not resolve, which may be input, with no cancellation point");
                continue;
            }
            try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("a loop {s} with no cancellation point: nothing it calls returns error.Canceled to it, so its task runs until the loop ends; call {s}.checkCancel() or a cancelable operation in it and pass the error on", .{ if (unbounded) "with no bound" else "bound by input", holder }));
        }
    }
}

/// Where a parameter holds an `Io`: itself, or through a pointer (`""`), or as a field of the
/// struct it is or points to (`self.io`, the field's name), one level down. Null where it holds
/// none.
fn heldIo(c: *Context, value: Facts.Value, io_type: Facts.Container) Context.Error!?[]const u8 {
    const held = switch (if (value == .pointer) value.pointer.* else value) {
        .instance, .container => |k| k,
        else => return null,
    };
    if (held.file == io_type.file and held.scope == io_type.scope) return "";
    const model = &c.project.at(held.file).model;
    for (model.declarations, 0..) |field, i| {
        if (field.kind != .field or field.scope != held.scope) continue;
        const typed = try c.facts.declaration(.{ .file = held.file, .index = @fromBackingInt(@intCast(i)) });
        switch (if (typed == .pointer) typed.pointer.* else typed) {
            .instance, .container => |k| if (k.file == io_type.file and k.scope == io_type.scope) return field.name,
            else => {},
        }
    }
    return null;
}

/// Whether a `continue` in `prong` goes to the labeled switch `choice`.
fn continuesTo(c: *Context, prong: Ast.Node.Index, choice: Ast.Node.Index) bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"continue") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < tree.firstToken(prong) or token > tree.lastToken(prong)) continue;
        if (jumpTarget(tree, model, node) == choice) return true;
    }
    return false;
}

/// Whether a body reaches a cancellation point on every pass: a call that can return
/// `error.Canceled` and passes it on (`passedOn`), on no path some pass skips (`always`), but
/// in the loop judged, behind one of two periodic forms (`periodic`). A function of the project
/// can return it where its body reaches one so; another (std's `checkCancel`, an `Io`
/// operation's `Cancelable`) by its declared error set. A call is none for being given an `Io`
/// (`Clock.now(io)` cannot cancel), nor for its name. A callee chosen per target (`const wait =
/// if (windows) waitWindows else waitPosix`, or a method of a type so chosen) is one where every
/// choice is; a pointer to a function, or a vtable's, is none. `errors_end` says, for a function's
/// body, that the call judged ends the loop on every error the function returns (`endsOnError`),
/// so a path of the body that leaves by an error before its point lets no pass go on.
fn cancels(c: *Context, file: Project.FileId, body: Ast.Node.Index, depth: u8, errors_end: bool) Context.Error!bool {
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
        if (!try always(c, file, node, body, .{ .every_so_often = depth == 0, .errors_end = errors_end, .through_loops = true })) continue;
        // Whether an error the callee returns ends the loop: in the loop judged, by what the call
        // does with it; in a function's body, by going on out of it to a call that does.
        const ended = if (depth == 0) try endsOnError(c, file, node, body) else errors_end and propagates(c, file, node);
        const callee = try c.facts.resolve(file, call.ast.fn_expr);
        const choices: []const Facts.Value = if (callee == .alternatives) callee.alternatives else &.{callee};
        const every = for (choices) |choice| {
            if (choice != .function or !try callCancels(c, choice.function, depth, ended)) break false;
        } else true;
        if (every) return true;
    }
    return false;
}

const Cancels = struct { map: std.AutoHashMapUnmanaged(struct { Facts.Decl, bool }, bool) = .empty };

/// Whether a call of `callee` is a cancellation point: a function of the program where its body
/// reaches one, whatever its error set declares (`error{Canceled}!void {}` cancels nothing); one
/// of std's where its declared error set holds `error.Canceled`, as `Io`'s contract has each
/// operation so declared return it to a task canceled (its bodies go through `Io`'s vtable).
/// `errors_end` as `cancels` takes it.
fn callCancels(c: *Context, callee: Facts.Decl, depth: u8, errors_end: bool) Context.Error!bool {
    const callee_tree = &c.project.at(callee.file).file.tree;
    const callee_model = &c.project.at(callee.file).model;
    if (try Program.owns(c, callee.file)) if (callee_model.parentOf(callee_model.declarations[@backingInt(callee.index)].node)) |parent| if (callee_tree.nodeTag(parent) == .fn_decl) {
        const memo = try c.facts.memo(Cancels);
        if (memo.map.get(.{ callee, errors_end })) |known| return known;
        // A function that reaches itself is no cancellation point while it is being read.
        try memo.map.put(c.allocator, .{ callee, errors_end }, false);
        const out = try cancels(c, callee.file, callee_tree.nodeData(parent).node_and_node[1], depth + 1, errors_end);
        try memo.map.put(c.allocator, .{ callee, errors_end }, out);
        return out;
    };
    // A dependency's function with no body here (`extern`, a declaration only) says nothing of
    // what it does: none.
    if (!Taint.inStd(try Taint.get(c, .input), callee)) return false;
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
/// branch, prong, inner loop (but a `while (true)`, `Pass.through_loops`) or right side of an
/// `and`, `or`, `orelse` or `catch`, and after no statement that may end the pass while what runs
/// it goes on (`skips`): in a function's body any that may leave it, in a loop's one that may skip
/// to the next pass, as a `return` or `try` there ends the loop too. With
/// `Pass.every_so_often`, a branch in one of the two periodic forms (`periodic`) runs on a pass
/// in turn.
/// How `always` reads a pass.
const Pass = struct {
    /// A branch in one of the two periodic forms runs on a pass in turn.
    every_so_often: bool = false,
    /// In a function's body, a path that leaves by an error lets no pass go on (`cancels`).
    errors_end: bool = false,
    /// A `while (true)` around `node` runs its first pass: what `node` is reached on at least
    /// once a pass is enough, as for a cancellation point, where a count stepped each pass is not.
    through_loops: bool = false,
};

fn always(c: *Context, file: Project.FileId, node: Ast.Node.Index, body: Ast.Node.Index, pass: Pass) Context.Error!bool {
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
                    if (try skips(c, file, statement, body, function, pass.errors_end)) return false;
                }
            },
            else => if (tree.fullIf(parent)) |branch| {
                if (branch.ast.cond_expr != at and !(pass.every_so_often and at == branch.ast.then_expr and try periodic(c, file, branch, body))) return false;
            } else if (tree.fullWhile(parent)) |loop| {
                // A `while (true)` runs its body's first pass whatever comes before, and a jump
                // out of it before `node` is a statement that may skip.
                if (loop.ast.cond_expr != at and !(pass.through_loops and at == loop.ast.then_expr and forever(tree, loop.ast.cond_expr))) return false;
            } else if (tree.fullFor(parent)) |loop| {
                if (std.mem.findScalar(Ast.Node.Index, loop.ast.inputs, at) == null) return false;
            },
        }
        at = parent;
    }
    return true;
}

/// Whether a statement before `node` on its path through `body` may end the pass while what runs
/// it goes on. In a function's body (`function`) a `return` or a `try` leaves it, which lets the
/// loop go on unless it leaves by an error (a `try`, or `return error.X`) and `errors_end`. A `break` or
/// `continue` goes where it names, resolved by its label or, unlabeled, to the innermost loop
/// whose body holds it (`jumpTarget`), not by its spelling: to a loop or block inside the
/// statement it ends only that; a `break` of the loop judged (the innermost one around `body`)
/// or a jump past it ends that loop with the pass, as a `return` does; any other, and one whose
/// target does not resolve, may skip the rest of the pass.
fn skips(c: *Context, file: Project.FileId, statement: Ast.Node.Index, body: Ast.Node.Index, function: bool, errors_end: bool) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const first = tree.firstToken(statement);
    const last = tree.lastToken(statement);
    for (first..last + 1) |token| switch (tree.tokenTag(@intCast(token))) {
        .keyword_try => if (function and !errors_end) return true,
        .keyword_return => if (function) {
            if (!errors_end) return true;
            const exit = (try jumpAt(c, file, @intCast(token))) orelse return true;
            const value = tree.nodeData(exit).opt_node.unwrap() orelse return true;
            if (tree.nodeTag(value) != .error_value) return true;
        },
        .keyword_continue, .keyword_break => {
            const jump = (try jumpAt(c, file, @intCast(token))) orelse return true;
            const target = jumpTarget(tree, model, jump) orelse return true;
            if (tree.firstToken(target) >= first and tree.lastToken(target) <= last) continue;
            if (function or !endsLoop(tree, model, body, target, tree.nodeTag(jump) == .@"break")) return true;
        },
        else => {},
    };
    return false;
}

/// Each file's `break`, `continue` and `return` nodes by their keyword's token, indexed once.
const Jumps = struct { files: std.AutoHashMapUnmanaged(Project.FileId, std.AutoHashMapUnmanaged(Ast.TokenIndex, Ast.Node.Index)) = .empty };

fn jumpAt(c: *Context, file: Project.FileId, token: Ast.TokenIndex) Context.Error!?Ast.Node.Index {
    const memo = try c.facts.memo(Jumps);
    const entry = try memo.files.getOrPut(c.allocator, file);
    if (!entry.found_existing) {
        entry.value_ptr.* = .empty;
        const tree = &c.project.at(file).file.tree;
        for (tree.nodes.items(.tag), 0..) |tag, i| switch (tag) {
            .@"break", .@"continue", .@"return" => {
                const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
                try entry.value_ptr.put(c.allocator, tree.nodeMainToken(node), node);
            },
            else => {},
        };
    }
    return entry.value_ptr.get(token);
}

/// The loop, labeled block or labeled switch a `break` or `continue` goes to: the one its label
/// names, or, unlabeled, the innermost loop whose body holds it (a jump in a loop's condition or
/// `else` belongs to the loop around it). Null past the function.
fn jumpTarget(tree: *const Ast, model: *const Model, jump: Ast.Node.Index) ?Ast.Node.Index {
    const label = tree.nodeData(jump).opt_token_and_opt_node[0].unwrap();
    var at = jump;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl) return null;
        const loop: ?struct { ?Ast.TokenIndex, Ast.Node.Index } = if (tree.fullWhile(parent)) |w| .{ w.label_token, w.ast.then_expr } else if (tree.fullFor(parent)) |f| .{ f.label_token, f.ast.then_expr } else null;
        if (loop) |l| {
            const named, const then = l;
            if (label) |name| {
                if (named) |own| if (sameName(tree, own, name)) return parent;
            } else if (then == at) return parent;
            continue;
        }
        const name = label orelse continue;
        if (tree.fullSwitch(parent)) |choice| if (choice.label_token) |own| if (sameName(tree, own, name)) return parent;
        switch (tree.nodeTag(parent)) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                const brace = tree.nodeMainToken(parent);
                if (brace >= 2 and tree.tokenTag(brace - 1) == .colon and sameName(tree, brace - 2, name)) return parent;
            },
            else => {},
        }
    }
    return null;
}

/// Whether a loop's condition is `true`: its first pass runs.
fn forever(tree: *const Ast, cond: Ast.Node.Index) bool {
    return tree.nodeTag(cond) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(cond)), "true");
}

/// Whether every error a call in the loop body `body` returns ends that loop: under a `try` or
/// returned, or caught (`catch`, or an `if`'s `else |err|`) by a handler none of whose paths goes
/// on with the loop (`ends`).
fn endsOnError(c: *Context, file: Project.FileId, call: Ast.Node.Index, body: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = call;
    while (model.parentOf(at)) |parent| : (at = parent) switch (tree.nodeTag(parent)) {
        .grouped_expression => {},
        .@"try", .@"return" => return true,
        .@"catch" => {
            const caught, const handler = tree.nodeData(parent).node_and_node;
            return caught == at and try ends(c, file, handler, body);
        },
        .@"if", .if_simple => {
            const branch = tree.fullIf(parent).?; // unreachable: the tag is an `if`'s
            if (branch.ast.cond_expr != at or branch.error_token == null) return false;
            return ends(c, file, branch.ast.else_expr.unwrap() orelse return false, body);
        },
        else => return false,
    };
    return false;
}

/// Whether a call's errors leave the function its body is: under a `try` or returned.
fn propagates(c: *Context, file: Project.FileId, call: Ast.Node.Index) bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = call;
    while (model.parentOf(at)) |parent| : (at = parent) switch (tree.nodeTag(parent)) {
        .grouped_expression => {},
        .@"try", .@"return" => return true,
        else => return false,
    };
    return false;
}

/// Whether no path through `node`, a handler in the loop body `body`, goes on with that loop: it
/// returns, is `unreachable`, or jumps where the loop ends (`endsLoop`); a switch whose every
/// prong does, an `if` whose both branches do, or a block whose last statement does with no
/// statement before it that may skip (`skips`).
fn ends(c: *Context, file: Project.FileId, node: Ast.Node.Index, body: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    switch (tree.nodeTag(node)) {
        .grouped_expression => return ends(c, file, tree.nodeData(node).node_and_token[0], body),
        .@"return", .unreachable_literal => return true,
        .@"break", .@"continue" => {
            const target = jumpTarget(tree, model, node) orelse return false;
            return endsLoop(tree, model, body, target, tree.nodeTag(node) == .@"break");
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, node).?;
            if (statements.len == 0) return false;
            for (statements[0 .. statements.len - 1]) |statement| if (try skips(c, file, statement, body, false, false)) return false;
            return ends(c, file, statements[statements.len - 1], body);
        },
        else => {},
    }
    if (tree.fullIf(node)) |branch| {
        const otherwise = branch.ast.else_expr.unwrap() orelse return false;
        return try ends(c, file, branch.ast.then_expr, body) and try ends(c, file, otherwise, body);
    }
    if (tree.fullSwitch(node)) |choice| {
        for (choice.ast.cases) |case| if (!try ends(c, file, tree.fullSwitchCase(case).?.ast.target_expr, body)) return false; // unreachable: a switch's cases are cases
        return true;
    }
    return false;
}

fn sameName(tree: *const Ast, a: Ast.TokenIndex, b: Ast.TokenIndex) bool {
    return std.mem.eql(u8, tree.tokenSlice(a), tree.tokenSlice(b));
}

/// Whether a jump to `target` from `body` ends the loop judged, the innermost loop whose body
/// holds `body`: a `break` of that loop, or any jump to a loop or block around it.
fn endsLoop(tree: *const Ast, model: *const Model, body: Ast.Node.Index, target: Ast.Node.Index, is_break: bool) bool {
    var at = body;
    const loop = while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl) return false;
        if (tree.fullWhile(parent)) |w| if (w.ast.then_expr == at) break parent;
        if (tree.fullFor(parent)) |f| if (f.ast.then_expr == at) break parent;
    } else return false;
    if (target == loop) return is_break;
    at = loop;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (parent == target) return true;
        if (tree.nodeTag(parent) == .fn_decl) return false;
    }
    return false;
}

/// Whether a branch in a loop's body runs every so many passes: `if (x % k == 0)` with `k` a
/// constant other than zero and `x` stepped by one every pass, or a countdown `if (x == 0)`
/// that sets `x` to a constant other than zero on every path through the branch, with `x`
/// stepped down every pass. Any other condition may hold once, or never.
fn periodic(c: *Context, file: Project.FileId, branch: Ast.full.If, body: Ast.Node.Index) Context.Error!bool {
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
/// through that branch. The counter is a variable of the function whose address is never
/// taken: one any other code may write (a container's, or one written through a pointer) is
/// none.
fn stepped(c: *Context, file: Project.FileId, counter: Ast.Node.Index, body: Ast.Node.Index, step: Ast.Node.Tag, reset: ?Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const declared = (model.reference(counter) orelse return false).declaration orelse return false;
    if (!localVariable(c, file, declared)) return false;
    const loop_node = model.parentOf(body) orelse return false;
    const cont: ?Ast.Node.Index = if (tree.fullWhile(loop_node)) |loop| loop.ast.cont_expr.unwrap() else null;
    var steps = false;
    var resets = false;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (!assigns(tag)) continue;
        const token = tree.nodeMainToken(node);
        if (token < tree.firstToken(loop_node) or token > tree.lastToken(loop_node)) continue;
        const written, const value = tree.nodeData(node).node_and_node;
        const target = rootOf(tree, written);
        if (tree.nodeTag(target) != .identifier) continue;
        if ((model.reference(target) orelse continue).declaration != declared) continue;
        if (target != written) return false;
        const one = tree.nodeTag(value) == .number_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "1");
        if (tag == step and one and (node == cont or try always(c, file, node, body, .{}))) {
            if (steps) return false;
            steps = true;
            continue;
        }
        if (reset) |branch| if (tag == .assign and tree.nodeTag(value) == .number_literal and !isZero(tree, value) and try always(c, file, node, branch, .{})) {
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

/// A loop bound's level: a counter the loop steps by what it enters with and steps by
/// (Taint.counterLevel); data where it counts no more passes than a short or the memory the
/// function holds (Proof.counts).
fn loopOperand(c: *Context, flow: *Taint.Flow, loop: Ast.Node.Index, node: Ast.Node.Index) Context.Error!Taint.Level {
    const level = try countered(c, flow, loop, node);
    if (level == .number and try Proof.counts(c, c.file, node)) return .data;
    return level;
}

/// The level of a loop operand with each counter in it read by `Taint.counterLevel`: the
/// counter itself, a sum with it (`at + 2`) or a difference from it (`end - 1`).
fn countered(c: *Context, flow: *Taint.Flow, loop: Ast.Node.Index, node: Ast.Node.Index) Context.Error!Taint.Level {
    const tree = &c.project.at(c.file).file.tree;
    if (try Taint.counterLevel(c, flow, c.file, loop, node)) |level| return level;
    switch (tree.nodeTag(node)) {
        .grouped_expression => return countered(c, flow, loop, tree.nodeData(node).node_and_token[0]),
        .add, .add_wrap, .add_sat => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return (try countered(c, flow, loop, lhs)).join(try countered(c, flow, loop, rhs));
        },
        .sub, .sub_wrap, .sub_sat => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const counter = (try Taint.counterLevel(c, flow, c.file, loop, lhs)) orelse return Taint.levelAt(c, flow, c.file, node);
            return counter.join(try countered(c, flow, loop, rhs));
        },
        else => return Taint.levelAt(c, flow, c.file, node),
    }
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

/// What decides how long a `while` runs, read by meaning, not spelling (`decides`): A009 and
/// A020 read a condition through it alike.
const Decided = struct {
    /// Each comparison the condition joins by `and`, `or` and `!`: its operands bound the loop.
    compared: std.ArrayList(Ast.Node.Index) = .empty,
    /// Any other leaf of a loop that takes a payload (`while (left) |n|`): a bound itself.
    leaves: std.ArrayList(Ast.Node.Index) = .empty,
    /// Any other leaf of one that takes none (`while (self.more())`): a truth input may decide
    /// every pass.
    truths: std.ArrayList(Ast.Node.Index) = .empty,

    /// The comparisons' operands and the payload's leaves: what a number from input bounds.
    fn bounds(d: *const Decided, c: *Context) Context.Error![]const Ast.Node.Index {
        const tree = &c.project.at(c.file).file.tree;
        var out: std.ArrayList(Ast.Node.Index) = .empty;
        for (d.compared.items) |condition| try out.appendSlice(c.allocator, &tree.nodeData(condition).node_and_node);
        try out.appendSlice(c.allocator, d.leaves.items);
        return out.items;
    }
};

/// Gathers into `into` what decides a `while` condition: its comparisons, and a variable of the
/// function whose address it never takes as each value it is given, read the same way (`more =
/// n != 0` is `while (n != 0)` for `while (more)`); any other leaf as `Decided` sorts it. Past
/// `depth` a variable is a leaf.
fn decides(c: *Context, condition: Ast.Node.Index, payload: bool, into: *Decided, depth: u8) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    switch (tree.nodeTag(condition)) {
        .bool_and, .bool_or => {
            const lhs, const rhs = tree.nodeData(condition).node_and_node;
            try decides(c, lhs, payload, into, depth);
            return decides(c, rhs, payload, into, depth);
        },
        .bool_not => return decides(c, tree.nodeData(condition).node, payload, into, depth),
        .grouped_expression => return decides(c, tree.nodeData(condition).node_and_token[0], payload, into, depth),
        .identifier => if (depth < 8) if (model.reference(condition)) |reference| if (reference.declaration) |declared| if (localVariable(c, c.file, declared)) {
            const record = model.declarations[@backingInt(declared)];
            if (tree.fullVarDecl(record.node)) |variable| if (variable.ast.init_node.unwrap()) |value| try decides(c, value, payload, into, depth + 1);
            for (tree.nodes.items(.tag), 0..) |tag, i| {
                if (!assigns(tag)) continue;
                const written, const value = tree.nodeData(@fromBackingInt(@intCast(i))).node_and_node;
                const target = rootOf(tree, written);
                if (tree.nodeTag(target) != .identifier) continue;
                if (((model.reference(target) orelse continue).declaration orelse continue) != declared) continue;
                // `left -= 1`, `left.? = n`: what it holds is its own arithmetic, read as itself.
                if (tag != .assign or target != written) break;
                try decides(c, value, payload, into, depth + 1);
            } else return;
        },
        else => if (comparison(tree.nodeTag(condition))) return into.compared.append(c.allocator, condition),
    }
    try (if (payload) &into.leaves else &into.truths).append(c.allocator, condition);
}

/// Whether nothing a loop does can change its condition, so once true it is `while (true)`:
/// the condition is names, literals and the operators between them, and each name is a
/// constant, a parameter, a capture, or a variable of the function (`localVariable`) that the loop never
/// assigns. A call, a field or an element read may change with every pass.
fn invariant(c: *Context, condition: Ast.Node.Index, loop: Ast.Node.Index) bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (tree.firstToken(condition)..tree.lastToken(condition) + 1) |token| switch (tree.tokenTag(@intCast(token))) {
        .identifier => {},
        .number_literal, .char_literal, .l_paren, .r_paren, .bang, .keyword_and, .keyword_or, .equal_equal, .bang_equal, .angle_bracket_left, .angle_bracket_left_equal, .angle_bracket_right, .angle_bracket_right_equal, .plus, .minus, .asterisk, .slash, .percent, .ampersand, .pipe, .caret, .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_right, .plus_percent, .minus_percent, .asterisk_percent => {},
        else => return false,
    };
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < tree.firstToken(condition) or token > tree.lastToken(condition)) continue;
        const reference = model.reference(node) orelse return false;
        const declared = reference.declaration orelse {
            if (reference.unknown == .primitive) continue;
            return false;
        };
        const record = model.declarations[@backingInt(declared)];
        switch (record.kind) {
            .parameter, .capture => continue,
            .variable => {},
            else => return false,
        }
        const variable = tree.fullVarDecl(record.node) orelse return false;
        if (tree.tokenTag(variable.ast.mut_token) == .keyword_const) continue;
        if (!localVariable(c, c.file, declared)) return false;
        for (tree.nodes.items(.tag), 0..) |each, j| {
            if (!assigns(each)) continue;
            const at: Ast.Node.Index = @fromBackingInt(@intCast(j));
            const written = tree.nodeMainToken(at);
            if (written < tree.firstToken(loop) or written > tree.lastToken(loop)) continue;
            const target = rootOf(tree, tree.nodeData(at).node_and_node[0]);
            if (tree.nodeTag(target) != .identifier) continue;
            if ((model.reference(target) orelse continue).declaration == declared) return false;
        }
    }
    return true;
}

/// Whether a declaration is a variable of a function whose address it never takes: only the
/// function's own assignments write it.
fn localVariable(c: *Context, file: Project.FileId, declared: Model.Declaration.Id) bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const record = model.declarations[@backingInt(declared)];
    if (record.kind != .variable) return false;
    switch (model.scopes[@backingInt(record.scope)].kind) {
        .file, .container => return false,
        else => {},
    }
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .address_of) continue;
        var operand = tree.nodeData(@fromBackingInt(@intCast(i))).node;
        while (tree.nodeTag(operand) == .grouped_expression) operand = tree.nodeData(operand).node_and_token[0];
        if (tree.nodeTag(operand) != .identifier) continue;
        if ((model.reference(operand) orelse continue).declaration == declared) return false;
    }
    return true;
}

/// The name an assignment writes through: `x` of `x`, `x.?`, `x.f`, `x[i]`.
fn rootOf(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var at = node;
    while (true) switch (tree.nodeTag(at)) {
        .unwrap_optional, .field_access => at = tree.nodeData(at).node_and_token[0],
        .array_access => at = tree.nodeData(at).node_and_node[0],
        .grouped_expression => at = tree.nodeData(at).node_and_token[0],
        else => return at,
    };
}

fn assigns(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .assign, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat => true,
        else => false,
    };
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
            if (try Proof.nonzero(c, c.file, slice.ast.start) and try always(c, c.file, node, body, .{})) return true;
            continue;
        }
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) continue;
        const name = tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]);
        const counted = std.mem.eql(u8, name, "take") or std.mem.eql(u8, name, "discard") or std.mem.eql(u8, name, "toss") or std.mem.eql(u8, name, "readSliceAll");
        const whole = std.mem.eql(u8, name, "takeByte") or std.mem.eql(u8, name, "takeByteSigned") or std.mem.eql(u8, name, "takeInt") or std.mem.eql(u8, name, "takeVarInt") or std.mem.eql(u8, name, "takeLeb128") or std.mem.eql(u8, name, "takeEnum");
        const taken = if (whole) true else if (counted and call.ast.params.len == 1) try Proof.nonzero(c, c.file, call.ast.params[0]) else false;
        if (taken and try Taint.isRead(c, flow, c.file, call) and try always(c, c.file, node, body, .{})) return true;
        if (std.mem.eql(u8, name, "checkCancel") and try passedOn(c, c.file, node) and try always(c, c.file, node, body, .{})) return true;
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
