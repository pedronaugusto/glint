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
const accesses = Facts.accesses;
const formAt = Range.formAt;
const nameRef = Range.nameRef;
const spellsName = Range.spellsName;
const Program = @import("Program.zig");
const Facts = @import("Facts.zig");
const Governed = @import("Governed.zig");
const aegis = @import("aegis");

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
fn impossible(rows: []const Lin) Error!bool {
    // What the steps work through is the answer's alone: it goes when the answer does, not when
    // the reading ends.
    var scratch: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
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
    return impossible(rows);
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
    if (try impossible(kept)) return State.unreachable_state;
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
    /// A loop's passes at most a short's count, or the length of memory the function holds that
    /// the loop does not change: no more passes than the work a peer already sent, whatever
    /// decides them. Keyed by the loop.
    passes,
    /// A switch prong no path takes: no value the subject can have there is one of its items,
    /// or, for an `else`, every value it can have is another prong's. Keyed by the prong.
    untaken,
    /// A `.?` whose operand holds a value on every path: no null reaches its `unreachable`.
    /// Keyed by the unwrap.
    present,
    /// A `catch` whose operand never fails there: on every path, what the call it gives is
    /// given rules out each of its callee's failing exits. Keyed by the `catch`.
    unfailing,
};

const Site = struct { node: Ast.Node.Index, kind: Kind };

/// A function read at one pointer width: whether every construct in it was modelled, each
/// site's verdict on every path that reached it, and its summary.
const Analysis = struct {
    supported: bool = false,
    verdicts: std.AutoHashMapUnmanaged(Site, bool) = .empty,
    summary: ?Summary = null,
    /// What each program function this one calls is given: the join, over its calls here
    /// that the reading reached, of the state at the call projected onto the callee's
    /// parameter slots (`slot`); null where a call's arguments do not match its parameters.
    calls: std.AutoHashMapUnmanaged(Callee, ?[]const Lin) = .empty,
    /// The calls the reading reached, on a path it did not try: a call it did not reach
    /// leaves what it gives its callee unknown.
    reached: std.AutoHashMapUnmanaged(Ast.Node.Index, void) = .empty,
};

/// A function of the program by its `fn` declaration.
const Callee = struct { file: Project.FileId, function: Ast.Node.Index };

/// What a function's successful returns give of its parameters and result: constraints over
/// slots, each parameter's value and length and the result's (`slot`), and each place of a
/// parameter's at entry and, through a pointer, at its exit (`placeSlot`).
const Summary = struct {
    rows: []const Lin,
    /// What each successful exit gives, apart, where they are few (`summary_exits`): a call
    /// reads each where its caller's state lets it be taken, and joins what they leave
    /// (`Frame.unwrap`). `rows` is their join, read where there are more.
    exits: []const []const Lin = &.{},
    /// What every failing exit gives of the parameters' slots at entry (`never` where none
    /// fails): an error path of a call is read past only where these hold.
    failing: []const Lin = &never,
    params: usize,
    places: []const SlotPlace = &.{},
    /// The fields of the program's structs the function may write, through any pointer; null
    /// where it may write any.
    written: ?[]const Facts.Decl = null,
};

/// The most successful exits a summary keeps apart (`Summary.exits`): past them, their join.
const summary_exits = 4;

/// `-1 ≥ 0`: the summary of a function that never succeeds, or never fails.
const never = [_]Lin{constant(-1)};

/// A field of a parameter's struct, or of the struct it points to, a summary reads.
const SlotPlace = struct {
    param: usize,
    /// The parameter's declaration, in the function the summary is of.
    root: Model.Declaration.Id,
    field: Facts.Decl,
    /// A pointer parameter's: the caller's struct holds what the callee leaves in it.
    exits: bool,
    /// Its memory's elements take room (`Facts.sizedMemory`).
    sized: bool,
};

fn slot(param: usize, length: bool) Var {
    return @intCast(param * 2 + @intFromBool(length));
}

/// How many places a summary gives: as many as a call's temporaries hold.
const max_slot_places = 6;
/// The temporaries of an operator's node that hold its left operand (`heldPast`), past any part
/// an operator's own value takes.
const held_part: u8 = 8;

/// A summary's slot of its `k`th place, after the parameters' and the result's: its value or
/// length at entry or at exit, a length's slot odd as `slot`'s are. A function of more
/// parameters than a u16 counts gives no places.
fn placeSlot(params: u16, k: u3, exit: bool, length: bool) Var {
    return (@as(Var, params) + 1) * 2 + @as(Var, k) * 4 + @as(Var, @intFromBool(exit)) * 2 + @intFromBool(length);
}

const Analyses = struct {
    /// Each function at a width, read alone or at one reading of a call (`Facts.bindCall`).
    map: std.AutoHashMapUnmanaged(struct { Project.FileId, Ast.Node.Index, u16, ?*const Facts.Env }, *Analysis) = .empty,
    /// How deep summaries are being read through calls.
    depth: u8 = 0,
};

fn analysis(c: *Context, file: Project.FileId, function: Ast.Node.Index, width: u16) Error!*Analysis {
    return analysisIn(c, null, file, function, width);
}

/// `function` read at `bound`, one reading of a call of it, its parameters typed by what the
/// call binds (`comptime T: type` given `usize`): only its summary is read from it, never a
/// verdict, which holds for the function's every call (`cleared`).
fn analysisIn(c: *Context, bound: ?*const Facts.Env, file: Project.FileId, function: Ast.Node.Index, width: u16) Error!*Analysis {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    try proveRelations(c);
    const memo = try c.facts.memo(Analyses);
    const key = .{ file, function, width, bound };
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
    try readInto(c, made, file, function, width, null, bound);
    return made;
}

/// One reading of `function` into `made`, its parameters starting from their types and, where
/// given, `entry`: constraints over their slots that every call of it in the program holds.
fn readInto(c: *Context, made: *Analysis, file: Project.FileId, function: Ast.Node.Index, width: u16, given: ?[]const Lin, bound: ?*const Facts.Env) Error!void {
    // On `backing`: the run's arena would keep each reading's scratch to the run's end.
    var scratch: std.heap.ArenaAllocator = .init(c.backing);
    defer scratch.deinit();
    var frame: Frame = .{ .c = c, .a = scratch.allocator(), .file = file, .tree = &c.project.at(file).file.tree, .model = &c.project.at(file).model, .width = width, .function = function, .entry = given, .bound = bound };
    frame.run() catch |err| switch (err) {
        error.Unsupported => return,
        else => |e| return e,
    };
    made.supported = true;
    // A reading at a binding, or of std's code, is asked only for its summary (`summaryOf`):
    // what it gives its callees and its verdicts are never read, so they are not kept.
    if (bound == null and try Program.owns(c, file)) try keepReading(c, made, &frame);
    if (frame.summary) |summary| made.summary = .{ .rows = try persisted(c.allocator, summary.rows), .exits = exits: {
        const kept = try c.allocator.alloc([]const Lin, summary.exits.len);
        for (summary.exits, kept) |rows, *copy| copy.* = try persisted(c.allocator, rows);
        break :exits kept;
    }, .failing = try persisted(c.allocator, summary.failing), .params = summary.params, .places = try c.allocator.dupe(SlotPlace, summary.places), .written = if (summary.written) |fields| try c.allocator.dupe(Facts.Decl, fields) else null };
}

/// What a reading of the program's own function gives the run beyond its summary: what it
/// gives each callee, the calls it reached, its verdicts.
fn keepReading(c: *Context, made: *Analysis, frame: *const Frame) Error!void {
    var calls = frame.calls.iterator();
    while (calls.next()) |call| try made.calls.put(c.allocator, call.key_ptr.*, if (call.value_ptr.*) |rows| try persisted(c.allocator, rows) else null);
    var reached = frame.reached.keyIterator();
    while (reached.next()) |call| try made.reached.put(c.allocator, call.*, {});
    var it = frame.verdicts.iterator();
    while (it.next()) |entry| try made.verdicts.put(c.allocator, entry.key_ptr.*, entry.value_ptr.*);
}

/// Rows copied out of a reading's scratch memory.
fn persisted(a: std.mem.Allocator, rows: []const Lin) Error![]const Lin {
    const out = try a.alloc(Lin, rows.len);
    for (rows, out) |row, *copy| copy.* = .{ .terms = try a.dupe(Term, row.terms), .c = row.c };
    return out;
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
    const site: Site = .{ .node = node, .kind = kind };
    for (Range.pointerWidths(c)) |width| {
        // Read from the parameters' types, or from what every caller gives them.
        const alone = try analysis(c, file, function, width);
        if (alone.supported and (alone.verdicts.get(site) orelse false)) continue;
        const called = try byCallers(c, file, function, width);
        if (called.supported and (called.verdicts.get(site) orelse false)) continue;
        return false;
    }
    return true;
}

//======================================================================
// Relations between a struct's fields.
//======================================================================

/// `small <= large` (or at most `large`'s length) of two fields of one struct, on every instance
/// of it at every point a program reads it: `pos <= end`, `end <= buf.len`.
///
/// Proved by induction over every write the program makes of either, each judged by this file's
/// own reading of the function that makes it (`judgeStore`, `judgeLiteral`): a literal gives
/// both; `x.small = v` puts `v` at most `x.large` there, and `x.large = w` at least `x.small`,
/// given what holds up to there. A whole value of the struct holds it by the same induction;
/// `undefined`, or one that does not resolve to the struct, holds nothing. The relations are
/// proved together: each reading assumes all those not yet refused, any that fails is refused and
/// all are read again, until none fails, on one budget (none where it runs short). Those left each hold, by induction over the program's
/// writes, whatever the order: every write keeps every one of them, given that they held before it.
///
/// One holds only where every write is seen and judged: a field the program alone writes, by
/// name, its address never taken (`Range.placeable`), and each write in a function Bounds reads,
/// through a name it tracks. Anything else, a holder that does not resolve, a budget, a
/// function it does not model, leaves no relation: it never decides a site, it only clears one.
///
/// A public field a consumer in another package writes is outside this: a package's lint reads
/// its own program, as `Range`'s field ranges do. Two stores in sequence are each judged against
/// the other's old value, so no point between them breaks it for this task; another task reading
/// there without a lock is a race, which is not this rule's.
const Relation = struct { small: Facts.Decl, large: Facts.Decl, length: bool };

/// A relation being proved: the literals that write it and what each gives, the nodes of the
/// writes a reading must meet, and those it has met.
const Proof = struct {
    relation: Relation,
    failed: bool = false,
    /// Refused in an earlier pass, as `proveRelations` counts them.
    seen_failed: bool = false,
    literals: std.AutoHashMapUnmanaged(Ast.Node.Index, LiteralGives) = .empty,
    checked: std.AutoHashMapUnmanaged(Ast.Node.Index, void) = .empty,
    expected: std.ArrayList(Expected) = .empty,

    const LiteralGives = struct { small: ?Ast.Node.Index = null, large: ?Ast.Node.Index = null };
    const Expected = struct { file: Project.FileId, function: Ast.Node.Index, node: Ast.Node.Index };
};

const Relations = struct {
    built: bool = false,
    building: bool = false,
    /// By either field: what holds of it.
    of: std.AutoHashMapUnmanaged(Facts.Decl, std.ArrayList(Relation)) = .empty,
};

/// What holds of `field` with its siblings: what the proofs assume while they run.
fn relationsOf(c: *Context, field: Facts.Decl) Error![]const Relation {
    const memo = try c.facts.memo(Relations);
    return if (memo.of.get(field)) |list| list.items else &.{};
}

/// A field's default, as a value at that field's type: its constant, or for `length` the length
/// of an empty slice. Null where it has none, or it is any other value (`undefined` among them).
fn defaultOf(c: *Context, member: Facts.Decl, length: bool) Error!?Lin {
    const tree = &c.project.at(member.file).file.tree;
    const model = &c.project.at(member.file).model;
    const record = model.declarations[@backingInt(member.index)];
    const full = model.containerField(tree, record.node) orelse return null;
    const node = full.ast.value_expr.unwrap() orelse return null;
    if (length) {
        const held = (try Range.memoryLength(c, member.file, node)) orelse return null;
        return if (held <= std.math.maxInt(Coef)) constant(@intCast(held)) else null;
    }
    const value = (try Range.constantValue(c, member.file, node)) orelse return null;
    if (value > std.math.maxInt(Coef)) return null;
    return constant(@intCast(value));
}

/// Proves the relations, once, before anything Bounds keeps is read: what a reading finds with
/// them is read with all of them, in any order of files. What the proofs read of their callees
/// is dropped when they end.
fn proveRelations(c: *Context) Error!void {
    const memo = try c.facts.memo(Relations);
    if (memo.built or memo.building) return;
    memo.building = true;
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    var proofs: std.ArrayList(Proof) = .empty;
    for (try Range.programFiles(c)) |file| try candidatesIn(c, file, &proofs);
    // Each function is read once per width, for every relation it writes.
    // The proofs no longer grow: each is named by where it is.
    var by_function: std.array_hash_map.Auto(Callee, std.ArrayList(*Proof)) = .empty;
    for (proofs.items) |*proof| {
        if (proof.failed) continue;
        for (proof.expected.items) |one| {
            const entry = try by_function.getOrPut(c.allocator, .{ .file = one.file, .function = one.function });
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            if (std.mem.findScalar(*Proof, entry.value_ptr.items, proof) == null) try entry.value_ptr.append(c.allocator, proof);
        }
    }
    // The proofs are one unit of solving, on the run's budget for one: every pass is charged to
    // it, and where it runs short none is shown. Each pass but the last refuses at least one, so
    // they end by themselves.
    const asker = c.facts.enter(c.config.fact_budget);
    while (true) {
        // What is read from here rests on what these assume: nothing earlier is kept.
        memo.of = .empty;
        (try c.facts.memo(Analyses)).* = .{};
        (try c.facts.memo(Entries)).* = .{};
        var left = false;
        for (proofs.items) |*proof| {
            if (proof.failed) continue;
            left = true;
            for ([_]Facts.Decl{ proof.relation.small, proof.relation.large }) |member| {
                const entry = try memo.of.getOrPut(c.allocator, member);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(c.allocator, proof.relation);
            }
        }
        if (!left) break;
        var refused = false;
        for (Range.pointerWidths(c)) |width| {
            for (proofs.items) |*proof| proof.checked.clearRetainingCapacity();
            for (by_function.keys(), by_function.values()) |callee, which| {
                var some = false;
                for (which.items) |proof| some = some or !proof.failed;
                if (!some) continue;
                try readProving(c, callee, width, which.items);
            }
            // A write no reading met is one no reading judged.
            for (proofs.items) |*proof| {
                if (proof.failed) continue;
                for (proof.expected.items) |one| {
                    if (!proof.checked.contains(one.node)) proof.failed = true;
                }
            }
        }
        // Read short of the budget, what a pass showed may rest on an answer cut short: none.
        if (c.facts.short) for (proofs.items) |*proof| {
            proof.failed = true;
        };
        for (proofs.items) |*proof| {
            if (proof.failed and !proof.seen_failed) {
                proof.seen_failed = true;
                refused = true;
            }
        }
        if (!refused) break;
    }
    _ = c.facts.leave(asker);
    (try c.facts.memo(Analyses)).* = .{};
    (try c.facts.memo(Entries)).* = .{};
    memo.built = true;
    memo.building = false;
}

/// One reading of `callee` judging the relations at `which`.
fn readProving(c: *Context, callee: Callee, width: u16, which: []const *Proof) Error!void {
    var scratch: std.heap.ArenaAllocator = .init(c.backing);
    defer scratch.deinit();
    const proving = try scratch.allocator().alloc(Proof, which.len);
    for (which, proving) |proof, *one| one.* = proof.*;
    var frame: Frame = .{ .c = c, .a = scratch.allocator(), .file = callee.file, .tree = &c.project.at(callee.file).file.tree, .model = &c.project.at(callee.file).model, .width = width, .function = callee.function, .entry = null, .bound = null, .proving = proving };
    frame.run() catch |err| switch (err) {
        // A function it does not model meets no write: each stays unchecked, and fails.
        error.Unsupported => {},
        else => |e| return e,
    };
    for (which, proving) |proof, one| proof.* = one;
}

/// The relations a file's structs may hold: an integer field at most another, or at most a
/// slice field's length; each with what the program writes of either read, or failed where a
/// write is not one a reading can judge.
fn candidatesIn(c: *Context, file: Project.FileId, proofs: *std.ArrayList(Proof)) Error!void {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var fields: std.ArrayList(Sibling) = .empty;
    for (model.declarations, 0..) |record, d| {
        if (record.kind != .field) continue;
        const decl: Facts.Decl = .{ .file = file, .index = @fromBackingInt(aegis.int.cast(u32, d) catch continue) };
        const full = model.containerField(tree, record.node) orelse continue;
        const type_node = full.ast.type_expr.unwrap() orelse continue;
        const slice = if (tree.fullPtrType(type_node)) |pointer| pointer.size == .slice else false;
        if (!slice and !try Range.integral(c, file, type_node)) continue;
        if (!try Range.placeable(c, decl)) continue;
        try fields.append(c.allocator, .{ .decl = decl, .scope = record.scope, .slice = slice });
    }
    for (fields.items) |small| {
        if (small.slice) continue;
        for (fields.items) |large| {
            if (large.scope != small.scope or std.meta.eql(large.decl, small.decl)) continue;
            var proof: Proof = .{ .relation = .{ .small = small.decl, .large = large.decl, .length = large.slice } };
            try sitesOf(c, &proof);
            if (!proof.failed) try proofs.append(c.allocator, proof);
        }
    }
}

const Sibling = struct { decl: Facts.Decl, scope: Model.Scope.Id, slice: bool };

/// What the program writes of a relation's fields, into `proof`.
fn sitesOf(c: *Context, proof: *Proof) Error!void {
    for ([_]Facts.Decl{ proof.relation.small, proof.relation.large }, 0..) |member, side| {
        var sites = Facts.accesses.writes(c.facts, .{ .field = member }, try Range.programFiles(c));
        while (try sites.next()) |site| {
            const tree = &c.project.at(site.file).file.tree;
            if (site.computed) return fail(proof);
            switch (site.kind) {
                .read => continue,
                .init, .set, .update => {},
                .covered, .address, .open => return fail(proof),
            }
            switch (site.reach) {
                .named, .unresolved => return fail(proof),
                .holder => {
                    // A whole value holds it where the struct does; a literal is judged itself.
                    const value = Facts.ungrouped(tree, site.value orelse return fail(proof));
                    var buffer: [2]Ast.Node.Index = undefined;
                    if (tree.fullStructInit(&buffer, value) != null) continue;
                    const made = try c.facts.resolve(site.file, value);
                    const record = c.project.at(member.file).model.declarations[@backingInt(member.index)];
                    if (made != .instance or made.instance.file != member.file or made.instance.scope != record.scope) return fail(proof);
                    continue;
                },
                .exact => {},
            }
            // The field's own default: read with the literals that take it.
            if (c.project.at(site.file).model.containerField(tree, site.node) != null) continue;
            const function = functionOf(c, site.file, site.node) orelse return fail(proof);
            var buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullStructInit(&buffer, site.node) != null) {
                const entry = try proof.literals.getOrPut(c.facts.gpa, site.node);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                if (side == 0) entry.value_ptr.small = site.value else entry.value_ptr.large = site.value;
                try proof.expected.append(c.facts.gpa, .{ .file = site.file, .function = function, .node = site.node });
                continue;
            }
            const target = site.target orelse return fail(proof);
            try proof.expected.append(c.facts.gpa, .{ .file = site.file, .function = function, .node = target });
        }
    }
    // A literal naming neither takes both defaults, and no site shows it: they must hold it.
    const small = (try defaultOf(c, proof.relation.small, false)) orelse return;
    const large = (try defaultOf(c, proof.relation.large, proof.relation.length)) orelse return;
    if (large.c < small.c) proof.failed = true;
}

fn fail(proof: *Proof) void {
    proof.failed = true;
}

//======================================================================
// Caller ranges.
//======================================================================

/// A reading of each function from its callers, at one pointer width: the function read with
/// an entry state, where every caller is known, and else its reading alone.
const Entries = struct {
    map: std.AutoHashMapUnmanaged(struct { Project.FileId, Ast.Node.Index, u16 }, *Analysis) = .empty,
};

/// How many callers deep an entry state is read: a function further from every root than this
/// is read alone.
const entry_depth = 32;

/// `function` read with the entry state its callers give it (`entryOf`), or its reading
/// alone where they give none. Its calls' states come from this reading, so a caller's own
/// entry reaches its callees in turn.
fn byCallers(c: *Context, file: Project.FileId, function: Ast.Node.Index, width: u16) Error!*Analysis {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Entries);
    const key = .{ file, function, width };
    if (memo.map.get(key)) |found| return found;
    const rows = (try entryOf(c, .{ .file = file, .function = function }, width)) orelse {
        const alone = try analysis(c, file, function, width);
        try memo.map.put(c.allocator, key, alone);
        return alone;
    };
    const made = try c.allocator.create(Analysis);
    made.* = .{};
    try readInto(c, made, file, function, width, rows, null);
    try memo.map.put(c.allocator, key, made);
    return made;
}

/// What every call of `function` in the program gives its parameter slots: the join over its
/// callers of each one's state at its calls (`Analysis.calls`), read from that caller's own
/// entry. Null where a caller may be missing: `function` is exported to consumers or by
/// `export`, is named other than as a callee, is called outside a function or within a cycle
/// of calls, lies further than `entry_depth` callers from every root, or where a caller's
/// reading did not model it or reach a call of it, or a call does not match its parameters.
fn entryOf(c: *Context, function: Callee, width: u16) Error!?[]const Lin {
    const index = try callersIndex(c);
    if (index.reflective) return null;
    const facts = index.callers.get(function) orelse return null;
    if (facts.escapes or facts.depth > entry_depth) return null;
    // On `backing`: what joining the callers' states works through is dropped; the rows they
    // join to are copied out.
    var scratch: std.heap.ArenaAllocator = .init(c.backing);
    defer scratch.deinit();
    var joined: ?State = null;
    for (facts.sites.items) |site| {
        const caller = try byCallers(c, site.file, site.function, width);
        if (!caller.supported or !caller.reached.contains(site.call)) return null;
        const given = (caller.calls.get(function) orelse return null) orelse return null;
        const state: State = .{ .rows = given };
        joined = if (joined) |j| try joinRows(scratch.allocator(), j, state) else state;
    }
    const s = joined orelse return null;
    return try persisted(c.allocator, s.rows);
}

/// What holds on either of two callers' states at their calls, written over the callee's
/// slots: each constraint one holds that the other entails as it stands. No length's range is
/// added, as `Frame.join` adds its frame's: the slots are another function's.
fn joinRows(a: std.mem.Allocator, x: State, y: State) Error!State {
    if (x.dead) return y;
    if (y.dead) return x;
    var out: std.ArrayList(Lin) = .empty;
    for (x.rows) |row| if (try entails(a, y, row)) try out.append(a, row);
    for (y.rows) |row| if (try entails(a, x, row)) try out.append(a, row);
    return .{ .rows = try canonical(a, out.items) };
}

/// Each program function's calls in the program, and whether all of them are known.
const Callers = struct {
    callers: std.AutoHashMapUnmanaged(Callee, Called) = .empty,
    built: bool = false,
    /// A program file names a declaration by a name it computes (`@field(T, name)`): any
    /// function may be reached so, and none has every caller known.
    reflective: bool = false,
};
const Called = struct {
    sites: std.ArrayList(struct { file: Project.FileId, function: Ast.Node.Index, call: Ast.Node.Index }) = .empty,
    /// Named other than as a callee, called outside a function, exported, or in a cycle.
    escapes: bool = false,
    /// The longest chain of callers above it.
    depth: usize = 0,
};

fn callersIndex(c: *Context) Error!*Callers {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Callers);
    if (memo.built) return memo;
    memo.built = true;
    for (c.project.sources) |*source| {
        if (source.file.status != .parsed or !try Program.owns(c, source.id)) continue;
        const file = source.id;
        const tree = &source.file.tree;
        const model = &source.model;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            switch (accesses.formOf(tag)) {
                // A name, or a decl literal (`.init`): a local's or a parameter's holds no
                // function the program declares by name; any other may be one, or an alias of one.
                .leaf => {
                    if (tree.tokenTag(tree.nodeMainToken(node)) != .identifier) continue;
                    if (nameRef(model, node)) |ref| if (ref.declaration) |d| switch (model.declarations[@backingInt(d)].kind) {
                        .function, .variable => {},
                        else => continue,
                    };
                },
                .member => {},
                .builtin => {
                    // `@field(T, "f")` names `f` (`Facts.fieldName`): each function of that name may
                    // be reached so; a name computed may be any.
                    if (!Facts.isBuiltin(tree, node, "@field")) continue;
                    var buffer: [2]Ast.Node.Index = undefined;
                    const args = Facts.builtinArgs(tree, node, &buffer);
                    if (args.len != 2) {
                        memo.reflective = true;
                        continue;
                    }
                    switch (try c.facts.fieldName(file, args[1])) {
                        .name => |name| try fieldNamed(c, memo, name),
                        .names => |names| for (names) |name| try fieldNamed(c, memo, name),
                        .each_of, .computed => memo.reflective = true,
                    }
                    continue;
                },
                else => continue,
            }
            // A declaration's own name is no use of it.
            const decl = switch (try c.facts.resolve(file, node)) {
                .function => |d| d,
                .alternatives => continue,
                else => continue,
            };
            const callee = calleeOf(c, decl) orelse continue;
            const entry = try memo.callers.getOrPut(c.allocator, callee);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            const parent = model.parentOf(node);
            var call_buffer: [1]Ast.Node.Index = undefined;
            const called = if (parent) |p| if (tree.fullCall(&call_buffer, p)) |call| call.ast.fn_expr == node else false else false;
            const caller = if (parent) |p| functionOf(c, file, p) else null;
            if (!called or caller == null) {
                entry.value_ptr.escapes = true;
                continue;
            }
            try entry.value_ptr.sites.append(c.allocator, .{ .file = file, .function = caller.?, .call = parent.? });
        }
    }
    // Callers the program may not hold: by `export`, or by name from another package.
    var it = memo.callers.iterator();
    while (it.next()) |entry| {
        const decl = declOf(c, entry.key_ptr.*) orelse {
            entry.value_ptr.escapes = true;
            continue;
        };
        const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        // `pub`: a consumer of the package may call it, and a run need not hold any file that
        // imports the package by name, so a public function's callers are never all known.
        if (record.exported or record.public) entry.value_ptr.escapes = true;
    }
    // Each function's depth below the roots; every function on a cycle of callers has no
    // entry, whichever of them the search starts from.
    var keys: std.ArrayList(Callee) = .empty;
    var keys_it = memo.callers.keyIterator();
    while (keys_it.next()) |k| try keys.append(c.allocator, k.*);
    var walk: Walk = .{ .memo = memo };
    for (keys.items) |k| _ = try walk.depthOf(c, k);
    return memo;
}

/// Every program function `@field` may name by `name`: none of them has its callers known.
fn fieldNamed(c: *Context, memo: *Callers, name: []const u8) Error!void {
    for (c.project.sources) |*source| {
        if (source.file.status != .parsed or !try Program.owns(c, source.id)) continue;
        for (source.model.declarations, 0..) |decl, i| {
            if (decl.kind != .function or !std.mem.eql(u8, decl.name, name)) continue;
            const callee = calleeOf(c, .{ .file = source.id, .index = @fromBackingInt(@intCast(i)) }) orelse continue;
            const entry = try memo.callers.getOrPut(c.allocator, callee);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            entry.value_ptr.escapes = true;
        }
    }
}

/// A search of the callers above each function: the longest chain to a root, past
/// `entry_depth` none, and each function on a cycle marked as escaping.
const Walk = struct {
    memo: *Callers,
    state: std.AutoHashMapUnmanaged(Callee, enum { active, done }) = .empty,
    stack: std.ArrayList(Callee) = .empty,

    fn depthOf(w: *Walk, c: *Context, function: Callee) Error!usize {
        const called = w.memo.callers.getPtr(function) orelse return 0;
        if (w.state.get(function)) |at| switch (at) {
            .done => return called.depth,
            // A cycle: each function from this one up the stack reaches itself again.
            .active => {
                var i = w.stack.items.len;
                while (i > 0) {
                    i -= 1;
                    const on = w.stack.items[i];
                    w.memo.callers.getPtr(on).?.escapes = true; // unreachable: each function on the stack is indexed
                    if (std.meta.eql(on, function)) break;
                }
                return entry_depth + 1;
            },
        };
        // A chain longer than any read: the search goes no deeper.
        if (w.stack.items.len > entry_depth) {
            called.escapes = true;
            return entry_depth + 1;
        }
        try w.state.put(c.allocator, function, .active);
        try w.stack.append(c.allocator, function);
        var deepest: usize = 0;
        for (called.sites.items) |site| deepest = @max(deepest, (try w.depthOf(c, .{ .file = site.file, .function = site.function })) +| 1);
        _ = w.stack.pop();
        called.depth = deepest;
        if (deepest > entry_depth) called.escapes = true;
        try w.state.put(c.allocator, function, .done);
        return deepest;
    }
};

/// The `fn` declaration of a program function, or null for one without a body there.
fn calleeOf(c: *Context, decl: Facts.Decl) ?Callee {
    const model = &c.project.at(decl.file).model;
    const proto = model.declarations[@backingInt(decl.index)].node;
    const function = model.parentOf(proto) orelse return null;
    if (c.project.at(decl.file).file.tree.nodeTag(function) != .fn_decl) return null;
    return .{ .file = decl.file, .function = function };
}

/// The declaration of the function a `fn` declaration makes.
fn declOf(c: *Context, callee: Callee) ?Facts.Decl {
    const model = &c.project.at(callee.file).model;
    const tree = &c.project.at(callee.file).file.tree;
    const proto = tree.nodeData(callee.function).node_and_node[0];
    for (model.declarations, 0..) |decl, i| if (decl.kind == .function and decl.node == proto) return .{ .file = callee.file, .index = @fromBackingInt(@intCast(i)) };
    return null;
}

/// Range's question of an index or a slice's bound: `index` within `memory`, as the access
/// that reads them both has it.
pub fn within(c: *Context, file: Project.FileId, index: Ast.Node.Index, memory: Ast.Node.Index, end: bool) Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const access = model.parentOf(index) orelse return false;
    switch (formAt(tree, access)) {
        .array_access => {
            const array, const at = tree.nodeData(access).node_and_node;
            if (array != memory or at != index or end) return false;
            return cleared(c, file, index, .index);
        },
        .slice => {
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
    temp: struct { node: Ast.Node.Index, part: u8, index: u32 = 0 },
    result,
    result_length,
    /// How many passes a loop has run since it was entered.
    passes: Ast.Node.Index,
    /// A variable a loop steps, as it was when the loop was entered.
    entry: struct { loop: Ast.Node.Index, d: Model.Declaration.Id },
    /// A place a loop steps, as it was when the loop was entered.
    place_step: struct { loop: Ast.Node.Index, place: Place },
    /// A `for` loop's count of passes, as its inputs gave it when the loop was entered: an input
    /// the body shrinks (`s = s[1..]`) does not change how many passes run.
    count: Ast.Node.Index,
    /// A field of a tracked declaration's struct or of the struct it points to (`self.at`),
    /// its value and its memory's length (`Frame.placeOf`).
    place: Place,
    place_length: Place,
    /// A place of a parameter's as the function was entered (`Frame.placeValue`).
    place_entry: Place,
    place_entry_length: Place,
    /// Whether a tracked optional holds a value: 1 where it does, 0 where it is null.
    presence: Model.Declaration.Id,
    /// Whether an optional field of a place holds a value (`Frame.presencePlaceOf`).
    place_presence: Place,
    /// A tracked `bool`, 1 for true: read only where Zig reads a bool (a condition, a bool's
    /// operand), never as a number.
    boolean: Model.Declaration.Id,
};

const Place = struct { root: Model.Declaration.Id, field: Facts.Decl };

/// What an expression gives: its integer value and the length of its memory, where they are
/// linear in what the state knows, and constraints that hold once it is unwrapped (an
/// optional's payload, an error union's success: a search found, a callee's summary).
const Value = struct {
    lin: ?Lin = null,
    length: ?Lin = null,
    unwrapped: []const Lin = &.{},
    /// Where a call's callee keeps its successful exits apart (`Summary.exits`): what each
    /// gives, read with `unwrapped` where it is taken.
    exits: []const []const Lin = &.{},
    /// What holds where it is an error: a call's callee's failing rows, applied to what the
    /// call gives it (`Summary.failing`). Empty where nothing is known.
    failed: []const Lin = &.{},
    /// Its length is the program's word, not memory shown to hold it: a many-item or C
    /// pointer sliced (`p[0..n]`), or a length stored (`s.len = n`). Such a length counts no
    /// work the function holds (`counted`).
    claimed: bool = false,
    /// Whether an optional holds a value, 1 or 0, where that is linear in what the state knows.
    present: ?Lin = null,
    /// A `bool`'s value, 1 or 0, where it is linear in what the state knows (`Frame.truthOf`).
    truth: ?Lin = null,
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

/// Whether a function leaves with an error where it returns a value (`Frame.failingOf`).
const Failing = enum { no, maybe, yes };

/// The builtins that give a number, never an error.
const numeric_builtins = [_][]const u8{ "@divCeil", "@divFloor", "@divTrunc", "@divExact", "@mod", "@rem", "@intCast", "@truncate", "@min", "@max", "@intFromEnum", "@intFromBool", "@intFromPtr", "@sizeOf", "@bitSizeOf", "@alignOf", "@popCount", "@ctz", "@clz", "@abs", "@shlExact", "@shrExact" };

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
    /// The length variables whose value is claimed, not held (`Value.claimed`).
    claimed: std.AutoHashMapUnmanaged(Var, void) = .empty,
    /// Each place's variable, its value's or its length's (`placeVar`).
    places: std.array_hash_map.Auto(Var, Place) = .empty,
    /// Each optional place's presence variable (`presencePlaceVar`): forgotten with the place,
    /// never a summary's.
    presences: std.array_hash_map.Auto(Var, Place) = .empty,
    /// Whether the function returns an integer, or an error union or optional of one.
    returns_int: bool = false,
    /// Whether the memory the function returns holds elements that take room.
    result_sized: bool = false,
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
    /// Whether no place has been stored or forgotten yet: a parameter's place first read now
    /// holds what it held at entry.
    entry_places: bool = true,
    /// The places the summary's slots read (`summarize`).
    slot_places: []const SlotPlace = &.{},
    /// The relations this reading is proving (`proveRelations`): each store and literal it
    /// meets of their fields is judged where it is made.
    proving: []Proof = &.{},
    /// The fields the function may write, or whether it may write any (`wrote`).
    writes: std.ArrayList(Facts.Decl) = .empty,
    writes_any: bool = false,
    summary: ?Summary = null,
    /// What every caller gives the parameters' slots (`entryOf`), assumed from the start.
    entry: ?[]const Lin = null,
    /// The reading of a call it is read at: its parameters' types are read in it.
    bound: ?*const Facts.Env = null,
    /// Each parameter's integer type, as its declaration names it in the reading (`bound`),
    /// where an expression's own type does not (`comptime T: type`'s `n: T`).
    param_ints: std.AutoHashMapUnmanaged(Model.Declaration.Id, Range.Int) = .empty,
    /// What this function gives each program function it calls (`Analysis.calls`).
    calls: std.AutoHashMapUnmanaged(Callee, ?[]const Lin) = .empty,
    /// The calls reached on a path not being tried.
    reached: std.AutoHashMapUnmanaged(Ast.Node.Index, void) = .empty,

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
        var index: usize = 0;
        while (it.next()) |param| : (index += 1) {
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
            if (param.type_expr) |type_node| if (try Range.intNamedIn(f.c, f.bound, f.file, type_node, f.width)) |int| {
                s = try f.typed(s, try f.variable(.{ .value = d }), int);
                try f.param_ints.put(f.a, d, int);
            };
            // A `comptime` bool the reading binds (`fill(false, n)`): 1 or 0 throughout, as a
            // parameter is never assigned.
            if (f.bound) |reading| if (index < reading.truths.len) if (reading.truths[index]) |bound_truth| {
                const u = try f.unit(s, .{ .boolean = d });
                s = try f.same(u[0], try single(f.a, u[1]), constant(@intFromBool(bound_truth)));
            };
        }
        f.params = params.items;
        if (f.entry) |rows| s = try f.fromCallers(s, rows);
        if (proto.ast.return_type.unwrap()) |result| {
            f.result_sized = try f.c.facts.sizedMemory(try f.c.facts.resolve(f.file, result));
            var t = result;
            if (formAt(f.tree, t) == .error_union) t = f.tree.nodeData(t).node_and_node[1];
            if (formAt(f.tree, t) == .optional_type) t = f.tree.nodeData(t).node;
            f.returns_int = try Range.intNamedIn(f.c, f.bound, f.file, t, f.width) != null;
        }
        const body = f.tree.nodeData(f.function).node_and_node[1];
        const out = try f.exec(s, body);
        if (!out.dead) try f.exits.append(f.a, .{ .state = out, .failed = false });
        try f.summarize();
    }

    /// `s` with what every caller gives the parameters: each row over their slots, read as
    /// the parameters' values and lengths. A row naming a slot with no parameter is dropped.
    fn fromCallers(f: *Frame, s: State, rows: []const Lin) Error!State {
        var out = s;
        each: for (rows) |row| {
            var renamed: Lin = constant(row.c);
            for (row.terms) |term| {
                const param = term.v / 2;
                if (param >= f.params.len) continue :each;
                const d = f.params[param] orelse continue :each;
                const v = try f.variable(if (term.v % 2 == 1) .{ .length = d } else .{ .value = d });
                renamed = (try combine(f.a, renamed, 1, try single(f.a, v), term.k)) orelse continue :each;
            }
            out = try assume(f.a, out, renamed);
        }
        return out;
    }

    /// What a call gives a program function it reaches, joined with its other calls' in this
    /// function: the state there projected onto the callee's parameter slots, each argument's
    /// value and length. Recorded only on a path not being tried; a call whose arguments do
    /// not match the callee's parameters gives it nothing known.
    fn recordCall(f: *Frame, s: State, node: Ast.Node.Index, fn_expr: Ast.Node.Index, args: []const Value) Error!void {
        if (f.trial > 0) return;
        try f.reached.put(f.a, node, {});
        const decl = switch (try f.c.facts.resolve(f.file, fn_expr)) {
            .function => |d| d,
            .alternatives => return,
            else => return,
        };
        if (!try Program.owns(f.c, decl.file)) return;
        const callee = calleeOf(f.c, decl) orelse return;
        const callee_tree = &f.c.project.at(decl.file).file.tree;
        var proto_buffer: [1]Ast.Node.Index = undefined;
        const proto = callee_tree.fullFnProto(&proto_buffer, f.c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return;
        var count: usize = 0;
        var it = proto.iterate(callee_tree);
        while (it.next()) |_| count += 1;
        const entry = try f.calls.getOrPut(f.a, callee);
        if (count != args.len) {
            entry.value_ptr.* = null;
            return;
        }
        if (entry.found_existing and entry.value_ptr.* == null) return;
        const projected = try f.projectArgs(s, args);
        if (!entry.found_existing) {
            entry.value_ptr.* = projected.rows;
            return;
        }
        const joined = try joinRows(f.a, .{ .rows = entry.value_ptr.*.? }, projected); // unreachable: a null entry returned above
        entry.value_ptr.* = joined.rows;
    }

    /// `s`'s constraints on a call's arguments alone, each renamed to its slot.
    fn projectArgs(f: *Frame, s: State, args: []const Value) Error!State {
        // Variables of their own for the slots, past any the frame makes.
        const base: Var = 1 << 30;
        var out = s;
        for (args, 0..) |arg, i| {
            if (arg.lin) |lin| out = try f.equal(out, base + slot(i, false), lin);
            if (arg.length) |lin| out = try f.equal(out, base + slot(i, true), lin);
        }
        if (out.dead) return out;
        var others: std.ArrayList(Var) = .empty;
        for (out.rows) |row| for (row.terms) |term| if (term.v < base) {
            if (std.mem.findScalar(Var, others.items, term.v) == null) try others.append(f.a, term.v);
        };
        std.mem.sort(Var, others.items, {}, std.sort.asc(Var));
        for (others.items) |v| out = try forget(f.a, out, v);
        var rows: std.ArrayList(Lin) = .empty;
        for (out.rows) |row| {
            const terms = try f.a.alloc(Term, row.terms.len);
            for (row.terms, terms) |term, *renamed| renamed.* = .{ .v = term.v - base, .k = term.k };
            try rows.append(f.a, .{ .terms = terms, .c = row.c });
        }
        return .{ .rows = try canonical(f.a, rows.items) };
    }

    /// The function's declarations by their names' tokens, and those another name may write, as
    /// `Facts.accesses` finds their writes: an address taken (`&x`, `&x.f`, a slice of an
    /// array, a `|*p|` capture) or memory code the program does not hold writes (`asm`). A
    /// method's pointer receiver is the call's, which the callee's summary reads.
    fn indexDeclarations(f: *Frame) Error!void {
        const first = f.tree.firstToken(f.function);
        const last = f.tree.lastToken(f.function);
        for (f.model.declarations, 0..) |decl, i| {
            if (decl.token < first or decl.token > last) continue;
            switch (decl.kind) {
                .variable, .capture, .parameter => {},
                else => continue,
            }
            const d: Model.Declaration.Id = @fromBackingInt(@intCast(i));
            try f.decls.put(f.a, decl.token, d);
            var buffer: [1]Ast.Node.Index = undefined;
            const in_file = [_]Project.FileId{f.file};
            var found_sites = Facts.accesses.writes(f.c.facts, .{ .declaration = .{ .file = f.file, .index = d } }, &in_file);
            while (try found_sites.next()) |site| switch (site.kind) {
                .address => if (f.tree.fullCall(&buffer, site.node) == null) try f.addressed.put(f.a, d, {}),
                .covered, .open => try f.addressed.put(f.a, d, {}),
                else => {},
            };
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

    /// `s` with what holds of every length it or `goal` reads: one object's length is at zero
    /// or above, and below half the address space where its elements take room (a claimed
    /// one, `Value.claimed`, only the first). A length's range holds everywhere, so no
    /// state keeps it: it takes no room a state's limit would give another fact, and a length
    /// first read inside a loop holds at the loop's entry as well.
    fn axioms(f: *Frame, space: Space, s: State, goal: ?Lin) Error!State {
        if (s.dead) return s;
        var rows: std.ArrayList(Lin) = .empty;
        try rows.appendSlice(f.a, s.rows);
        var seen: std.AutoHashMapUnmanaged(Var, void) = .empty;
        const most = Range.longest(f.width);
        for ([_][]const Lin{ s.rows, if (goal) |g| &.{g} else &.{} }) |group| for (group) |row| for (row.terms) |term| {
            if (space == .frame) try f.relationRows(&rows, term.v);
            if (!f.isLength(space, term.v)) continue;
            if ((try seen.getOrPut(f.a, term.v)).found_existing) continue;
            const x = try single(f.a, term.v);
            try rows.append(f.a, x);
            // A claimed length (`s.len = n`, a many-item pointer's slice) is no object's: any
            // `usize`.
            if (space == .frame and f.claimed.contains(term.v)) continue;
            if (!try f.sizedLength(space, term.v)) continue;
            if (most <= std.math.maxInt(Coef)) if (try atLeast(f.a, constant(@intCast(most)), x)) |row_most| try rows.append(f.a, row_most);
        };
        return .{ .rows = rows.items };
    }

    /// What every store keeps of the place `v` and its siblings on one instance (`Relations`):
    /// the same root, so one instance while nothing assigns it, which forgets its places.
    fn relationRows(f: *Frame, rows: *std.ArrayList(Lin), v: Var) Error!void {
        const p = f.places.get(v) orelse return;
        for (try relationsOf(f.c, p.field)) |one| {
            const small = try single(f.a, try f.placeVar(.{ .root = p.root, .field = one.small }, false));
            const large = try single(f.a, try f.placeVar(.{ .root = p.root, .field = one.large }, one.length));
            if (try atLeast(f.a, large, small)) |row| try rows.append(f.a, row);
        }
    }

    /// A store of `value` into the place `p` at `target`, judged for each relation being proved
    /// of its field: it holds there, given that it held on this instance before the store.
    fn judgeStore(f: *Frame, s: State, target: Ast.Node.Index, p: Place, value: Value) Error!void {
        for (f.proving) |*proof| {
            const is_small = std.meta.eql(p.field, proof.relation.small);
            if (!is_small and !std.meta.eql(p.field, proof.relation.large)) continue;
            try proof.checked.put(f.c.facts.gpa, target, {});
            if (proof.failed) continue;
            const small_var = try single(f.a, try f.placeVar(.{ .root = p.root, .field = proof.relation.small }, false));
            const large_var = try single(f.a, try f.placeVar(.{ .root = p.root, .field = proof.relation.large }, proof.relation.length));
            const given = if (is_small) value.lin else if (proof.relation.length) value.length else value.lin;
            const made = given orelse {
                proof.failed = true;
                continue;
            };
            const goal = (if (is_small) try atLeast(f.a, large_var, made) else try atLeast(f.a, made, small_var)) orelse {
                proof.failed = true;
                continue;
            };
            const before = try assume(f.a, s, try atLeast(f.a, large_var, small_var));
            if (!try f.shows(before, goal)) proof.failed = true;
        }
    }

    /// A struct literal at `node`, its fields' values evaluated, judged for each relation being
    /// proved that a site of it writes: what it gives both sides or their defaults.
    fn judgeLiteral(f: *Frame, s: State, node: Ast.Node.Index, fields: []const Ast.Node.Index, values: []const Value) Error!void {
        for (f.proving) |*proof| {
            const given = proof.literals.get(node) orelse continue;
            try proof.checked.put(f.c.facts.gpa, node, {});
            if (proof.failed) continue;
            const small = try f.givenOr(s, given.small, proof.relation.small, false, fields, values);
            const large = try f.givenOr(s, given.large, proof.relation.large, proof.relation.length, fields, values);
            const goal = if (small != null and large != null) try atLeast(f.a, large.?, small.?) else null;
            if (goal == null or !try f.shows(s, goal.?)) proof.failed = true;
        }
    }

    /// What a literal gives a field: its value (its length, where `length`), or its default's.
    fn givenOr(f: *Frame, s: State, value: ?Ast.Node.Index, member: Facts.Decl, length: bool, fields: []const Ast.Node.Index, values: []const Value) Error!?Lin {
        if (value) |node| {
            for (fields, values) |field_node, given| {
                if (field_node != node) continue;
                if (!length) return given.lin;
                return (try f.lengthOf(s, node, given))[1];
            }
            return null;
        }
        return defaultOf(f.c, member, length);
    }

    /// Which variables a state is written over: the frame's own, or a summary's slots
    /// (`slot`), which name a parameter or the result and whether it is the length.
    const Space = enum { frame, slots };

    /// Whether a length's memory holds elements that take room (`Facts.sizedMemory`).
    fn sizedLength(f: *Frame, space: Space, v: Var) Error!bool {
        const d = switch (space) {
            .slots => if (v / 2 < f.params.len) f.params[v / 2] orelse return false else if (v / 2 == f.params.len) return f.result_sized else {
                const width = std.math.cast(u16, f.params.len) orelse return false;
                const k = (std.math.sub(Var, v, placeSlot(width, 0, false, false)) catch return false) / 4;
                return k < f.slot_places.len and f.slot_places[k].sized;
            },
            .frame => switch (f.vars.keys()[v]) {
                .length => |d| d,
                .result_length => return f.result_sized,
                .place_length, .place_entry_length => |p| return f.sizedField(p.field),
                else => return false,
            },
        };
        return f.c.facts.sizedMemory(try f.c.facts.declaration(.{ .file = f.file, .index = d }));
    }

    /// Whether a field's memory holds elements that take room.
    fn sizedField(f: *Frame, member: Facts.Decl) Error!bool {
        return f.c.facts.sizedMemory(try f.c.facts.declaration(member));
    }

    fn isLength(f: *Frame, space: Space, v: Var) bool {
        return switch (space) {
            .slots => v % 2 == 1,
            .frame => switch (f.vars.keys()[v]) {
                .length, .result_length, .place_length, .place_entry_length => true,
                else => false,
            },
        };
    }

    /// Whether `s` shows `goal`, the lengths' ranges with it.
    fn shows(f: *Frame, s: State, goal: Lin) Error!bool {
        if (s.dead) return true;
        return entails(f.a, try f.axioms(.frame, s, goal), goal);
    }

    /// What holds on either path: each constraint one holds that the other shows.
    fn join(f: *Frame, x: State, y: State) Error!State {
        return f.joinIn(.frame, x, y);
    }

    fn joinIn(f: *Frame, space: Space, x: State, y: State) Error!State {
        if (x.dead) return y;
        if (y.dead) return x;
        var out: std.ArrayList(Lin) = .empty;
        for (x.rows) |row| if (try entails(f.a, try f.axioms(space, y, row), row)) try out.append(f.a, row);
        for (y.rows) |row| if (try entails(f.a, try f.axioms(space, x, row), row)) try out.append(f.a, row);
        return .{ .rows = try canonical(f.a, out.items) };
    }

    /// Whether `s` shows every constraint of `t`.
    fn implied(f: *Frame, s: State, t: State) Error!bool {
        if (s.dead) return true;
        if (t.dead) return false;
        for (t.rows) |row| if (!try f.shows(s, row)) return false;
        return true;
    }

    /// The constraints of `s` that `t` shows: what a loop's pass preserved.
    fn preservedBy(f: *Frame, s: State, t: State) Error!State {
        if (s.dead) return s;
        var out: std.ArrayList(Lin) = .empty;
        for (s.rows) |row| if (try f.shows(t, row)) try out.append(f.a, row);
        return .{ .rows = out.items };
    }

    fn record(f: *Frame, node: Ast.Node.Index, kind: Kind, proven: bool) Error!void {
        if (f.trial > 0) return;
        const entry = try f.verdicts.getOrPut(f.a, .{ .node = node, .kind = kind });
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* and proven else proven;
    }

    /// Whether `node`, valued `value` in `s`, counts no more than the work the function holds:
    /// within a short's count either way, or between zero and the length of some memory it
    /// holds. Recorded at every node that may decide a loop's passes, as DangerFlow's `decides`
    /// reads a condition (each comparison's operands, a payload loop's condition, and each
    /// value a variable is given), and at each argument a call is given, which may size its
    /// work. DangerFlow asks only at the loops' own and at the sizes a call takes; a node never
    /// recorded here is never cleared.
    fn counted(f: *Frame, s: State, node: Ast.Node.Index, value: ?Lin) Error!void {
        if (f.trial > 0) return;
        const x = value orelse return f.record(node, .count, false);
        const short = constant(std.math.maxInt(u16));
        if (try f.holds(s, try atLeast(f.a, short, x)) and try f.holds(s, try plus(f.a, x, short))) return f.record(node, .count, true);
        if (try f.holds(s, try atLeast(f.a, x, constant(0)))) {
            for (f.vars.keys(), f.vars.values()) |key, v| {
                if (key != .length or f.claimed.contains(v)) continue;
                if (try f.holds(s, try atLeast(f.a, try single(f.a, v), x))) return f.record(node, .count, true);
            }
        }
        try f.record(node, .count, false);
    }

    fn holds(f: *Frame, s: State, goal: ?Lin) Error!bool {
        return goal != null and try f.shows(s, goal.?);
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
        return f.tempAt(s, node, part, 0);
    }

    /// The `index`th of a node's temporaries of one `part`: an operand's, a place's, as many as
    /// the node has.
    fn tempAt(f: *Frame, s: State, node: Ast.Node.Index, part: u8, index: u32) Error!struct { State, Var } {
        const t = try f.variable(.{ .temp = .{ .node = node, .part = part, .index = index } });
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
        // The places of parameters, each once, its value and length at entry and exit.
        var places: std.ArrayList(SlotPlace) = .empty;
        if (std.math.cast(u16, f.params.len) != null) for (f.places.values()) |p| {
            if (places.items.len >= max_slot_places) break;
            const param = std.mem.findScalar(?Model.Declaration.Id, f.params, p.root) orelse continue;
            for (places.items) |listed| {
                if (listed.param == param and std.meta.eql(listed.field, p.field)) break;
            } else {
                // What a parameter given by value holds at exit is the callee's copy's.
                const exits = try f.c.facts.declaration(.{ .file = f.file, .index = p.root }) == .pointer;
                try places.append(f.a, .{ .param = param, .root = p.root, .field = p.field, .exits = exits, .sized = try f.sizedField(p.field) });
            }
        };
        f.slot_places = places.items;
        const failing = try f.exitsJoined(true);
        // No successful exit: every call that succeeds is unreachable.
        const rows: []const Lin = if (try f.exitsJoined(false)) |s| s.rows else &never;
        // Each successful exit apart, where they are few: a caller that rules one out reads
        // the others alone, where their join would lose what only they hold.
        var apart: std.ArrayList([]const Lin) = .empty;
        for (f.exits.items) |exit| {
            if (exit.failed or exit.state.dead) continue;
            if (apart.items.len == summary_exits) {
                apart.clearRetainingCapacity();
                break;
            }
            try apart.append(f.a, (try f.project(exit.state)).rows);
        }
        f.summary = .{ .rows = rows, .exits = if (apart.items.len > 1) apart.items else &.{}, .failing = if (failing) |s| s.rows else &never, .params = f.params.len, .places = f.slot_places, .written = if (f.writes_any) null else f.writes.items };
    }

    /// The join of the exits that fail, or of those that succeed, projected onto the slots;
    /// null where there is none.
    fn exitsJoined(f: *Frame, failed: bool) Error!?State {
        var joined: ?State = null;
        for (f.exits.items) |exit| {
            if (exit.failed != failed or exit.state.dead) continue;
            const projected = try f.project(exit.state);
            joined = if (joined) |j| try f.joinIn(.slots, j, projected) else projected;
        }
        return joined;
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
        if (std.math.cast(u16, f.params.len)) |width| for (0..max_slot_places) |k| {
            if (k >= f.slot_places.len) break;
            const listed = f.slot_places[k];
            const slot_k: u3 = @intCast(k);
            const p: Place = .{ .root = listed.root, .field = listed.field };
            if (f.known(.{ .place_entry = p })) |v| try slots.put(f.a, v, placeSlot(width, slot_k, false, false));
            if (f.known(.{ .place_entry_length = p })) |v| try slots.put(f.a, v, placeSlot(width, slot_k, false, true));
            if (!listed.exits) continue;
            if (f.known(.{ .place = p })) |v| try slots.put(f.a, v, placeSlot(width, slot_k, true, false));
            if (f.known(.{ .place_length = p })) |v| try slots.put(f.a, v, placeSlot(width, slot_k, true, true));
        };
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
        switch (formAt(f.tree, node)) {
            .variable => return f.declare(s, node),
            .assign, .compound_assign => return f.assignment(s, node),
            .destructure => return f.destructure(s, node),
            .deferred => {
                try f.defers.append(f.a, .{ .body = f.tree.nodeData(node).node, .on_error = f.tree.tokenTag(f.tree.nodeMainToken(node)) == .keyword_errdefer });
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
        for (target.breaks.items) |state| out = try f.join(out, state);
        return .{ .s = out, .v = .{ .lin = try single(f.a, result.?) } };
    }

    fn declare(f: *Frame, s: State, node: Ast.Node.Index) RunError!State {
        const local = f.tree.fullVarDecl(node).?; // unreachable: the tag is a declaration's
        const init = local.ast.init_node.unwrap() orelse return s;
        var e = if (f.condition(init)) try f.truthOf(s, init) else try f.eval(s, init);
        const d = f.decls.get(local.ast.mut_token + 1) orelse return e.s;
        if (!f.tracked(d)) return e.s;
        try f.counted(e.s, init, e.v.lin);
        e.v.present = try f.presentOf(init, e.v);
        const int = if (local.ast.type_node.unwrap()) |t| try Range.intNamed(f.c, f.file, t, f.width) else try f.intOf(init);
        return f.bind(e.s, d, e.v, int);
    }

    /// The state with a tracked declaration given a value: its integer where its type is one,
    /// and the length of its memory.
    fn bind(f: *Frame, s: State, d: Model.Declaration.Id, value: Value, int: ?Range.Int) Error!State {
        // Another struct, or a pointer to another: its fields are not the old ones.
        var out = try f.forgetPlaces(s, d, null, null);
        out = try f.assign(out, try f.variable(.{ .value = d }), if (int != null) value.lin else null, int);
        const length = try f.variable(.{ .length = d });
        out = try f.assign(out, length, value.length, null);
        if (value.claimed) try f.claimed.put(f.a, length, {}) else _ = f.claimed.remove(length);
        out = try f.assign(out, try f.variable(.{ .presence = d }), value.present, null);
        return f.assign(out, try f.variable(.{ .boolean = d }), value.truth, null);
    }

    fn assignment(f: *Frame, s: State, node: Ast.Node.Index) RunError!State {
        const tag = f.tree.nodeTag(node);
        const whole = formAt(f.tree, node) == .assign;
        const target, const rhs = f.tree.nodeData(node).node_and_node;
        const d = f.trackedName(target) orelse {
            if (try f.lengthStored(target)) |memory| return f.storeLength(s, node, target, rhs, memory);
            // An optional field: the store writes it as any store does, and it then holds a
            // value where what it is given does.
            if (whole) if (try f.presencePlaceOf(target)) |p| {
                const e = try f.eval(s, rhs);
                const out = try f.storedThrough(e.s, target);
                return f.assign(out, try f.presencePlaceVar(p), try f.presentOf(rhs, e.v), null);
            };
            if (try f.placeOf(target)) |p| return f.storePlace(s, node, target, rhs, p);
            // A store to memory: what it reads is evaluated, and no tracked variable changes.
            const place = try f.eval(s, target);
            return f.storedThrough((try f.eval(place.s, rhs)).s, target);
        };
        var e = if (whole and f.condition(rhs)) try f.truthOf(s, rhs) else try f.eval(s, rhs);
        const int = try f.intOf(target);
        if (whole) {
            try f.counted(e.s, rhs, e.v.lin);
            e.v.present = try f.presentOf(rhs, e.v);
            return f.bind(e.s, d, e.v, int);
        }
        const v = try f.variable(.{ .value = d });
        const current = try f.name(e.s, target);
        const result = try f.arith(current.s, node, opOf(tag), current.v.lin, e.v.lin, rhs, int);
        return f.assign(result.s, v, result.v.lin, int);
    }

    /// The operation a compound assignment applies (`+=` adds).
    fn opOf(tag: Ast.Node.Tag) Ast.Node.Tag {
        return switch (tag) {
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
    }

    /// The place `node` names: a field, but `len` and `ptr`, of a tracked declaration's struct
    /// or of the struct it points to, that only stores through its name change
    /// (`Range.placeable`): no pointer reaches it, and no byte view or reflection writes it.
    fn placeOf(f: *Frame, node: Ast.Node.Index) Error!?Place {
        return f.fieldPlace(node, .number);
    }

    /// The field `node` names of a tracked declaration's struct, or of the struct it points to,
    /// where only stores through its name change it: its value (`Range.placeable`) or, for an
    /// optional, whether it holds one (`Range.presenceable`).
    fn fieldPlace(f: *Frame, node: Ast.Node.Index, comptime held: enum { number, presence }) Error!?Place {
        if (formAt(f.tree, node) != .member) return null;
        const holder = f.tree.nodeData(node).node_and_token[0];
        const root = f.trackedName(holder) orelse return null;
        if (held == .presence and try f.c.facts.resolve(f.file, node) != .optional) return null;
        const decl = ((try f.c.facts.definition(f.file, node)).orNull()) orelse return null;
        const member = ((try f.c.facts.origin(decl)).orNull()) orelse decl;
        const shown = switch (held) {
            .number => try Range.placeable(f.c, member),
            .presence => try Range.presenceable(f.c, member),
        };
        return if (shown) .{ .root = root, .field = member } else null;
    }

    /// A place's value, within its type, or the length of the memory it holds.
    fn placeValue(f: *Frame, s: State, node: Ast.Node.Index, p: Place) Error!Eval {
        var out = s;
        if (try f.intOf(node)) |int| {
            const made = f.known(.{ .place = p }) == null;
            const v = try f.placeVar(p, false);
            if (!f.typed_vars.contains(v)) {
                out = try f.typed(out, v, int);
                try f.typed_vars.put(f.a, v, {});
            }
            if (made) out = try f.atEntry(out, v, p, false);
            return .{ .s = out, .v = .{ .lin = try single(f.a, v) } };
        }
        // An array's length is its type's (`knownLength`); a struct or a pointer with no length
        // holds none.
        if (!try f.holdsLength(node) or try Range.memoryLength(f.c, f.file, node) != null) return .{ .s = out };
        const made = f.known(.{ .place_length = p }) == null;
        const l = try f.placeVar(p, true);
        if (made) out = try f.atEntry(out, l, p, true);
        return .{ .s = out, .v = .{ .length = try single(f.a, l), .claimed = f.claimed.contains(l) } };
    }

    /// `s` with a parameter's place, first read while nothing has stored or forgotten a place,
    /// equal to what it held at entry, which a summary's entry slot names.
    fn atEntry(f: *Frame, s: State, v: Var, p: Place, length: bool) Error!State {
        if (!f.entry_places) return s;
        if (std.mem.findScalar(?Model.Declaration.Id, f.params, p.root) == null) return s;
        const entry = try f.variable(if (length) .{ .place_entry_length = p } else .{ .place_entry = p });
        return f.equal(s, v, try single(f.a, entry));
    }

    /// `place = rhs`, or `place op= rhs`: the place takes the value; the same field of
    /// another struct, which this one may be through another pointer, is no longer known.
    fn storePlace(f: *Frame, s: State, node: Ast.Node.Index, target: Ast.Node.Index, rhs: Ast.Node.Index, p: Place) RunError!State {
        const tag = f.tree.nodeTag(node);
        const e = try f.eval(s, rhs);
        const int = try f.intOf(target);
        if (formAt(f.tree, node) == .assign) return f.setPlace(e.s, target, p, e.v);
        // `op=` reads the place first: what it held at entry, where nothing has stored one yet.
        const current = try f.placeValue(e.s, target, p);
        const out = try f.storedIn(current.s, p);
        const result = try f.arith(out, node, opOf(tag), current.v.lin, e.v.lin, rhs, int);
        if (f.proving.len != 0) try f.judgeStore(current.s, target, p, .{ .lin = result.v.lin });
        return f.assign(result.s, try f.placeVar(p, false), result.v.lin, int);
    }

    /// The state past `p` given `value` (`=`): within its type, or the length of the memory it
    /// holds.
    fn setPlace(f: *Frame, s: State, target: Ast.Node.Index, p: Place, value: Value) Error!State {
        if (f.proving.len != 0) try f.judgeStore(s, target, p, value);
        const int = try f.intOf(target);
        const out = try f.storedIn(s, p);
        if (int != null) return f.assign(out, try f.placeVar(p, false), value.lin, int);
        if (!try f.holdsLength(target) or try Range.memoryLength(f.c, f.file, target) != null) return out;
        const l = try f.placeVar(p, true);
        if (value.claimed) try f.claimed.put(f.a, l, {}) else _ = f.claimed.remove(l);
        return f.assign(out, l, value.length, null);
    }

    /// The state past a store of `value` into `target`, a name's place aside, as `=` gives it:
    /// a length, a place, or memory no place of this function's is. A destructure's targets
    /// each take one so.
    fn storeValue(f: *Frame, s: State, target: Ast.Node.Index, value: Value) RunError!State {
        if (try f.lengthStored(target)) |memory| return f.setLength(s, target, memory, value);
        if (try f.placeOf(target)) |p| return f.setPlace(s, target, p, value);
        // A store to memory: what it reads is evaluated, and no tracked variable changes.
        const place = try f.eval(s, target);
        return f.storedThrough(place.s, target);
    }

    /// The state past a store to `target`, no place of this function's: the same field of a
    /// struct a place may be, or, for a value that may hold one (a struct, a union, an unknown),
    /// every place. A number or a pointer stored into memory writes no place, as no pointer
    /// reaches a place's field (`placeOf`); `_ = x` stores nothing.
    fn storedThrough(f: *Frame, s: State, target: Ast.Node.Index) Error!State {
        switch (formAt(f.tree, target)) {
            .leaf => if (Range.discards(f.tree, target)) return s,
            .member => {
                // A field that does not resolve (`p.at` of an `anytype` `p`) may be any place's.
                const decl = ((try f.c.facts.definition(f.file, target)).orNull()) orelse return f.wrote(s, null, null);
                const value = try f.c.facts.resolve(f.file, target);
                if (value == .scalar or value == .pointer or try f.flatOptional(value)) return f.wrote(s, ((try f.c.facts.origin(decl)).orNull()) orelse decl, null);
            },
            // `@field(x, "at") = v`: a field by a name read as the program compiles.
            .builtin => return f.wrote(s, null, null),
            else => {},
        }
        const value = try f.c.facts.resolve(f.file, target);
        // An optional of a number or a pointer stored through a pointer writes an optional no
        // place is: a place's field, and an optional one's (`presencePlaceOf`), never has its
        // address taken. One of a struct may hold a place a pointer to its payload names.
        if (try f.flatOptional(value)) return s;
        return switch (value) {
            .scalar, .pointer => s,
            // A number's store, its type read where the value does not resolve or resolves as
            // its type's name (`k.*` of a capture's pointer), writes no place.
            // A field's store is recorded as its field's above, or as any.
            .unknown, .primitive => if (formAt(f.tree, target) != .member and try f.intOf(target) != null) s else f.wrote(s, null, null),
            .alternatives => f.wrote(s, null, null),
            else => f.wrote(s, null, null),
        };
    }

    /// Whether `value` is an optional of a number or a pointer: its store holds no place.
    fn flatOptional(_: *Frame, value: Facts.Value) Error!bool {
        return switch (value) {
            .optional => |child| child.* == .scalar or child.* == .pointer,
            .alternatives => false,
            else => false,
        };
    }

    /// The state past a store to the place `p`: the same field of another struct, which this one
    /// may be through another pointer, no longer known, and the write the summary's. A struct a
    /// local or a parameter holds by value, whose address the function never takes (`tracked`),
    /// is its own: no other pointer reaches it, and no caller sees the store.
    fn storedIn(f: *Frame, s: State, p: Place) Error!State {
        f.entry_places = false;
        // A capture may name memory the function was given (`|*c|`).
        const kind = f.model.declarations[@backingInt(p.root)].kind;
        if ((kind == .variable or kind == .parameter) and try f.c.facts.declaration(.{ .file = f.file, .index = p.root }) == .instance) return s;
        return f.wrote(s, p.field, p.root);
    }

    /// The state past a write to memory of the field `member` (any field where null), the
    /// places of `except` aside: recorded as the summary's (`Summary.written`).
    fn wrote(f: *Frame, s: State, member: ?Facts.Decl, except: ?Model.Declaration.Id) Error!State {
        if (member) |d| {
            if (!f.writes_any) for (f.writes.items) |listed| {
                if (std.meta.eql(listed, d)) break;
            } else try f.writes.append(f.a, d);
        } else f.writes_any = true;
        return f.forgetPlaces(s, null, member, except);
    }

    /// The state with nothing known of the places of `root` (any root where null), of the field
    /// `member` (any where null), but those of `except`.
    fn forgetPlaces(f: *Frame, s: State, root: ?Model.Declaration.Id, member: ?Facts.Decl, except: ?Model.Declaration.Id) Error!State {
        f.entry_places = false;
        var out = s;
        for (f.places.keys(), f.places.values()) |v, p| {
            if (root) |r| if (p.root != r) continue;
            if (member) |d| if (!std.meta.eql(p.field, d)) continue;
            if (except) |r| if (p.root == r) continue;
            out = try forget(f.a, out, v);
            _ = f.typed_vars.remove(v);
            _ = f.claimed.remove(v);
        }
        for (f.presences.keys(), f.presences.values()) |v, p| {
            if (root) |r| if (p.root != r) continue;
            if (member) |d| if (!std.meta.eql(p.field, d)) continue;
            if (except) |r| if (p.root == r) continue;
            out = try forget(f.a, out, v);
        }
        return out;
    }

    /// The variable of a place's value or its length, recorded as a place's.
    fn placeVar(f: *Frame, p: Place, length: bool) Error!Var {
        const v = try f.variable(if (length) .{ .place_length = p } else .{ .place = p });
        try f.places.put(f.a, v, p);
        return v;
    }

    fn destructure(f: *Frame, s: State, node: Ast.Node.Index) RunError!State {
        const full = f.tree.assignDestructure(node);
        // A literal of as many values gives each target its own; any other value, nothing linear.
        var values: std.ArrayList(Value) = .empty;
        var out = s;
        var buffer: [2]Ast.Node.Index = undefined;
        if (f.tree.fullArrayInit(&buffer, full.ast.value_expr)) |literal| if (literal.ast.type_expr == .none and literal.ast.elements.len == full.ast.variables.len) {
            for (literal.ast.elements) |item| {
                const e = try f.eval(out, item);
                out = e.s;
                try values.append(f.a, e.v);
            }
        };
        if (values.items.len == 0) out = (try f.eval(s, full.ast.value_expr)).s;
        for (full.ast.variables, 0..) |target, k| {
            const value: Value = if (k < values.items.len) values.items[k] else .{};
            if (f.tree.fullVarDecl(target)) |local| {
                const d = f.decls.get(local.ast.mut_token + 1) orelse continue;
                if (f.tracked(d)) out = try f.bind(out, d, value, null);
                continue;
            }
            if (f.trackedName(target)) |d| {
                out = try f.bind(out, d, value, try f.intOf(target));
                continue;
            }
            // A field, a length or memory: stored as `=` stores it.
            out = try f.storeValue(out, target, value);
        }
        return out;
    }

    /// Whether `memory` names a tracked declaration whose length is claimed.
    fn lengthClaimed(f: *Frame, memory: Ast.Node.Index) bool {
        const d = f.trackedName(memory) orelse return false;
        const v = f.known(.{ .length = d }) orelse return false;
        return f.claimed.contains(v);
    }

    /// Whether `node` is memory with a length: a slice or an array, `len` its length.
    fn holdsLength(f: *Frame, node: Ast.Node.Index) Error!bool {
        return switch (try memoryKind(f.c, f.file, node, 0)) {
            .checked, .sentinel => true,
            .unchecked, .unknown => false,
        };
    }

    /// The tracked slice whose length a store to `target` sets: `s.len = n`, or
    /// `@field(s, name)`, whose name may be `len`.
    fn lengthStored(f: *Frame, target: Ast.Node.Index) Error!?Model.Declaration.Id {
        switch (formAt(f.tree, target)) {
            .member => {
                const holder = f.tree.nodeData(target).node_and_token[0];
                // A slice's own `len` (`Facts.languageField`), or a holder's that does not resolve.
                switch (try f.c.facts.languageField(f.file, target)) {
                    .len, .unknown => {},
                    .ptr, .none => return null,
                }
                const d = f.trackedName(holder) orelse return null;
                return if (try f.holdsLength(holder)) d else null;
            },
            .builtin => {
                if (!Facts.isBuiltin(f.tree, target, "@field")) return null;
                const holder, const field_name = f.tree.nodeData(target).opt_node_and_opt_node;
                // A name that cannot be `len` stores another field: a store to memory.
                if (field_name.unwrap()) |spelled| if (!f.c.facts.mayName(try f.c.facts.fieldName(f.file, spelled), "len")) return null;
                return f.trackedName(holder.unwrap() orelse return null);
            },
            else => return null,
        }
    }

    /// `s.len = n` (or `op=`): the slice's length takes the value; through `@field`, whose name
    /// is read as the program compiles, nothing is known of it.
    fn storeLength(f: *Frame, s: State, node: Ast.Node.Index, target: Ast.Node.Index, rhs: Ast.Node.Index, d: Model.Declaration.Id) RunError!State {
        const tag = f.tree.nodeTag(node);
        const e = try f.eval(s, rhs);
        if (formAt(f.tree, node) == .assign or formAt(f.tree, target) != .member) return f.setLength(e.s, target, d, e.v);
        const v = try f.variable(.{ .length = d });
        try f.claimed.put(f.a, v, {});
        const int = try f.intOf(target);
        const result = try f.arith(e.s, node, opOf(tag), try single(f.a, v), e.v.lin, rhs, int);
        return f.assign(result.s, v, result.v.lin, null);
    }

    /// The state past `d`'s length given `value` (`=`): a length claimed, no longer its memory's.
    fn setLength(f: *Frame, s: State, target: Ast.Node.Index, d: Model.Declaration.Id, value: Value) Error!State {
        const v = try f.variable(.{ .length = d });
        try f.claimed.put(f.a, v, {});
        // `@field(s, name)` with a name read as the program compiles: any field, `len` among them.
        if (formAt(f.tree, target) != .member) return f.assign(try f.wrote(s, null, null), v, null, null);
        return f.assign(s, v, value.lin, null);
    }

    /// The tracked declaration an identifier names, where it names one.
    fn trackedName(f: *Frame, node: Ast.Node.Index) ?Model.Declaration.Id {
        const d = (nameRef(f.model, node) orelse return null).declaration orelse return null;
        return if (f.tracked(d)) d else null;
    }

    //------------------------------------------------------------------
    // Expressions.
    //------------------------------------------------------------------

    /// What evaluating `node` from `s` leaves and gives.
    fn eval(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        if (s.dead) return .{ .s = s };
        const tree = f.tree;
        switch (formAt(tree, node)) {
            .leaf => {
                const token = tree.nodeMainToken(node);
                if (spellsName(tree, node)) return f.name(s, node);
                return switch (tree.tokenTag(token)) {
                    .number_literal => .{ .s = s, .v = .{ .lin = switch (std.zig.parseNumberLiteral(tree.tokenSlice(token))) {
                        .int => |n| constant(n),
                        else => null,
                    } } },
                    .keyword_unreachable => .{ .s = State.unreachable_state },
                    // A string, a character, an enum literal or an error: nothing at run time.
                    else => .{ .s = s },
                };
            },
            // A statement as a branch's or a loop's whole body (`if (a) i = 0;`).
            .assign, .compound_assign => return .{ .s = try f.assignment(s, node) },
            .grouped => return f.eval(s, tree.nodeData(node).node_and_token[0]),
            .@"nosuspend" => return f.eval(s, tree.nodeData(node).node),
            .member => return f.field(s, node),
            .array_access => return f.element(s, node),
            .slice => return f.slice(s, node),
            .operator => {
                if (accesses.unaryOf(tree.nodeTag(node))) |unary| {
                    if (unary == .negation) {
                        const operand = try f.eval(s, tree.nodeData(node).node);
                        return f.arith(operand.s, node, .sub, constant(0), operand.v.lin, tree.nodeData(node).node, try f.intOf(node));
                    }
                    return f.fresh((try f.eval(s, tree.nodeData(node).node)).s, node, 0);
                }
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                const left = try f.heldPast(try f.eval(s, lhs), node, rhs);
                const right = try f.eval(left.s, rhs);
                return f.arith(right.s, node, tree.nodeTag(node), left.v.lin, right.v.lin, rhs, try f.intOf(node));
            },
            .deref, .address_of => return f.fresh((try f.eval(s, tree.nodeData(node).node)).s, node, 0),
            .unwrap_optional => {
                const e = try f.eval(s, tree.nodeData(node).node_and_token[0]);
                // Proven where the operand holds a value on the path; past it, it does (a safe
                // build traps otherwise).
                const p = e.v.present;
                const goal: ?Lin = if (p) |x| try atLeast(f.a, x, constant(1)) else null;
                try f.record(node, .present, if (goal) |g| try f.shows(e.s, g) else false);
                const after = if (p) |x| try f.same(e.s, x, constant(1)) else e.s;
                return f.fresh(after, node, 0);
            },
            .comparison, .logic => {
                const split = try f.cond(s, node);
                return .{ .s = try f.join(split.yes, split.no) };
            },
            .tried => return f.tried(s, node),
            .@"catch", .@"orelse" => return f.otherwise(s, node),
            .@"if" => return f.branch(s, node),
            .@"while" => return f.whileLoop(s, node),
            .@"for" => return f.forLoop(s, node),
            .@"switch" => return f.switchOn(s, node),
            .@"return" => return f.returned(s, node),
            .@"break" => return f.jump(s, node, true),
            .@"continue" => return f.jump(s, node, false),
            .body => {
                var buffer: [2]Ast.Node.Index = undefined;
                if (tree.blockStatements(&buffer, node) == null) return .{ .s = s };
                return f.block(s, node);
            },
            .call => return f.call(s, node),
            .builtin => return f.builtin(s, node),
            .struct_literal => {
                var buffer: [2]Ast.Node.Index = undefined;
                const full = tree.fullStructInit(&buffer, node).?; // unreachable: a struct literal's form holds them
                var out = s;
                var values: std.ArrayList(Value) = .empty;
                for (full.ast.fields) |each| {
                    const e = try f.eval(out, each);
                    out = e.s;
                    if (f.proving.len != 0) try values.append(f.a, e.v);
                }
                if (f.proving.len != 0) try f.judgeLiteral(out, node, full.ast.fields, values.items);
                return .{ .s = out };
            },
            .array_literal => {
                var buffer: [2]Ast.Node.Index = undefined;
                const full = tree.fullArrayInit(&buffer, node).?; // unreachable: an array literal's form holds them
                var out = s;
                for (full.ast.elements) |each| out = (try f.eval(out, each)).s;
                return .{ .s = out, .v = .{ .length = constant(@intCast(full.ast.elements.len)) } };
            },
            .@"asm", .frame => return error.Unsupported,
            // Evaluated as the program compiles, or a type: nothing at run time.
            .@"comptime", .optional_type, .array_type, .pointer_type, .anyframe_type, .error_union, .merged_errors, .prototype => return .{ .s = s },
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
            switch (accesses.formOf(tag)) {
                .@"return", .@"break", .@"continue" => if (functionOf(f.c, f.file, inner) == f.function) return error.Unsupported,
                .assign, .compound_assign => if (f.trackedName(tree.nodeData(inner).node_and_node[0]) != null) return error.Unsupported,
                .destructure, .variable => if (functionOf(f.c, f.file, inner) == f.function) return error.Unsupported,
                .@"asm" => return error.Unsupported,
                else => {},
            }
        }
        // What it does is not read: it may call or store into any place.
        return f.fresh(try f.wrote(s, null, null), node, 0);
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
        if (Facts.isNull(f.tree, node)) return .{ .s = s, .v = .{ .present = constant(0) } };
        const reference = f.model.reference(node) orelse return .{ .s = s };
        const d = reference.declaration orelse return .{ .s = s };
        if (f.tracked(d) and try f.c.facts.resolve(f.file, node) == .optional) {
            const u = try f.unit(s, .{ .presence = d });
            return .{ .s = u[0], .v = .{ .present = try single(f.a, u[1]) } };
        }
        if (f.tracked(d)) {
            const int = (try f.intOf(node)) orelse f.param_ints.get(d) orelse return .{ .s = s };
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

    /// `x.len` of memory: the length of `x`'s memory; any other field: nothing known.
    fn field(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const holder, const field_token = f.tree.nodeData(node).node_and_token;
        const e = try f.eval(s, holder);
        // `len` is a slice's or an array's length; a struct's own field of that name is a field.
        _ = field_token;
        if (try f.c.facts.languageField(f.file, node) != .len or !try f.holdsLength(holder)) {
            if (try f.presencePlaceOf(node)) |p| {
                const v = try f.presencePlaceVar(p);
                return .{ .s = try f.within(e.s, v), .v = .{ .present = try single(f.a, v) } };
            }
            if (try f.placeOf(node)) |p| return f.placeValue(e.s, node, p);
            // A constant a namespace declares (`frame.legacy_block_len`), as a name's.
            if (try Range.constantValue(f.c, f.file, node)) |value| if (value <= std.math.maxInt(Coef)) return .{ .s = e.s, .v = .{ .lin = constant(@intCast(value)) } };
            return f.fresh(e.s, node, 0);
        }
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
        // A many-item or C pointer has no length, and memory of a type not read has none known.
        switch (try memoryKind(f.c, f.file, memory, 0)) {
            .checked, .sentinel => {},
            .unchecked, .unknown => return .{ s, null },
        }
        if (value.length) |known_length| return .{ s, known_length };
        if (try Range.memoryLength(f.c, f.file, memory)) |fixed| if (fixed <= std.math.maxInt(Coef)) return .{ s, constant(@intCast(fixed)) };
        const d = f.trackedName(memory) orelse return .{ s, null };
        return .{ s, try single(f.a, try f.variable(.{ .length = d })) };
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
            // Memory with a sentinel reads it at its length: a safe build checks `i <= len`.
            const high = if (try memoryKind(f.c, f.file, memory, 0) == .sentinel) try atLeast(f.a, length, position) else try above(f.a, length, position);
            try f.record(at, .index, (low != null and try f.shows(out, low.?)) and (high != null and try f.shows(out, high.?)));
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
        // A sentinel's slice reads the element at its end too, which memory with a sentinel of its
        // own holds at its length.
        const own_sentinel = try memoryKind(f.c, f.file, full.ast.sliced, 0) == .sentinel;
        const room: ?Lin = if (length) |l| (if (full.ast.sentinel != .none and !own_sentinel) shiftedBy(l, -1) else l) else null;
        // An open slice ends at its length; an end with no known value proves nothing.
        const last = if (full.ast.end != .none) end else length;
        if (full.ast.end.unwrap()) |end_node| {
            const fits_end = if (last != null and room != null) try atLeast(f.a, room.?, last.?) else null;
            try f.record(end_node, .end, fits_end != null and try f.shows(out, fits_end.?));
            out = try assume(f.a, out, fits_end);
            const ordered_bounds = if (start.v.lin != null and last != null) try atLeast(f.a, last.?, start.v.lin.?) else null;
            try f.record(full.ast.start, .order, ordered_bounds != null and try f.shows(out, ordered_bounds.?));
            out = try assume(f.a, out, ordered_bounds);
        }
        const fits_start = if (start.v.lin != null and room != null) try atLeast(f.a, room.?, start.v.lin.?) else null;
        try f.record(full.ast.start, .start, fits_start != null and try f.shows(out, fits_start.?));
        out = try assume(f.a, out, fits_start);
        const size: ?Lin = if (last != null and start.v.lin != null) try minus(f.a, last.?, start.v.lin.?) else null;
        // A part of memory whose length is claimed, or of a pointer with none, holds a claim.
        const claimed = m.v.claimed or try memoryKind(f.c, f.file, full.ast.sliced, 0) == .unchecked or f.lengthClaimed(full.ast.sliced);
        return .{ .s = out, .v = .{ .length = size, .claimed = claimed } };
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
                try f.record(node, .arith, low != null and high != null and try f.shows(out, low.?) and try f.shows(out, high.?));
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
                        try f.shows(out, (try atLeast(f.a, exact.?, constant(bounds.low.?))) orelse return f.fresh(out, node, 0)) and
                        try f.shows(out, (try atLeast(f.a, constant(bounds.high.?), exact.?)) orelse return f.fresh(out, node, 0)))
                        return .{ .s = out, .v = .{ .lin = exact } };
                }
                return f.fresh(out, node, 0);
            },
            .div, .mod => {
                if (y) |d| {
                    const positive = try atLeast(f.a, d, constant(1));
                    const negative = try atLeast(f.a, constant(-1), d);
                    try f.record(divisor, .divisor, (positive != null and try f.shows(out, positive.?)) or (negative != null and try f.shows(out, negative.?)));
                    // An unsigned divisor other than zero is one or more.
                    if (try f.shows(out, (try atLeast(f.a, d, constant(0))).?)) out = try assume(f.a, out, positive);
                } else try f.record(divisor, .divisor, false);
                const made = try f.fresh(out, node, 0);
                out = made.s;
                const t = made.v.lin orelse return made;
                const left = x orelse return made;
                const d = y orelse return made;
                const left_natural = try f.shows(out, (try atLeast(f.a, left, constant(0))).?);
                const d_positive = try f.shows(out, (try atLeast(f.a, d, constant(1))).?);
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
                if (!try f.shows(out, (try atLeast(f.a, left, constant(0))).?)) return made;
                // An unsigned shift right or mask is at most what it takes from.
                out = try assume(f.a, out, try atLeast(f.a, t, constant(0)));
                out = try assume(f.a, out, try atLeast(f.a, left, t));
                if (op == .bit_and) if (y) |mask| if (try f.shows(out, (try atLeast(f.a, mask, constant(0))).?)) {
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

    /// A builtin call; one that writes through a pointer it is given (`@memcpy`, an atomic
    /// store) leaves nothing known of any place.
    fn builtin(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const made = try f.builtinValue(s, node);
        const which = f.tree.tokenSlice(f.tree.nodeMainToken(node));
        // `@call` calls a function this reading does not follow: it may write any memory its
        // arguments reach, as a builtin that writes memory does.
        for ([_][]const u8{ "@memcpy", "@memset", "@memmove", "@atomicStore", "@atomicRmw", "@cmpxchgWeak", "@cmpxchgStrong", "@call" }) |writes| if (std.mem.eql(u8, which, writes)) {
            return .{ .s = try f.wrote(made.s, null, null), .v = made.v };
        };
        return made;
    }

    fn builtinValue(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
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
            const within_type = low != null and high != null and try f.shows(out, low.?) and try f.shows(out, high.?);
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
            // A `u1`, whatever type it is read in.
            const made = try f.temp(out, node, 0);
            const t = try single(f.a, made[1]);
            var bounded = try assume(f.a, made[0], try atLeast(f.a, t, constant(0)));
            bounded = try assume(f.a, bounded, try atLeast(f.a, constant(1), t));
            return .{ .s = bounded, .v = .{ .lin = t } };
        }
        if (is(which, "@popCount") or is(which, "@ctz") or is(which, "@clz")) {
            // A count of bits, whatever type it is read in: at most its operand's width, as
            // Range shows it.
            const most = (try Range.stepMost(f.c, f.file, node, f.width)) orelse return f.fresh(out, node, 0);
            if (most > std.math.maxInt(Coef)) return f.fresh(out, node, 0);
            const made = try f.temp(out, node, 0);
            const t = try single(f.a, made[1]);
            var bounded = try assume(f.a, made[0], try atLeast(f.a, t, constant(0)));
            bounded = try assume(f.a, bounded, try atLeast(f.a, constant(@intCast(most)), t));
            return .{ .s = bounded, .v = .{ .lin = t } };
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
        switch (Facts.conditionOf(tree, node)) {
            .not => |inner| {
                const split = try f.cond(s, inner);
                return .{ .yes = split.no, .no = split.yes };
            },
            .both => |sides| {
                const left = try f.cond(s, sides[0]);
                const right = try f.cond(left.yes, sides[1]);
                return .{ .yes = right.yes, .no = try f.join(left.no, right.no) };
            },
            .either => |sides| {
                const left = try f.cond(s, sides[0]);
                const right = try f.cond(left.no, sides[1]);
                return .{ .yes = try f.join(left.yes, right.yes), .no = right.no };
            },
            .compare => |compared| {
                const left = try f.heldPast(try f.eval(s, compared.left), compared.node, compared.right);
                const right = try f.eval(left.s, compared.right);
                const base = right.s;
                try f.counted(base, compared.left, left.v.lin);
                try f.counted(base, compared.right, right.v.lin);
                // A comparison with `null`: whether the other side holds a value.
                const null_right = Facts.isNull(tree, compared.right);
                if (null_right or Facts.isNull(tree, compared.left)) {
                    const p = (if (null_right) left.v.present else right.v.present) orelse return .{ .yes = base, .no = base };
                    const absent = try f.same(base, p, constant(0));
                    const held = try f.same(base, p, constant(1));
                    return switch (compared.order) {
                        .equal => .{ .yes = absent, .no = held },
                        .not_equal => .{ .yes = held, .no = absent },
                        else => .{ .yes = base, .no = base },
                    };
                }
                const x = left.v.lin orelse return .{ .yes = base, .no = base };
                const y = right.v.lin orelse return .{ .yes = base, .no = base };
                return switch (compared.order) {
                    .less => .{ .yes = try assume(f.a, base, try above(f.a, y, x)), .no = try assume(f.a, base, try atLeast(f.a, x, y)) },
                    .less_or_equal => .{ .yes = try assume(f.a, base, try atLeast(f.a, y, x)), .no = try assume(f.a, base, try above(f.a, x, y)) },
                    .greater => .{ .yes = try assume(f.a, base, try above(f.a, x, y)), .no = try assume(f.a, base, try atLeast(f.a, y, x)) },
                    .greater_or_equal => .{ .yes = try assume(f.a, base, try atLeast(f.a, x, y)), .no = try assume(f.a, base, try above(f.a, y, x)) },
                    .equal => .{ .yes = try f.same(base, x, y), .no = base },
                    .not_equal => .{ .yes = base, .no = try f.same(base, x, y) },
                };
            },
            .other => |at| if (spellsName(tree, at)) {
                if (try f.c.facts.literalOf(f.file, at)) |written| if (written == .boolean) return if (written.boolean) .{ .yes = s, .no = State.unreachable_state } else .{ .yes = State.unreachable_state, .no = s };
                // A tracked `bool`: 1 where it holds, 0 where it does not.
                if (f.trackedName(at)) |d| {
                    const u = try f.unit(s, .{ .boolean = d });
                    const b = try single(f.a, u[1]);
                    return .{ .yes = try f.same(u[0], b, constant(1)), .no = try f.same(u[0], b, constant(0)) };
                }
            },
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
            // An optional's capture: it holds a value in the then, none in the else.
            if (full.error_token == null) if (e.v.present) |p| {
                split = .{ .yes = try f.same(split.yes, p, constant(1)), .no = try f.same(split.no, p, constant(0)) };
            };
            payload = .{ .lin = e.v.lin, .length = e.v.length };
        } else split = try f.cond(s, full.ast.cond_expr);
        const t = try f.temp(split.yes, node, 0);
        const tl = try f.variable(.{ .temp = .{ .node = node, .part = 1 } });
        var yes = try forget(f.a, try forget(f.a, split.no, t[1]), tl);
        _ = &yes;
        var then_state = try forget(f.a, t[0], tl);
        then_state = try f.capture(then_state, full.payload_token, payload, try f.intOf(full.ast.cond_expr));
        const then_value = try f.eval(then_state, full.ast.then_expr);
        const tp = try f.variable(.{ .temp = .{ .node = node, .part = 2 } });
        var then_out = try f.assign(then_value.s, t[1], then_value.v.lin, null);
        then_out = try f.assign(then_out, tl, then_value.v.length, null);
        then_out = try f.branchRange(then_out, t[1], full.ast.then_expr);
        then_out = try f.assign(then_out, tp, try f.presentOf(full.ast.then_expr, then_value.v), null);
        var else_out = try forget(f.a, yes, tp);
        if (full.ast.else_expr.unwrap()) |else_expr| {
            else_out = try f.capture(else_out, full.error_token, .{}, null);
            const else_value = try f.eval(else_out, else_expr);
            else_out = try f.assign(else_value.s, t[1], else_value.v.lin, null);
            else_out = try f.assign(else_out, tl, else_value.v.length, null);
            else_out = try f.branchRange(else_out, t[1], else_expr);
            else_out = try f.assign(else_out, tp, try f.presentOf(else_expr, else_value.v), null);
        }
        return .{ .s = try f.join(then_out, else_out), .v = .{ .lin = try single(f.a, t[1]), .length = try single(f.a, tl), .present = try single(f.a, tp) } };
    }

    /// `s` with a branch's value `v` between zero and the most Range shows the branch's
    /// expression `node` reaches, where it shows it never below zero: the join of the branches
    /// keeps what each row one branch holds the other shows, so each branch's range survives it
    /// as the wider of them (`if (c) a else b` of a `u8` and a `u16` is at most 65535), where
    /// the branches' own rows (`t = a`, `t = b`) do not.
    fn branchRange(f: *Frame, s: State, v: Var, node: Ast.Node.Index) Error!State {
        const most = (try Range.stepMost(f.c, f.file, node, f.width)) orelse return s;
        if (most > std.math.maxInt(Coef)) return s;
        const x = try single(f.a, v);
        const out = try assume(f.a, s, try atLeast(f.a, x, constant(0)));
        return assume(f.a, out, try atLeast(f.a, constant(@intCast(most)), x));
    }

    /// The state where an optional or error union held its payload: what the expression's
    /// summary gives there.
    fn unwrap(f: *Frame, s: State, value: Value) Error!State {
        var out = s;
        for (value.unwrapped) |row| out = try assume(f.a, out, row);
        if (value.exits.len == 0 or out.dead) return out;
        // Each exit the state lets the callee take, and what it leaves: their join. One it rules
        // out leaves nothing.
        var joined: State = State.unreachable_state;
        for (value.exits) |rows| {
            var taken = out;
            for (rows) |row| taken = try assume(f.a, taken, row);
            if (!taken.dead) joined = try f.join(joined, taken);
        }
        return joined;
    }

    fn tried(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const e = try f.eval(s, f.tree.nodeData(node).node);
        // The error leaves the function, where the callee can fail.
        var failing = e.s;
        for (e.v.failed) |row| failing = try assume(f.a, failing, row);
        try f.leave(failing, true);
        return .{ .s = try f.unwrap(e.s, e.v), .v = .{ .lin = e.v.lin, .length = e.v.length } };
    }

    /// `x catch y`, `x orelse y`: `x`'s payload where it held one, `y` where it did not.
    fn otherwise(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const lhs, const rhs = f.tree.nodeData(node).node_and_node;
        const e = try f.eval(s, lhs);
        const t = try f.temp(e.s, node, 0);
        const tl = try f.variable(.{ .temp = .{ .node = node, .part = 1 } });
        const tp = try f.variable(.{ .temp = .{ .node = node, .part = 2 } });
        const base = try forget(f.a, try forget(f.a, t[0], tl), tp);
        var held = try f.unwrap(base, e.v);
        var missing = base;
        // `x orelse y`: `x` holds a value where its payload is given, none where `y` runs.
        if (f.tree.nodeTag(node) == .@"orelse") if (e.v.present) |p| {
            held = try f.same(held, p, constant(1));
            missing = try f.same(missing, p, constant(0));
        };
        held = try f.assign(held, t[1], e.v.lin, null);
        held = try f.assign(held, tl, e.v.length, null);
        held = try f.assign(held, tp, try f.payloadPresent(lhs), null);
        if (f.tree.nodeTag(node) == .@"catch") {
            // Where it fails, the call's callee left by a failing exit.
            for (e.v.failed) |row| missing = try assume(f.a, missing, row);
            if (!base.dead) try f.record(node, .unfailing, missing.dead);
            const after = f.tree.nodeMainToken(node) + 1;
            if (f.tree.tokenTag(after) == .pipe) missing = try f.capture(missing, after + 1, .{}, null);
        }
        const fallback = try f.eval(missing, rhs);
        missing = try f.assign(fallback.s, t[1], fallback.v.lin, null);
        missing = try f.assign(missing, tl, fallback.v.length, null);
        missing = try f.assign(missing, tp, try f.presentOf(rhs, fallback.v), null);
        return .{ .s = try f.join(held, missing), .v = .{ .lin = try single(f.a, t[1]), .length = try single(f.a, tl), .present = try single(f.a, tp) } };
    }

    fn switchOn(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const full = f.tree.fullSwitch(node).?; // unreachable: the tag is a switch's
        // A labeled switch's `continue` re-enters it: not modelled.
        if (full.label_token != null) return error.Unsupported;
        const subject = try f.eval(s, full.ast.condition);
        const t = try f.temp(subject.s, node, 0);
        const tl = try f.variable(.{ .temp = .{ .node = node, .part = 1 } });
        const tp = try f.variable(.{ .temp = .{ .node = node, .part = 2 } });
        var base = try forget(f.a, try forget(f.a, t[0], tl), tp);
        // Range's greatest value of a subject never below zero (`@max(4, @min(n, 7))` at most 7).
        if (subject.v.lin) |x| if (try Range.stepMost(f.c, f.file, full.ast.condition, f.width)) |most| if (most <= std.math.maxInt(Coef)) {
            base = try assume(f.a, base, try atLeast(f.a, constant(@intCast(most)), x));
        };
        try f.prongsTaken(base, full, subject.v.lin);
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
            done = try f.branchRange(done, t[1], case.ast.target_expr);
            done = try f.assign(done, tp, try f.presentOf(case.ast.target_expr, e.v), null);
            joined = try f.join(joined, done);
        }
        return .{ .s = joined, .v = .{ .lin = try single(f.a, t[1]), .length = try single(f.a, tl), .present = try single(f.a, tp) } };
    }

    //------------------------------------------------------------------
    // Presence and booleans.
    //------------------------------------------------------------------

    /// `s` with `v` between 0 and 1: a presence or a `bool`.
    fn within(f: *Frame, s: State, v: Var) Error!State {
        const x = try single(f.a, v);
        const out = try assume(f.a, s, try atLeast(f.a, x, constant(0)));
        return assume(f.a, out, try atLeast(f.a, constant(1), x));
    }

    /// The 0/1 variable of `key`, held between 0 and 1 in the state.
    fn unit(f: *Frame, s: State, key: Key) Error!struct { State, Var } {
        const v = try f.variable(key);
        return .{ try f.within(s, v), v };
    }

    /// The optional field a tracked declaration's struct holds, or the struct it points to,
    /// whose presence only stores through its name change (`Range.presenceable`).
    fn presencePlaceOf(f: *Frame, node: Ast.Node.Index) Error!?Place {
        return f.fieldPlace(node, .presence);
    }

    /// A place's presence variable, recorded so a write of the field forgets it.
    fn presencePlaceVar(f: *Frame, p: Place) Error!Var {
        const v = try f.variable(.{ .place_presence = p });
        try f.presences.put(f.a, v, p);
        return v;
    }

    /// Whether `node`, valued `value`, holds a value as an optional: what evaluating it gave,
    /// or 1 for a value of a type that is not an optional (a struct literal is never null).
    fn presentOf(f: *Frame, node: Ast.Node.Index, value: Value) Error!?Lin {
        if (value.present) |p| return p;
        return if (try f.neverNull(node)) constant(1) else null;
    }

    /// Whether what `node` gives is never null: a struct or array literal, a number literal, a
    /// value whose type resolves to a struct, a pointer, an array or a function, or one whose
    /// written type (`exprType`) is not an optional's. A scalar is never read so: `null`
    /// resolves as one (`const nothing = null`), and an optional integer's type as its payload's.
    fn neverNull(f: *Frame, node: Ast.Node.Index) Error!bool {
        const at = Facts.ungrouped(f.tree, node);
        switch (Facts.accesses.formOf(f.tree.nodeTag(at))) {
            .struct_literal, .array_literal => return true,
            else => {},
        }
        if (try f.c.facts.literalOf(f.file, at)) |written| if (written == .number or written == .char) return true;
        switch (try f.c.facts.resolve(f.file, at)) {
            .instance, .pointer, .array, .function => return true,
            .alternatives => {},
            else => {},
        }
        const t = (try exprType(f.c, f.file, at, 0)) orelse return false;
        return typeNeverNull(f.c, t, f.width, 0);
    }

    /// Whether the payload of an optional or an error union `node` gives holds a value: 1 for
    /// a payload whose written type is not an optional, else unknown.
    fn payloadPresent(f: *Frame, node: Ast.Node.Index) Error!?Lin {
        const t = (try exprType(f.c, f.file, node, 0)) orelse return null;
        const tree = &f.c.project.at(t.file).file.tree;
        const payload: TypeRef = switch (formAt(tree, t.node)) {
            .optional_type => .{ .file = t.file, .node = tree.nodeData(t.node).node },
            .error_union => .{ .file = t.file, .node = tree.nodeData(t.node).node_and_node[1] },
            else => return null,
        };
        return if (try typeNeverNull(f.c, payload, f.width, 0)) constant(1) else null;
    }

    /// Whether Zig reads `node` as a `bool`: a comparison, a negation, `and` or `or`.
    fn condition(f: *Frame, node: Ast.Node.Index) bool {
        return Facts.conditionOf(f.tree, node) != .other;
    }

    /// A `bool` expression's value: 1 on the paths where it holds and 0 where it fails,
    /// joined, and what it is of what the state knows (`truth`).
    fn truthOf(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        const split = try f.cond(s, node);
        const t = try f.variable(.{ .temp = .{ .node = node, .part = 4 } });
        const b = try single(f.a, t);
        const yes = try f.same(try forget(f.a, split.yes, t), b, constant(1));
        const no = try f.same(try forget(f.a, split.no, t), b, constant(0));
        var out = try f.within(try f.join(yes, no), t);
        if (try f.truth(out, node)) |held| out = try f.same(held[0], b, held[1]);
        return .{ .s = out, .v = .{ .truth = b } };
    }

    /// `truth` of `node`, or where it cannot read it, a fresh variable of any of 0 and 1, whatever
    /// an earlier pass over it held.
    fn truthOrAny(f: *Frame, s: State, node: Ast.Node.Index) Error!struct { State, Lin } {
        if (try f.truth(s, node)) |r| return r;
        const v = try f.variable(.{ .temp = .{ .node = node, .part = 4 } });
        return .{ try f.within(try forget(f.a, s, v), v), try single(f.a, v) };
    }

    /// What a `bool` expression is of the state's variables, reading no more than they hold
    /// (no call, no store): a comparison with `null` is 1 less the other side's presence (or
    /// it), a negation 1 less its operand, `a or b` at least each and at most their sum, `a
    /// and b` at most each and at least their sum less 1, a literal 1 or 0, a tracked bool its
    /// variable. An operand it cannot read is any of 0 and 1.
    fn truth(f: *Frame, s: State, node: Ast.Node.Index) Error!?struct { State, Lin } {
        const tree = f.tree;
        switch (Facts.conditionOf(tree, node)) {
            .not => |inner| {
                const r = (try f.truth(s, inner)) orelse return null;
                return .{ r[0], (try minus(f.a, constant(1), r[1])) orelse return null };
            },
            .both, .either => |sides| {
                const left = try f.truthOrAny(s, sides[0]);
                const right = try f.truthOrAny(left[0], sides[1]);
                var out = right[0];
                const parts: [2]Lin = .{ left[1], right[1] };
                const made_var = try f.variable(.{ .temp = .{ .node = node, .part = 2 } });
                const made: struct { State, Var } = .{ try f.within(try forget(f.a, out, made_var), made_var), made_var };
                out = made[0];
                const u = try single(f.a, made[1]);
                const sum = (try plus(f.a, parts[0], parts[1])) orelse return null;
                if (Facts.conditionOf(tree, node) == .either) {
                    out = try assume(f.a, out, try atLeast(f.a, u, parts[0]));
                    out = try assume(f.a, out, try atLeast(f.a, u, parts[1]));
                    out = try assume(f.a, out, try atLeast(f.a, sum, u));
                } else {
                    out = try assume(f.a, out, try atLeast(f.a, parts[0], u));
                    out = try assume(f.a, out, try atLeast(f.a, parts[1], u));
                    out = try assume(f.a, out, try atLeast(f.a, u, (try minus(f.a, sum, constant(1))) orelse return null));
                }
                return .{ out, u };
            },
            .compare => |compared| {
                const null_right = Facts.isNull(tree, compared.right);
                if (!null_right and !Facts.isNull(tree, compared.left)) return null;
                const other = if (null_right) compared.left else compared.right;
                const read = (try f.presenceRead(s, other)) orelse return null;
                return switch (compared.order) {
                    .equal => .{ read[0], (try minus(f.a, constant(1), read[1])) orelse return null },
                    .not_equal => read,
                    else => null,
                };
            },
            .other => |at| {
                if (!spellsName(tree, at)) return null;
                if (try f.c.facts.literalOf(f.file, at)) |written| if (written == .boolean) return .{ s, constant(@intFromBool(written.boolean)) };
                const d = f.trackedName(at) orelse return null;
                const u = try f.unit(s, .{ .boolean = d });
                return .{ u[0], try single(f.a, u[1]) };
            },
        }
    }

    /// The presence an expression holds, read without evaluating it: `null`'s 0, a tracked
    /// optional's or an optional place's variable.
    fn presenceRead(f: *Frame, s: State, node: Ast.Node.Index) Error!?struct { State, Lin } {
        const at = Facts.ungrouped(f.tree, node);
        if (Facts.isNull(f.tree, at)) return .{ s, constant(0) };
        if (f.trackedName(at)) |d| {
            if (try f.c.facts.resolve(f.file, at) != .optional) return null;
            const u = try f.unit(s, .{ .presence = d });
            return .{ u[0], try single(f.a, u[1]) };
        }
        const p = (try f.presencePlaceOf(at)) orelse return null;
        const v = try f.presencePlaceVar(p);
        return .{ try f.within(s, v), try single(f.a, v) };
    }

    /// Records whether each prong of a switch on a number is taken on no path from `base`
    /// (Kind.untaken): each item a constant (a literal or a range of them) the subject cannot
    /// equal there, and an `else` where the subject can take no value between or beside the
    /// other prongs' items, inline ones' too. An inline prong, a prong an item of which is not
    /// an integer constant, and every prong of a subject that is not linear (an enum, a value
    /// of unknown reach) are taken as far as this reading knows.
    fn prongsTaken(f: *Frame, base: State, full: Ast.full.Switch, subject: ?Lin) Error!void {
        if (f.trial > 0 or base.dead) return;
        const x = subject orelse {
            for (full.ast.cases) |case| try f.record(case, .untaken, false);
            return;
        };
        const Span = struct { low: Coef, high: Coef };
        var spans: std.ArrayList(Span) = .empty;
        var constants = true;
        for (full.ast.cases) |case_node| {
            const case = f.tree.fullSwitchCase(case_node).?; // unreachable: a switch's cases
            // An inline prong is compiled for each of its items: taken, though its items
            // still count against the `else`.
            var untaken = case.ast.values.len > 0 and case.inline_token == null;
            for (case.ast.values) |item| {
                const span = (try f.constantSpan(item)) orelse {
                    constants = false;
                    untaken = false;
                    continue;
                };
                try spans.append(f.a, .{ .low = span[0], .high = span[1] });
                if (untaken) untaken = try f.excludes(base, x, span[0], span[1]);
            }
            if (case.ast.values.len > 0) try f.record(case_node, .untaken, untaken);
        }
        const other = for (full.ast.cases) |case_node| {
            if (f.tree.fullSwitchCase(case_node).?.ast.values.len == 0) break case_node; // unreachable: a switch's cases
        } else return;
        if (!constants) return f.record(other, .untaken, false);
        std.mem.sort(Span, spans.items, {}, struct {
            fn less(_: void, p: Span, q: Span) bool {
                return p.low < q.low;
            }
        }.less);
        // The values no item names: below the first, between two, above the last.
        var next: ?Coef = null;
        for (spans.items) |span| {
            if (next) |from| {
                if (from < span.low and !try f.excludes(base, x, from, span.low - 1)) return f.record(other, .untaken, false);
            } else if (!try f.excludes(base, x, null, span.low - 1)) return f.record(other, .untaken, false);
            next = if (next) |from| @max(from, span.high +| 1) else span.high +| 1;
        }
        if (next) |from| if (!try f.excludes(base, x, from, null)) return f.record(other, .untaken, false);
        try f.record(other, .untaken, true);
    }

    /// The constant an item is, or the constants a range of them spans.
    fn constantSpan(f: *Frame, item: Ast.Node.Index) Error!?[2]Coef {
        const low, const high = if (f.tree.nodeTag(item) == .switch_range) f.tree.nodeData(item).node_and_node else .{ item, item };
        const a = (try Range.constantValue(f.c, f.file, low)) orelse return null;
        const b = (try Range.constantValue(f.c, f.file, high)) orelse return null;
        // u64 items: no overflow in i128, nor in `span.low - 1` and `span.high +| 1` below.
        return .{ @intCast(a), @intCast(b) };
    }

    /// Whether `s` leaves `x` no value from `low` to `high` (either open where null) in `s`.
    fn excludes(f: *Frame, s: State, x: Lin, low: ?Coef, high: ?Coef) Error!bool {
        var in = s;
        if (low) |k| in = try assume(f.a, in, try atLeast(f.a, x, constant(k)));
        if (high) |k| in = try assume(f.a, in, try atLeast(f.a, constant(k), x));
        return in.dead;
    }

    //------------------------------------------------------------------
    // Jumps.
    //------------------------------------------------------------------

    fn returned(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        var out = s;
        var failing: Failing = .no;
        if (f.tree.nodeData(node).opt_node.unwrap()) |operand| {
            const e = try f.eval(out, operand);
            out = e.s;
            failing = try f.failingOf(operand);
            const result = try f.variable(.result);
            out = try f.assign(out, result, if (f.returns_int) e.v.lin else null, null);
            const result_length = try f.variable(.result_length);
            out = try f.assign(out, result_length, e.v.length, null);
        }
        // A value that may be an error leaves either way: with the function's errdefers run
        // where it is one.
        if (failing != .yes) try f.leave(out, false);
        if (failing != .no) try f.leave(out, true);
        return .{ .s = State.unreachable_state };
    }

    /// Whether a returned value is an error: `error.X` is; a value no error can be (a `try`'s
    /// payload, a literal, what an operator or an arithmetic builtin gives, a value of a kind
    /// that holds no error, `failingValue`) is not; anything else may be.
    fn failingOf(f: *Frame, operand: Ast.Node.Index) Error!Failing {
        switch (formAt(f.tree, operand)) {
            .leaf => if (try f.c.facts.literalOf(f.file, operand)) |written| switch (written) {
                .error_value => return .yes,
                .number, .char, .string, .enum_literal => return .no,
                else => {},
            },
            .tried, .operator, .logic, .comparison => return .no,
            .builtin => {
                const called = f.tree.tokenSlice(f.tree.nodeMainToken(operand));
                for (numeric_builtins) |each| if (std.mem.eql(u8, called, each)) return .no;
            },
            else => {},
        }
        // A name declared of an integer type is never an error (an expression's own type,
        // `Range.intOf`, is a call's payload's, whether or not it failed).
        if (try f.declaredInt(operand)) return .no;
        return failingValue(try f.c.facts.resolve(f.file, operand));
    }

    /// Whether `node` names a parameter or a local declared of an integer type, as written
    /// (`d: usize`, `const n: u32 = …`) or bound in the reading (`n: T`).
    fn declaredInt(f: *Frame, node: Ast.Node.Index) Error!bool {
        const d = (nameRef(f.model, node) orelse return false).declaration orelse return false;
        if (f.param_ints.contains(d)) return true;
        const decl = f.model.declarations[@backingInt(d)];
        if (decl.kind != .variable) return false;
        const local = f.tree.fullVarDecl(decl.node) orelse return false;
        const type_node = local.ast.type_node.unwrap() orelse return false;
        return try Range.intNamedIn(f.c, f.bound, f.file, type_node, f.width) != null;
    }

    /// Whether a value of what `value` resolves to is an error: only a number, a pointer, a
    /// struct's or an array's value, an optional or a function is none; one that may be a
    /// type's name (`anyerror`) or of a kind not read may be one.
    fn failingValue(value: Facts.Value) Failing {
        return switch (value) {
            // An anonymous literal (`return .{ .a = d }` into `!Foo`) is a payload, never an error.
            .scalar, .pointer, .instance, .array, .optional, .function, .literal => .no,
            .alternatives => |each| for (each) |one| {
                if (failingValue(one) != .no) break .maybe;
            } else .no,
            else => .maybe,
        };
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
        for (candidates) |row| if (try f.shows(entry, row)) {
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
                if (!try f.implied(pass.back, invariant)) invariant = .{};
                break;
            }
            f.trial += 1;
            const pass = try f.passOf(invariant, node, label, t[1], form);
            f.trial -= 1;
            var next = try f.preservedBy(invariant, pass.back);
            // A candidate the head holds and the pass keeps is kept, though the head held it
            // in a tighter form the pass does not keep (`i < n` on entry, `i <= n` after).
            for (candidates) |row| {
                if (try f.shows(next, row)) continue;
                if (try f.shows(invariant, row) and try f.shows(pass.back, row)) next = try assume(f.a, next, row);
            }
            if (try f.implied(next, invariant)) break;
            invariant = next;
        }
        const final = try f.passOf(invariant, node, label, t[1], form);
        var out = final.exit;
        for (final.breaks) |state| out = try f.join(out, state);
        return .{ .s = try f.leftLoop(out, node), .v = .{ .lin = try single(f.a, t[1]) } };
    }

    /// `s` past the loop `node`, without the variables only its passes read (its count of
    /// passes, its `for` count and counter, what its steps entered with): what they gave the
    /// variables that live on stays, and they take none of the room a state keeps for those.
    fn leftLoop(f: *Frame, s: State, node: Ast.Node.Index) Error!State {
        var out = s;
        for (f.vars.keys(), f.vars.values()) |key, v| {
            const own = switch (key) {
                .passes, .count => |at| at == node,
                .entry => |e| e.loop == node,
                .place_step => |e| e.loop == node,
                .temp => |t| t.node == node and t.part == 6,
                else => false,
            };
            if (own) out = try forget(f.a, out, v);
        }
        return out;
    }

    /// `s` with what it implies among the variables the loop `node` leaves alone: a value or
    /// length of a declaration made before the loop that nothing in it assigns, and the
    /// loop's own entry snapshots.
    fn fixedOver(f: *Frame, s: State, node: Ast.Node.Index) Error!State {
        const first = f.tree.firstToken(node);
        const last = f.tree.lastToken(node);
        const assigned = (try f.assignedIn(node)) orelse return s;
        var kept = s;
        for (f.vars.keys(), f.vars.values()) |key, v| {
            const fixed = switch (key) {
                .value, .length => |d| !assigned.contains(d) and outside(f.model.declarations[@backingInt(d)].token, first, last),
                .entry => |e| e.loop == node,
                .place_step => |e| e.loop == node,
                .count => |counted_loop| counted_loop == node,
                else => false,
            };
            if (!fixed) kept = try forget(f.a, kept, v);
        }
        var out = s;
        for (kept.rows) |row| out = try assume(f.a, out, row);
        return out;
    }

    /// The tracked declarations the loop `node` assigns, a length stored among them (`s.len =
    /// n`, `@field(s, …) = v`); null where a destructure in it may assign any.
    fn assignedIn(f: *Frame, node: Ast.Node.Index) Error!?std.AutoHashMapUnmanaged(Model.Declaration.Id, void) {
        const first = f.tree.firstToken(node);
        const last = f.tree.lastToken(node);
        var assigned: std.AutoHashMapUnmanaged(Model.Declaration.Id, void) = .empty;
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            switch (accesses.formOf(tag)) {
                .assign, .compound_assign => {},
                .destructure => return null,
                else => continue,
            }
            const inner: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const token = f.tree.nodeMainToken(inner);
            if (token < first or token > last) continue;
            const target = f.tree.nodeData(inner).node_and_node[0];
            const d = f.trackedName(target) orelse (try f.lengthStored(target)) orelse continue;
            try assigned.put(f.a, d, {});
        }
        return assigned;
    }

    /// Records whether the pass of the loop `node` about to run in `s` is within a short's count
    /// of passes, or within the length of memory the function holds that the loop leaves alone:
    /// a slice declared before it and not assigned in it, whose length is its memory's, not a
    /// claim (`Value.claimed`). Where every pass is, the loop runs no more passes than that
    /// length, whatever its condition reads.
    fn passesHeld(f: *Frame, s: State, node: Ast.Node.Index) Error!void {
        if (f.trial > 0) return;
        const ran = shiftedBy(try single(f.a, try f.variable(.{ .passes = node })), 1).?; // unreachable: a variable's constant is 0
        if (try f.holds(s, try atLeast(f.a, constant(std.math.maxInt(u16)), ran))) return f.record(node, .passes, true);
        const assigned = (try f.assignedIn(node)) orelse return f.record(node, .passes, false);
        const first = f.tree.firstToken(node);
        const last = f.tree.lastToken(node);
        for (f.vars.keys(), f.vars.values()) |key, v| {
            const d = switch (key) {
                .length => |d| d,
                else => continue,
            };
            if (f.claimed.contains(v) or assigned.contains(d) or !outside(f.model.declarations[@backingInt(d)].token, first, last)) continue;
            if (try f.holds(s, try atLeast(f.a, try single(f.a, v), ran))) return f.record(node, .passes, true);
        }
        try f.record(node, .passes, false);
    }

    /// What a loop's assignment steps: a tracked variable, or a place (`s.at`).
    const Stepped = union(enum) { decl: Model.Declaration.Id, place: Place };

    /// The variable or place `node` names, as a step may assign it.
    fn steppedBy(f: *Frame, node: Ast.Node.Index) Error!?Stepped {
        if (f.trackedName(node)) |d| return .{ .decl = d };
        if (try f.placeOf(node)) |p| return .{ .place = p };
        return null;
    }

    fn sameStepped(f: *Frame, node: Ast.Node.Index, target: Stepped) Error!bool {
        const named = (try f.steppedBy(node)) orelse return false;
        return std.meta.eql(named, target);
    }

    /// Each variable or place the loop `node` steps, by an amount of at most `U` up and `D` down
    /// each time (`n += 1`, `total += byte`, `at = at - 2`, `depth -= 1`): kept as it entered,
    /// with the candidates `v - v0 <= U·p` and `v0 - v <= D·p` over the passes `p`, and, where
    /// it goes one way only, `v0 <= v` (or `v <= v0`). A candidate a pass does not keep (two
    /// steps in one pass) is dropped like any other: the loop's invariant keeps only what every
    /// pass preserves.
    fn stepCandidates(f: *Frame, s: State, node: Ast.Node.Index, p: Var, out: *std.ArrayList(Lin)) Error!State {
        const Step = struct { target: Stepped, at: Ast.Node.Index, up: Coef = 0, down: Coef = 0, least: ?Coef = null, way: ?bool = null, other: bool = false };
        var steps: std.ArrayList(Step) = .empty;
        const first = f.tree.firstToken(node);
        const last = f.tree.lastToken(node);
        for (f.tree.nodes.items(.tag), 0..) |tag, i| {
            const inner: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const token = f.tree.nodeMainToken(inner);
            if (token < first or token > last) continue;
            const target, const value = switch (accesses.formOf(tag)) {
                .assign, .compound_assign => f.tree.nodeData(inner).node_and_node,
                else => continue,
            };
            const stepped = (try f.steppedBy(target)) orelse continue;
            const found = for (steps.items) |*step| {
                if (std.meta.eql(step.target, stepped)) break step;
            } else blk: {
                try steps.append(f.a, .{ .target = stepped, .at = target });
                break :blk &steps.items[steps.items.len - 1];
            };
            const way = try f.stepOf(stepped, tag, value) orelse {
                found.other = true;
                continue;
            };
            if (way.up) found.up = @max(found.up, way.most) else found.down = @max(found.down, way.most);
            // A step at least `k` counts only where every step goes the same way.
            if (found.way) |w| {
                if (w != way.up) found.least = 0;
            }
            found.way = way.up;
            found.least = @min(found.least orelse way.least, way.least);
        }
        var entry = s;
        for (steps.items) |step| {
            if (step.other or (step.up == 0 and step.down == 0)) continue;
            const v: Lin = switch (step.target) {
                .decl => |d| try single(f.a, try f.variable(.{ .value = d })),
                .place => |place| read: {
                    // Read as the loop's body reads it: within its type, and what it held at
                    // entry where nothing has stored a place yet.
                    const e = try f.placeValue(entry, step.at, place);
                    entry = e.s;
                    break :read e.v.lin orelse continue;
                },
            };
            const v0_var = try f.variable(switch (step.target) {
                .decl => |d| .{ .entry = .{ .loop = node, .d = d } },
                .place => |place| .{ .place_step = .{ .loop = node, .place = place } },
            });
            entry = try forget(f.a, entry, v0_var);
            entry = try f.equal(entry, v0_var, v);
            const v0 = try single(f.a, v0_var);
            if (step.up > 0) {
                const reach = (try scaled(f.a, try single(f.a, p), step.up)) orelse continue;
                if (try plus(f.a, v0, reach)) |top| if (try atLeast(f.a, top, v)) |row| try out.append(f.a, row);
            } else if (try atLeast(f.a, v0, v)) |row| try out.append(f.a, row);
            if (step.down > 0) {
                const reach = (try scaled(f.a, try single(f.a, p), step.down)) orelse continue;
                if (try plus(f.a, v, reach)) |bottom| if (try atLeast(f.a, bottom, v0)) |row| try out.append(f.a, row);
            } else if (try atLeast(f.a, v, v0)) |row| try out.append(f.a, row);
            // A step of at least `k` on each path through a pass (`: (i += 1)`) goes at least
            // `k·p`: the count of passes is then bounded by how far the variable may go.
            const least = step.least orelse 0;
            if (least == 0) continue;
            const gone = (try scaled(f.a, try single(f.a, p), least)) orelse continue;
            if (step.down == 0) {
                if (try plus(f.a, v0, gone)) |bottom| if (try atLeast(f.a, v, bottom)) |row| try out.append(f.a, row);
            } else if (step.up == 0) {
                if (try plus(f.a, v, gone)) |top| if (try atLeast(f.a, v0, top)) |row| try out.append(f.a, row);
            }
        }
        return entry;
    }

    /// An assignment to `target` as a step: which way and by at most how much, or null where it
    /// is no step (a wrapping one, a product, a value of its own).
    fn stepOf(f: *Frame, target: Stepped, tag: Ast.Node.Tag, value: Ast.Node.Index) Error!?struct { up: bool, most: Coef, least: Coef } {
        const up, const amount = switch (tag) {
            .assign_add, .assign_add_sat => .{ true, value },
            .assign_sub, .assign_sub_sat => .{ false, value },
            .assign => switch (f.tree.nodeTag(value)) {
                .add, .add_sat, .sub, .sub_sat => blk: {
                    const lhs, const rhs = f.tree.nodeData(value).node_and_node;
                    const sum = f.tree.nodeTag(value) == .add or f.tree.nodeTag(value) == .add_sat;
                    if (try f.sameStepped(lhs, target)) break :blk .{ sum, rhs };
                    if (sum and try f.sameStepped(rhs, target)) break :blk .{ true, lhs };
                    return null;
                },
                else => return null,
            },
            else => return null,
        };
        if (try f.sameStepped(amount, target)) return null;
        if (try f.c.facts.literalOf(f.file, amount)) |written| if (written == .number) switch (std.zig.parseNumberLiteral(f.tree.tokenSlice(f.tree.nodeMainToken(Facts.ungrouped(f.tree, amount))))) {
            .int => |k| return .{ .up = up, .most = k, .least = k },
            else => return null,
        };
        if (try f.intOf(amount)) |int| {
            if (int.signed) return null;
            const most = (try f.range(int, true)).high orelse return null;
            return .{ .up = up, .most = most, .least = 0 };
        }
        // An amount of no integer type of its own (`@intFromBool(b)`, `@popCount(x)`): at most
        // what Range shows it, where it shows it never below zero.
        const most = (try Range.stepMost(f.c, f.file, amount, f.width)) orelse return null;
        if (most > std.math.maxInt(Coef)) return null;
        return .{ .up = up, .most = @intCast(most), .least = 0 };
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
        for (target.continues.items) |state| back = try f.join(back, state);
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
        try f.passesHeld(split.yes, node);
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
        switch (Facts.conditionOf(f.tree, node)) {
            .both => |sides| {
                try f.candidatesOf(s, sides[0], out);
                try f.candidatesOf(s, sides[1], out);
            },
            .compare => |compared| {
                if (compared.order == .equal or compared.order == .not_equal) return;
                const lhs = compared.left;
                const rhs = compared.right;
                const was_trial = f.trial;
                // Read for their forms alone: no verdicts.
                f.trial += 1;
                defer f.trial = was_trial;
                const left = f.eval(s, lhs) catch return;
                const right = f.eval(left.s, rhs) catch return;
                const x = left.v.lin orelse return;
                const y = right.v.lin orelse return;
                const row = switch (compared.order) {
                    .less, .less_or_equal => try atLeast(f.a, y, x),
                    .greater, .greater_or_equal => try atLeast(f.a, x, y),
                    .equal, .not_equal => unreachable, // returned above
                };
                if (row) |r| try out.append(f.a, r);
            },
            .not, .either, .other => {},
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
        const at_entry = try f.variable(.{ .count = node });
        if (count) |n| {
            out = try f.assign(out, at_entry, n, null);
        } else {
            // A count no input shows is still a length or a range's: a `usize`, so a loop
            // makes fewer passes than `usize` counts.
            out = try f.assign(out, at_entry, null, .{ .bits = f.width, .signed = false });
        }
        count = try single(f.a, at_entry);
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
        try f.passesHeld(entered, node);
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

    /// A call: its arguments evaluated in order, each read as it was before the call; unless it
    /// cannot write the program's memory (`Range.inert`), nothing known of any place after it;
    /// and where it reaches one function of the program, that function's summary on the path
    /// where it returns a value, of the arguments, the result and the places the arguments
    /// hold.
    /// `s` past the call `node`, which has no summary, with its result's length `tl` as long as
    /// an argument says where std's own function is known by declaration
    /// (`Range.lengthArgument`: a reader's `take(n)`).
    fn lengthGiven(f: *Frame, s: State, node: Ast.Node.Index, args: []const Value, tl: Var) Error!State {
        const position = (try Range.lengthArgument(f.c, f.file, node)) orelse return s;
        if (position >= args.len) return s;
        const n = args[position].lin orelse return s;
        return f.equal(s, tl, n);
    }

    fn call(f: *Frame, s: State, node: Ast.Node.Index) RunError!Eval {
        var buffer: [1]Ast.Node.Index = undefined;
        const full = f.tree.fullCall(&buffer, node).?; // unreachable: the tag is a call's
        var out = s;
        var receiver: ?Value = null;
        var holder_node: ?Ast.Node.Index = null;
        if (formAt(f.tree, full.ast.fn_expr) == .member) {
            const holder = f.tree.nodeData(full.ast.fn_expr).node_and_token[0];
            const e = try f.eval(out, holder);
            out = e.s;
            switch (try f.c.facts.resolve(f.file, holder)) {
                .instance, .pointer, .optional => {
                    const measured = try f.lengthOf(out, holder, e.v);
                    out = measured[0];
                    receiver = .{ .lin = e.v.lin, .length = measured[1] };
                    holder_node = holder;
                    out = try f.heldAtCall(out, node, 1, &receiver.?, f.assignsAny(full.ast.params));
                },
                .alternatives => {},
                else => {},
            }
        }
        var args: std.ArrayList(Value) = .empty;
        if (receiver) |r| try args.append(f.a, r);
        for (full.ast.params, 0..) |param, i| {
            const e = try f.eval(out, param);
            out = e.s;
            try f.counted(out, param, e.v.lin);
            var arg: Value = .{ .lin = e.v.lin };
            if (e.v.lin == null) {
                const measured = try f.lengthOf(out, param, e.v);
                out = measured[0];
                arg = .{ .length = measured[1] };
            }
            out = try f.heldAtCall(out, node, @intCast(2 + i), &arg, f.assignsAny(full.ast.params[i + 1 ..]));
            try args.append(f.a, arg);
        }
        try f.recordCall(out, node, full.ast.fn_expr, args.items);
        const summary = try f.summaryOf(node, full.ast.fn_expr);
        // The places the summary reads, each where an argument holds it: what it held before the
        // call, kept in the call's temporaries, and the place itself after.
        const places: []const SlotPlace = if (summary) |callee| callee.places else &.{};
        var entries: [max_slot_places]Given = @splat(.{});
        for (0..max_slot_places) |k| {
            if (k >= places.len) break;
            const listed = places[k];
            const operand = operand: {
                if (holder_node) |holder| {
                    // The receiver is the first operand.
                    const i = std.math.sub(usize, listed.param, 1) catch break :operand holder;
                    if (i >= full.ast.params.len) continue;
                    break :operand full.ast.params[i];
                }
                if (listed.param >= full.ast.params.len) continue;
                break :operand full.ast.params[listed.param];
            };
            const root = f.trackedName(if (formAt(f.tree, operand) == .address_of) f.tree.nodeData(operand).node else operand) orelse continue;
            const p: Place = .{ .root = root, .field = listed.field };
            entries[k].place = p;
            // Each place's entries in the temporaries after the operands'.
            inline for (.{ false, true }, 0..) |length, part| {
                const made = f.known(if (length) .{ .place_length = p } else .{ .place = p }) == null;
                const v = try f.placeVar(p, length);
                if (made) out = try f.atEntry(out, v, p, length);
                const t = try f.tempAt(out, node, 3, @intCast(k * 2 + part));
                out = try f.equal(t[0], t[1], try single(f.a, v));
                entries[k].before[part] = try single(f.a, t[1]);
            }
        }
        // The fields the callee may write: those its summary names, or any.
        if (!try Range.inert(f.c, f.file, node)) {
            if (summary) |callee| if (callee.written) |fields| {
                for (fields) |written| out = try f.wrote(out, written, null);
            } else {
                out = try f.wrote(out, null, null);
            } else out = try f.wrote(out, null, null);
        }
        const made = try f.fresh(out, node, 0);
        out = made.s;
        const t = made.v.lin;
        const tl = try f.variable(.{ .temp = .{ .node = node, .part = 1 } });
        out = try forget(f.a, out, tl);
        const summed = summary orelse return .{ .s = try f.lengthGiven(out, node, args.items, tl), .v = .{ .lin = t, .length = try single(f.a, tl) } };
        // A std callee's length, as with no summary: from its declaration.
        if (!summed.own) out = try f.lengthGiven(out, node, args.items, tl);
        // A place's exit holds where the success is read at once: a callee that cannot fail, or
        // `try`; a result unwrapped later may meet a store to the place first.
        const at_once = !summed.fails or if (f.model.parentOf(node)) |parent| f.tree.nodeTag(parent) == .@"try" else false;
        const rows = try f.appliedRows(summed.rows, summed.params, args.items, &entries, .{ .result = .{ t, try single(f.a, tl) }, .exits = at_once });
        // Each exit apart, read over the call's slots as the join is.
        const exits = try f.a.alloc([]const Lin, summed.exits.len);
        for (summed.exits, exits) |each, *applied| applied.* = try f.appliedRows(each, summed.params, args.items, &entries, .{ .result = .{ t, try single(f.a, tl) }, .exits = at_once });
        // Where it fails: what the call gave, never a result or what it leaves in a place.
        const failed: []const Lin = if (summed.fails) try f.appliedRows(summed.failing, summed.params, args.items, &entries, .{}) else &.{};
        const value: Value = .{ .lin = t, .length = try single(f.a, tl), .unwrapped = rows, .exits = exits, .failed = failed };
        if (summed.fails) return .{ .s = out, .v = value };
        // A callee that cannot fail returns where it succeeds.
        return .{ .s = try f.unwrap(out, value), .v = .{ .lin = t, .length = value.length } };
    }

    /// A place a call's summary reads, where an operand holds it, and what it held before.
    const Given = struct { place: ?Place = null, before: [2]?Lin = .{ null, null } };

    /// What a call's slots stand for in its caller, past its parameters: its result's value and
    /// length, and whether a place's exit is read (where the success is read at once).
    const Applied = struct { result: ?struct { ?Lin, ?Lin } = null, exits: bool = false };

    /// A summary's `rows` over a call's slots, read in the caller: each parameter's slot as
    /// what the call gave it (`args`), a place's entry as what it held before (`entries`),
    /// the result's and a place's exit as `applied` gives them. A row naming a slot with
    /// nothing for it is dropped.
    fn appliedRows(f: *Frame, rows: []const Lin, params: usize, args: []const Value, entries: []const Given, applied: Applied) Error![]const Lin {
        var out: std.ArrayList(Lin) = .empty;
        each: for (rows) |row| {
            var made: Lin = constant(row.c);
            for (row.terms) |term| {
                const param = term.v / 2;
                const length = term.v % 2 == 1;
                const given: ?Lin = if (param == params)
                    (if (applied.result) |result| (if (length) result[1] else result[0]) else null)
                else if (param < params)
                    (if (param < args.len) (if (length) args[param].length else args[param].lin) else null)
                else at: {
                    const width = std.math.cast(u16, params) orelse break :at null;
                    const offset = std.math.sub(Var, term.v, placeSlot(width, 0, false, false)) catch break :at null;
                    const k = offset / 4;
                    if (k >= entries.len) break :at null;
                    if (offset % 4 < 2) break :at entries[k].before[@intFromBool(length)];
                    if (!applied.exits) break :at null;
                    const p = entries[k].place orelse break :at null;
                    break :at try single(f.a, try f.placeVar(p, length));
                };
                const lin = given orelse continue :each;
                made = (try combine(f.a, made, 1, lin, term.k)) orelse continue :each;
            }
            try out.append(f.a, made);
        }
        return out.items;
    }

    /// `value`, where it reads a place, or with `later` any variable, held in the call's own
    /// temporaries for its `ordinal`th operand (the receiver's first, `2 * ordinal` and the
    /// next): the callee may store into the place, and what its summary says is of the value it
    /// was given; a later operand may assign a variable it reads (`get(i, blk: { i = 3; … })`),
    /// and Zig passes the value it read.
    fn heldAtCall(f: *Frame, s: State, node: Ast.Node.Index, ordinal: u32, value: *Value, later: bool) Error!State {
        var out = s;
        inline for (.{ "lin", "length" }, 0..) |part_name, k| if (@field(value, part_name)) |lin| if (f.readsPlace(lin) or (later and lin.terms.len != 0)) {
            const t = try f.tempAt(out, node, 2, ordinal * 2 + @as(u32, k));
            out = try f.equal(t[0], t[1], lin);
            @field(value, part_name) = try single(f.a, t[1]);
        };
        return out;
    }

    /// `e`'s value held in `node`'s own temporaries where `later`, evaluated after it, may
    /// assign a variable it reads (`i + blk: { i = 0; break :blk 0; }`): Zig takes each operand's
    /// value where it reads it.
    fn heldPast(f: *Frame, e: Eval, node: Ast.Node.Index, later: Ast.Node.Index) Error!Eval {
        if (!f.assigns(later)) return e;
        var out = e;
        inline for (.{ "lin", "length" }, 0..) |part_name, k| if (@field(e.v, part_name)) |lin| if (lin.terms.len != 0) {
            const t = try f.temp(out.s, node, held_part + k);
            out.s = try f.equal(t[0], t[1], lin);
            @field(out.v, part_name) = try single(f.a, t[1]);
        };
        return out;
    }

    /// Whether any of `nodes` may assign a variable: holds an assignment's operator.
    fn assignsAny(f: *Frame, nodes: []const Ast.Node.Index) bool {
        for (nodes) |node| if (f.assigns(node)) return true;
        return false;
    }

    /// Whether `node` may assign a variable: an assignment's operator among its tokens (a
    /// declaration's or a literal's `=` among them, read the same).
    fn assigns(f: *Frame, node: Ast.Node.Index) bool {
        const tree = f.tree;
        var token = tree.firstToken(node);
        while (token <= tree.lastToken(node)) : (token += 1) switch (tree.tokenTag(token)) {
            .equal, .plus_equal, .minus_equal, .asterisk_equal, .slash_equal, .percent_equal, .ampersand_equal, .pipe_equal, .caret_equal, .angle_bracket_angle_bracket_left_equal, .angle_bracket_angle_bracket_left_pipe_equal, .angle_bracket_angle_bracket_right_equal, .plus_percent_equal, .minus_percent_equal, .asterisk_percent_equal, .plus_pipe_equal, .minus_pipe_equal, .asterisk_pipe_equal => return true,
            else => {},
        };
        return false;
    }

    fn readsPlace(f: *Frame, lin: Lin) bool {
        for (lin.terms) |term| if (f.places.contains(term.v)) return true;
        return false;
    }

    /// The summary of the one function of the program a call reaches, at this pointer width.
    fn summaryOf(f: *Frame, node: Ast.Node.Index, callee: Ast.Node.Index) Error!?struct { rows: []const Lin, exits: []const []const Lin, failing: []const Lin, params: usize, places: []const SlotPlace, written: ?[]const Facts.Decl, fails: bool, own: bool } {
        const decl = switch (try f.c.facts.resolve(f.file, callee)) {
            .function => |d| d,
            .alternatives => return null,
            else => return null,
        };
        // std's functions are read only where the program calls them, and give only their
        // failing exits: what they succeed with and write stays unknown.
        const own = try Program.owns(f.c, decl.file);
        if (!own and !try Program.owns(f.c, f.file)) return null;
        const callee_tree = &f.c.project.at(decl.file).file.tree;
        const callee_model = &f.c.project.at(decl.file).model;
        const proto = callee_model.declarations[@backingInt(decl.index)].node;
        const function = callee_model.parentOf(proto) orelse return null;
        if (callee_tree.nodeTag(function) != .fn_decl) return null;
        var proto_buffer: [1]Ast.Node.Index = undefined;
        const full = callee_tree.fullFnProto(&proto_buffer, proto) orelse return null;
        // A generic std function is read at this call's binding, its parameters typed by what
        // the call gives (`divCeil(usize, n, d)` reads `d` as a usize).
        const bound: ?*const Facts.Env = if (!generic(callee_tree, full)) null else bound: {
            const made = (try Facts.calls.at(f.c.facts, f.file, node)) orelse return null;
            break :bound switch (try f.c.facts.bindCall(&made, decl, f.bound)) {
                .reading => |reading| reading,
                .unknown => return null,
            };
        };
        const read = try analysisIn(f.c, bound, decl.file, function, f.width);
        if (!read.supported) return null;
        const summary = read.summary orelse return null;
        const result = full.ast.return_type.unwrap() orelse return null;
        const fails = formAt(callee_tree, result) == .error_union or
            (callee_tree.firstToken(result) > 0 and callee_tree.tokenTag(callee_tree.firstToken(result) - 1) == .bang) or
            try mayFail(f.c, decl.file, result);
        if (!own) return .{ .rows = &.{}, .exits = &.{}, .failing = summary.failing, .params = summary.params, .places = &.{}, .written = null, .fails = fails, .own = false };
        return .{ .rows = summary.rows, .exits = summary.exits, .failing = summary.failing, .params = summary.params, .places = summary.places, .written = summary.written, .fails = fails, .own = true };
    }

    /// Whether a result type named rather than written in place (`R`, `Result(u64)`) may be an
    /// error union: it resolves to one, to a choice among types one of which is, or to nothing
    /// known.
    /// Whether a function is generic: a parameter it takes at compile time or of any type.
    fn generic(tree: *const Ast, proto: Ast.full.FnProto) bool {
        var it = proto.iterate(tree);
        while (it.next()) |param| {
            if (param.anytype_ellipsis3 != null) return true;
            if (param.comptime_noalias) |token| if (tree.tokenTag(token) == .keyword_comptime) return true;
        }
        return false;
    }

    fn mayFail(c: *Context, file: Project.FileId, node: Ast.Node.Index) Error!bool {
        return switch (try c.facts.resolve(file, node)) {
            .error_union, .unknown => true,
            .alternatives => |each| for (each) |one| {
                if (one == .error_union) break true;
            } else false,
            else => false,
        };
    }
};

/// What indexing memory checks, by its type: a slice or an array, a position below its length;
/// one with a sentinel, at most its length (the sentinel is read there); a many-item or C
/// pointer, nothing, and it has no length. Memory whose type is not read checks nothing known.
const Memory = enum { checked, sentinel, unchecked, unknown };

/// A type expression in its file.
const TypeRef = struct { file: Project.FileId, node: Ast.Node.Index };

const type_depth = 16;

/// What indexing `node` checks (`Memory`), read from the expression's own form or its type.
fn memoryKind(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Error!Memory {
    if (depth > type_depth) return .unknown;
    const tree = &c.project.at(file).file.tree;
    switch (formAt(tree, node)) {
        .leaf => if (try c.facts.literalOf(file, node)) |written| if (written == .string) return .sentinel,
        // A literal is memory of the type it names (`[_:0]u8{…}` has a sentinel); one that names
        // none (`.{…}`) is a tuple's, which has none.
        .array_literal => {
            var buffer: [2]Ast.Node.Index = undefined;
            const literal = tree.fullArrayInit(&buffer, node).?; // unreachable: an array literal's form holds them
            return typeKind(c, .{ .file = file, .node = literal.ast.type_expr.unwrap() orelse return .checked }, depth + 1);
        },
        .grouped => return memoryKind(c, file, tree.nodeData(node).node_and_token[0], depth + 1),
        .tried, .@"comptime", .@"nosuspend", .address_of => return memoryKind(c, file, tree.nodeData(node).node, depth + 1),
        .slice => {
            const full = tree.fullSlice(node).?; // unreachable: a slice's form holds them
            if (full.ast.sentinel != .none) return .sentinel;
            // A many-item pointer sliced with no end is one still.
            if (full.ast.end == .none) return memoryKind(c, file, full.ast.sliced, depth + 1);
            return .checked;
        },
        .member => if (try c.facts.languageField(file, node) == .ptr) return .unchecked,
        // A local with no type written is what it is made from (`const s = buf[0..n];`).
        else => {},
    }
    if (spellsName(tree, node)) {
        if (nameRef(&c.project.at(file).model, node)) |ref| if (ref.declaration) |d| {
            const decl = c.project.at(file).model.declarations[@backingInt(d)];
            if (decl.kind == .variable) if (tree.fullVarDecl(decl.node)) |full| if (full.ast.type_node == .none) {
                return memoryKind(c, file, full.ast.init_node.unwrap() orelse return .unknown, depth + 1);
            };
        };
    }
    const t = (try exprType(c, file, node, depth + 1)) orelse return .unknown;
    return typeKind(c, t, depth + 1);
}

/// The type an expression is declared with: a name's (its declaration's type, or its
/// initializer's), a field's, a call's result, an element's, a payload's; null where none is
/// written.
fn exprType(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Error!?TypeRef {
    if (depth > type_depth) return null;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    switch (formAt(tree, node)) {
        .grouped => return exprType(c, file, tree.nodeData(node).node_and_token[0], depth + 1),
        .tried, .@"comptime", .@"nosuspend" => return exprType(c, file, tree.nodeData(node).node, depth + 1),
        .unwrap_optional => return payloadOf(c, (try exprType(c, file, tree.nodeData(node).node_and_token[0], depth + 1)) orelse return null, depth + 1),
        .@"orelse", .@"catch" => return payloadOf(c, (try exprType(c, file, tree.nodeData(node).node_and_node[0], depth + 1)) orelse return null, depth + 1),
        .deref => {
            const pointer = (try exprType(c, file, tree.nodeData(node).node, depth + 1)) orelse return null;
            const pointer_tree = &c.project.at(pointer.file).file.tree;
            const full = pointer_tree.fullPtrType(pointer.node) orelse return null;
            return if (full.size == .one) .{ .file = pointer.file, .node = full.ast.child_type } else null;
        },
        .array_access => return elementType(c, (try exprType(c, file, tree.nodeData(node).node_and_node[0], depth + 1)) orelse return null, depth + 1),
        .leaf => {
            const d = (nameRef(model, node) orelse return null).declaration orelse return null;
            const decl = model.declarations[@backingInt(d)];
            switch (decl.kind) {
                .variable => {
                    const full = tree.fullVarDecl(decl.node) orelse return null;
                    if (full.ast.type_node.unwrap()) |t| return .{ .file = file, .node = t };
                    return exprType(c, file, full.ast.init_node.unwrap() orelse return null, depth + 1);
                },
                // A parameter's declaration node is its type expression.
                .parameter => return if (tree.nodeTag(decl.node) == .fn_proto or tree.nodeTag(decl.node) == .fn_proto_one or tree.nodeTag(decl.node) == .fn_proto_multi or tree.nodeTag(decl.node) == .fn_proto_simple) null else .{ .file = file, .node = decl.node },
                .capture => {
                    const loop = tree.fullFor(decl.node) orelse return null;
                    const position = Model.capturePosition(tree, loop, decl.token) orelse return null;
                    if (position >= loop.ast.inputs.len) return null;
                    const input = loop.ast.inputs[position];
                    if (tree.nodeTag(input) == .for_range) return null;
                    return elementType(c, (try exprType(c, file, input, depth + 1)) orelse return null, depth + 1);
                },
                else => return null,
            }
        },
        .member => {
            const decl = ((try c.facts.definition(file, node)).orNull()) orelse return null;
            const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
            const field = c.project.at(decl.file).model.containerField(&c.project.at(decl.file).file.tree, record.node) orelse return null;
            return .{ .file = decl.file, .node = field.ast.type_expr.unwrap() orelse return null };
        },
        .call => {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, node).?; // unreachable: a call's form holds calls
            const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
                .function => |d| d,
                .alternatives => return null,
                else => return null,
            };
            const callee_tree = &c.project.at(decl.file).file.tree;
            var proto_buffer: [1]Ast.Node.Index = undefined;
            const proto = callee_tree.fullFnProto(&proto_buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return null;
            return .{ .file = decl.file, .node = proto.ast.return_type.unwrap() orelse return null };
        },
        .builtin => {
            if (!Facts.isBuiltin(tree, node, "@as")) return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            return if (args.len == 2) .{ .file = file, .node = args[0] } else null;
        },
        else => return null,
    }
}

/// Whether a value of the written type `t` is never null: an integer type, `bool`, a pointer
/// that is not optional, a container, or an error union whose payload is one of these (as the
/// union or as `try` gives its payload: neither is null; `exprType` reads `try x` as `x`'s
/// type). An optional, a name that does not resolve to one of these (an alias may be an
/// optional) and anything else may be null.
fn typeNeverNull(c: *Context, t: TypeRef, width: u16, depth: u8) Error!bool {
    if (depth > type_depth) return false;
    const tree = &c.project.at(t.file).file.tree;
    switch (formAt(tree, t.node)) {
        .grouped => return typeNeverNull(c, .{ .file = t.file, .node = tree.nodeData(t.node).node_and_token[0] }, width, depth + 1),
        .error_union => return typeNeverNull(c, .{ .file = t.file, .node = tree.nodeData(t.node).node_and_node[1] }, width, depth + 1),
        .optional_type => return false,
        else => {},
    }
    if (tree.fullPtrType(t.node) != null) return true;
    if (Facts.accesses.formOf(tree.nodeTag(t.node)) == .body) return true;
    if (try Range.intNamed(c, t.file, t.node, width) != null) return true;
    const value = try c.facts.resolve(t.file, t.node);
    return value == .primitive and std.mem.eql(u8, value.primitive, "bool");
}

/// What indexing memory of type `t` checks.
fn typeKind(c: *Context, t: TypeRef, depth: u8) Error!Memory {
    if (depth > type_depth) return .unknown;
    const tree = &c.project.at(t.file).file.tree;
    if (tree.fullPtrType(t.node)) |pointer| return switch (pointer.size) {
        .many, .c => .unchecked,
        .slice => if (pointer.ast.sentinel != .none) .sentinel else .checked,
        // A pointer to an array indexes as the array.
        .one => if (tree.fullArrayType(pointer.ast.child_type)) |array| (if (array.ast.sentinel != .none) .sentinel else .checked) else .unknown,
    };
    if (tree.fullArrayType(t.node)) |array| return if (array.ast.sentinel != .none) .sentinel else .checked;
    switch (formAt(tree, t.node)) {
        .optional_type => return typeKind(c, .{ .file = t.file, .node = tree.nodeData(t.node).node }, depth + 1),
        .error_union => return typeKind(c, .{ .file = t.file, .node = tree.nodeData(t.node).node_and_node[1] }, depth + 1),
        .grouped => return typeKind(c, .{ .file = t.file, .node = tree.nodeData(t.node).node_and_token[0] }, depth + 1),
        .leaf, .member => return typeKind(c, (try aliased(c, t)) orelse return .unknown, depth + 1),
        else => return .unknown,
    }
}

/// The element type of memory of type `t`.
fn elementType(c: *Context, t: TypeRef, depth: u8) Error!?TypeRef {
    if (depth > type_depth) return null;
    const tree = &c.project.at(t.file).file.tree;
    if (tree.fullPtrType(t.node)) |pointer| {
        if (pointer.size != .one) return .{ .file = t.file, .node = pointer.ast.child_type };
        const array = tree.fullArrayType(pointer.ast.child_type) orelse return null;
        return .{ .file = t.file, .node = array.ast.elem_type };
    }
    if (tree.fullArrayType(t.node)) |array| return .{ .file = t.file, .node = array.ast.elem_type };
    return switch (formAt(tree, t.node)) {
        .leaf, .member => elementType(c, (try aliased(c, t)) orelse return null, depth + 1),
        else => null,
    };
}

/// What an optional or error union of type `t` holds; `t` where it is neither.
fn payloadOf(c: *Context, t: TypeRef, depth: u8) Error!?TypeRef {
    if (depth > type_depth) return null;
    const tree = &c.project.at(t.file).file.tree;
    return switch (formAt(tree, t.node)) {
        .optional_type => .{ .file = t.file, .node = tree.nodeData(t.node).node },
        .error_union => .{ .file = t.file, .node = tree.nodeData(t.node).node_and_node[1] },
        .leaf, .member => payloadOf(c, (try aliased(c, t)) orelse return null, depth + 1),
        else => t,
    };
}

/// The type a name for a type stands for (`const Bytes = []const u8;`).
fn aliased(c: *Context, t: TypeRef) Error!?TypeRef {
    const decl = ((try c.facts.definition(t.file, t.node)).orNull()) orelse return null;
    const declared = ((try c.facts.origin(decl)).orNull()) orelse decl;
    const tree = &c.project.at(declared.file).file.tree;
    const full = tree.fullVarDecl(c.project.at(declared.file).model.declarations[@backingInt(declared.index)].node) orelse return null;
    return .{ .file = declared.file, .node = full.ast.init_node.unwrap() orelse return null };
}

/// The most entries `memory` holds where it is one of the tables std names by a u32 index (an
/// `Ast`'s `nodes` or `tokens`), or a field's view of one (`t.nodes.items(.tag)`). std makes
/// each node's index with `@intCast(p.nodes.len)` (zig/Parse.zig:78, `addNode`; a reserved
/// node's index is cast where it is set) and each token's start with `@intCast` of its offset
/// (zig/Ast.zig:162), so a table past `maxInt(u32) + 1` entries is never made.
fn table(c: *Context, file: Project.FileId, memory: Ast.Node.Index) Error!?Coef {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const tree = &c.project.at(file).file.tree;
    var node = memory;
    var buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&buffer, node)) |call| {
        if (formAt(tree, call.ast.fn_expr) != .member) return null;
        const holder = tree.nodeData(call.ast.fn_expr).node_and_token[0];
        // The holder's own `items` (a MultiArrayList's), by the declaration its type gives the name.
        const callee = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
            .function => |function| function,
            .alternatives => return null,
            else => return null,
        };
        var held = try c.facts.resolve(file, holder);
        while (held == .pointer) held = held.pointer.child.*;
        const container = switch (held) {
            .instance, .container => |k| k,
            .alternatives => return null,
            else => return null,
        };
        const items = c.facts.member(container, "items") orelse return null;
        if (!std.meta.eql(items, callee)) return null;
        node = holder;
    }
    if (formAt(tree, node) != .member) return null;
    const decl = ((try c.facts.definition(file, node)).orNull()) orelse return null;
    const tables = try c.facts.memo(Tables);
    if (!tables.found) {
        tables.found = true;
        for (((try Governed.declarations(c, "std", "zig.Ast")).orNull()) orelse &.{}) |ast| {
            const value = try c.facts.declaration(((try c.facts.origin(ast)).orNull()) orelse ast);
            if (value != .container) continue;
            for ([_][]const u8{ "nodes", "tokens" }) |name| if (c.facts.member(value.container, name)) |field| {
                try tables.fields.append(c.allocator, field);
            };
        }
    }
    const field = ((try c.facts.origin(decl)).orNull()) orelse decl;
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
