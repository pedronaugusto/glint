//! The danger rules that read a flow fact (Taint.zig; designs/aegis.md §7): where a value from
//! outside the program indexes, slices, bounds a loop, names a path (A009), is converted or
//! takes part in arithmetic that can fail (A010), sizes work (A012), where an error's name reaches a peer
//! (A018), and a loop on input that never lets its task be canceled (A020). A value the fact
//! holds as unknown makes its sink undecided.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");
const Taint = @import("Taint.zig");
const Range = @import("Range.zig");
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
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (!site(c, node)) continue;
        switch (tag) {
            // A position into input's own memory is data's to reach; an entry of the program's
            // own table a byte or a hash picks is the table's design, a number's to reach.
            .array_access => {
                const array, const index = tree.nodeData(node).node_and_node;
                if (try Range.within(c, c.file, index, array, false)) continue;
                const least: Taint.Level = if (try Taint.levelAt(c, flow, c.file, array) == .clean) .number else .data;
                try judged(c, flow, rule, index, try ranged(c, flow, index), least, "input indexes memory: a peer chooses the position; parse it into a refined type with aegis input.Untrusted");
            },
            .slice_open, .slice, .slice_sentinel => {
                const slice = tree.fullSlice(node) orelse continue;
                // A bound the program checked against the memory's length is its own, and a
                // start held at most the end is within the memory wherever the end is.
                const before_end = if (slice.ast.end.unwrap()) |end| try Range.notAfter(c, c.file, slice.ast.start, end) else false;
                if (!before_end and !try Range.within(c, c.file, slice.ast.start, slice.ast.sliced, true)) try sink(c, flow, rule, slice.ast.start, "input bounds a slice: a peer chooses its extent; parse it into a refined type with aegis input.Untrusted");
                if (slice.ast.end.unwrap()) |end| if (!try Range.within(c, c.file, end, slice.ast.sliced, true)) try sink(c, flow, rule, end, "input bounds a slice: a peer chooses its extent; parse it into a refined type with aegis input.Untrusted");
            },
            // A loop a byte bounds runs a byte's count at most: a number bounds one a peer's way.
            .for_range => if (tree.nodeData(node).node_and_opt_node[1].unwrap()) |end| {
                const parent = c.project.models[c.file.raw()].node_parents[@backingInt(node)] orelse continue;
                const loop = tree.fullFor(parent) orelse continue;
                if (try consumes(c, flow, loop.ast.then_expr)) continue;
                try judged(c, flow, rule, end, try ranged(c, flow, end), .number, loop_message);
            },
            .@"while", .while_simple, .while_cont => {
                const loop = tree.fullWhile(node) orelse continue;
                const condition = loop.ast.cond_expr;
                if (!comparison(tree.nodeTag(condition))) continue;
                if (try consumes(c, flow, loop.ast.then_expr) or clears(tree, condition, loop.ast.then_expr)) continue;
                const lhs, const rhs = tree.nodeData(condition).node_and_node;
                try judged(c, flow, rule, lhs, try ranged(c, flow, lhs), .number, loop_message);
                try judged(c, flow, rule, rhs, try ranged(c, flow, rhs), .number, loop_message);
            },
            else => {
                var buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buffer, node) orelse continue;
                const reached = try Taint.reached(c, flow, c.file, call);
                const decl = reached.decl orelse continue;
                const dir = Taint.directoryType(flow) orelse continue;
                if (!decl.file.eql(dir.file)) continue;
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
/// `@truncate` keeps the low bits by intent and is no conversion that fails. Float arithmetic
/// gives an infinity or a NaN where an integer's would stop, so it is none of A010's.
pub fn integers(c: *Context, rule: Rule) Context.Error!void {
    const flow = try Taint.get(c, .input);
    const tree = &c.project.files[c.file.raw()].tree;
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
                if (level.reaches(.number) and try Range.fits(c, c.file, node)) continue;
                try judged(c, flow, rule, node, level, .number, "arithmetic on a number from input: a peer's value that overflows it stops the program; aegis int.Checked or Ranged returns the overflow");
            },
            // A difference underflows on what it takes away, a byte of input enough.
            .sub, .assign_sub => {
                if (!site(c, node) or try Range.floating(c, c.file, node)) continue;
                if (tag == .sub and try Range.addresses(c, c.file, node)) continue;
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                const left = try Taint.levelAt(c, flow, c.file, lhs);
                const right = try Taint.levelAt(c, flow, c.file, rhs);
                const level: Taint.Level = if (right.reaches(.data) or left.reaches(.number)) .number else left.join(right);
                if (level.reaches(.number) and try Range.fits(c, c.file, node)) continue;
                try judged(c, flow, rule, node, level, .number, "a difference with input: a peer's value that underflows it stops the program; aegis int.Checked or Ranged returns the error");
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
                try judged(c, flow, rule, node, try Taint.levelAt(c, flow, c.file, tree.nodeData(node).node), .number, "negation of a number from input: a peer's minimum value overflows it and stops the program; aegis int.Checked returns the overflow");
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
    const tree = &c.project.files[c.file.raw()].tree;
    const sizes = [_][]const u8{ "n", "len", "new_len", "new_n", "new_capacity", "additional_count", "num", "capacity", "count", "new_size", "size" };
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (!site(c, node)) continue;
        const reached = try Taint.reached(c, flow, c.file, call);
        const decl = reached.decl orelse continue;
        if (!reached.std) continue;
        const name = c.project.models[decl.file.raw()].declarations[decl.index].name;
        const from_reader = if (Taint.readerType(flow)) |r| r.file.eql(decl.file) else false;
        // A reader over the program's own bytes (`Reader.fixed`) reads no peer's size.
        const own = from_reader and tree.nodeTag(call.ast.fn_expr) == .field_access and fixedReader(c, tree.nodeData(call.ast.fn_expr).node_and_token[0]);
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
        var allocates = false;
        for (names) |each| allocates = allocates or std.mem.eql(u8, each, "gpa") or std.mem.eql(u8, each, "allocator");
        if (own and !allocates) continue;
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
    const tree = &c.project.files[c.file.raw()].tree;
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
    var reader_type: ?Facts.Container = null;
    if (try Governed.declarations(c, "std", "Io.Reader")) |found| for (found) |decl| {
        const value = try c.facts.declaration((try c.facts.origin(decl)) orelse decl);
        if (value == .container) reader_type = value.container;
    };
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
        if (!held.file.eql(io_type.file) or held.scope != io_type.scope) continue;
        for (tree.nodes.items(.tag), 0..) |_, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const loop = tree.fullWhile(node) orelse continue;
            if (!within(c, node, decl.node) or !site(c, node)) continue;
            const cond = loop.ast.cond_expr;
            const unbounded = tree.nodeTag(cond) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(cond)), "true");
            var by_input = false;
            if (!unbounded and comparison(tree.nodeTag(cond))) {
                const lhs, const rhs = tree.nodeData(cond).node_and_node;
                by_input = (try ranged(c, flow, lhs)).join(try ranged(c, flow, rhs)).reaches(.number);
            }
            if (!unbounded and !by_input) continue;
            if (gives(c, loop.ast.then_expr, @intCast(d)) or refills(c, loop.ast.then_expr, @intCast(d))) continue;
            if (try cancels(c, c.file, loop.ast.then_expr, io_type, reader_type, 0)) continue;
            try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("a loop {s} that gives '{s}' to nothing: no cancellation point, so its task runs until the loop ends; call {s}.checkCancel() or a cancelable operation in it", .{ if (unbounded) "with no bound" else "bound by input", decl.name, decl.name }));
        }
    }
}

/// Whether a loop's body calls a method of a reader or writer made from the `Io` `d`
/// (`file.reader(io, &buffer)`, called as itself or through `&reader.interface`): its refill or
/// drain goes through that `Io`, a cancellation point.
fn refills(c: *Context, body: Ast.Node.Index, d: u32) bool {
    const tree = &c.project.files[c.file.raw()].tree;
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) continue;
        if (madeFrom(c, tree.nodeData(call.ast.fn_expr).node_and_token[0], d)) return true;
    }
    return false;
}

/// Whether a body reaches a cancellation point through what it calls: `checkCancel`, a call
/// given an `Io` (the function's own or one a value holds, `c.socket.io`), or a consuming read
/// (`take*`, `read*`, `discard*`, `stream*`, `fillMore`) on the interface of a std reader made
/// from an `Io` (`File.Reader`, `net.Stream.Reader`), whose refill goes through it; in the body
/// or in a function of the project it calls, to a depth of four. A bare `std.Io.Reader` may be
/// a fixed one over the program's bytes, which no `Io` refills: never one.
fn cancels(c: *Context, file: Project.FileId, body: Ast.Node.Index, io: Facts.Container, reader: ?Facts.Container, depth: u8) Context.Error!bool {
    if (depth > 4) return false;
    const tree = &c.project.files[file.raw()].tree;
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        for (call.ast.params) |arg| if (try holds(c, file, arg, io)) return true;
        if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
            const receiver, const name_token = tree.nodeData(call.ast.fn_expr).node_and_token;
            const name = tree.tokenSlice(name_token);
            if (std.mem.eql(u8, name, "checkCancel") and try holds(c, file, receiver, io)) return true;
            var consuming = std.mem.eql(u8, name, "fillMore");
            for ([_][]const u8{ "take", "read", "discard", "stream" }) |prefix| consuming = consuming or std.mem.startsWith(u8, name, prefix);
            if (consuming and reader != null and try streamed(c, file, receiver, reader.?)) return true;
        }
        const callee = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
            .function => |decl| decl,
            else => continue,
        };
        if (!c.project.inputs[callee.file.raw()].selected) continue;
        const callee_model = &c.project.models[callee.file.raw()];
        const parent = callee_model.node_parents[@backingInt(callee_model.declarations[callee.index].node)] orelse continue; // safe: a node index indexes its own tree's parent table.
        const callee_tree = &c.project.files[callee.file.raw()].tree;
        if (callee_tree.nodeTag(parent) != .fn_decl) continue;
        if (try cancels(c, callee.file, callee_tree.nodeData(parent).node_and_node[1], io, reader, depth + 1)) return true;
    }
    return false;
}

/// Whether a value is an `Io`, or a pointer to one.
fn holds(c: *Context, file: Project.FileId, node: Ast.Node.Index, io: Facts.Container) Context.Error!bool {
    var held = try c.facts.resolve(file, node);
    if (held == .pointer) held = held.pointer.*;
    return switch (held) {
        .instance => |k| k.file.eql(io.file) and k.scope == io.scope,
        else => false,
    };
}

/// Whether a reader is the `interface` of a std reader other than `Io.Reader` itself, which
/// holds the `Io` its refill goes through (`file_reader.interface`, `&stream_reader.interface`).
fn streamed(c: *Context, file: Project.FileId, receiver: Ast.Node.Index, reader: Facts.Container) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    var at = receiver;
    while (tree.nodeTag(at) == .address_of or tree.nodeTag(at) == .grouped_expression) at = switch (tree.nodeTag(at)) {
        .address_of => tree.nodeData(at).node,
        else => tree.nodeData(at).node_and_token[0],
    };
    if (tree.nodeTag(at) != .field_access) return false;
    const holder, const name = tree.nodeData(at).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(name), "interface")) return false;
    var held = try c.facts.resolve(file, holder);
    if (held == .pointer) held = held.pointer.*;
    const k = switch (held) {
        .instance => |k| k,
        else => return false,
    };
    if (k.file.eql(reader.file) and k.scope == reader.scope) return false;
    const model = &c.project.models[k.file.raw()];
    if (!c.project.inputs[k.file.raw()].selected and model.scopes[k.scope].kind == .container) {
        const declared = model.scopes[k.scope].node;
        const parent = model.node_parents[@backingInt(declared)] orelse return false; // safe: a node index indexes its own tree's parent table.
        const k_tree = &c.project.files[k.file.raw()].tree;
        const variable = k_tree.fullVarDecl(parent) orelse return false;
        return std.mem.eql(u8, k_tree.tokenSlice(variable.ast.mut_token + 1), "Reader") and c.facts.member(k, "io") != null;
    }
    return false;
}

/// Whether a receiver is a local made by a call given the declaration `d`, followed through
/// fields, addresses and the locals that name it.
fn madeFrom(c: *Context, receiver: Ast.Node.Index, d: u32) bool {
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    var at = receiver;
    var steps: u8 = 0;
    while (steps < 8) : (steps += 1) {
        switch (tree.nodeTag(at)) {
            .address_of => at = tree.nodeData(at).node,
            .field_access => at = tree.nodeData(at).node_and_token[0],
            .identifier => {
                const ref = model.reference(at) orelse return false;
                const local = ref.declaration orelse return false;
                const variable = tree.fullVarDecl(model.declarations[local].node) orelse return false;
                const init = variable.ast.init_node.unwrap() orelse return false;
                var buffer: [1]Ast.Node.Index = undefined;
                if (tree.fullCall(&buffer, init)) |made| {
                    for (made.ast.params) |arg| if (tree.nodeTag(arg) == .identifier) {
                        if ((model.reference(arg) orelse continue).declaration == d) return true;
                    };
                    return false;
                }
                at = init;
            },
            else => return false,
        }
    }
    return false;
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
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
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
    try judged(c, flow, rule, node, try Taint.levelAt(c, flow, c.file, node), .data, message);
}

/// Whether a reader is one `Reader.fixed` made: a local it initializes, or a field every
/// assignment in the file gives one.
fn fixedReader(c: *Context, receiver: Ast.Node.Index) bool {
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    if (tree.nodeTag(receiver) == .identifier) {
        const ref = model.reference(receiver) orelse return false;
        const decl = model.declarations[ref.declaration orelse return false];
        const variable = tree.fullVarDecl(decl.node) orelse return false;
        return fixedCall(tree, variable.ast.init_node.unwrap() orelse return false);
    }
    if (tree.nodeTag(receiver) != .field_access) return false;
    const spelled = tree.getNodeSource(receiver);
    var any = false;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .assign) continue;
        const lhs, const rhs = tree.nodeData(@fromBackingInt(@intCast(i))).node_and_node;
        if (!std.mem.eql(u8, tree.getNodeSource(lhs), spelled)) continue;
        if (!fixedCall(tree, rhs)) return false;
        any = true;
    }
    return any;
}

/// Whether `node` calls `fixed` (`.fixed(bytes)`, `Reader.fixed(bytes)`).
fn fixedCall(tree: *const Ast, node: Ast.Node.Index) bool {
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    const name = switch (tree.nodeTag(call.ast.fn_expr)) {
        .enum_literal => tree.tokenSlice(tree.nodeMainToken(call.ast.fn_expr)),
        .field_access => tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]),
        else => return false,
    };
    return std.mem.eql(u8, name, "fixed");
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
    const tree = &c.project.files[decl.file.raw()].tree;
    const model = &c.project.models[decl.file.raw()];
    const names = try parameters(c, decl);
    const result = done: {
        if (position >= names.len or names[position].len == 0) break :done false;
        const function = model.node_parents[@backingInt(model.declarations[decl.index].node)] orelse break :done false; // safe: a declaration's node indexes its own tree's parent table.
        if (tree.nodeTag(function) != .fn_decl) break :done false;
        const body = tree.nodeData(function).node_and_node[1];
        const first = tree.firstToken(body);
        const last = tree.lastToken(body);
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const token = tree.nodeMainToken(node);
            if (token < first or token > last or !std.mem.eql(u8, tree.tokenSlice(token), names[position])) continue;
            if (grows(tree, model.node_parents, node, body)) break :done false;
        }
        break :done true;
    };
    try memo.map.put(c.allocator, .{ decl, position }, result);
    return result;
}

/// Whether the use `node` of a parameter can size work before the walk up reaches `body`: an
/// argument of a call (not `assert`'s) or a builtin, a loop's bound, a local's value or what
/// the function returns.
fn grows(tree: *const Ast, parents: []const ?Ast.Node.Index, node: Ast.Node.Index, body: Ast.Node.Index) bool {
    var at = node;
    while (parents[@backingInt(at)]) |parent| : (at = parent) { // safe: a node index indexes its own tree's parent table.
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

/// A finding where the value is input at `least` (data, or only a number), undecided where the
/// fact cannot tell.
/// Reports `node` where its level reaches `least`, naming the read its input came from where
/// `flow` is the input fact and the walk back finds one (`input from src/config.zig:683
/// `file.readAll``), so a package fixes each source once at its parser.
fn judged(c: *Context, flow: ?*Taint.Flow, rule: Rule, node: Ast.Node.Index, level: Taint.Level, least: Taint.Level, message: []const u8) Context.Error!void {
    const tree = &c.project.files[c.file.raw()].tree;
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
    const file = &c.project.files[at.file.raw()];
    var buffer: [1]Ast.Node.Index = undefined;
    const made = file.tree.fullCall(&buffer, at.node).?;
    const line = file.line(file.tree.tokenStart(file.tree.firstToken(at.node))) + 1;
    var spelled: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, file.tree.getNodeSource(made.ast.fn_expr), " \t\r\n");
    while (it.next()) |part| try spelled.appendSlice(c.allocator, part);
    return c.allocator.print("{s}:{d} `{s}`", .{ c.project.inputs[at.file.raw()].name, line, spelled.items });
}

/// Production code that runs with the program.
/// Whether each pass of a loop's body consumes input or lets its task be canceled, so a
/// peer's count runs it no longer than the data it sent or the caller allows: the body reads
/// from input (a reader's `take`, a file's read), advances a slice past what it took (`cp =
/// cp[slash + 1 ..]`), or checks for cancelation (`io.checkCancel()`).
fn consumes(c: *Context, flow: *Taint.Flow, body: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[c.file.raw()].tree;
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
            if (std.mem.eql(u8, tree.getNodeSource(slice.ast.sliced), tree.getNodeSource(target)) and tree.nodeTag(slice.ast.start) != .number_literal) return true;
            continue;
        }
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) == .field_access and std.mem.eql(u8, tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]), "checkCancel")) return true;
        if (try Taint.isRead(c, flow, c.file, call)) return true;
    }
    return false;
}

/// Whether `while (x != 0)` clears a bit of `x` (`x &= x - 1`) or shifts it right on every
/// pass: it runs at most `x`'s width of times.
fn clears(tree: *const Ast, condition: Ast.Node.Index, body: Ast.Node.Index) bool {
    if (tree.nodeTag(condition) != .bang_equal) return false;
    const value, const zero = tree.nodeData(condition).node_and_node;
    if (tree.nodeTag(zero) != .number_literal or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(zero)), "0")) return false;
    const name = tree.getNodeSource(value);
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, body) orelse return false;
    for (statements) |statement| {
        const target, const operand = switch (tree.nodeTag(statement)) {
            .assign_bit_and, .assign_shr => tree.nodeData(statement).node_and_node,
            else => continue,
        };
        if (!std.mem.eql(u8, tree.getNodeSource(target), name)) continue;
        if (tree.nodeTag(statement) == .assign_shr) return true;
        if (tree.nodeTag(operand) != .sub) continue;
        const minuend, const one = tree.nodeData(operand).node_and_node;
        if (std.mem.eql(u8, tree.getNodeSource(minuend), name) and std.mem.eql(u8, tree.getNodeSource(one), "1")) return true;
    }
    return false;
}

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
