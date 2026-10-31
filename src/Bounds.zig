//! Bounds: what each path of a function gives its integers, as linear constraints.
//!
//! A forward abstract interpretation of one function at a time over conjunctions of linear
//! constraints on integers (`Σ k·x + c ≥ 0`): the function's parameters, its locals whose
//! address is never taken, the lengths of its slices, and the values of the expressions it
//! reads. A comparison adds its constraint on the path where it holds; an assignment replaces
//! what was known of its variable; a join keeps what holds on both sides; a loop keeps what
//! each pass preserves. A call of a function resolved exactly applies that function's summary
//! on the path where the call succeeds: what its returns give of its parameters and result.
//!
//! Each check a safe build makes (an index below its memory's length, a slice's bounds, a
//! difference at zero or above, arithmetic within its type, a conversion within its
//! destination, a divisor other than zero) is decided on every path that reaches it, at every
//! pointer width the package builds for. Range asks it as one more way to clear a site, and a
//! site is clear only where every path proved it.
//!
//! What it never does is clear a check it did not prove:
//! - Zig's integers are bounded, and an operation's result carries a fact only where Bounds
//!   proved the operation within its type. A wrapping operation, a truncation, a shift past
//!   the type and the bit operations give their result no more than their type's range (`& k`
//!   at most `k`), unless the operands are shown to stay within it, where they are exact.
//! - Elimination is rational (Fourier–Motzkin), which is sound for what it shows impossible.
//!   A strict comparison is the integers' (`a < b` is `a + 1 <= b`).
//! - Each limit (`state_rows` constraints a state keeps, `elimination_rows` an elimination may
//!   make) drops facts and so clears less, never more; a function with a construct it does not
//!   model (`asm`, `suspend`, a labeled switch's `continue`) gives no verdict at all.
//! - A summary counts only for a callee resolved to one function, on the path where its call
//!   succeeds; memory reached through a pointer holds no fact.
//! Every verdict is a function of the function's own text and its callees': the same files in
//! any order give the same verdicts.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");
const Model = @import("Model.zig");
const Range = @import("Range.zig");
const Governed = @import("Governed.zig");

const Error = Context.Error;

/// The most constraints a state keeps; past it the ones of most variables go first.
const state_rows = 48;
/// The most constraints one elimination may make before it gives up, proving nothing.
const elimination_rows = 320;
/// The most passes a loop's invariant takes to settle; each drops at least one constraint.
const loop_passes = state_rows + 2;
/// The most nodes a function may hold for Bounds to read it.
const function_nodes = 6000;
/// How deep summaries are read through calls in turn.
const call_depth = 6;

//======================================================================
// Linear forms.
//======================================================================

const Var = u32;
const Coef = i128;
const Term = struct { v: Var, k: Coef };

/// `Σ k·v + c`: a value, or, as a constraint, one at zero or above.
const Lin = struct {
    terms: []const Term = &.{},
    c: Coef = 0,

    fn coefficient(self: Lin, v: Var) Coef {
        for (self.terms) |term| if (term.v == v) return term.k;
        return 0;
    }
};

fn constant(k: Coef) Lin {
    return .{ .c = k };
}

fn single(a: std.mem.Allocator, v: Var) Error!Lin {
    const terms = try a.alloc(Term, 1);
    terms[0] = .{ .v = v, .k = 1 };
    return .{ .terms = terms };
}

/// `kx·x + ky·y`, or null where a coefficient overflows.
fn combine(a: std.mem.Allocator, x: Lin, kx: Coef, y: Lin, ky: Coef) Error!?Lin {
    var terms: std.ArrayList(Term) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < x.terms.len or j < y.terms.len) {
        const take_x = j >= y.terms.len or (i < x.terms.len and x.terms[i].v < y.terms[j].v);
        const take_y = i >= x.terms.len or (j < y.terms.len and y.terms[j].v < x.terms[i].v);
        var v: Var = undefined;
        var k: Coef = 0;
        if (take_x) {
            v = x.terms[i].v;
            k = std.math.mul(Coef, x.terms[i].k, kx) catch return null;
            i += 1;
        } else if (take_y) {
            v = y.terms[j].v;
            k = std.math.mul(Coef, y.terms[j].k, ky) catch return null;
            j += 1;
        } else {
            v = x.terms[i].v;
            const left = std.math.mul(Coef, x.terms[i].k, kx) catch return null;
            const right = std.math.mul(Coef, y.terms[j].k, ky) catch return null;
            k = std.math.add(Coef, left, right) catch return null;
            i += 1;
            j += 1;
        }
        if (k != 0) try terms.append(a, .{ .v = v, .k = k });
    }
    const left = std.math.mul(Coef, x.c, kx) catch return null;
    const right = std.math.mul(Coef, y.c, ky) catch return null;
    return .{ .terms = terms.items, .c = std.math.add(Coef, left, right) catch return null };
}

fn plus(a: std.mem.Allocator, x: Lin, y: Lin) Error!?Lin {
    return combine(a, x, 1, y, 1);
}

fn minus(a: std.mem.Allocator, x: Lin, y: Lin) Error!?Lin {
    return combine(a, x, 1, y, -1);
}

fn scaled(a: std.mem.Allocator, x: Lin, k: Coef) Error!?Lin {
    return combine(a, x, k, .{}, 0);
}

fn shiftedBy(x: Lin, k: Coef) ?Lin {
    return .{ .terms = x.terms, .c = std.math.add(Coef, x.c, k) catch return null };
}

/// The constraint `x - y ≥ 0`, `x ≥ y`.
fn atLeast(a: std.mem.Allocator, x: Lin, y: Lin) Error!?Lin {
    return minus(a, x, y);
}

/// The constraint `x - y - 1 ≥ 0`, `x > y`.
fn above(a: std.mem.Allocator, x: Lin, y: Lin) Error!?Lin {
    const d = (try minus(a, x, y)) orelse return null;
    return shiftedBy(d, -1);
}

fn sameTerms(x: Lin, y: Lin) bool {
    if (x.terms.len != y.terms.len) return false;
    for (x.terms, y.terms) |p, q| if (p.v != q.v or p.k != q.k) return false;
    return true;
}

fn termOrder(_: void, x: Lin, y: Lin) bool {
    const n = @min(x.terms.len, y.terms.len);
    for (x.terms[0..n], y.terms[0..n]) |p, q| {
        if (p.v != q.v) return p.v < q.v;
        if (p.k != q.k) return p.k < q.k;
    }
    if (x.terms.len != y.terms.len) return x.terms.len < y.terms.len;
    return x.c < y.c;
}

/// The constraints in a canonical order, each set of terms once at its tightest; a constant
/// that holds goes, and one that fails is the only constraint left.
fn canonical(a: std.mem.Allocator, rows: []const Lin) Error![]const Lin {
    const sorted = try a.dupe(Lin, rows);
    std.mem.sort(Lin, sorted, {}, termOrder);
    var out: std.ArrayList(Lin) = .empty;
    for (sorted) |row| {
        if (row.terms.len == 0) {
            if (row.c < 0) {
                const failed = try a.alloc(Lin, 1);
                failed[0] = constant(-1);
                return failed;
            }
            continue;
        }
        // Sorted by terms then constant: the first of a run is the tightest.
        if (out.items.len > 0 and sameTerms(out.items[out.items.len - 1], row)) continue;
        try out.append(a, row);
    }
    return out.items;
}

/// One step of Fourier–Motzkin: the constraints with `v` eliminated, each pair of opposite
/// signs summed so `v` cancels; null where that makes more than `elimination_rows`.
fn eliminate(a: std.mem.Allocator, rows: []const Lin, v: Var) Error!?[]const Lin {
    var kept: std.ArrayList(Lin) = .empty;
    var positive: std.ArrayList(Lin) = .empty;
    var negative: std.ArrayList(Lin) = .empty;
    for (rows) |row| {
        const k = row.coefficient(v);
        if (k > 0) try positive.append(a, row) else if (k < 0) try negative.append(a, row) else try kept.append(a, row);
    }
    if (kept.items.len + positive.items.len * negative.items.len > elimination_rows) return null;
    for (positive.items) |p| for (negative.items) |n| {
        const kp = p.coefficient(v);
        const kn = -n.coefficient(v);
        // An overflowing sum is left out: fewer constraints prove less.
        const sum = (try combine(a, p, kn, n, kp)) orelse continue;
        try kept.append(a, sum);
    };
    return try canonical(a, kept.items);
}

/// The variable whose elimination makes the fewest constraints, the lowest of a tie.
fn cheapest(rows: []const Lin) ?Var {
    var best: ?Var = null;
    var best_cost: usize = std.math.maxInt(usize);
    for (rows) |row| for (row.terms) |term| {
        var pos: usize = 0;
        var neg: usize = 0;
        for (rows) |other| {
            const k = other.coefficient(term.v);
            if (k > 0) pos += 1 else if (k < 0) neg += 1;
        }
        const cost = pos * neg;
        if (cost < best_cost or (cost == best_cost and best != null and term.v < best.?)) {
            best = term.v;
            best_cost = cost;
        }
    };
    return best;
}

/// Whether the constraints are shown to have no rational solution, and so no integer one.
fn impossible(a: std.mem.Allocator, rows: []const Lin) Error!bool {
    var work = try canonical(a, rows);
    while (true) {
        for (work) |row| if (row.terms.len == 0 and row.c < 0) return true;
        const v = cheapest(work) orelse return false;
        work = (try eliminate(a, work, v)) orelse return false;
    }
}

//======================================================================
// States.
//======================================================================

/// What holds on a path: a conjunction of constraints, or no path at all.
const State = struct {
    rows: []const Lin = &.{},
    dead: bool = false,

    const unreachable_state: State = .{ .dead = true };
};

fn entails(a: std.mem.Allocator, s: State, goal: Lin) Error!bool {
    if (s.dead) return true;
    // Its negation, `-goal - 1 ≥ 0`, with the state: no solution shows the goal.
    const negated = shiftedBy((try scaled(a, goal, -1)) orelse return false, -1) orelse return false;
    const rows = try a.alloc(Lin, s.rows.len + 1);
    @memcpy(rows[0..s.rows.len], s.rows);
    rows[s.rows.len] = negated;
    return impossible(a, rows);
}

/// The state with `row` added; a path it rules out is none.
fn assume(a: std.mem.Allocator, s: State, row: ?Lin) Error!State {
    if (s.dead) return s;
    const added = row orelse return s;
    const rows = try a.alloc(Lin, s.rows.len + 1);
    @memcpy(rows[0..s.rows.len], s.rows);
    rows[s.rows.len] = added;
    var kept = try canonical(a, rows);
    if (kept.len == 1 and kept[0].terms.len == 0) return State.unreachable_state;
    if (try impossible(a, kept)) return State.unreachable_state;
    if (kept.len > state_rows) kept = try trimmed(a, kept);
    return .{ .rows = kept };
}

/// The `state_rows` constraints of fewest variables, in canonical order.
fn trimmed(a: std.mem.Allocator, rows: []const Lin) Error![]const Lin {
    const sorted = try a.dupe(Lin, rows);
    std.mem.sort(Lin, sorted, {}, struct {
        fn less(_: void, x: Lin, y: Lin) bool {
            if (x.terms.len != y.terms.len) return x.terms.len < y.terms.len;
            return termOrder({}, x, y);
        }
    }.less);
    return canonical(a, sorted[0..state_rows]);
}

/// The state with what it held of `v` forgotten.
fn forget(a: std.mem.Allocator, s: State, v: Var) Error!State {
    if (s.dead) return s;
    var mentions = false;
    for (s.rows) |row| if (row.coefficient(v) != 0) {
        mentions = true;
        break;
    };
    if (!mentions) return s;
    if (try eliminate(a, s.rows, v)) |rows| return .{ .rows = if (rows.len > state_rows) try trimmed(a, rows) else rows };
    // Past the limit: keep only what does not read `v`.
    var kept: std.ArrayList(Lin) = .empty;
    for (s.rows) |row| if (row.coefficient(v) == 0) try kept.append(a, row);
    return .{ .rows = kept.items };
}

/// What holds on either path: each constraint one holds that the other implies.
fn join(a: std.mem.Allocator, x: State, y: State) Error!State {
    if (x.dead) return y;
    if (y.dead) return x;
    var out: std.ArrayList(Lin) = .empty;
    for (x.rows) |row| if (try entails(a, y, row)) try out.append(a, row);
    for (y.rows) |row| if (try entails(a, x, row)) try out.append(a, row);
    return .{ .rows = try canonical(a, out.items) };
}

/// The constraints of `s` that `t` implies: what a loop's pass preserved.
fn preserved(a: std.mem.Allocator, s: State, t: State) Error!State {
    if (s.dead) return s;
    var out: std.ArrayList(Lin) = .empty;
    for (s.rows) |row| if (try entails(a, t, row)) try out.append(a, row);
    return .{ .rows = out.items };
}

//======================================================================
// Verdicts, analyses and summaries.
//======================================================================

/// The check a safe build makes at a site.
pub const Kind = enum {
    /// An index below its memory's length, keyed by the index.
    index,
    /// A slice's end at most its memory's length, keyed by the end.
    end,
    /// A slice's start at most its memory's length, keyed by the start.
    start,
    /// A slice's start at most its end, keyed by the start.
    order,
    /// Arithmetic within its type, keyed by the operation.
    arith,
    /// A conversion within its destination, keyed by the conversion.
    cast,
    /// A divisor other than zero, keyed by the divisor.
    divisor,
};

const Site = struct { node: Ast.Node.Index, kind: Kind };

/// A function read at one pointer width: whether every construct in it was modelled, each
/// site's verdict on every path that reached it, and its summary.
const Analysis = struct {
    supported: bool = false,
    verdicts: std.AutoHashMapUnmanaged(Site, bool) = .empty,
    summary: ?Summary = null,
};

/// What a function's successful returns give of its parameters and result: constraints over
/// slots, each parameter's value and length and the result's (`slot`).
const Summary = struct { rows: []const Lin, params: usize };

fn slot(param: usize, length: bool) Var {
    return @intCast(param * 2 + @intFromBool(length));
}

const Analyses = struct {
    map: std.AutoHashMapUnmanaged(struct { Project.FileId, Ast.Node.Index, u16 }, *Analysis) = .empty,
    /// How deep summaries are being read through calls.
    depth: u8 = 0,
};

fn analysis(c: *Context, file: Project.FileId, function: Ast.Node.Index, width: u16) Error!*Analysis {
    const memo = try c.facts.memo(Analyses);
    const key = .{ file, function, width };
    if (memo.map.get(key)) |found| return found;
    const made = try c.allocator.create(Analysis);
    made.* = .{};
    // A function read while it is being read (recursion) gives nothing: no summary, no verdict.
    try memo.map.put(c.allocator, key, made);
    if (memo.depth >= call_depth) {
        _ = memo.map.remove(key);
        return made;
    }
    memo.depth += 1;
    defer memo.depth -= 1;
    var scratch: std.heap.ArenaAllocator = .init(c.allocator);
    defer scratch.deinit();
    var frame: Frame = .{ .c = c, .a = scratch.allocator(), .file = file, .tree = &c.project.at(file).file.tree, .model = &c.project.at(file).model, .width = width, .function = function };
    frame.run() catch |err| switch (err) {
        error.Unsupported => return made,
        else => |e| return e,
    };
    made.supported = true;
    var it = frame.verdicts.iterator();
    while (it.next()) |entry| try made.verdicts.put(c.allocator, entry.key_ptr.*, entry.value_ptr.*);
    if (frame.summary) |summary| {
        const rows = try c.allocator.alloc(Lin, summary.rows.len);
        for (summary.rows, rows) |row, *out| out.* = .{ .terms = try c.allocator.dupe(Term, row.terms), .c = row.c };
        made.summary = .{ .rows = rows, .params = summary.params };
    }
    return made;
}

/// The function a node is in: its innermost `fn` declaration.
fn functionOf(c: *Context, file: Project.FileId, node: Ast.Node.Index) ?Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl) return parent;
    }
    return null;
}

/// Whether every path to `node` in its function proves its check, at every pointer width.
pub fn cleared(c: *Context, file: Project.FileId, node: Ast.Node.Index, kind: Kind) Error!bool {
    const function = functionOf(c, file, node) orelse return false;
    for (Range.pointerWidths(c)) |width| {
        const read = try analysis(c, file, function, width);
        if (!read.supported) return false;
        if (!(read.verdicts.get(.{ .node = node, .kind = kind }) orelse return false)) return false;
    }
    return true;
}

/// Range's question of an index or a slice's bound: `index` within `memory`, as the access
/// that reads them both has it.
pub fn within(c: *Context, file: Project.FileId, index: Ast.Node.Index, memory: Ast.Node.Index, end: bool) Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const access = model.parentOf(index) orelse return false;
    switch (tree.nodeTag(access)) {
        .array_access => {
            const array, const at = tree.nodeData(access).node_and_node;
            if (array != memory or at != index or end) return false;
            return cleared(c, file, index, .index);
        },
        .slice_open, .slice, .slice_sentinel => {
            const slice = tree.fullSlice(access) orelse return false;
            if (slice.ast.sliced != memory or !end) return false;
            if (slice.ast.start == index) return cleared(c, file, index, .start);
            if (slice.ast.end.unwrap()) |at| if (at == index) return cleared(c, file, index, .end);
            return false;
        },
        else => return false,
    }
}

/// Range's question of a slice's start: at most its end.
pub fn notAfter(c: *Context, file: Project.FileId, start: Ast.Node.Index, end: Ast.Node.Index) Error!bool {
    const tree = &c.project.at(file).file.tree;
    const access = c.project.at(file).model.parentOf(start) orelse return false;
    const slice = tree.fullSlice(access) orelse return false;
    if (slice.ast.start != start or slice.ast.end.unwrap() != end) return false;
    return cleared(c, file, start, .order);
}

//======================================================================
// Reading one function.
//======================================================================

const Key = union(enum) {
    value: Model.Declaration.Id,
    length: Model.Declaration.Id,
    /// What an expression gives, read again on each pass over it.
    temp: struct { node: Ast.Node.Index, part: u8 },
    result,
    result_length,
};

/// What an expression gives: its integer value and the length of its memory, where they are
/// linear in what the state knows, and constraints that hold once it is unwrapped (an
/// optional's payload, an error union's success: a search found, a callee's summary).
const Value = struct {
    lin: ?Lin = null,
    length: ?Lin = null,
    unwrapped: []const Lin = &.{},
};

const Target = struct {
    kind: enum { loop, block },
    label: ?[]const u8,
    /// The defers registered when it was entered: a jump to it runs the ones after.
    defers: usize,
    /// The trial depth it was made at: a jump from a deeper trial pass leaves no state.
    trial: u32,
    breaks: std.ArrayList(State) = .empty,
    continues: std.ArrayList(State) = .empty,
    /// The variable a labeled block's or a loop's `break` value goes to.
    value: ?Var = null,
};

const Deferred = struct { body: Ast.Node.Index, on_error: bool };

const Exit = struct { state: State, failed: bool };

const Frame = struct {
    c: *Context,
    a: std.mem.Allocator,
    file: Project.FileId,
    tree: *const Ast,
    model: *const Model,
    width: u16,
    function: Ast.Node.Index,
    vars: std.AutoArrayHashMapUnmanaged(Key, Var) = .empty,
    addressed: std.AutoHashMapUnmanaged(Model.Declaration.Id, void) = .empty,
    captures: std.AutoHashMapUnmanaged(Ast.TokenIndex, Model.Declaration.Id) = .empty,
    verdicts: std.AutoHashMapUnmanaged(Site, bool) = .empty,
    targets: std.ArrayList(Target) = .empty,
    defers: std.ArrayList(Deferred) = .empty,
    exits: std.ArrayList(Exit) = .empty,
    /// How many loop passes being tried enclose the reading: their verdicts and jumps out
    /// count for nothing.
    trial: u32 = 0,
    params: []const ?Model.Declaration.Id = &.{},
    summary: ?Summary = null,

    const RunError = Error || error{Unsupported};

    fn run(f: *Frame) RunError!void {
        if (f.tree.nodes.len > 0) {
            const first = f.tree.firstToken(f.function);
            const last = f.tree.lastToken(f.function);
            if (last - first > function_nodes) return error.Unsupported;
        }
        try f.index();
        var proto_buffer: [1]Ast.Node.Index = undefined;
        const proto = f.tree.fullFnProto(&proto_buffer, f.tree.nodeData(f.function).node_and_node[0]) orelse return error.Unsupported;
        var params: std.ArrayList(?Model.Declaration.Id) = .empty;
        var s: State = .{};
        var it = proto.iterate(f.tree);
        while (it.next()) |param| {
            const name = param.name_token orelse {
                try params.append(f.a, null);
                continue;
            };
            var found: ?Model.Declaration.Id = null;
            for (f.model.declarations, 0..) |decl, d| if (decl.kind == .parameter and decl.token == name) {
                found = @fromBackingInt(@intCast(d));
                break;
            };
            try params.append(f.a, found);
            const d = found orelse continue;
            if (param.type_expr) |type_node| if (try Range.intNamed(f.c, f.file, type_node, f.width)) |int| {
                s = try f.typed(s, try f.variable(.{ .value = d }), int);
            };
        }
        f.params = params.items;
        const body = f.tree.nodeData(f.function).node_and_node[1];
        const out = try f.exec(s, body);
        if (!out.dead) try f.exits.append(f.a, .{ .state = out, .failed = false });
        try f.summarize();
    }

    /// The locals whose address is taken, and each capture's declaration by its name.
    fn index(f: *Frame) Error!void {
        const first = f.tree.firstToken(f.function);
        const last = f.tree.lastToken(f.function);
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .address_of) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const token = f.tree.nodeMainToken(node);
            if (token < first or token > last) continue;
            var operand = f.tree.nodeData(node).node;
            while (true) operand = switch (f.tree.nodeTag(operand)) {
                .grouped_expression => f.tree.nodeData(operand).node_and_token[0],
                else => break,
            };
            if (f.tree.nodeTag(operand) != .identifier) continue;
            const ref = f.model.reference(operand) orelse continue;
            if (ref.declaration) |d| try f.addressed.put(f.a, d, {});
        }
        for (f.model.declarations, 0..) |decl, d| {
            if (decl.kind != .capture or decl.token < first or decl.token > last) continue;
            try f.captures.put(f.a, decl.token, @fromBackingInt(@intCast(d)));
        }
    }

    /// The variable a key names, made the first time it is asked for.
    fn variable(f: *Frame, key: Key) Error!Var {
        const entry = try f.vars.getOrPut(f.a, key);
        if (!entry.found_existing) entry.value_ptr.* = @intCast(f.vars.count() - 1);
        return entry.value_ptr.*;
    }

    fn known(f: *Frame, key: Key) ?Var {
        return f.vars.get(key);
    }

    /// The state with `v` within an integer type's range, the widest on any target.
    fn typed(f: *Frame, s: State, v: Var, int: Range.Int) Error!State {
        const x = try single(f.a, v);
        const bits = int.wide orelse int.bits;
        var out = s;
        if (!int.signed or int.either) {
            if (!int.signed) out = try assume(f.a, out, x);
            if (bits <= 126) out = try assume(f.a, out, try atLeast(f.a, constant((@as(Coef, 1) << @intCast(bits)) - 1), x));
        } else if (bits <= 127) {
            const half = @as(Coef, 1) << @intCast(bits - 1);
            out = try assume(f.a, out, try atLeast(f.a, x, constant(-half)));
            out = try assume(f.a, out, try atLeast(f.a, constant(half - 1), x));
        }
        return out;
    }

    /// The state with `v` a length of memory: at zero or above, below half the address space.
    fn lengthy(f: *Frame, s: State, v: Var) Error!State {
        const x = try single(f.a, v);
        const most = Range.longest(f.width);
        var out = try assume(f.a, s, x);
        if (most <= std.math.maxInt(Coef)) out = try assume(f.a, out, try atLeast(f.a, constant(@intCast(most)), x));
        return out;
    }

    fn record(f: *Frame, node: Ast.Node.Index, kind: Kind, proven: bool) Error!void {
        if (f.trial > 0) return;
        const entry = try f.verdicts.getOrPut(f.a, .{ .node = node, .kind = kind });
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* and proven else proven;
    }

    /// Whether a declaration is a variable this function alone writes: a parameter, a local
    /// or a capture whose address is never taken.
    fn tracked(f: *Frame, d: Model.Declaration.Id) bool {
        const decl = f.model.declarations[@backingInt(d)];
        switch (decl.kind) {
            .parameter, .capture => {},
            .variable => switch (f.model.scopes[@backingInt(decl.scope)].kind) {
                .file, .container => return false,
                else => {},
            },
            else => return false,
        }
        if (decl.token < f.tree.firstToken(f.function) or decl.token > f.tree.lastToken(f.function)) return false;
        return !f.addressed.contains(d);
    }

    /// The state with `v` given `value` (unknown where null), in its type's range where known.
    fn assign(f: *Frame, s: State, v: Var, value: ?Lin, int: ?Range.Int) Error!State {
        if (s.dead) return s;
        var out = s;
        if (value) |given| {
            const k = given.coefficient(v);
            if (k == 1) {
                // `v := v + d`: the old `v` is the new one less `d`.
                const d = (try minus(f.a, given, try single(f.a, v))) orelse return f.assign(s, v, null, int);
                var rows: std.ArrayList(Lin) = .empty;
                for (s.rows) |row| {
                    const kv = row.coefficient(v);
                    if (kv == 0) {
                        try rows.append(f.a, row);
                        continue;
                    }
                    const moved = (try combine(f.a, row, 1, d, -kv)) orelse continue;
                    try rows.append(f.a, moved);
                }
                return .{ .rows = try canonical(f.a, rows.items) };
            }
            if (k != 0) {
                // A value of `v` other than `v` plus something: through a fresh variable.
                const t = try f.variable(.{ .temp = .{ .node = f.function, .part = 255 } });
                out = try forget(f.a, out, t);
                out = try f.equal(out, t, given);
                out = try forget(f.a, out, v);
                out = try f.equal(out, v, try single(f.a, t));
                return forget(f.a, out, t);
            }
            out = try forget(f.a, out, v);
            return f.equal(out, v, given);
        }
        out = try forget(f.a, out, v);
        if (int) |known_int| out = try f.typed(out, v, known_int);
        return out;
    }

    fn equal(f: *Frame, s: State, v: Var, value: Lin) Error!State {
        const x = try single(f.a, v);
        const out = try assume(f.a, s, try atLeast(f.a, x, value));
        return assume(f.a, out, try atLeast(f.a, value, x));
    }

    /// A fresh variable for an expression's result, read again on each pass over it.
    fn temp(f: *Frame, s: State, node: Ast.Node.Index, part: u8) Error!struct { State, Var } {
        const t = try f.variable(.{ .temp = .{ .node = node, .part = part } });
        return .{ try forget(f.a, s, t), t };
    }

    fn intOf(f: *Frame, node: Ast.Node.Index) Error!?Range.Int {
        return Range.intOf(f.c, f.file, node, f.width);
    }

    /// Runs the defers registered since `mark`, the last first; an error's exit runs its
    /// `errdefer`s too.
    fn runDefers(f: *Frame, s: State, mark: usize, failed: bool) RunError!State {
        var out = s;
        var i = f.defers.items.len;
        while (i > mark) {
            i -= 1;
            const item = f.defers.items[i];
            if (item.on_error and !failed) continue;
            out = try f.exec(out, item.body);
        }
        return out;
    }

    /// Leaves the function on this path, with or without an error.
    fn leave(f: *Frame, s: State, failed: bool) RunError!void {
        if (s.dead) return;
        const out = try f.runDefers(s, 0, failed);
        if (f.trial == 0) try f.exits.append(f.a, .{ .state = out, .failed = failed });
    }

    /// The summary: what the successful exits give of the parameters' slots and the result's.
    fn summarize(f: *Frame) Error!void {
        var joined: ?State = null;
        for (f.exits.items) |exit| {
            if (exit.failed or exit.state.dead) continue;
            const projected = try f.project(exit.state);
            joined = if (joined) |j| try join(f.a, j, projected) else projected;
        }
        const s = joined orelse {
            // No successful exit: every call that succeeds is unreachable.
            f.summary = .{ .rows = &.{constant(-1)}, .params = f.params.len };
            return;
        };
        f.summary = .{ .rows = s.rows, .params = f.params.len };
    }

    /// A state's constraints on the slots alone, each variable renamed to its slot.
    fn project(f: *Frame, s: State) Error!State {
        var out = s;
        var slots: std.AutoHashMapUnmanaged(Var, Var) = .empty;
        for (f.params, 0..) |param, i| {
            const d = param orelse continue;
            if (f.known(.{ .value = d })) |v| try slots.put(f.a, v, slot(i, false));
            if (f.known(.{ .length = d })) |v| try slots.put(f.a, v, slot(i, true));
        }
        if (f.known(.result)) |v| try slots.put(f.a, v, slot(f.params.len, false));
        if (f.known(.result_length)) |v| try slots.put(f.a, v, slot(f.params.len, true));
        var others: std.ArrayList(Var) = .empty;
        for (s.rows) |row| for (row.terms) |term| if (!slots.contains(term.v)) {
            if (std.mem.indexOfScalar(Var, others.items, term.v) == null) try others.append(f.a, term.v);
        };
        std.mem.sort(Var, others.items, {}, std.sort.asc(Var));
        for (others.items) |v| out = try forget(f.a, out, v);
        var rows: std.ArrayList(Lin) = .empty;
        for (out.rows) |row| {
            const terms = try f.a.alloc(Term, row.terms.len);
            for (row.terms, terms) |term, *renamed| renamed.* = .{ .v = slots.get(term.v).?, .k = term.k };
            std.mem.sort(Term, terms, {}, struct {
                fn less(_: void, x: Term, y: Term) bool {
                    return x.v < y.v;
                }
            }.less);
            try rows.append(f.a, .{ .terms = terms, .c = row.c });
        }
        return .{ .rows = try canonical(f.a, rows.items) };
    }
};
