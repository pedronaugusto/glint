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
//! pointer width the package builds for. Proof asks it after Range as one more way to clear a
//! site, and a site is clear only where every path proved it.
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
const Project = @import("Project.zig");
const Model = @import("Model.zig");
const Range = @import("Range.zig");
const Program = @import("Program.zig");
const Facts = @import("Facts.zig");
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

fn sameTerms(x: Lin, y: Lin) bool {
    if (x.terms.len != y.terms.len) return false;
    for (x.terms, y.terms) |p, q| if (p.v != q.v or p.k != q.k) return false;
    return true;
}

fn entails(a: std.mem.Allocator, s: State, goal: Lin) Error!bool {
    if (s.dead) return true;
    // A row of the state with the goal's terms and a constant no larger shows it alone,
    // however large an elimination would grow.
    for (s.rows) |row| if (row.c <= goal.c and sameTerms(row, goal)) return true;
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

/// Whether `s` implies every constraint of `t`.
fn implies(a: std.mem.Allocator, s: State, t: State) Error!bool {
    if (s.dead) return true;
    if (t.dead) return false;
    for (t.rows) |row| if (!try entails(a, s, row)) return false;
    return true;
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
    /// A loop's bound at most a short's count, or between zero and the length of memory the
    /// function holds: no more passes than the work a peer already sent. Keyed by the operand
    /// of a `while` condition's comparison or a `for` range's end.
    count,
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
    /// How many passes a loop has run since it was entered.
    passes: Ast.Node.Index,
    /// A variable a loop steps, as it was when the loop was entered.
    entry: struct { loop: Ast.Node.Index, d: Model.Declaration.Id },
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

/// What evaluating an expression leaves and gives.
const Eval = struct { s: State, v: Value = .{} };

/// A loop pass's body: the state its body ends in, and the one its loop exits in.
const Ran = struct { body: State, exit: State };

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
    vars: std.array_hash_map.Auto(Key, Var) = .empty,
    addressed: std.AutoHashMapUnmanaged(Model.Declaration.Id, void) = .empty,
    /// Each declaration of the function by its name's token.
    decls: std.AutoHashMapUnmanaged(Ast.TokenIndex, Model.Declaration.Id) = .empty,
    /// The variables whose type's range a state was given since last assigned.
    typed_vars: std.AutoHashMapUnmanaged(Var, void) = .empty,
    /// Whether the function returns an integer, or an error union or optional of one.
    returns_int: bool = false,
    /// Each `for` loop's count of passes, read once before them.
    for_counts: std.AutoHashMapUnmanaged(Ast.Node.Index, ?Lin) = .empty,
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
        try f.indexDeclarations();
        var proto_buffer: [1]Ast.Node.Index = undefined;
        const proto = f.tree.fullFnProto(&proto_buffer, f.tree.nodeData(f.function).node_and_node[0]) orelse return error.Unsupported;
        var params: std.ArrayList(?Model.Declaration.Id) = .empty;
        var s: State = .{};
        var it = proto.iterate(f.tree);
        while (it.next()) |param| {
            const name_token = param.name_token orelse {
                try params.append(f.a, null);
                continue;
            };
            var found: ?Model.Declaration.Id = null;
            for (f.model.declarations, 0..) |decl, d| if (decl.kind == .parameter and decl.token == name_token) {
                found = @fromBackingInt(@intCast(d));
                break;
            };
            try params.append(f.a, found);
            const d = found orelse continue;
            if (param.type_expr) |type_node| if (try Range.intNamed(f.c, f.file, type_node, f.width)) |int| {
                s = try f.typed(s, try f.variable(.{ .value = d }), int);
            };
            // A slice's length is one from the start: a fact first read inside a loop then
            // holds at its entry too.
            if (param.type_expr) |type_node| if (f.tree.fullPtrType(type_node)) |pointer| if (pointer.size == .slice) {
                s = try f.lengthy(s, try f.variable(.{ .length = d }));
            };
        }
        f.params = params.items;
        if (proto.ast.return_type.unwrap()) |result| {
            var t = result;
            if (f.tree.nodeTag(t) == .error_union) t = f.tree.nodeData(t).node_and_node[1];
            if (f.tree.nodeTag(t) == .optional_type) t = f.tree.nodeData(t).node;
            f.returns_int = try Range.intNamed(f.c, f.file, t, f.width) != null;
        }
        const body = f.tree.nodeData(f.function).node_and_node[1];
        const out = try f.exec(s, body);
        if (!out.dead) try f.exits.append(f.a, .{ .state = out, .failed = false });
        try f.summarize();
    }

    /// The locals whose address is taken, and each declaration by its name's token.
    fn indexDeclarations(f: *Frame) Error!void {
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
            if (decl.token < first or decl.token > last) continue;
            switch (decl.kind) {
                .variable, .capture, .parameter => try f.decls.put(f.a, decl.token, @fromBackingInt(@intCast(d))),
                else => {},
            }
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

    /// Whether `node`, valued `value` in `s`, counts no more than the work the function holds:
    /// within a short's count either way, or between zero and the length of some memory it
    /// holds. Recorded at every node that may decide a loop's passes, as DangerFlow's `decides`
    /// reads a condition: each comparison's operands, a payload loop's condition, and each value
    /// a variable is given. DangerFlow asks only at the loops' own; a node never recorded here
    /// is never cleared.
    fn counted(f: *Frame, s: State, node: Ast.Node.Index, value: ?Lin) Error!void {
        if (f.trial > 0) return;
        const x = value orelse return f.record(node, .count, false);
        const short = constant(std.math.maxInt(u16));
        if (try f.holds(s, try atLeast(f.a, short, x)) and try f.holds(s, try plus(f.a, x, short))) return f.record(node, .count, true);
        if (try f.holds(s, try atLeast(f.a, x, constant(0)))) {
            for (f.vars.keys(), f.vars.values()) |key, v| {
                if (key != .length) continue;
                if (try f.holds(s, try atLeast(f.a, try single(f.a, v), x))) return f.record(node, .count, true);
            }
        }
        try f.record(node, .count, false);
    }

    fn holds(f: *Frame, s: State, goal: ?Lin) Error!bool {
        return goal != null and try entails(f.a, s, goal.?);
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
        // Its type's range is given again where it is next read, or here.
        _ = f.typed_vars.remove(v);
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
        if (int) |known_int| {
            out = try f.typed(out, v, known_int);
            try f.typed_vars.put(f.a, v, {});
        }
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

    /// `-1 ≥ 0`: the summary of a function that never succeeds.
    const never = [_]Lin{constant(-1)};

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
            f.summary = .{ .rows = &never, .params = f.params.len };
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
            if (std.mem.findScalar(Var, others.items, term.v) == null) try others.append(f.a, term.v);
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

    //------------------------------------------------------------------
    // Statements.
    //------------------------------------------------------------------

    /// The state after `node` runs from `s`.
    fn exec(f: *Frame, s: State, node: Ast.Node.Index) RunError!State {
        if (s.dead) return s;
        switch (f.tree.nodeTag(node)) {
            .simple_var_decl, .local_var_decl, .aligned_var_decl, .global_var_decl => return f.declare(s, node),
            .assign, .assign_add, .assign_add_wrap, .assign_add_sat, .assign_sub, .assign_sub_wrap, .assign_sub_sat, .assign_mul, .assign_mul_wrap, .assign_mul_sat, .assign_div, .assign_mod, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor => return f.assignment(s, node),
            .assign_destructure => return f.destructure(s, node),
            .@"defer", .@"errdefer" => {
                try f.defers.append(f.a, .{ .body = f.tree.nodeData(node).node, .on_error = f.tree.nodeTag(node) == .@"errdefer" });
                return s;
            },
            else => return (try f.eval(s, node)).s,
        }
    }

    /// A block's statements in order, its defers run as it ends; a labeled block's `break`s
    /// join where it ends, with the value each gives.
    fn block(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = f.tree.blockStatements(&buffer, node).?; // unreachable: the tag is a block's
        const mark = f.defers.items.len;
        const label = blockLabel(f.tree, node);
        var out = s;
        var result: ?Var = null;
        if (label != null) {
            const t = try f.temp(out, node, 0);
            out = t[0];
            result = t[1];
            try f.targets.append(f.a, .{ .kind = .block, .label = label, .defers = mark, .trial = f.trial, .value = result });
        }
        for (statements) |statement| out = try f.exec(out, statement);
        out = try f.runDefers(out, mark, false);
        f.defers.shrinkRetainingCapacity(mark);
        if (label == null) return .{ .s = out };
        const target = f.targets.pop().?; // unreachable: pushed above
        for (target.breaks.items) |state| out = try join(f.a, out, state);
        return .{ .s = out, .v = .{ .lin = try single(f.a, result.?) } };
    }

    fn declare(f: *Frame, s: State, node: Ast.Node.Index) RunError!State {
        const local = f.tree.fullVarDecl(node).?; // unreachable: the tag is a declaration's
        const init = local.ast.init_node.unwrap() orelse return s;
        const e = try f.eval(s, init);
        const d = f.decls.get(local.ast.mut_token + 1) orelse return e.s;
        if (!f.tracked(d)) return e.s;
        try f.counted(e.s, init, e.v.lin);
        const int = if (local.ast.type_node.unwrap()) |t| try Range.intNamed(f.c, f.file, t, f.width) else try f.intOf(init);
        return f.bind(e.s, d, e.v, int);
    }

    /// The state with a tracked declaration given a value: its integer where its type is one,
    /// and the length of its memory.
    fn bind(f: *Frame, s: State, d: Model.Declaration.Id, value: Value, int: ?Range.Int) Error!State {
        var out = try f.assign(s, try f.variable(.{ .value = d }), if (int != null) value.lin else null, int);
        const length = try f.variable(.{ .length = d });
        out = try f.assign(out, length, value.length, null);
        if (value.length == null) out = try f.lengthy(out, length);
        return out;
    }

    fn assignment(f: *Frame, s: State, node: Ast.Node.Index) RunError!State {
        const tag = f.tree.nodeTag(node);
        const target, const rhs = f.tree.nodeData(node).node_and_node;
        const d = f.trackedName(target) orelse {
            // A store to memory: what it reads is evaluated, and no tracked variable changes.
            const place = try f.eval(s, target);
            return (try f.eval(place.s, rhs)).s;
        };
        const e = try f.eval(s, rhs);
        const int = try f.intOf(target);
        if (tag == .assign) {
            try f.counted(e.s, rhs, e.v.lin);
            return f.bind(e.s, d, e.v, int);
        }
        const v = try f.variable(.{ .value = d });
        const current = try f.name(e.s, target);
        const op: Ast.Node.Tag = switch (tag) {
            .assign_add => .add,
            .assign_add_wrap => .add_wrap,
            .assign_add_sat => .add_sat,
            .assign_sub => .sub,
            .assign_sub_wrap => .sub_wrap,
            .assign_sub_sat => .sub_sat,
            .assign_mul => .mul,
            .assign_mul_wrap => .mul_wrap,
            .assign_mul_sat => .mul_sat,
            .assign_div => .div,
            .assign_mod => .mod,
            .assign_shl => .shl,
            .assign_shl_sat => .shl_sat,
            .assign_shr => .shr,
            .assign_bit_and => .bit_and,
            .assign_bit_or => .bit_or,
            else => .bit_xor,
        };
        const result = try f.arith(current.s, node, op, current.v.lin, e.v.lin, rhs, int);
        return f.assign(result.s, v, result.v.lin, int);
    }

    fn destructure(f: *Frame, s: State, node: Ast.Node.Index) RunError!State {
        const full = f.tree.assignDestructure(node);
        var out = (try f.eval(s, full.ast.value_expr)).s;
        for (full.ast.variables) |target| {
            if (f.tree.fullVarDecl(target)) |local| {
                const d = f.decls.get(local.ast.mut_token + 1) orelse continue;
                if (f.tracked(d)) out = try f.bind(out, d, .{}, null);
                continue;
            }
            if (f.trackedName(target)) |d| {
                out = try f.bind(out, d, .{}, null);
                continue;
            }
            out = (try f.eval(out, target)).s;
        }
        return out;
    }

    /// The tracked declaration an identifier names, where it names one.
    fn trackedName(f: *Frame, node: Ast.Node.Index) ?Model.Declaration.Id {
        if (f.tree.nodeTag(node) != .identifier) return null;
        const d = (f.model.reference(node) orelse return null).declaration orelse return null;
        return if (f.tracked(d)) d else null;
    }

    //------------------------------------------------------------------
    // Expressions.
    //------------------------------------------------------------------

    /// What evaluating `node` from `s` leaves and gives.
    fn eval(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        if (s.dead) return .{ .s = s };
        const tree = f.tree;
        switch (tree.nodeTag(node)) {
            .number_literal => return .{ .s = s, .v = .{ .lin = switch (std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(node)))) {
                .int => |n| constant(n),
                else => null,
            } } },
            .identifier => return f.name(s, node),
            // A statement as a branch's or a loop's whole body (`if (a) i = 0;`).
            .assign, .assign_add, .assign_add_wrap, .assign_add_sat, .assign_sub, .assign_sub_wrap, .assign_sub_sat, .assign_mul, .assign_mul_wrap, .assign_mul_sat, .assign_div, .assign_mod, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_destructure => return .{ .s = try f.exec(s, node) },
            .grouped_expression => return f.eval(s, tree.nodeData(node).node_and_token[0]),
            .@"nosuspend" => return f.eval(s, tree.nodeData(node).node),
            .field_access => return f.field(s, node),
            .array_access => return f.element(s, node),
            .slice_open, .slice, .slice_sentinel => return f.slice(s, node),
            .add, .sub, .mul, .add_wrap, .sub_wrap, .mul_wrap, .add_sat, .sub_sat, .mul_sat, .div, .mod, .shl, .shl_sat, .shr, .bit_and, .bit_or, .bit_xor => {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                const left = try f.eval(s, lhs);
                const right = try f.eval(left.s, rhs);
                return f.arith(right.s, node, tree.nodeTag(node), left.v.lin, right.v.lin, rhs, try f.intOf(node));
            },
            .negation => {
                const operand = try f.eval(s, tree.nodeData(node).node);
                return f.arith(operand.s, node, .sub, constant(0), operand.v.lin, tree.nodeData(node).node, try f.intOf(node));
            },
            .negation_wrap, .bit_not, .deref, .address_of, .unwrap_optional => {
                const operand: Ast.Node.Index = switch (tree.nodeTag(node)) {
                    .unwrap_optional => tree.nodeData(node).node_and_token[0],
                    else => tree.nodeData(node).node,
                };
                const e = try f.eval(s, operand);
                return f.fresh(e.s, node, 0);
            },
            .less_than, .less_or_equal, .greater_than, .greater_or_equal, .equal_equal, .bang_equal, .bool_and, .bool_or, .bool_not => {
                const split = try f.cond(s, node);
                return .{ .s = try join(f.a, split.yes, split.no) };
            },
            .@"try" => return f.tried(s, node),
            .@"catch", .@"orelse" => return f.otherwise(s, node),
            .@"if", .if_simple => return f.branch(s, node),
            .@"while", .while_simple, .while_cont => return f.whileLoop(s, node),
            .@"for", .for_simple => return f.forLoop(s, node),
            .@"switch", .switch_comma => return f.switchOn(s, node),
            .@"return" => return f.returned(s, node),
            .@"break" => return f.jump(s, node, true),
            .@"continue" => return f.jump(s, node, false),
            .unreachable_literal => return .{ .s = State.unreachable_state },
            .block, .block_semicolon, .block_two, .block_two_semicolon => return f.block(s, node),
            .call_one, .call_one_comma, .call, .call_comma => return f.call(s, node),
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => return f.builtin(s, node),
            .struct_init_one, .struct_init_one_comma, .struct_init_dot_two, .struct_init_dot_two_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init, .struct_init_comma => {
                var buffer: [2]Ast.Node.Index = undefined;
                const full = tree.fullStructInit(&buffer, node).?; // unreachable: the tag is a struct literal's
                var out = s;
                for (full.ast.fields) |each| out = (try f.eval(out, each)).s;
                return .{ .s = out };
            },
            .array_init_one, .array_init_one_comma, .array_init_dot_two, .array_init_dot_two_comma, .array_init_dot, .array_init_dot_comma, .array_init, .array_init_comma => {
                var buffer: [2]Ast.Node.Index = undefined;
                const full = tree.fullArrayInit(&buffer, node).?; // unreachable: the tag is an array literal's
                var out = s;
                for (full.ast.elements) |each| out = (try f.eval(out, each)).s;
                return .{ .s = out, .v = .{ .length = constant(@intCast(full.ast.elements.len)) } };
            },
            .@"asm", .asm_simple, .@"suspend", .@"resume" => return error.Unsupported,
            // Evaluated as the program compiles, or a type: nothing at run time.
            .@"comptime", .string_literal, .multiline_string_literal, .char_literal, .enum_literal, .error_value, .error_set_decl, .anyframe_literal, .anyframe_type, .optional_type, .array_type, .array_type_sentinel, .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range, .error_union, .merge_error_sets, .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing, .container_decl_arg, .container_decl_arg_trailing, .tagged_union, .tagged_union_trailing, .tagged_union_two, .tagged_union_two_trailing, .tagged_union_enum_tag, .tagged_union_enum_tag_trailing, .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto => return .{ .s = s },
            else => return f.opaqueExpr(s, node),
        }
    }

    /// An expression Bounds does not read: its sites get no verdict, and the state goes on
    /// unchanged where nothing in it may change a tracked variable or jump; otherwise the
    /// function is unsupported.
    fn opaqueExpr(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const tree = f.tree;
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            const inner: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const token = tree.nodeMainToken(inner);
            if (token < first or token > last) continue;
            switch (tag) {
                .@"return", .@"break", .@"continue" => if (functionOf(f.c, f.file, inner) == f.function) return error.Unsupported,
                .assign, .assign_add, .assign_add_wrap, .assign_add_sat, .assign_sub, .assign_sub_wrap, .assign_sub_sat, .assign_mul, .assign_mul_wrap, .assign_mul_sat, .assign_div, .assign_mod, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor => if (f.trackedName(tree.nodeData(inner).node_and_node[0]) != null) return error.Unsupported,
                .assign_destructure, .simple_var_decl, .local_var_decl, .aligned_var_decl => if (functionOf(f.c, f.file, inner) == f.function) return error.Unsupported,
                .@"asm", .asm_simple => return error.Unsupported,
                else => {},
            }
        }
        return f.fresh(s, node, 0);
    }

    /// A fresh variable for what `node` gives, within its integer type where it has one.
    fn fresh(f: *Frame, s: State, node: Ast.Node.Index, part: u8) Error!Eval {
        const int = try f.intOf(node);
        if (int == null) return .{ .s = s };
        const t = try f.temp(s, node, part);
        return .{ .s = try f.typed(t[0], t[1], int.?), .v = .{ .lin = try single(f.a, t[1]) } };
    }

    /// An identifier: a tracked variable's value, within its type; a constant's value; or
    /// nothing known.
    fn name(f: *Frame, s: State, node: Ast.Node.Index) Error!Eval {
        const reference = f.model.reference(node) orelse return .{ .s = s };
        const d = reference.declaration orelse return .{ .s = s };
        if (f.tracked(d)) {
            const int = (try f.intOf(node)) orelse return .{ .s = s };
            const v = try f.variable(.{ .value = d });
            var out = s;
            if (!f.typed_vars.contains(v)) {
                out = try f.typed(out, v, int);
                try f.typed_vars.put(f.a, v, {});
            }
            return .{ .s = out, .v = .{ .lin = try single(f.a, v) } };
        }
        if (try Range.constantValue(f.c, f.file, node)) |value| if (value <= std.math.maxInt(Coef)) return .{ .s = s, .v = .{ .lin = constant(@intCast(value)) } };
        return .{ .s = s };
    }

    /// `x.len`: the length of `x`'s memory; any other field: nothing known.
    fn field(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const holder, const field_token = f.tree.nodeData(node).node_and_token;
        const e = try f.eval(s, holder);
        if (!std.mem.eql(u8, f.tree.tokenSlice(field_token), "len")) return f.fresh(e.s, node, 0);
        const measured = try f.lengthOf(e.s, holder, e.v);
        return .{ .s = measured[0], .v = .{ .lin = measured[1] } };
    }

    /// The length of `memory`'s memory: what evaluating it gave, an array's fixed length, or a
    /// tracked slice's length variable.
    fn lengthOf(f: *Frame, s: State, memory: Ast.Node.Index, value: Value) Error!struct { State, ?Lin } {
        const given = try f.knownLength(s, memory, value);
        // A table std names by a u32 index: whatever else is known of its length, at most the
        // indexes there are.
        const most = (try table(f.c, f.file, memory)) orelse return given;
        var out = given[0];
        const l = given[1] orelse made: {
            const t = try f.temp(out, memory, 5);
            out = t[0];
            break :made try single(f.a, t[1]);
        };
        out = try assume(f.a, out, try atLeast(f.a, l, constant(0)));
        out = try assume(f.a, out, try atLeast(f.a, constant(most), l));
        return .{ out, l };
    }

    /// What evaluating `memory` gave of its length, an array's fixed length, or a tracked
    /// slice's length variable.
    fn knownLength(f: *Frame, s: State, memory: Ast.Node.Index, value: Value) Error!struct { State, ?Lin } {
        if (value.length) |known_length| return .{ s, known_length };
        if (try Range.memoryLength(f.c, f.file, memory)) |fixed| if (fixed <= std.math.maxInt(Coef)) return .{ s, constant(@intCast(fixed)) };
        const d = f.trackedName(memory) orelse return .{ s, null };
        const key: Key = .{ .length = d };
        const made = f.known(key) == null;
        const v = try f.variable(key);
        return .{ if (made) try f.lengthy(s, v) else s, try single(f.a, v) };
    }

    /// `m[i]`: the index below the memory's length, checked by a safe build and so held past it.
    fn element(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const memory, const at = f.tree.nodeData(node).node_and_node;
        const m = try f.eval(s, memory);
        const i = try f.eval(m.s, at);
        const measured = try f.lengthOf(i.s, memory, m.v);
        var out = measured[0];
        if (i.v.lin) |position| if (measured[1]) |length| {
            const low = try atLeast(f.a, position, constant(0));
            const high = try above(f.a, length, position);
            try f.record(at, .index, (low != null and try entails(f.a, out, low.?)) and (high != null and try entails(f.a, out, high.?)));
            out = try assume(f.a, out, low);
            out = try assume(f.a, out, high);
            return f.fresh(out, node, 0);
        };
        try f.record(at, .index, false);
        return f.fresh(out, node, 0);
    }

    /// `m[a..b]`: its bounds in order and its end within the memory, checked by a safe build
    /// and so held past it; its length the difference.
    fn slice(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const full = f.tree.fullSlice(node).?; // unreachable: the tag is a slice's
        const m = try f.eval(s, full.ast.sliced);
        const start = try f.eval(m.s, full.ast.start);
        var out = start.s;
        var end: ?Lin = null;
        if (full.ast.end.unwrap()) |end_node| {
            const e = try f.eval(out, end_node);
            out = e.s;
            end = e.v.lin;
        }
        if (full.ast.sentinel.unwrap()) |sentinel| out = (try f.eval(out, sentinel)).s;
        const measured = try f.lengthOf(out, full.ast.sliced, m.v);
        out = measured[0];
        const length = measured[1];
        // A sentinel's slice reads the element at its end too.
        const room: ?Lin = if (length) |l| (if (full.ast.sentinel != .none) shiftedBy(l, -1) else l) else null;
        // An open slice ends at its length; an end with no known value proves nothing.
        const last = if (full.ast.end != .none) end else length;
        if (full.ast.end.unwrap()) |end_node| {
            const fits_end = if (last != null and room != null) try atLeast(f.a, room.?, last.?) else null;
            try f.record(end_node, .end, fits_end != null and try entails(f.a, out, fits_end.?));
            out = try assume(f.a, out, fits_end);
            const ordered_bounds = if (start.v.lin != null and last != null) try atLeast(f.a, last.?, start.v.lin.?) else null;
            try f.record(full.ast.start, .order, ordered_bounds != null and try entails(f.a, out, ordered_bounds.?));
            out = try assume(f.a, out, ordered_bounds);
        }
        const fits_start = if (start.v.lin != null and room != null) try atLeast(f.a, room.?, start.v.lin.?) else null;
        try f.record(full.ast.start, .start, fits_start != null and try entails(f.a, out, fits_start.?));
        out = try assume(f.a, out, fits_start);
        const size: ?Lin = if (last != null and start.v.lin != null) try minus(f.a, last.?, start.v.lin.?) else null;
        return .{ .s = out, .v = .{ .length = size } };
    }

    /// Arithmetic `op` of `x` and `y` in `int`, at `node`: a checked operation's verdict, and its
    /// result exact where it is shown within its type (a checked one past its check).
    fn arith(f: *Frame, s: State, node: Ast.Node.Index, op: Ast.Node.Tag, x: ?Lin, y: ?Lin, divisor: Ast.Node.Index, int: ?Range.Int) Error!Eval {
        var out = s;
        switch (op) {
            .add, .sub, .mul => {
                const exact: ?Lin = if (x == null or y == null) null else switch (op) {
                    .add => try plus(f.a, x.?, y.?),
                    .sub => try minus(f.a, x.?, y.?),
                    else => if (y.?.terms.len == 0) try scaled(f.a, x.?, y.?.c) else if (x.?.terms.len == 0) try scaled(f.a, y.?, x.?.c) else null,
                };
                const known_int = int orelse {
                    // Comptime arithmetic is exact.
                    return .{ .s = out, .v = .{ .lin = exact } };
                };
                const bounds = try f.range(known_int, false);
                const result = exact orelse {
                    try f.record(node, .arith, false);
                    return f.fresh(out, node, 0);
                };
                const low = if (bounds.low) |l| try atLeast(f.a, result, constant(l)) else null;
                const high = if (bounds.high) |h| try atLeast(f.a, constant(h), result) else null;
                try f.record(node, .arith, low != null and high != null and try entails(f.a, out, low.?) and try entails(f.a, out, high.?));
                out = try assume(f.a, out, low);
                out = try assume(f.a, out, high);
                return .{ .s = out, .v = .{ .lin = result } };
            },
            .add_wrap, .sub_wrap, .mul_wrap, .add_sat, .sub_sat, .mul_sat, .shl, .shl_sat => {
                // Exact only where shown within the type; otherwise anything in it.
                const exact: ?Lin = if (x == null or y == null) null else switch (op) {
                    .add_wrap, .add_sat => try plus(f.a, x.?, y.?),
                    .sub_wrap, .sub_sat => try minus(f.a, x.?, y.?),
                    .shl, .shl_sat => if (y.?.terms.len == 0 and y.?.c >= 0 and y.?.c < 120) try scaled(f.a, x.?, @as(Coef, 1) << @intCast(y.?.c)) else null,
                    else => if (y.?.terms.len == 0) try scaled(f.a, x.?, y.?.c) else if (x.?.terms.len == 0) try scaled(f.a, y.?, x.?.c) else null,
                };
                if (exact != null and int != null) {
                    const bounds = try f.range(int.?, false);
                    if (bounds.low != null and bounds.high != null and
                        try entails(f.a, out, (try atLeast(f.a, exact.?, constant(bounds.low.?))) orelse return f.fresh(out, node, 0)) and
                        try entails(f.a, out, (try atLeast(f.a, constant(bounds.high.?), exact.?)) orelse return f.fresh(out, node, 0)))
                        return .{ .s = out, .v = .{ .lin = exact } };
                }
                return f.fresh(out, node, 0);
            },
            .div, .mod => {
                if (y) |d| {
                    const positive = try atLeast(f.a, d, constant(1));
                    const negative = try atLeast(f.a, constant(-1), d);
                    try f.record(divisor, .divisor, (positive != null and try entails(f.a, out, positive.?)) or (negative != null and try entails(f.a, out, negative.?)));
                    // An unsigned divisor other than zero is one or more.
                    if (try entails(f.a, out, (try atLeast(f.a, d, constant(0))).?)) out = try assume(f.a, out, positive);
                } else try f.record(divisor, .divisor, false);
                const made = try f.fresh(out, node, 0);
                out = made.s;
                const t = made.v.lin orelse return made;
                const left = x orelse return made;
                const d = y orelse return made;
                const left_natural = try entails(f.a, out, (try atLeast(f.a, left, constant(0))).?);
                const d_positive = try entails(f.a, out, (try atLeast(f.a, d, constant(1))).?);
                if (!left_natural or !d_positive) return made;
                if (op == .mod) {
                    // `0 <= x % d < d`, and at most `x`.
                    out = try assume(f.a, out, try atLeast(f.a, t, constant(0)));
                    out = try assume(f.a, out, try above(f.a, d, t));
                    out = try assume(f.a, out, try atLeast(f.a, left, t));
                } else if (d.terms.len == 0) {
                    // `k·(x / k) <= x < k·(x / k) + k`.
                    const kt = (try scaled(f.a, t, d.c)) orelse return .{ .s = out, .v = made.v };
                    out = try assume(f.a, out, try atLeast(f.a, kt, constant(0)));
                    out = try assume(f.a, out, try atLeast(f.a, left, kt));
                    out = try assume(f.a, out, try above(f.a, (try plus(f.a, kt, d)) orelse return .{ .s = out, .v = made.v }, left));
                } else {
                    out = try assume(f.a, out, try atLeast(f.a, t, constant(0)));
                    out = try assume(f.a, out, try atLeast(f.a, left, t));
                }
                return .{ .s = out, .v = made.v };
            },
            .shr, .bit_and => {
                const made = try f.fresh(out, node, 0);
                out = made.s;
                const t = made.v.lin orelse return made;
                const left = x orelse return made;
                if (!try entails(f.a, out, (try atLeast(f.a, left, constant(0))).?)) return made;
                // An unsigned shift right or mask is at most what it takes from.
                out = try assume(f.a, out, try atLeast(f.a, t, constant(0)));
                out = try assume(f.a, out, try atLeast(f.a, left, t));
                if (op == .bit_and) if (y) |mask| if (try entails(f.a, out, (try atLeast(f.a, mask, constant(0))).?)) {
                    out = try assume(f.a, out, try atLeast(f.a, mask, t));
                };
                return .{ .s = out, .v = made.v };
            },
            else => return f.fresh(out, node, 0),
        }
    }

    /// An integer type's least and greatest values on every target, where they fit a `Coef`.
    fn range(f: *Frame, int: Range.Int, widest: bool) Error!struct { low: ?Coef, high: ?Coef } {
        _ = f;
        const bits = if (widest) int.wide orelse int.bits else int.bits;
        if (int.signed and !(widest and int.either)) {
            if (bits == 0 or bits > 127) return .{ .low = null, .high = null };
            const half = @as(Coef, 1) << @intCast(bits - 1);
            return .{ .low = -half, .high = half - 1 };
        }
        if (bits > 126) return .{ .low = 0, .high = null };
        return .{ .low = 0, .high = (@as(Coef, 1) << @intCast(bits)) - 1 };
    }

    fn builtin(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const tree = f.tree;
        const which = tree.tokenSlice(tree.nodeMainToken(node));
        var buffer: [2]Ast.Node.Index = undefined;
        const args = tree.builtinCallParams(&buffer, node) orelse &.{};
        const is = struct {
            fn named(spelled: []const u8, wanted: []const u8) bool {
                return std.mem.eql(u8, spelled, wanted);
            }
        }.named;
        // Read as the program compiles: nothing at run time.
        for ([_][]const u8{ "@import", "@This", "@TypeOf", "@typeInfo", "@typeName", "@sizeOf", "@alignOf", "@bitSizeOf", "@offsetOf", "@bitOffsetOf", "@hasDecl", "@hasField", "@compileError", "@compileLog", "@Type", "@Int", "@Struct", "@Union", "@Enum", "@Tuple", "@Pointer", "@Fn", "@EnumLiteral", "@field", "@src", "@inComptime", "@setEvalBranchQuota", "@setRuntimeSafety", "@setFloatMode", "@branchHint", "@embedFile" }) |compiled| if (is(which, compiled)) {
            if (is(which, "@compileError")) return .{ .s = State.unreachable_state };
            if (is(which, "@field") and args.len == 2) return f.fresh((try f.eval(s, args[0])).s, node, 0);
            return f.fresh(s, node, 0);
        };
        if (is(which, "@panic") or is(which, "@trap")) {
            if (args.len == 1) _ = try f.eval(s, args[0]);
            return .{ .s = State.unreachable_state };
        }
        var out = s;
        var values: [2]Value = .{ .{}, .{} };
        var all: std.ArrayList(Value) = .empty;
        for (args, 0..) |arg, i| {
            const e = try f.eval(out, arg);
            out = e.s;
            if (i < 2) values[i] = e.v;
            try all.append(f.a, e.v);
        }
        if (is(which, "@as") and args.len == 2) return .{ .s = out, .v = values[1] };
        if ((is(which, "@intCast") or is(which, "@truncate")) and args.len == 1) {
            const into = (try f.intOf(node)) orelse {
                if (is(which, "@intCast")) try f.record(node, .cast, false);
                return .{ .s = out };
            };
            const bounds = try f.range(into, false);
            const x = values[0].lin;
            const low = if (x != null and bounds.low != null) try atLeast(f.a, x.?, constant(bounds.low.?)) else null;
            const high = if (x != null and bounds.high != null) try atLeast(f.a, constant(bounds.high.?), x.?) else null;
            const within_type = low != null and high != null and try entails(f.a, out, low.?) and try entails(f.a, out, high.?);
            if (is(which, "@intCast")) {
                try f.record(node, .cast, within_type);
                // A safe build checks the conversion: past it the value is within.
                out = try assume(f.a, out, low);
                out = try assume(f.a, out, high);
                if (x != null) return .{ .s = out, .v = .{ .lin = x } };
                return f.fresh(out, node, 0);
            }
            if (within_type) return .{ .s = out, .v = .{ .lin = x } };
            return f.fresh(out, node, 0);
        }
        if (is(which, "@intFromBool")) {
            const made = try f.fresh(out, node, 0);
            const t = made.v.lin orelse return made;
            var bounded = try assume(f.a, made.s, try atLeast(f.a, t, constant(0)));
            bounded = try assume(f.a, bounded, try atLeast(f.a, constant(1), t));
            return .{ .s = bounded, .v = made.v };
        }
        if (is(which, "@min") or is(which, "@max")) {
            const made = try f.fresh(out, node, 0);
            out = made.s;
            const t = made.v.lin orelse return made;
            for (all.items) |each| if (each.lin) |x| {
                out = try assume(f.a, out, if (is(which, "@min")) try atLeast(f.a, x, t) else try atLeast(f.a, t, x));
            };
            return .{ .s = out, .v = made.v };
        }
        return f.fresh(out, node, 0);
    }

    //------------------------------------------------------------------
    // Conditions and branches.
    //------------------------------------------------------------------

    const Split = struct { yes: State, no: State };

    /// The states where a condition holds and where it fails.
    fn cond(f: *Frame, s: State, node: Ast.Node.Index) RunError!Split {
        if (s.dead) return .{ .yes = s, .no = s };
        const tree = f.tree;
        switch (tree.nodeTag(node)) {
            .grouped_expression => return f.cond(s, tree.nodeData(node).node_and_token[0]),
            .bool_not => {
                const inner = try f.cond(s, tree.nodeData(node).node);
                return .{ .yes = inner.no, .no = inner.yes };
            },
            .bool_and => {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                const left = try f.cond(s, lhs);
                const right = try f.cond(left.yes, rhs);
                return .{ .yes = right.yes, .no = try join(f.a, left.no, right.no) };
            },
            .bool_or => {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                const left = try f.cond(s, lhs);
                const right = try f.cond(left.no, rhs);
                return .{ .yes = try join(f.a, left.yes, right.yes), .no = right.no };
            },
            .less_than, .less_or_equal, .greater_than, .greater_or_equal, .equal_equal, .bang_equal => {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                const left = try f.eval(s, lhs);
                const right = try f.eval(left.s, rhs);
                const base = right.s;
                try f.counted(base, lhs, left.v.lin);
                try f.counted(base, rhs, right.v.lin);
                const x = left.v.lin orelse return .{ .yes = base, .no = base };
                const y = right.v.lin orelse return .{ .yes = base, .no = base };
                return switch (tree.nodeTag(node)) {
                    .less_than => .{ .yes = try assume(f.a, base, try above(f.a, y, x)), .no = try assume(f.a, base, try atLeast(f.a, x, y)) },
                    .less_or_equal => .{ .yes = try assume(f.a, base, try atLeast(f.a, y, x)), .no = try assume(f.a, base, try above(f.a, x, y)) },
                    .greater_than => .{ .yes = try assume(f.a, base, try above(f.a, x, y)), .no = try assume(f.a, base, try atLeast(f.a, y, x)) },
                    .greater_or_equal => .{ .yes = try assume(f.a, base, try atLeast(f.a, x, y)), .no = try assume(f.a, base, try above(f.a, y, x)) },
                    .equal_equal => .{ .yes = try f.same(base, x, y), .no = base },
                    else => .{ .yes = base, .no = try f.same(base, x, y) },
                };
            },
            .identifier => {
                const spelled = tree.tokenSlice(tree.nodeMainToken(node));
                if (std.mem.eql(u8, spelled, "true")) return .{ .yes = s, .no = State.unreachable_state };
                if (std.mem.eql(u8, spelled, "false")) return .{ .yes = State.unreachable_state, .no = s };
            },
            else => {},
        }
        const e = try f.eval(s, node);
        return .{ .yes = e.s, .no = e.s };
    }

    fn same(f: *Frame, s: State, x: Lin, y: Lin) Error!State {
        const out = try assume(f.a, s, try atLeast(f.a, x, y));
        return assume(f.a, out, try atLeast(f.a, y, x));
    }

    /// Binds a capture's declaration to what it captures, from the token its name is at, as the
    /// integer `int` where it is one.
    fn capture(f: *Frame, s: State, token: ?Ast.TokenIndex, value: Value, int: ?Range.Int) Error!State {
        var at = token orelse return s;
        if (f.tree.tokenTag(at) == .asterisk) at += 1;
        const d = f.decls.get(at) orelse return s;
        if (!f.tracked(d)) return s;
        return f.bind(s, d, value, int);
    }

    fn branch(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const full = f.tree.fullIf(node).?; // unreachable: the tag is an if's
        var split: Split = undefined;
        var payload: Value = .{};
        if (full.payload_token != null) {
            // An optional or error union: whether it holds a value says nothing linear.
            const e = try f.eval(s, full.ast.cond_expr);
            split = .{ .yes = try f.unwrap(e.s, e.v), .no = e.s };
            payload = .{ .lin = e.v.lin, .length = e.v.length };
        } else split = try f.cond(s, full.ast.cond_expr);
        const t = try f.temp(split.yes, node, 0);
        const tl = try f.variable(.{ .temp = .{ .node = node, .part = 1 } });
        var yes = try forget(f.a, try forget(f.a, split.no, t[1]), tl);
        _ = &yes;
        var then_state = try forget(f.a, t[0], tl);
        then_state = try f.capture(then_state, full.payload_token, payload, try f.intOf(full.ast.cond_expr));
        const then_value = try f.eval(then_state, full.ast.then_expr);
        var then_out = try f.assign(then_value.s, t[1], then_value.v.lin, null);
        then_out = try f.assign(then_out, tl, then_value.v.length, null);
        var else_out = yes;
        if (full.ast.else_expr.unwrap()) |else_expr| {
            else_out = try f.capture(else_out, full.error_token, .{}, null);
            const else_value = try f.eval(else_out, else_expr);
            else_out = try f.assign(else_value.s, t[1], else_value.v.lin, null);
            else_out = try f.assign(else_out, tl, else_value.v.length, null);
        }
        return .{ .s = try join(f.a, then_out, else_out), .v = .{ .lin = try single(f.a, t[1]), .length = try single(f.a, tl) } };
    }

    /// The state where an optional or error union held its payload: what the expression's
    /// summary gives there.
    fn unwrap(f: *Frame, s: State, value: Value) Error!State {
        var out = s;
        for (value.unwrapped) |row| out = try assume(f.a, out, row);
        return out;
    }

    fn tried(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const e = try f.eval(s, f.tree.nodeData(node).node);
        // The error leaves the function.
        try f.leave(e.s, true);
        return .{ .s = try f.unwrap(e.s, e.v), .v = .{ .lin = e.v.lin, .length = e.v.length } };
    }

    /// `x catch y`, `x orelse y`: `x`'s payload where it held one, `y` where it did not.
    fn otherwise(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const lhs, const rhs = f.tree.nodeData(node).node_and_node;
        const e = try f.eval(s, lhs);
        const t = try f.temp(e.s, node, 0);
        const tl = try f.variable(.{ .temp = .{ .node = node, .part = 1 } });
        const base = try forget(f.a, t[0], tl);
        var held = try f.unwrap(base, e.v);
        held = try f.assign(held, t[1], e.v.lin, null);
        held = try f.assign(held, tl, e.v.length, null);
        var missing = base;
        if (f.tree.nodeTag(node) == .@"catch") {
            const after = f.tree.nodeMainToken(node) + 1;
            if (f.tree.tokenTag(after) == .pipe) missing = try f.capture(missing, after + 1, .{}, null);
        }
        const fallback = try f.eval(missing, rhs);
        missing = try f.assign(fallback.s, t[1], fallback.v.lin, null);
        missing = try f.assign(missing, tl, fallback.v.length, null);
        return .{ .s = try join(f.a, held, missing), .v = .{ .lin = try single(f.a, t[1]), .length = try single(f.a, tl) } };
    }

    fn switchOn(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const full = f.tree.fullSwitch(node).?; // unreachable: the tag is a switch's
        // A labeled switch's `continue` re-enters it: not modelled.
        if (full.label_token != null) return error.Unsupported;
        const subject = try f.eval(s, full.ast.condition);
        const t = try f.temp(subject.s, node, 0);
        const tl = try f.variable(.{ .temp = .{ .node = node, .part = 1 } });
        const base = try forget(f.a, t[0], tl);
        var joined: State = State.unreachable_state;
        for (full.ast.cases) |case_node| {
            const case = f.tree.fullSwitchCase(case_node).?; // unreachable: a switch's cases
            var arm = base;
            // One literal or range a numeric subject matches: it holds in the prong.
            if (subject.v.lin) |x| if (case.ast.values.len == 1) {
                const item = case.ast.values[0];
                if (f.tree.nodeTag(item) == .switch_range) {
                    const lo, const hi = f.tree.nodeData(item).node_and_node;
                    const low = try f.eval(arm, lo);
                    const high = try f.eval(low.s, hi);
                    arm = high.s;
                    if (low.v.lin) |l| arm = try assume(f.a, arm, try atLeast(f.a, x, l));
                    if (high.v.lin) |h| arm = try assume(f.a, arm, try atLeast(f.a, h, x));
                } else {
                    const value = try f.eval(arm, item);
                    arm = value.s;
                    if (value.v.lin) |k| arm = try f.same(arm, x, k);
                }
            };
            arm = try f.capture(arm, case.payload_token, .{}, null);
            const e = try f.eval(arm, case.ast.target_expr);
            var done = try f.assign(e.s, t[1], e.v.lin, null);
            done = try f.assign(done, tl, e.v.length, null);
            joined = try join(f.a, joined, done);
        }
        return .{ .s = joined, .v = .{ .lin = try single(f.a, t[1]), .length = try single(f.a, tl) } };
    }

    //------------------------------------------------------------------
    // Jumps.
    //------------------------------------------------------------------

    fn returned(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        var out = s;
        var failed = false;
        if (f.tree.nodeData(node).opt_node.unwrap()) |operand| {
            const e = try f.eval(out, operand);
            out = e.s;
            failed = f.tree.nodeTag(operand) == .error_value;
            const result = try f.variable(.result);
            out = try f.assign(out, result, if (f.returns_int) e.v.lin else null, null);
            const result_length = try f.variable(.result_length);
            out = try f.assign(out, result_length, e.v.length, null);
        }
        try f.leave(out, failed);
        return .{ .s = State.unreachable_state };
    }

    fn jump(f: *Frame, s: State, node: Ast.Node.Index, breaks: bool) RunError!Eval {
        const label_token, const operand = f.tree.nodeData(node).opt_token_and_opt_node;
        var out = s;
        var value: Value = .{};
        if (operand.unwrap()) |given| {
            const e = try f.eval(out, given);
            out = e.s;
            value = e.v;
        }
        if (out.dead) return .{ .s = out };
        const label: ?[]const u8 = if (label_token.unwrap()) |t| f.tree.tokenSlice(t) else null;
        var i = f.targets.items.len;
        const found = while (i > 0) {
            i -= 1;
            const target = &f.targets.items[i];
            if (label) |wanted| {
                if (target.label) |has| if (std.mem.eql(u8, wanted, has)) break target;
            } else if (target.kind == .loop) break target;
        } else return error.Unsupported;
        if (!breaks and found.kind != .loop) return error.Unsupported;
        out = try f.runDefers(out, found.defers, false);
        if (breaks) if (found.value) |v| {
            out = try f.assign(out, v, value.lin, null);
        };
        // A jump from a pass being tried for the target's own invariant counts; one from a pass
        // tried deeper does not.
        if (found.trial == f.trial) {
            if (breaks) try found.breaks.append(f.a, out) else try found.continues.append(f.a, out);
        }
        return .{ .s = State.unreachable_state };
    }

    //------------------------------------------------------------------
    // Loops.
    //------------------------------------------------------------------

    const Pass = struct { back: State, exit: State, breaks: []const State };

    /// What a loop gives: the invariant its passes preserve, from the state it is entered in
    /// and the conditions' non-strict forms the entry already holds, read once more for the
    /// verdicts; then its exits joined.
    /// Which loop a pass reads: a `while`, its continue expression run after each pass, or a
    /// `for`, whose counter steps with its inputs.
    const Form = enum { @"while", @"for" };

    fn loop(f: *Frame, entered: State, node: Ast.Node.Index, label: ?[]const u8, conditions: []const Lin, form: Form) RunError!Eval {
        if (entered.dead) return .{ .s = entered };
        // The passes start at none, and each variable the loop steps is kept as it entered:
        // what a pass steps it by, at most, bounds how far it goes in so many passes.
        const p = try f.variable(.{ .passes = node });
        var entry = try f.assign(entered, p, constant(0), null);
        var all: std.ArrayList(Lin) = .empty;
        try all.appendSlice(f.a, conditions);
        entry = try f.stepCandidates(entry, node, p, &all);
        const candidates = all.items;
        // What the entry gives of the variables no pass assigns holds on every pass: its
        // constraints among them alone (`found0 = 0` where `found0 = found = 0`).
        var invariant = try f.fixedOver(entry, node);
        for (candidates) |row| if (try entails(f.a, entry, row)) {
            invariant = try assume(f.a, invariant, row);
        };
        const t = try f.temp(invariant, node, 7);
        invariant = t[0];
        var passes: usize = 0;
        while (true) : (passes += 1) {
            // Past its budget, the loop keeps only what no pass changes: the entry's facts among
            // the variables no pass assigns, where a pass keeps them, else nothing.
            if (passes > loop_passes) {
                invariant = try f.fixedOver(entry, node);
                f.trial += 1;
                const pass = try f.passOf(invariant, node, label, t[1], form);
                f.trial -= 1;
                if (!try implies(f.a, pass.back, invariant)) invariant = .{};
                break;
            }
            f.trial += 1;
            const pass = try f.passOf(invariant, node, label, t[1], form);
            f.trial -= 1;
            var next = try preserved(f.a, invariant, pass.back);
            // A candidate the head holds and the pass keeps is kept, though the head held it
            // in a tighter form the pass does not keep (`i < n` on entry, `i <= n` after).
            for (candidates) |row| {
                if (try entails(f.a, next, row)) continue;
                if (try entails(f.a, invariant, row) and try entails(f.a, pass.back, row)) next = try assume(f.a, next, row);
            }
            if (try implies(f.a, next, invariant)) break;
            invariant = next;
        }
        const final = try f.passOf(invariant, node, label, t[1], form);
        var out = final.exit;
        for (final.breaks) |state| out = try join(f.a, out, state);
        return .{ .s = out, .v = .{ .lin = try single(f.a, t[1]) } };
    }

    /// `s` with what it implies among the variables the loop `node` leaves alone: a value or
    /// length of a declaration made before the loop that nothing in it assigns, and the
    /// loop's own entry snapshots.
    fn fixedOver(f: *Frame, s: State, node: Ast.Node.Index) Error!State {
        const first = f.tree.firstToken(node);
        const last = f.tree.lastToken(node);
        var assigned: std.AutoHashMapUnmanaged(Model.Declaration.Id, void) = .empty;
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            switch (tag) {
                .assign, .assign_add, .assign_add_wrap, .assign_add_sat, .assign_sub, .assign_sub_wrap, .assign_sub_sat, .assign_mul, .assign_mul_wrap, .assign_mul_sat, .assign_div, .assign_mod, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor => {},
                .assign_destructure => return s,
                else => continue,
            }
            const inner: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const token = f.tree.nodeMainToken(inner);
            if (token < first or token > last) continue;
            const d = f.trackedName(f.tree.nodeData(inner).node_and_node[0]) orelse continue;
            try assigned.put(f.a, d, {});
        }
        var kept = s;
        for (f.vars.keys(), f.vars.values()) |key, v| {
            const fixed = switch (key) {
                .value, .length => |d| !assigned.contains(d) and outside(f.model.declarations[@backingInt(d)].token, first, last),
                .entry => |e| e.loop == node,
                else => false,
            };
            if (!fixed) kept = try forget(f.a, kept, v);
        }
        var out = s;
        for (kept.rows) |row| out = try assume(f.a, out, row);
        return out;
    }

    /// Each variable the loop `node` only steps one way, by an amount of at most `D` each time
    /// (`n += 1`, `total += byte`, `at = at - 2`): kept as it entered, with the candidates
    /// `0 <= v - v0 <= D·p` (or the same downward) over the passes `p`. A candidate a pass
    /// does not keep (two steps in one pass) is dropped like any other.
    fn stepCandidates(f: *Frame, s: State, node: Ast.Node.Index, p: Var, out: *std.ArrayList(Lin)) Error!State {
        const Step = struct { d: Model.Declaration.Id, up: bool, most: Coef, least: ?Coef = null, mixed: bool = false };
        var steps: std.ArrayList(Step) = .empty;
        const first = f.tree.firstToken(node);
        const last = f.tree.lastToken(node);
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            const inner: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const token = f.tree.nodeMainToken(inner);
            if (token < first or token > last) continue;
            const target, const value = switch (tag) {
                .assign, .assign_add, .assign_add_wrap, .assign_add_sat, .assign_sub, .assign_sub_wrap, .assign_sub_sat, .assign_mul, .assign_mul_wrap, .assign_mul_sat, .assign_div, .assign_mod, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor => f.tree.nodeData(inner).node_and_node,
                else => continue,
            };
            const d = f.trackedName(target) orelse continue;
            const found = for (steps.items) |*step| {
                if (step.d == d) break step;
            } else blk: {
                try steps.append(f.a, .{ .d = d, .up = true, .most = 0 });
                break :blk &steps.items[steps.items.len - 1];
            };
            const way = try f.stepOf(d, tag, value) orelse {
                found.mixed = true;
                continue;
            };
            if (found.most != 0 and found.up != way.up) found.mixed = true;
            found.up = way.up;
            found.most = @max(found.most, way.most);
            found.least = @min(found.least orelse way.least, way.least);
        }
        var entry = s;
        for (steps.items) |step| {
            if (step.mixed or step.most == 0) continue;
            const v = try single(f.a, try f.variable(.{ .value = step.d }));
            const v0_var = try f.variable(.{ .entry = .{ .loop = node, .d = step.d } });
            entry = try forget(f.a, entry, v0_var);
            entry = try f.equal(entry, v0_var, v);
            const v0 = try single(f.a, v0_var);
            const reach = (try scaled(f.a, try single(f.a, p), step.most)) orelse continue;
            if (step.up) {
                if (try atLeast(f.a, v, v0)) |row| try out.append(f.a, row);
                if (try plus(f.a, v0, reach)) |top| if (try atLeast(f.a, top, v)) |row| try out.append(f.a, row);
            } else {
                if (try atLeast(f.a, v0, v)) |row| try out.append(f.a, row);
                if (try plus(f.a, v, reach)) |bottom| if (try atLeast(f.a, bottom, v0)) |row| try out.append(f.a, row);
            }
            // A step of at least `k` on each path through a pass (`: (i += 1)`) goes at least
            // `k·p`: the count of passes is then bounded by how far the variable may go.
            const least = step.least orelse 0;
            if (least == 0) continue;
            const gone = (try scaled(f.a, try single(f.a, p), least)) orelse continue;
            if (step.up) {
                if (try plus(f.a, v0, gone)) |bottom| if (try atLeast(f.a, v, bottom)) |row| try out.append(f.a, row);
            } else {
                if (try plus(f.a, v, gone)) |top| if (try atLeast(f.a, v0, top)) |row| try out.append(f.a, row);
            }
        }
        return entry;
    }

    /// An assignment to `d` as a step: which way and by at most how much, or null where it is
    /// no step (a wrapping one, a product, a value of its own).
    fn stepOf(f: *Frame, d: Model.Declaration.Id, tag: Ast.Node.Tag, value: Ast.Node.Index) Error!?struct { up: bool, most: Coef, least: Coef } {
        const up, const amount = switch (tag) {
            .assign_add, .assign_add_sat => .{ true, value },
            .assign_sub, .assign_sub_sat => .{ false, value },
            .assign => switch (f.tree.nodeTag(value)) {
                .add, .add_sat, .sub, .sub_sat => blk: {
                    const lhs, const rhs = f.tree.nodeData(value).node_and_node;
                    const sum = f.tree.nodeTag(value) == .add or f.tree.nodeTag(value) == .add_sat;
                    if (f.trackedName(lhs) == d) break :blk .{ sum, rhs };
                    if (sum and f.trackedName(rhs) == d) break :blk .{ true, lhs };
                    return null;
                },
                else => return null,
            },
            else => return null,
        };
        if (f.trackedName(amount) == d) return null;
        if (f.tree.nodeTag(amount) == .number_literal) switch (std.zig.parseNumberLiteral(f.tree.tokenSlice(f.tree.nodeMainToken(amount)))) {
            .int => |k| return .{ .up = up, .most = k, .least = k },
            else => return null,
        };
        const int = (try f.intOf(amount)) orelse return null;
        if (int.signed) return null;
        const most = (try f.range(int, true)).high orelse return null;
        return .{ .up = up, .most = most, .least = 0 };
    }

    fn passOf(f: *Frame, invariant: State, node: Ast.Node.Index, label: ?[]const u8, value: Var, form: Form) RunError!Pass {
        try f.targets.append(f.a, .{ .kind = .loop, .label = label, .defers = f.defers.items.len, .trial = f.trial, .value = value });
        const ran = (switch (form) {
            .@"while" => f.whileBody(invariant, node),
            .@"for" => f.forBody(invariant, node),
        }) catch |err| {
            _ = f.targets.pop();
            return err;
        };
        const target = f.targets.pop().?; // unreachable: pushed above
        var back = ran.body;
        for (target.continues.items) |state| back = try join(f.a, back, state);
        if (form == .@"while") back = try f.whileContinue(back, node);
        // One more pass has run.
        const p = try f.variable(.{ .passes = node });
        back = try f.assign(back, p, try plus(f.a, try single(f.a, p), constant(1)), null);
        return .{ .back = back, .exit = ran.exit, .breaks = target.breaks.items };
    }

    fn whileLoop(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const full = f.tree.fullWhile(node).?; // unreachable: the tag is a while's
        const label: ?[]const u8 = if (full.label_token) |t| f.tree.tokenSlice(t) else null;
        var candidates: std.ArrayList(Lin) = .empty;
        if (full.payload_token == null) try f.candidatesOf(s, full.ast.cond_expr, &candidates);
        return f.loop(s, node, label, candidates.items, .@"while");
    }

    fn whileBody(f: *Frame, s: State, node: Ast.Node.Index) RunError!Ran {
        const full = f.tree.fullWhile(node).?; // unreachable: the tag is a while's
        var split: Split = undefined;
        var payload: Value = .{};
        if (full.payload_token != null) {
            const e = try f.eval(s, full.ast.cond_expr);
            split = .{ .yes = try f.unwrap(e.s, e.v), .no = e.s };
            payload = .{ .lin = e.v.lin, .length = e.v.length };
            try f.counted(e.s, full.ast.cond_expr, e.v.lin);
        } else split = try f.cond(s, full.ast.cond_expr);
        const entered = try f.capture(split.yes, full.payload_token, payload, try f.intOf(full.ast.cond_expr));
        const ran = try f.exec(entered, full.ast.then_expr);
        var exit = split.no;
        if (full.ast.else_expr.unwrap()) |else_expr| exit = (try f.eval(try f.capture(exit, full.error_token, .{}, null), else_expr)).s;
        return .{ .body = ran, .exit = exit };
    }

    fn whileContinue(f: *Frame, s: State, node: Ast.Node.Index) RunError!State {
        const full = f.tree.fullWhile(node).?; // unreachable: the tag is a while's
        const step = full.ast.cont_expr.unwrap() orelse return s;
        return f.exec(s, step);
    }

    /// A loop condition's comparisons in their non-strict forms (`i < n` gives `i <= n`):
    /// what a counter stepping toward its bound keeps on every pass.
    fn candidatesOf(f: *Frame, s: State, node: Ast.Node.Index, out: *std.ArrayList(Lin)) RunError!void {
        const tree = f.tree;
        switch (tree.nodeTag(node)) {
            .grouped_expression => return f.candidatesOf(s, tree.nodeData(node).node_and_token[0], out),
            .bool_and => {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                try f.candidatesOf(s, lhs, out);
                try f.candidatesOf(s, rhs, out);
            },
            .less_than, .less_or_equal, .greater_than, .greater_or_equal => {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                const was_trial = f.trial;
                // Read for their forms alone: no verdicts.
                f.trial += 1;
                defer f.trial = was_trial;
                const left = f.eval(s, lhs) catch return;
                const right = f.eval(left.s, rhs) catch return;
                const x = left.v.lin orelse return;
                const y = right.v.lin orelse return;
                const row = switch (tree.nodeTag(node)) {
                    .less_than, .less_or_equal => try atLeast(f.a, y, x),
                    else => try atLeast(f.a, x, y),
                };
                if (row) |r| try out.append(f.a, r);
            },
            else => {},
        }
    }

    fn forLoop(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const full = f.tree.fullFor(node).?; // unreachable: the tag is a for's
        const label: ?[]const u8 = if (full.label_token) |t| f.tree.tokenSlice(t) else null;
        // The inputs are read once, before the passes: their lengths are equal, which a safe
        // build checks.
        var out = s;
        var count: ?Lin = null;
        for (full.ast.inputs) |input| {
            var length: ?Lin = null;
            if (f.tree.nodeTag(input) == .for_range) {
                const start_node, const end_node = f.tree.nodeData(input).node_and_opt_node;
                const start = try f.eval(out, start_node);
                out = start.s;
                if (end_node.unwrap()) |e_node| {
                    const end = try f.eval(out, e_node);
                    out = end.s;
                    try f.counted(out, e_node, end.v.lin);
                    if (start.v.lin != null and end.v.lin != null) {
                        length = try minus(f.a, end.v.lin.?, start.v.lin.?);
                        // A range's end is at least its start, which a safe build checks.
                        out = try assume(f.a, out, try atLeast(f.a, end.v.lin.?, start.v.lin.?));
                    }
                }
            } else {
                const m = try f.eval(out, input);
                const measured = try f.lengthOf(m.s, input, m.v);
                out = measured[0];
                length = measured[1];
            }
            if (length) |l| {
                if (count) |n| out = try f.same(out, n, l) else count = l;
            }
        }
        const counter = try f.variable(.{ .temp = .{ .node = node, .part = 6 } });
        _ = counter;
        try f.for_counts.put(f.a, node, count);
        const result = try f.loop(out, node, label, &.{}, .@"for");
        // Its `else` runs where the passes ran out.
        return result;
    }

    fn forBody(f: *Frame, s: State, node: Ast.Node.Index) RunError!Ran {
        const full = f.tree.fullFor(node).?; // unreachable: the tag is a for's
        // The counter read again at its own place; `count` and the counter were set by the loop.
        const count = f.for_counts.get(node) orelse null;
        const counter = try f.variable(.{ .temp = .{ .node = node, .part = 6 } });
        var entered = try forget(f.a, s, counter);
        const k = try single(f.a, counter);
        entered = try assume(f.a, entered, try atLeast(f.a, k, constant(0)));
        if (count) |n| entered = try assume(f.a, entered, try above(f.a, n, k));
        // The counter is the passes run before this one.
        entered = try f.same(entered, k, try single(f.a, try f.variable(.{ .passes = node })));
        // Captures: a range's is its start plus the counter; an element's, nothing known.
        var token = full.payload_token;
        for (full.ast.inputs) |input| {
            if (f.tree.tokenTag(token) == .asterisk) token += 1;
            var value: Value = .{};
            if (f.tree.nodeTag(input) == .for_range) {
                const start_node, _ = f.tree.nodeData(input).node_and_opt_node;
                const was_trial = f.trial;
                f.trial += 1;
                const start = f.eval(entered, start_node) catch |err| {
                    f.trial = was_trial;
                    return err;
                };
                f.trial = was_trial;
                if (start.v.lin) |first| value.lin = try plus(f.a, first, k);
            }
            entered = try f.capture(entered, token, value, if (f.tree.nodeTag(input) == .for_range) .{ .bits = f.width, .signed = false } else null);
            token += 1;
            if (f.tree.tokenTag(token) == .comma) token += 1;
        }
        const ran = try f.exec(entered, full.ast.then_expr);
        // Out of passes: every pass ran, or none did.
        var exit = s;
        if (full.ast.else_expr.unwrap()) |else_expr| exit = (try f.eval(exit, else_expr)).s;
        return .{ .body = ran, .exit = exit };
    }

    //------------------------------------------------------------------
    // Calls.
    //------------------------------------------------------------------

    /// A call: its arguments evaluated in order, and where it reaches one function of the
    /// program, that function's summary on the path where it returns a value.
    fn call(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        var buffer: [1]Ast.Node.Index = undefined;
        const full = f.tree.fullCall(&buffer, node).?; // unreachable: the tag is a call's
        var out = s;
        var receiver: ?Value = null;
        if (f.tree.nodeTag(full.ast.fn_expr) == .field_access) {
            const holder = f.tree.nodeData(full.ast.fn_expr).node_and_token[0];
            const e = try f.eval(out, holder);
            out = e.s;
            switch (try f.c.facts.resolve(f.file, holder)) {
                .instance, .pointer, .optional => {
                    const measured = try f.lengthOf(out, holder, e.v);
                    out = measured[0];
                    receiver = .{ .lin = e.v.lin, .length = measured[1] };
                },
                else => {},
            }
        }
        var args: std.ArrayList(Value) = .empty;
        if (receiver) |r| try args.append(f.a, r);
        for (full.ast.params) |param| {
            const e = try f.eval(out, param);
            out = e.s;
            if (e.v.lin != null) {
                try args.append(f.a, .{ .lin = e.v.lin });
                continue;
            }
            const measured = try f.lengthOf(out, param, e.v);
            out = measured[0];
            try args.append(f.a, .{ .length = measured[1] });
        }
        const made = try f.fresh(out, node, 0);
        out = made.s;
        const t = made.v.lin;
        const tl = try f.variable(.{ .temp = .{ .node = node, .part = 1 } });
        out = try forget(f.a, out, tl);
        const summary = try f.summaryOf(full.ast.fn_expr) orelse return .{ .s = out, .v = .{ .lin = t, .length = try single(f.a, tl) } };
        var rows: std.ArrayList(Lin) = .empty;
        each: for (summary.rows) |row| {
            var applied: Lin = constant(row.c);
            for (row.terms) |term| {
                const param = term.v / 2;
                const length = term.v % 2 == 1;
                const given: ?Lin = if (param == summary.params)
                    (if (length) try single(f.a, tl) else t)
                else if (param < args.items.len)
                    (if (length) args.items[param].length else args.items[param].lin)
                else
                    null;
                const lin = given orelse continue :each;
                applied = (try combine(f.a, applied, 1, lin, term.k)) orelse continue :each;
            }
            try rows.append(f.a, applied);
        }
        const value: Value = .{ .lin = t, .length = try single(f.a, tl), .unwrapped = rows.items };
        if (summary.fails) return .{ .s = out, .v = value };
        // A callee that cannot fail returns where it succeeds.
        return .{ .s = try f.unwrap(out, value), .v = .{ .lin = t, .length = value.length } };
    }

    /// The summary of the one function of the program a call reaches, at this pointer width.
    fn summaryOf(f: *Frame, callee: Ast.Node.Index) Error!?struct { rows: []const Lin, params: usize, fails: bool } {
        const decl = switch (try f.c.facts.resolve(f.file, callee)) {
            .function => |d| d,
            else => return null,
        };
        if (!try Program.owns(f.c, decl.file)) return null;
        const callee_tree = &f.c.project.at(decl.file).file.tree;
        const callee_model = &f.c.project.at(decl.file).model;
        const proto = callee_model.declarations[@backingInt(decl.index)].node;
        const function = callee_model.parentOf(proto) orelse return null;
        if (callee_tree.nodeTag(function) != .fn_decl) return null;
        const read = try analysis(f.c, decl.file, function, f.width);
        if (!read.supported) return null;
        const summary = read.summary orelse return null;
        var proto_buffer: [1]Ast.Node.Index = undefined;
        const full = callee_tree.fullFnProto(&proto_buffer, proto) orelse return null;
        const result = full.ast.return_type.unwrap() orelse return null;
        const fails = callee_tree.nodeTag(result) == .error_union or
            (callee_tree.firstToken(result) > 0 and callee_tree.tokenTag(callee_tree.firstToken(result) - 1) == .bang);
        return .{ .rows = summary.rows, .params = summary.params, .fails = fails };
    }
};

/// The most entries `memory` holds where it is one of the tables std names by a u32 index (an
/// `Ast`'s `nodes` or `tokens`), or a field's view of one (`t.nodes.items(.tag)`). std makes
/// each node's index with `@intCast(p.nodes.len)` (zig/Parse.zig:78, `addNode`; a reserved
/// node's index is cast where it is set) and each token's start with `@intCast` of its offset
/// (zig/Ast.zig:162), so a table past `maxInt(u32) + 1` entries is never made.
fn table(c: *Context, file: Project.FileId, memory: Ast.Node.Index) Error!?Coef {
    const tree = &c.project.at(file).file.tree;
    var node = memory;
    var buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&buffer, node)) |call| {
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
        const holder, const name = tree.nodeData(call.ast.fn_expr).node_and_token;
        if (!std.mem.eql(u8, tree.tokenSlice(name), "items")) return null;
        node = holder;
    }
    if (tree.nodeTag(node) != .field_access) return null;
    const decl = (try c.facts.definition(file, node)) orelse return null;
    const tables = try c.facts.memo(Tables);
    if (!tables.found) {
        tables.found = true;
        for ((try Governed.declarations(c, "std", "zig.Ast")) orelse &.{}) |ast| {
            const value = try c.facts.declaration((try c.facts.origin(ast)) orelse ast);
            if (value != .container) continue;
            for ([_][]const u8{ "nodes", "tokens" }) |name| if (c.facts.member(value.container, name)) |field| {
                try tables.fields.append(c.allocator, field);
            };
        }
    }
    const field = (try c.facts.origin(decl)) orelse decl;
    for (tables.fields.items) |each| if (std.meta.eql(each, field)) return @as(Coef, std.math.maxInt(u32)) + 1;
    return null;
}
const Tables = struct { found: bool = false, fields: std.ArrayList(Facts.Decl) = .empty };

/// A labeled block's label: `blk: { … }`.
fn blockLabel(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    const brace = tree.nodeMainToken(node);
    if (brace < 2 or tree.tokenTag(brace - 1) != .colon or tree.tokenTag(brace - 2) != .identifier) return null;
    return tree.tokenSlice(brace - 2);
}

fn outside(token: Ast.TokenIndex, first: Ast.TokenIndex, last: Ast.TokenIndex) bool {
    return token < first or token > last;
}
