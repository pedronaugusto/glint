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
const Records = @import("Summary.zig");
const Model = @import("Model.zig");
const Range = @import("Range.zig");
const accesses = Facts.accesses;
const formAt = Range.formAt;
const nameRef = Range.nameRef;
const spellsName = Range.spellsName;
const discards = Range.discards;
const Project = @import("Project.zig");
const Governed = @import("Governed.zig");
const Contract = @import("AegisContract.zig");
const Program = @import("Program.zig");
const FactSpec = @import("FactSpec.zig");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

pub const Level = FactSpec.Level;
pub const Spec = FactSpec.Spec;

/// What an expression holds, read inside one function: a level of its own, and the
/// parameters it depends on: fully; made a number (a parameter's data shifted or multiplied);
/// kept to a range the program chose (a parameter's number masked or truncated: data); or,
/// through a call that did not resolve, at most as unknown. Each level is per fact (`Levels`);
/// the parameters it depends on are the same for every fact.
///
/// What a condition decides (`ruling`) holds only for the facts that take what they decide
/// (`Spec.control`): its level is those lanes', and the parameters it reads are `ruled`.
///
/// Memory also has a length, which is not what it holds: `out[0..n]` holds the program's
/// bytes in a length the peer chose. `length` and `lengths` are that length's level and the
/// slots it depends on (`lengthSlot`): a parameter's value as a bound, or a parameter's own
/// length. What the memory holds stays the program's; its `.len` is the peer's.
pub const Dep = struct {
    level: Levels = .clean,
    params: Slots = .{},
    numbers: Slots = .{},
    ranged: Slots = .{},
    maybe: Slots = .{},
    ruled: Slots = .{},
    length: Levels = .clean,
    lengths: Slots = .{},
    /// The parameters a condition reads that decides the length (`ruled`'s, for the length).
    ruled_lengths: Slots = .{},
    /// The parameters that decide how many passes a loop steps this value by a sum (`total +=
    /// 1`), for the facts control takes: as far as the callers give them where the loop counts
    /// against them (`counted`), a number where nothing counts its passes (`counted_numbers`).
    counted: Slots = .{},
    counted_numbers: Slots = .{},
    /// A length no build holds to the memory: written in place (`s.len = n`), or one a
    /// measure already gave (a global's, a parameter's own); its level, and the parameters
    /// whose value it was written from, as the callers give them.
    unchecked: Levels = .clean,
    bare: Slots = .{},
    /// The parameters whose number it was written from (`s.len = n`, `n` made a number of a
    /// parameter's data), as the callers give them, a number in each fact's lane where they give
    /// data (`concrete`'s `numbers`).
    bare_numbers: Slots = .{},
    /// The lanes it may carry: a value whose type may hold no writer reaching a peer carries
    /// none in the peer writer's lane, from its own level or its parameters' (`within`).
    lanes: Mask = all_lanes,
    /// The lanes it holds only as unknown: a value kept in a place whose type may hold a writer
    /// only through what does not resolve is no writer shown (`Gate.capped`).
    capped: Mask = none,

    /// The same value, its slots' tails on `gpa`: what a solve round keeps past the round.
    fn kept(a: Dep, gpa: Allocator) Allocator.Error!Dep {
        return .{ .level = a.level, .lanes = a.lanes, .capped = a.capped, .params = try a.params.kept(gpa), .numbers = try a.numbers.kept(gpa), .ranged = try a.ranged.kept(gpa), .maybe = try a.maybe.kept(gpa), .ruled = try a.ruled.kept(gpa), .length = a.length, .lengths = try a.lengths.kept(gpa), .ruled_lengths = try a.ruled_lengths.kept(gpa), .counted = try a.counted.kept(gpa), .counted_numbers = try a.counted_numbers.kept(gpa), .unchecked = a.unchecked, .bare = try a.bare.kept(gpa), .bare_numbers = try a.bare_numbers.kept(gpa) };
    }

    pub fn join(a: Dep, gpa: Allocator, b: Dep) Allocator.Error!Dep {
        return .{ .level = a.level.join(b.level), .lanes = a.lanes | b.lanes, .capped = a.capped & b.capped, .params = try a.params.unite(gpa, b.params), .numbers = try a.numbers.unite(gpa, b.numbers), .ranged = try a.ranged.unite(gpa, b.ranged), .maybe = try a.maybe.unite(gpa, b.maybe), .ruled = try a.ruled.unite(gpa, b.ruled), .length = a.length.join(b.length), .lengths = try a.lengths.unite(gpa, b.lengths), .ruled_lengths = try a.ruled_lengths.unite(gpa, b.ruled_lengths), .counted = try a.counted.unite(gpa, b.counted), .counted_numbers = try a.counted_numbers.unite(gpa, b.counted_numbers), .unchecked = a.unchecked.join(b.unchecked), .bare = try a.bare.unite(gpa, b.bare), .bare_numbers = try a.bare_numbers.unite(gpa, b.bare_numbers) };
    }
    fn lowered(a: Dep, gpa: Allocator) Allocator.Error!Dep {
        return .{ .level = a.level.lowered(), .lanes = a.lanes, .capped = a.capped, .maybe = try Slots.all(gpa, &.{ a.params, a.numbers, a.ranged, a.maybe }), .ruled = a.ruled, .counted = a.counted, .counted_numbers = a.counted_numbers, .length = a.length, .lengths = a.lengths, .ruled_lengths = a.ruled_lengths, .unchecked = a.unchecked, .bare = a.bare, .bare_numbers = a.bare_numbers };
    }
    /// Data made a number: a shift or a product of it, or what std decodes from it.
    fn widened(a: Dep, gpa: Allocator) Allocator.Error!Dep {
        return .{ .level = a.level.widened(), .lanes = a.lanes, .capped = a.capped, .params = a.params, .numbers = try Slots.all(gpa, &.{ a.numbers, a.params, a.ranged }), .maybe = a.maybe, .ruled = a.ruled, .counted_numbers = try a.counted.unite(gpa, a.counted_numbers), .length = a.length, .lengths = a.lengths, .ruled_lengths = a.ruled_lengths, .unchecked = a.unchecked, .bare = a.bare, .bare_numbers = a.bare_numbers };
    }
    /// A value kept to a range the program chose: a number is data there.
    fn narrowed(a: Dep, gpa: Allocator) Allocator.Error!Dep {
        return .{ .level = a.level.narrowed(), .lanes = a.lanes, .capped = a.capped, .ranged = try Slots.all(gpa, &.{ a.params, a.numbers, a.ranged }), .maybe = a.maybe, .ruled = try Slots.all(gpa, &.{ a.ruled, a.counted, a.counted_numbers }), .length = a.length, .lengths = a.lengths, .ruled_lengths = a.ruled_lengths, .unchecked = a.unchecked, .bare = a.bare, .bare_numbers = a.bare_numbers };
    }
    /// What a condition reading this value decides: data held to the choice, for the facts
    /// that take what they decide (`Masks.control`); for the others nothing.
    fn ruling(a: Dep, gpa: Allocator, masks: Masks) Allocator.Error!Dep {
        return .{ .level = a.level.narrowed().masked(masks.control), .lanes = a.lanes, .capped = a.capped, .ruled = try Slots.all(gpa, &.{ a.params, a.numbers, a.ranged, a.maybe, a.ruled, a.counted, a.counted_numbers }) };
    }
    /// What a loop whose passes this value decides counts into a sum each pass steps (`total
    /// += 1`), where the loop counts against it (a `for`'s range or input, a `while` comparing a
    /// counter it steps by a sum): as far as the value goes, for the facts control takes.
    fn counting(a: Dep, gpa: Allocator, masks: Masks) Allocator.Error!Dep {
        return .{ .level = a.level.masked(masks.control), .lanes = a.lanes, .capped = a.capped, .counted = try a.params.unite(gpa, a.counted), .counted_numbers = try a.numbers.unite(gpa, a.counted_numbers), .ruled = try Slots.all(gpa, &.{ a.ranged, a.maybe, a.ruled }) };
    }
    /// The same where nothing counts the loop's passes (a `while` on what it reads, a labeled
    /// switch): each pass steps the sum again as long as the value says, so a number.
    fn unbounded(a: Dep, gpa: Allocator, masks: Masks) Allocator.Error!Dep {
        return .{ .level = a.level.widened().masked(masks.control), .lanes = a.lanes, .capped = a.capped, .counted_numbers = try Slots.all(gpa, &.{ a.params, a.numbers, a.ranged, a.maybe, a.ruled, a.counted, a.counted_numbers }) };
    }
    /// Its length read as a value (`.len`): within the memory, so data at most, unless no
    /// build holds it there (`unchecked`). A parameter's own length (its `lengthSlot`) is
    /// what its callers measured; a parameter's value bounding a slice is data.
    fn measured(a: Dep) Dep {
        return .{ .level = a.length.narrowed().join(a.unchecked), .lanes = a.lanes, .capped = a.capped, .params = a.bare, .numbers = a.bare_numbers, .ranged = a.lengths, .ruled = a.ruled_lengths };
    }
    /// Memory whose length is this value written in place (`s.len = n`), which no build
    /// checks against the memory: the value's level, and a parameter's as its callers give it,
    /// a number in each fact's lane where it was made one (`bare_numbers`).
    fn written(a: Dep, gpa: Allocator) Allocator.Error!Dep {
        return .{ .unchecked = a.level, .lanes = a.lanes, .capped = a.capped, .bare = try a.params.unite(gpa, a.counted), .bare_numbers = try a.numbers.unite(gpa, a.counted_numbers), .lengths = try a.ranged.unite(gpa, a.maybe), .ruled_lengths = a.ruled };
    }
    /// Memory whose length a measure gave (`concreteLength`), read back.
    fn measuredLength(level: Levels) Dep {
        return .{ .unchecked = level };
    }
    /// Memory whose length is this value (a slice's bound): data at most.
    fn sizing(a: Dep, gpa: Allocator) Allocator.Error!Dep {
        return .{ .length = a.level.narrowed(), .lanes = a.lanes, .capped = a.capped, .lengths = try Slots.all(gpa, &.{ a.params, a.numbers, a.ranged, a.maybe }), .ruled_lengths = try Slots.all(gpa, &.{ a.ruled, a.counted, a.counted_numbers }) };
    }
    /// What it holds, with no length.
    fn held(a: Dep) Dep {
        return .{ .level = a.level, .lanes = a.lanes, .capped = a.capped, .params = a.params, .numbers = a.numbers, .ranged = a.ranged, .maybe = a.maybe, .ruled = a.ruled, .counted = a.counted, .counted_numbers = a.counted_numbers };
    }
    /// Its length alone: what a slice to the end of this memory keeps of it.
    fn lengthOnly(a: Dep) Dep {
        return .{ .length = a.length, .lanes = a.lanes, .capped = a.capped, .lengths = a.lengths, .ruled_lengths = a.ruled_lengths, .unchecked = a.unchecked, .bare = a.bare, .bare_numbers = a.bare_numbers };
    }
    /// Whether it takes nothing: no level of its own and no parameter.
    pub fn clean(a: Dep) bool {
        return a.level.isClean() and a.params.empty() and a.numbers.empty() and a.ranged.empty() and a.maybe.empty() and a.ruled.empty() and a.length.isClean() and a.lengths.empty() and a.ruled_lengths.empty() and a.counted.empty() and a.counted_numbers.empty() and a.unchecked.isClean() and a.bare.empty() and a.bare_numbers.empty();
    }
    /// The same, as a place keeps it by its type (`placeGate`): only the lanes the gate carries,
    /// those it caps unknown.
    fn within(a: Dep, gate: Gate) Dep {
        var out = a;
        out.level = a.level.gated(gate);
        out.length = a.length.gated(gate);
        out.unchecked = a.unchecked.gated(gate);
        out.lanes = a.lanes & gate.lanes;
        out.capped = a.capped | gate.capped;
        return out;
    }
    fn eql(a: Dep, b: Dep) bool {
        return a.lanes == b.lanes and a.capped == b.capped and a.level.eql(b.level) and a.params.eql(b.params) and a.numbers.eql(b.numbers) and a.ranged.eql(b.ranged) and a.maybe.eql(b.maybe) and a.ruled.eql(b.ruled) and a.length.eql(b.length) and a.lengths.eql(b.lengths) and a.ruled_lengths.eql(b.ruled_lengths) and a.counted.eql(b.counted) and a.counted_numbers.eql(b.counted_numbers) and a.unchecked.eql(b.unchecked) and a.bare.eql(b.bare) and a.bare_numbers.eql(b.bare_numbers);
    }
};

/// A set of a function's slots (`valueSlot`, `lengthSlot`), or of its parameters by position,
/// as wide as the function: the first 64 in a word, the rest in a tail only a function of more
/// than 32 parameters makes. A union keeps a side's tail where it holds the other's, so the
/// fixpoint, which unites what it already holds, makes none.
const Slots = struct {
    word: u64 = 0,
    tail: []const u64 = &.{},

    fn of(gpa: Allocator, slot: usize) Allocator.Error!Slots {
        if (slot < 64) return .{ .word = @as(u64, 1) << @intCast(slot) };
        const at = (slot - 64) / 64;
        const tail = try gpa.alloc(u64, at + 1);
        @memset(tail, 0);
        tail[at] = @as(u64, 1) << @intCast((slot - 64) % 64);
        return .{ .tail = tail };
    }

    fn with(s: Slots, gpa: Allocator, slot: usize) Allocator.Error!Slots {
        return s.unite(gpa, try .of(gpa, slot));
    }

    fn has(s: Slots, slot: usize) bool {
        if (slot < 64) return s.word & (@as(u64, 1) << @intCast(slot)) != 0;
        const at = (slot - 64) / 64;
        return at < s.tail.len and s.tail[at] & (@as(u64, 1) << @intCast((slot - 64) % 64)) != 0;
    }

    fn empty(s: Slots) bool {
        return s.word == 0 and within(s.tail, &.{});
    }

    /// Whether every slot of `s` is in `t`.
    fn subset(s: Slots, t: Slots) bool {
        return (s.word & ~t.word) == 0 and within(s.tail, t.tail);
    }

    fn eql(s: Slots, t: Slots) bool {
        return s.word == t.word and within(s.tail, t.tail) and within(t.tail, s.tail);
    }

    fn unite(s: Slots, gpa: Allocator, t: Slots) Allocator.Error!Slots {
        const word = s.word | t.word;
        if (within(t.tail, s.tail)) return .{ .word = word, .tail = s.tail };
        if (within(s.tail, t.tail)) return .{ .word = word, .tail = t.tail };
        const tail = try gpa.alloc(u64, @max(s.tail.len, t.tail.len));
        for (tail, 0..) |*w, i| w.* = (if (i < s.tail.len) s.tail[i] else 0) | (if (i < t.tail.len) t.tail[i] else 0);
        return .{ .word = word, .tail = tail };
    }

    /// The same set, its tail on `gpa`.
    fn kept(s: Slots, gpa: Allocator) Allocator.Error!Slots {
        return .{ .word = s.word, .tail = if (s.tail.len == 0) &.{} else try gpa.dupe(u64, s.tail) };
    }

    fn all(gpa: Allocator, sets: []const Slots) Allocator.Error!Slots {
        var out: Slots = .{};
        for (sets) |each| out = try out.unite(gpa, each);
        return out;
    }

    /// Whether every slot of the tail `x` is in `y`'s.
    fn within(x: []const u64, y: []const u64) bool {
        for (x, 0..) |w, i| if (w & ~(if (i < y.len) y[i] else 0) != 0) return false;
        return true;
    }
};

/// The slot of a parameter's value among a function's levels and in a dependence's sets.
fn valueSlot(index: usize) usize {
    return 2 * index;
}

/// The slot of a parameter's length: beside its value's.
fn lengthSlot(index: usize) usize {
    return 2 * index + 1;
}

/// How many levels a function of `n` parameters keeps: a value's and a length's for each.
fn slots(n: usize) usize {
    return 2 * n;
}

/// The most facts one run solves together.
pub const lane_count = 8;

/// Lanes, a bit each.
pub const Mask = u8;

const none: Mask = 0;
const all_lanes: Mask = ~none;

fn selected(mask: Mask) @Vector(lane_count, bool) {
    return @bitCast(mask);
}

/// A level per fact: one solve carries every fact the run asks at once, each in its own lane.
pub const Levels = struct {
    v: @Vector(lane_count, u2) = @splat(0),

    pub const clean: Levels = .{};

    pub fn all(level: Level) Levels {
        return .{ .v = @splat(@backingInt(level)) };
    }
    /// `level` in the lanes `mask` holds, clean in the rest.
    pub fn in(mask: Mask, level: Level) Levels {
        return .{ .v = @select(u2, selected(mask), @as(@Vector(lane_count, u2), @splat(@backingInt(level))), Levels.clean.v) };
    }
    pub fn join(a: Levels, b: Levels) Levels {
        return .{ .v = @max(a.v, b.v) };
    }
    pub fn eql(a: Levels, b: Levels) bool {
        return @reduce(.And, a.v == b.v);
    }
    pub fn isClean(a: Levels) bool {
        return a.eql(.clean);
    }
    pub fn at(a: Levels, lane: usize) Level {
        const lanes: [lane_count]u2 = a.v;
        return @fromBackingInt(lanes[lane]);
    }
    /// Its lanes `mask` holds, the rest clean.
    pub fn masked(a: Levels, mask: Mask) Levels {
        return .{ .v = @select(u2, selected(mask), a.v, Levels.clean.v) };
    }
    /// Data made a number.
    fn widened(a: Levels) Levels {
        return a.mapped(.data, .number);
    }
    /// A number kept to a range the program chose: data.
    fn narrowed(a: Levels) Levels {
        return a.mapped(.number, .data);
    }
    /// What it is, read through a call that does not resolve: unknown where it is not clean.
    fn lowered(a: Levels) Levels {
        return .{ .v = @select(u2, a.v != Levels.clean.v, Levels.all(.unknown).v, a.v) };
    }
    /// What a place keeps of it by its type (`Gate`): the lanes it carries, unknown where it
    /// caps them.
    fn gated(a: Levels, gate: Gate) Levels {
        const kept = a.masked(gate.lanes);
        return .{ .v = @select(u2, selected(gate.capped) & (kept.v != Levels.clean.v), Levels.all(.unknown).v, kept.v) };
    }
    fn mapped(a: Levels, from: Level, to: Level) Levels {
        return .{ .v = @select(u2, a.v == Levels.all(from).v, Levels.all(to).v, a.v) };
    }
};

/// The lanes each kind of source, answer and choice reaches, from the run's specs.
const Masks = struct {
    /// Input a peer gives.
    peer: Mask = none,
    /// Input the operator gives.
    operator: Mask = none,
    error_text: Mask = none,
    peer_writer: Mask = none,
    /// The facts what they decide takes (`Spec.control`).
    control: Mask = none,
    /// The facts aegis answers.
    aegis: Mask = none,
    int_from_error: Mask = none,

    fn input(m: Masks) Mask {
        return m.peer | m.operator;
    }
};

/// A fact a rule asks: the run's solve and the fact's lane in it.
pub const Fact = struct {
    flow: *Flow,
    lane: u8,
    spec: Spec,
};

const Function = struct {
    file: Project.FileId,
    node: Ast.Node.Index,
    /// Its parameters' declarations in order, the receiver first; null for an unnamed one.
    params: []const ?Model.Declaration.Id,
    /// The nodes its body holds outside any function nested in it: what each round reads.
    nodes: []const Ast.Node.Index = &.{},
    /// What its callers give each parameter, and the length of each (`lengthSlot`).
    levels: []Levels,
    ret: Dep = .{},
    /// What it stores through each parameter, by position (`out.* = v`, `list.append(gpa, v)`,
    /// `self.part = buf[0..n]` of a field outside the program): a summary as `ret` is, which
    /// each call stores into its argument.
    writes: []Dep,
    /// The parameters it returns a pointer into, by position, and the fields and variables:
    /// what its caller then holds (`resultPlaces`).
    returned: Slots = .{},
    returned_globals: std.ArrayList(Facts.Decl) = .empty,
    /// Its comptime parameters: fixed when the program is compiled, so no input reaches them.
    fixed: Slots = .{},
    /// It is handed to aegis's `Untrusted.parse`: what it returns reaches the program refined
    /// where it shows the value's range.
    parser: bool = false,
    /// What a parse given it gives: the level of the values it returns without showing their
    /// range, which the parse refines nothing of.
    unrefined: Levels = .clean,
    /// In a summary of code outside the program (`Flow.sized`), the slots whose value or
    /// length the body sizes work by; those it sizes by only kept to a range or as a
    /// comparison decides (`a.len` checked, a mask): data at most; and those it may through a
    /// call that does not resolve.
    sizes: Slots = .{},
    ranged_sizes: Slots = .{},
    maybe_sizes: Slots = .{},
    /// In a summary of one instantiation (`instanceSizes`), the readings it is reached with,
    /// each a chain of calls' bindings: what a call on a generic's parameter calls in each
    /// (`instanceCall`). `every_reading`: reached with none, so as every instantiation reads it.
    readings: std.ArrayList(*const Facts.Env) = .empty,
    every_reading: bool = false,
    /// Of a summary of one instantiation (`Flow.shared`): taken whole from the summary of every
    /// instantiation, which read it with no reading of its own, as this one would. Its sizes,
    /// returns and writes are by parameter, the same whoever calls it, so it is not read again
    /// here unless a reading of its own reaches it.
    settled: bool = false,
    /// Of std's open-world summary (`OpenUnit`): first read in a closing whose budget ran out, so
    /// what it sizes by is not known (designs/glint-summaries.md, exhaustion): its record is
    /// unknown, and read as undecided.
    exhausted: bool = false,

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
    /// The facts solved, a lane each, and the lanes each kind of source and answer reaches.
    specs: []const Spec = &.{},
    masks: Masks = .{},
    functions: std.ArrayList(Function) = .empty,
    /// Per file, the functions the flow reads of it (`Owners`).
    owners: std.AutoHashMapUnmanaged(Project.FileId, Owners) = .empty,
    by_node: std.AutoHashMapUnmanaged(Facts.Key, Function.Id) = .empty,
    /// What each call read reaches (`resolveCall`).
    callees: std.AutoHashMapUnmanaged(Facts.Key, Callee) = .empty,
    /// Per file, its jumps (`return`, `try`, `break`, `continue`) in source order: what `leaves`
    /// reads of a statement.
    jumps: std.AutoHashMapUnmanaged(Project.FileId, []const Ast.Node.Index) = .empty,
    locals: std.AutoHashMapUnmanaged(Facts.Decl, Dep) = .empty,
    /// Fields and container-level variables, by declaration.
    globals: std.AutoHashMapUnmanaged(Facts.Decl, Levels) = .empty,
    /// The lengths of the memory they hold, by declaration (`Dep.length`).
    lengths: std.AutoHashMapUnmanaged(Facts.Decl, Levels) = .empty,
    /// Memory no place names (`Place.unknown`: what a pointer made from an integer or a call
    /// that does not resolve reaches): what any store into it puts there, and the length of the
    /// memory it holds. A read of such memory may read any of it.
    unnamed: Levels = .clean,
    unnamed_length: Levels = .clean,
    /// Per field and container-level variable, whether a store through memory no place names may
    /// reach it (`reachedUnnamed`).
    unnamed_reach: std.AutoHashMapUnmanaged(Facts.Decl, bool) = .empty,
    /// The files the solve holds as its own (`own`), listed once (`reachedUnnamed`).
    own_files: ?[]const Project.FileId = null,
    /// What a function of a file the run does not select may read of input other than through
    /// its parameters (`besideParameters`), found once the solve is done.
    beside: ?Levels = null,
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
    /// The types a writer that reaches a peer may be: std's `Io.Writer`, which every writer of
    /// std's writes through, and what the configuration's peer writers give.
    writer_types: std.ArrayList(Facts.Container) = .empty,
    /// std's writer, or a configured peer writer's result, does not resolve: any type may be one.
    writer_unknown: bool = false,
    /// How a container outside the program holds a writer, once each (`writerHold`).
    writer_holders: std.AutoHashMapUnmanaged(Facts.Container, Hold) = .empty,
    /// What each place a declaration names keeps by its type, once each (`placeGate`).
    place_gates: std.AutoHashMapUnmanaged(Facts.Decl, Gate) = .empty,
    /// Whether a ceiling's limit is being read (`ceilingHeld`): a limit read through a call given
    /// the value it bounds (`if (x > f(x)) return`) reads no ceiling again, so none holds there.
    in_ceiling: bool = false,
    /// Functions whose result is what they read: std's `process.run`, which holds a child's output,
    /// and aegis's whole-file reads, `own.readFile` and `own.readFileSentinel`.
    reads: std.ArrayList(Facts.Decl) = .empty,
    /// Where each pointer the program makes may be kept (`Link`).
    links: std.ArrayList(Link) = .empty,
    /// std's accessors of a Zig tree's text (`zig_text`) and its parser, resolved once.
    zig_text: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty,
    zig_parse: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty,
    /// std's Zig tree's file, and the types of an index into its own tables (`treeValue`).
    zig_ast: ?Project.FileId = null,
    zig_index: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty,
    /// What decides how many passes each loop takes, read once per round (`passes`).
    loops: std.AutoHashMapUnmanaged(Facts.Key, Dep) = .empty,
    /// How each `while` steps its counters (`stepsOf`), read once.
    steps: std.AutoHashMapUnmanaged(Facts.Key, Steps) = .empty,
    /// What decides that each statement jumps past what follows it (`leaves`), read once per
    /// round, by the statement and the declaration a store's target is (none: one outliving
    /// the function).
    leaving: std.AutoHashMapUnmanaged(struct { Facts.Key, ?Ast.TokenIndex }, Dep) = .empty,
    changed: bool = false,
    /// While the solve's rounds run, the round's own memory: what a round reads once per round
    /// (`loops`, `leaving`) and its temporaries, given back when the round ends.
    round: ?Allocator = null,
    /// What the functions outside the program its calls reach size work by (`sizesFlow`): a
    /// flow of its own over them, read for no fact.
    sized: ?*Flow = null,
    /// Of a summary, the functions that read with no limit (`unlimitedRead`), and how many of
    /// its functions were read for it.
    unlimited: std.AutoHashMapUnmanaged(Function.Id, void) = .empty,
    unlimited_read: usize = 0,
    /// The sinks' sites per fact's lane and file (`sinkSites`).
    sink_sites: std.AutoHashMapUnmanaged(struct { u8, Project.FileId }, []const SinkSite) = .empty,
    /// std's allocations: `Allocator.rawAlloc`, `rawResize` and `rawRemap`, each argument but
    /// the allocator a size; not known where std's allocator does not resolve.
    allocations: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty,
    allocations_known: bool = true,
    /// The sinks a rule reads in each function of a file the run does not select (a
    /// dependency's), by the rule and the function (`functionKey`), read once: what each takes
    /// from its function's parameters, judged at the calls that reach it (`PassedSink`,
    /// designs/glint-provenance.md part 1). Only the functions a selected call reaches are read,
    /// with the functions of their file they call.
    reached_sinks: std.AutoHashMapUnmanaged(struct { u16, u32 }, []const PassedSink) = .empty,
    /// The files a rule's reading of them is under way for: a call back into one meets no list
    /// yet, which is undecided.
    reading_sinks: std.AutoHashMapUnmanaged(struct { u16, Project.FileId }, void) = .empty,
    /// Where a rule reading a file the run does not select puts what its sinks take, in place of
    /// a report (`PassedSink`).
    recording: ?*std.ArrayList(PassedSink) = null,
    /// The calls into the file being read that its own functions make, composed once the
    /// file's own sinks are in (`PassedCall`).
    recording_calls: ?*std.ArrayList(PassedCall) = null,
    /// The functions of the file being read whose sinks the reading takes (`readHere`): the
    /// others are read only when a call reaches them.
    recording_within: ?*const std.AutoHashMapUnmanaged(u32, void) = null,
    /// Of the summary every instantiation reads, the summaries of one instantiation each
    /// (`instanceSizes`), by the reading of the program's call that roots it.
    instances: std.ArrayList(struct { env: *const Facts.Env, flow: *Flow }) = .empty,
    /// For a summary of one instantiation, every instantiation's (`instanceSizes`).
    shared: ?*Flow = null,

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

/// The run's solve: the facts the enabled rules declare, and any other a rule asked since. It
/// lasts through `Facts.forget`: a solve kept is complete (`get`), and a short one is marked.
const Solved = struct {
    pub const lasting = {};
    flow: ?*Flow = null,
    /// The solve ran short of its own budget: nothing is kept, and no later file solves again.
    short: bool = false,
};

/// The fact `spec` describes, solved with every other the run's enabled rules declare the
/// first time one is asked. A rule asks only the facts it declares (`Context.Rule.facts`);
/// another is `error.InvalidSelection`. `error.SolveShort` where the solve ran short of its
/// budget, or would read what the asking file's work built short of one: the rule's check of
/// the file stops there, and the Runner reports the file's budget exhausted.
pub fn get(c: *Context, spec: Spec) Context.Error!Fact {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Solved);
    if (memo.short) return error.SolveShort;
    const flow = memo.flow orelse solved: {
        // What was built short of a budget would answer the solve as if complete (C1), and
        // what the asking file's check holds of it may not be dropped under it: a later file
        // solves, once the Runner has forgotten it (`Facts.forget`).
        if (c.facts.short) return error.SolveShort;
        var specs: std.ArrayList(Spec) = .empty;
        for (c.compiled) |rule| {
            if (!try enabled(c, rule)) continue;
            for (rule.facts) |each| if (laneOf(specs.items, each) == null) try specs.append(c.allocator, each);
        }
        // The run's rules fit the lanes (`fits`): the Runner refuses a set that does not.
        const flow = try c.allocator.create(Flow);
        flow.* = .{ .specs = specs.items, .masks = masksOf(specs.items), .program = try Program.get(c) };
        // The solve is the run's, never the asking file's: a unit on a budget of its own, a
        // file's per program file it reads (designs/glint-summaries.md, "One budget model").
        var files: usize = 0;
        for (c.project.sources) |*each| {
            if (solves(c, flow, each)) files += 1;
        }
        const budget = std.math.mul(usize, c.config.fact_budget, @max(files, 1)) catch std.math.maxInt(usize);
        const asker = c.facts.enter(budget);
        const solved = solve(c, flow);
        const short = c.facts.leave(asker);
        try solved;
        if (short) {
            memo.short = true;
            return error.SolveShort;
        }
        flow.solved = true;
        memo.flow = flow;
        break :solved flow;
    };
    const lane = laneOf(flow.specs, spec) orelse return error.InvalidSelection;
    return .{ .flow = flow, .lane = lane, .spec = spec };
}

/// Whether the facts `rules` declare fit one solve's lanes.
pub fn fits(rules: []const Context.Rule) bool {
    var lanes: [lane_count]Spec = undefined;
    var count: usize = 0;
    for (rules) |rule| for (rule.facts) |spec| {
        if (laneOf(lanes[0..count], spec) != null) continue;
        if (count == lane_count) return false;
        lanes[count] = spec;
        count += 1;
    };
    return true;
}

/// The lane of the specs that `spec` flows as: a lane is a source, whether control takes it,
/// and its answers. The sinks a rule judges and the level it judges them at read a lane and
/// make none, so rules that ask the same flow of different sinks share one.
fn laneOf(specs: []const Spec, spec: Spec) ?u8 {
    for (specs, 0..) |each, i| {
        if (std.meta.eql(each.source, spec.source) and each.control == spec.control and each.answers == spec.answers) return @intCast(i);
    }
    return null;
}

/// Whether some file of the program is checked with `rule`.
fn enabled(c: *Context, rule: Context.Rule) Context.Error!bool {
    if (c.config.has(rule.definition.id)) return true;
    for (c.project.sources) |*each| if (c.configOf(each.id).has(rule.definition.id)) return true;
    return false;
}

fn masksOf(specs: []const Spec) Masks {
    var out: Masks = .{};
    for (specs, 0..) |spec, i| {
        const bit = @as(Mask, 1) << @intCast(i);
        switch (spec.source) {
            .input => |from| {
                if (from.peer) out.peer |= bit;
                if (from.operator) out.operator |= bit;
            },
            .error_text => out.error_text |= bit,
            .peer_writer => out.peer_writer |= bit,
        }
        if (spec.control) out.control |= bit;
        if (spec.answers.aegis) out.aegis |= bit;
        if (spec.answers.int_from_error) out.int_from_error |= bit;
    }
    return out;
}

fn solve(c: *Context, flow: *Flow) Context.Error!void {
    try known(c, flow);
    for (c.project.sources) |*each| {
        if (solves(c, flow, each)) try functionsOf(c, flow, each.id);
    }
    try parsers(c, flow);
    try escaped(c, flow);
    try linksOf(c, flow);
    try rounds(c, flow, .facts);
}

/// Reads each function of `flow` not settled, and what its links hold, round after round:
/// every step joins, and each level and set is finite, so the rounds end when one changes
/// nothing, however long a chain of calls a fact runs through. `.sizes`: a summary's, which
/// also reads what each function sizes work by (`sizing`). Each round works on its own memory
/// and keeps on the run's only the facts it raises (`Dep.kept`, `Slots.kept`), so a flow holds
/// its facts once, not every round's work; its pages are unmapped when the round ends, so what
/// a round kept by mistake faults where it is read again.
fn rounds(c: *Context, flow: *Flow, comptime reads: enum { facts, sizes }) Context.Error!void {
    var round: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer round.deinit();
    const run_memory = c.allocator;
    defer {
        c.allocator = run_memory;
        flow.round = null;
        flow.loops = .empty;
        flow.leaving = .empty;
    }
    while (true) {
        flow.changed = false;
        flow.loops = .empty;
        flow.leaving = .empty;
        c.allocator = round.allocator();
        flow.round = c.allocator;
        for (flow.functions.items, 0..) |f, i| {
            if (f.settled) continue;
            try bindings(c, flow, @fromBackingInt(@intCast(i)));
            if (reads == .sizes) try sizing(c, flow, @fromBackingInt(@intCast(i)));
        }
        try takeHeld(c, flow);
        flow.loops = .empty;
        flow.leaving = .empty;
        _ = round.reset(.free_all);
        if (!flow.changed) break;
    }
}

/// Whether the solve reads `source`'s functions: the program's files but its tests, whose rules
/// ask a fact. A file whose rules ask none (a tool the package develops with) is no part of the
/// program the facts describe.
fn solves(c: *Context, flow: *const Flow, each: *const Project.Source) bool {
    return each.input.classification != .@"test" and flow.own(each.id) and asks(c, c.configOf(each.id));
}

/// Whether a file's rules ask a fact.
fn asks(c: *Context, config: @import("Rule.zig").Config) bool {
    for (c.compiled) |rule| if (rule.facts.len > 0 and config.has(rule.definition.id)) return true;
    return false;
}

/// Marks each function the program hands to `Untrusted.parse`, before the rounds, so what its
/// returned literals hold is settled from the first round.
fn parsers(c: *Context, flow: *Flow) Context.Error!void {
    var files = flow.owners.iterator();
    while (files.next()) |entry| {
        const file = entry.key_ptr.*;
        for (0..entry.value_ptr.syntax.of.len) |i| {
            if (entry.value_ptr.at(i) == null) continue;
            const callee = (try resolveCall(c, flow, file, @fromBackingInt(@intCast(i)))) orelse continue;
            if (callee.kind != .aegis) continue;
            if (try parserOf(c, flow, file, callee.params, callee.decl.?)) |target| flow.functions.items[@backingInt(target)].parser = true;
        }
    }
}

/// The declarations the fact starts from and stops at: std's reader, file, directory and stream.
fn known(c: *Context, flow: *Flow) Context.Error!void {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const paths = [_][]const u8{ "Io.Reader", "Io.File", "Io.Dir", "Io.net.Stream" };
    var found: [paths.len]?Facts.Container = @splat(null);
    for (paths, &found) |path, *slot| {
        for (((try Governed.declarations(c, "std", path)).orNull()) orelse &.{}) |decl| {
            const value = try c.facts.declaration(((try c.facts.origin(decl)).orNull()) orelse decl);
            if (value == .container) slot.* = value.container;
        }
    }
    flow.reader, flow.file, flow.dir, flow.stream = found;
    for (c.config.peer_writers) |declared| {
        const found_writers = ((try Governed.declarations(c, declared.module, declared.declaration)).orNull()) orelse ((try Governed.declarationsOfPackage(c, declared.module, declared.declaration)).orNull()) orelse &.{};
        for (found_writers) |decl| try flow.peer_writers.append(c.allocator, ((try c.facts.origin(decl)).orNull()) orelse decl);
    }
    // Where std's writer does not resolve, any type may be one.
    switch (try Governed.declarations(c, "std", "Io.Writer")) {
        .decls => |decls| for (decls) |decl| {
            const origin = switch (try c.facts.origin(decl)) {
                .decl => |aliased| aliased,
                .none => decl,
                .unknown => {
                    flow.writer_unknown = true;
                    continue;
                },
            };
            switch (try c.facts.declaration(origin)) {
                .container => |k| try flow.writer_types.append(c.allocator, k),
                .alternatives => flow.writer_unknown = true,
                else => flow.writer_unknown = true,
            }
        },
        .none => {},
        .unknown => flow.writer_unknown = true,
    }
    for (flow.peer_writers.items) |decl| {
        const tree = &c.project.at(decl.file).file.tree;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse continue;
        const result_type = proto.ast.return_type.unwrap() orelse {
            flow.writer_unknown = true;
            continue;
        };
        try writerTypes(c, flow, try c.facts.resolve(decl.file, result_type));
    }
    for (((try Governed.declarations(c, "std", "process.run")).orNull()) orelse &.{}) |decl| try flow.reads.append(c.allocator, ((try c.facts.origin(decl)).orNull()) orelse decl);
    for (zig_text) |path| for (((try Governed.declarations(c, "std", path)).orNull()) orelse &.{}) |decl| try flow.zig_text.put(c.allocator, decl, {});
    for ([_][]const u8{ "mem.Allocator.rawAlloc", "mem.Allocator.rawResize", "mem.Allocator.rawRemap" }) |path| switch (try Governed.declarations(c, "std", path)) {
        .decls => |decls| for (decls) |decl| switch (try c.facts.origin(decl)) {
            .decl => |origin| try flow.allocations.put(c.allocator, origin, {}),
            .none => try flow.allocations.put(c.allocator, decl, {}),
            .unknown => flow.allocations_known = false,
        },
        .none => {},
        .unknown => flow.allocations_known = false,
    };
    for (((try Governed.declarations(c, "std", "zig.Ast.parse")).orNull()) orelse &.{}) |decl| {
        try flow.zig_parse.put(c.allocator, decl, {});
        flow.zig_ast = decl.file;
    }
    for (zig_index) |path| for (((try Governed.declarations(c, "std", path)).orNull()) orelse &.{}) |decl| try flow.zig_index.put(c.allocator, decl, {});
    for ([_][]const u8{ "own.readFile", "own.readFileSentinel" }) |path| {
        for (((try Governed.declarations(c, "aegis", path)).orNull()) orelse &.{}) |decl| try flow.reads.append(c.allocator, ((try c.facts.origin(decl)).orNull()) orelse decl);
    }
    for ([_][]const u8{ "mem", "fmt", "ascii", "unicode", "math", "base64" }) |namespace| {
        for (((try Governed.declarations(c, "std", namespace)).orNull()) orelse &.{}) |decl| {
            const value = try c.facts.declaration(((try c.facts.origin(decl)).orNull()) orelse decl);
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
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const syntax = try functionsIn(c, file);
    const ids = try c.allocator.alloc(?Function.Id, syntax.decls.len);
    for (syntax.decls, syntax.bodies, ids) |node, body, *id| {
        id.* = try addFunction(c, flow, file, node);
        if (id.*) |one| flow.functions.items[@backingInt(one)].nodes = body;
    }
    try flow.owners.put(c.allocator, file, .{ .syntax = syntax, .ids = ids });
}

/// A file's functions by syntax alone (`enclosing`), found once per run however many flows
/// read the file: each `fn_decl` in the file's order, its body (the nodes it holds outside any
/// function nested in it), and each node's function among them.
const FileFunctions = struct {
    decls: []const Ast.Node.Index,
    bodies: []const []const Ast.Node.Index,
    /// Per node, its function's position in `decls`.
    of: []const Position,

    const Position = enum(u32) { none = std.math.maxInt(u32), _ };

    /// The position of the `fn_decl` `node` in `decls`.
    fn position(self: *const FileFunctions, node: Ast.Node.Index) ?usize {
        return std.sort.binarySearch(Ast.Node.Index, self.decls, node, struct {
            fn order(key: Ast.Node.Index, item: Ast.Node.Index) std.math.Order {
                return std.math.order(@backingInt(key), @backingInt(item));
            }
        }.order);
    }
};

/// The run's `FileFunctions`, by file, and the nodes their grouping read: a count a test
/// holds to the files, not the functions or the flows that read them.
const Functions = struct {
    map: std.AutoHashMapUnmanaged(Project.FileId, *const FileFunctions) = .empty,
    walked: usize = 0,
};

fn functionsIn(c: *Context, file: Project.FileId) Context.Error!*const FileFunctions {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Functions);
    if (memo.map.get(file)) |known_functions| return known_functions;
    const tree = &c.project.at(file).file.tree;
    // Counted, then each list made at its size: what the run holds is the same in whatever
    // order the file declares its functions.
    const tags = tree.nodes.items(.tag);
    const decls = try c.allocator.alloc(Ast.Node.Index, std.mem.count(Ast.Node.Tag, tags, &.{.fn_decl}));
    var next_decl: usize = 0;
    for (tags, 0..) |tag, i| if (tag == .fn_decl) {
        decls[next_decl] = @fromBackingInt(@intCast(i));
        next_decl += 1;
    };
    const of = try c.allocator.alloc(FileFunctions.Position, tree.nodes.len);
    const made = try c.allocator.create(FileFunctions);
    made.* = .{ .decls = decls, .bodies = &.{}, .of = of };
    const sizes = try c.allocator.alloc(usize, decls.len);
    @memset(sizes, 0);
    var held: usize = 0;
    for (of, 0..) |*slot, i| {
        memo.walked += 1;
        const function = enclosing(c, file, @fromBackingInt(@intCast(i))) orelse {
            slot.* = .none;
            continue;
        };
        const at = made.position(function).?; // unreachable: `enclosing` gives a `fn_decl`
        slot.* = @fromBackingInt(@intCast(at));
        sizes[at] += 1;
        held += 1;
    }
    const nodes = try c.allocator.alloc(Ast.Node.Index, held);
    const bodies = try c.allocator.alloc([]Ast.Node.Index, decls.len);
    var start: usize = 0;
    for (bodies, sizes) |*body, size| {
        body.* = nodes[start..][0..size];
        start += size;
    }
    @memset(sizes, 0);
    for (of, 0..) |slot, i| if (slot != .none) {
        const at = @backingInt(slot);
        bodies[at][sizes[at]] = @fromBackingInt(@intCast(i));
        sizes[at] += 1;
    };
    made.bodies = bodies;
    try memo.map.put(c.allocator, file, made);
    return made;
}

/// The functions a flow reads of a file: its `FileFunctions`, and the flow's function for each
/// one it reads, by position.
const Owners = struct {
    syntax: *const FileFunctions,
    ids: []?Function.Id,

    /// The flow's function whose body holds the node at `index`, if the flow reads it.
    fn at(self: Owners, index: usize) ?Function.Id {
        if (index >= self.syntax.of.len) return null;
        const position = self.syntax.of[index];
        if (position == .none) return null;
        return self.ids[@backingInt(position)];
    }
};

/// A function of the flow for the `fn_decl` `node`, its nodes not yet given.
fn addFunction(c: *Context, flow: *Flow, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Function.Id {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(node).node_and_node[0]) orelse return null;
    var params: std.ArrayList(?Model.Declaration.Id) = .empty;
    var fixed: Slots = .{};
    var it = proto.iterate(tree);
    while (it.next()) |param| {
        if (param.comptime_noalias) |token| if (tree.tokenTag(token) == .keyword_comptime) {
            fixed = try fixed.with(c.allocator, params.items.len);
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
    const levels = try c.allocator.alloc(Levels, slots(params.items.len));
    @memset(levels, .clean);
    const writes = try c.allocator.alloc(Dep, params.items.len);
    @memset(writes, .{});
    const id: Function.Id = @fromBackingInt(@intCast(flow.functions.items.len));
    try flow.functions.append(c.allocator, .{ .file = file, .node = node, .params = params.items, .levels = levels, .writes = writes, .fixed = fixed });
    try flow.by_node.put(c.allocator, .{ .file = file, .node = node }, id);
    return id;
}

/// The `fn_decl` whose body holds `node`, within its container.
fn enclosing(c: *Context, file: Project.FileId, node: Ast.Node.Index) ?Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl) return parent;
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buffer, parent) != null) return null;
    }
    return null;
}

/// The function whose body holds `node`, if the fact reads it.
fn owner(flow: *const Flow, file: Project.FileId, node: Ast.Node.Index) ?Function.Id {
    const owners = flow.owners.get(file) orelse return null;
    return owners.at(@backingInt(node));
}

/// One round over a function's bindings: what each local, field, parameter and result takes.
fn bindings(c: *Context, flow: *Flow, function: Function.Id) Context.Error!void {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    for (f.nodes) |node| {
        switch (formAt(tree, node)) {
            .variable => {
                const init = (tree.fullVarDecl(node) orelse continue).ast.init_node.unwrap() orelse continue;
                const d = declaredAt(model, node) orelse continue;
                try raiseLocal(c, flow, .{ .file = f.file, .index = d }, try dep(c, flow, function, init));
            },
            .assign, .compound_assign => {
                const target, const value = tree.nodeData(node).node_and_node;
                const operator = accesses.operatorOf(tree.nodeTag(node));
                // A product or a shift in place grows what the target held by what it is given.
                if (operator) |update| if (update.op == .mul or update.op == .shl) {
                    const grown = try (try dep(c, flow, function, target)).widened(c.allocator);
                    const given = try grown.join(c.allocator, try dep(c, flow, function, value));
                    try storeAt(c, flow, function, node, target, value, try given.join(c.allocator, try control(c, flow, function, node, target)));
                    continue;
                };
                var given = try dep(c, flow, function, value);
                const ruled = try control(c, flow, function, node, target);
                // A sum or a product that feeds its own target accumulates a number past any
                // range what it adds holds (`n = n * 10 + d`, `total += b`).
                const accumulating = operator == null and accumulates(tree, model, target, value);
                const update_op: ?Range.Op = if (operator) |update| update.op else null;
                if (update_op == .add or accumulating) given = try given.widened(c.allocator);
                var held = try given.join(c.allocator, ruled);
                // A sum each pass steps again counts the passes of the loops around it.
                const stepped = accumulating or update_op == .add or update_op == .sub;
                if (stepped) held = try held.join(c.allocator, try counts(c, flow, function, node, target));
                // A slice's length written (`s.len = n`): the memory's length is the value. What
                // decides whether it is written chooses between it and the length it had, which
                // was within the memory; one taken from (`s.len -= k`, which a safe build checks)
                // stays within it.
                if (try c.facts.lengthOf(f.file, target) != null) {
                    held = if (Range.updates(tree, node, .sub)) try ruled.sizing(c.allocator) else try (try given.written(c.allocator)).join(c.allocator, try ruled.sizing(c.allocator));
                }
                try storeAt(c, flow, function, node, target, value, held);
            },
            .destructure => {
                const parts = tree.assignDestructure(node);
                const all = try dep(c, flow, function, parts.ast.value_expr);
                // A literal of as many elements gives each variable its own (`x, y = .{ 5, n }`).
                var buffer: [2]Ast.Node.Index = undefined;
                const elements: ?[]const Ast.Node.Index = if (tree.fullArrayInit(&buffer, parts.ast.value_expr)) |literal| (if (literal.ast.elements.len == parts.ast.variables.len) literal.ast.elements else null) else null;
                for (parts.ast.variables, 0..) |variable, at| {
                    const value = try (if (elements) |each| try dep(c, flow, function, each[at]) else all).join(c.allocator, try control(c, flow, function, node, variable));
                    if (declaredAt(model, variable)) |d| try raiseLocal(c, flow, .{ .file = f.file, .index = d }, value) else try storeAt(c, flow, function, node, variable, if (elements) |each| each[at] else null, value);
                }
            },
            .@"return" => {
                const value = tree.nodeData(node).opt_node.unwrap() orelse continue;
                const now = try (try flow.functions.items[@backingInt(function)].ret.join(c.allocator, try dep(c, flow, function, value))).join(c.allocator, try control(c, flow, function, node, null));
                if (!now.eql(flow.functions.items[@backingInt(function)].ret)) {
                    flow.functions.items[@backingInt(function)].ret = try now.kept(c.facts.gpa);
                    flow.changed = true;
                }
                if (f.parser) try unrefined(c, flow, function, value);
            },
            else => {
                if (try resolveCall(c, flow, f.file, node)) |callee| try effects(c, flow, function, callee);
                var literal_buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullStructInit(&literal_buffer, node)) |literal| if (try literalFields(c, f.file, node, literal)) |fields| {
                    // A parser's result holds its numbers as its own value (`dep`): the parse
                    // refines them, a direct call gives them as they were read.
                    const refined = f.parser and returned(tree, model, node);
                    for (literal.ast.fields, fields) |value, field| {
                        // A number the parser shows the range of reaches the program as data
                        // held to that range, which a sink judges as it judges any value's.
                        const given = try (try dep(c, flow, function, value)).join(c.allocator, try control(c, flow, function, node, null));
                        var level = concrete(flow, function, given);
                        if (refined and anyAt(level, .number) and try shownField(c, f.file, value, field)) level = level.narrowed();
                        try raiseGlobal(c, flow, field, level, concreteLength(flow, function, given));
                    }
                };
                // A copy gives its destination the source's bytes, which its elements put
                // together into numbers (input's bytes copied into a `u32` are a peer's count;
                // a sink reads an element its type holds small as data again), a fill the value,
                // a combination the value with what the memory held, past any range either has
                // (`.Add` accumulates as `+=` does); under its site's control each way.
                if (filler(tree, node)) |writes| {
                    var args_buffer: [2]Ast.Node.Index = undefined;
                    const args = Facts.builtinArgs(tree, node, &args_buffer);
                    if (args.len > @max(writes.destination, writes.value)) {
                        const destination = args[writes.destination];
                        const value = switch (writes.kind) {
                            .copy => try (try whole(c, flow, function, args[writes.value])).widened(c.allocator),
                            .fill => try dep(c, flow, function, args[writes.value]),
                            .combine => combine: {
                                const operand = try dep(c, flow, function, args[writes.value]);
                                break :combine try (try operand.join(c.allocator, try whole(c, flow, function, destination))).widened(c.allocator);
                            },
                        };
                        try storeAt(c, flow, function, node, destination, null, try value.join(c.allocator, try control(c, flow, function, node, destination)));
                    }
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

/// A builtin that writes memory it is given: its destination's argument, and how the value
/// written is read from another. `@memcpy` and `@memmove` copy the source's bytes, `@memset`
/// fills with its value, `@atomicStore` stores its value and a `@cmpxchg` its new one, and
/// `@atomicRmw` combines its operand with what the memory held.
const Filler = struct {
    destination: usize,
    value: usize,
    kind: enum { copy, fill, combine },
};

fn filler(tree: *const Ast, node: Ast.Node.Index) ?Filler {
    if (formAt(tree, node) != .builtin) return null;
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    if (std.mem.eql(u8, name, "@memcpy") or std.mem.eql(u8, name, "@memmove")) return .{ .destination = 0, .value = 1, .kind = .copy };
    if (std.mem.eql(u8, name, "@memset")) return .{ .destination = 0, .value = 1, .kind = .fill };
    if (std.mem.eql(u8, name, "@atomicStore")) return .{ .destination = 1, .value = 2, .kind = .fill };
    if (std.mem.eql(u8, name, "@cmpxchgWeak") or std.mem.eql(u8, name, "@cmpxchgStrong")) return .{ .destination = 1, .value = 3, .kind = .fill };
    if (std.mem.eql(u8, name, "@atomicRmw")) return .{ .destination = 1, .value = 3, .kind = .combine };
    return null;
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
            out = try (try out.join(c.allocator, .{ .level = flow.globals.get(field) orelse .clean, .unchecked = flow.lengths.get(field) orelse .clean })).join(c.allocator, try throughUnnamed(c, flow, field));
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
            if (end.unwrap()) |last| return try out.join(c.allocator, (try dep(c, flow, function, last)).held());
            for (loop.ast.inputs) |other| if (tree.nodeTag(other) != .for_range) {
                out = try out.join(c.allocator, (try dep(c, flow, function, other)).measured());
            };
            return out;
        }
        return dep(c, flow, function, input);
    }
    return .{};
}

/// A function of the program code outside it may call (`Facts.escapes`: std's sort given
/// `less`, a hash map's context, a spawned thread's worker, an exported name) is called with
/// values no call of the program shows: each parameter a comptime one does not fix, and each
/// one's length, may hold input at its most, and one whose type may hold a writer may be one
/// that reaches a peer (`writerSlots`). Whether it holds an error's text its type says
/// (`errorDeclared`). In a file only the build runner compiles (a build script), that caller is
/// the build runner, or code the script hands its values: what it gives (`std.Build`, an option,
/// the build's arguments) is whoever runs the build's, the operator's, never a peer's, and it
/// hands no writer a peer reads. What the script itself reads (a fetch over the network) is
/// still the reader's source.
fn escaped(c: *Context, flow: *Flow) Context.Error!void {
    var by_node: std.AutoHashMapUnmanaged(Facts.Key, Model.Declaration.Id) = .empty;
    var indexed: std.AutoHashMapUnmanaged(Project.FileId, void) = .empty;
    for (flow.functions.items) |*f| {
        const model = &c.project.at(f.file).model;
        if (!(try indexed.getOrPut(c.allocator, f.file)).found_existing) {
            for (model.declarations, 0..) |decl, d| if (decl.kind == .function) if (model.parentOf(decl.node)) |body| try by_node.put(c.allocator, .{ .file = f.file, .node = body }, @fromBackingInt(@intCast(d)));
        }
        const d = by_node.get(.{ .file = f.file, .node = f.node }) orelse continue;
        if (!try c.facts.handedOut(.{ .file = f.file, .index = d })) continue;
        const build = c.project.at(f.file).input.compilations == .build;
        const input: Levels = .in(if (build) flow.masks.operator else flow.masks.input(), .number);
        const writers: Slots = if (build) .{} else try writerSlots(c, flow, .{ .file = f.file, .index = d });
        const lengthless = try lengthlessSlots(c, .{ .file = f.file, .index = d });
        for (f.levels, 0..) |*level, slot| {
            if (f.fixed.has(slot / 2) or lengthless.has(slot)) continue;
            level.* = if (writers.has(slot)) input.join(.in(flow.masks.peer_writer, .unknown)) else input;
        }
    }
}

/// The length slots of a function's parameters whose declared type has no length and holds
/// no memory with one (`Facts.holdsLength`): a number, `bool`, an enum. No caller gives one.
fn lengthlessSlots(c: *Context, decl: Facts.Decl) Context.Error!Slots {
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return .{};
    var out: Slots = .{};
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        const kind = param.type_expr orelse continue;
        if (!try c.facts.holdsLength(decl.file, kind)) out = try out.with(c.allocator, lengthSlot(position));
    }
    return out;
}

/// The value slots of a function's parameters that may be handed a writer reaching a peer: one
/// whose type may hold a writer (`writerHold`), or one the declaration does not spell.
fn writerSlots(c: *Context, flow: *Flow, decl: Facts.Decl) Context.Error!Slots {
    if (flow.masks.peer_writer == none) return .{};
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return .{};
    var out: Slots = .{};
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        const kind = param.type_expr orelse {
            out = try out.with(c.allocator, valueSlot(position));
            continue;
        };
        if (try writerHold(c, flow, try c.facts.resolve(decl.file, kind), 0) != .none) out = try out.with(c.allocator, valueSlot(position));
    }
    return out;
}

/// How a value of a type holds a writer that reaches a peer: `holds`, one of the writer types
/// (`Flow.writer_types`) as it is, behind a pointer, an optional or in an array, or in a field a
/// type outside the program holds (`Facts.heldFields`, by a made type's bindings); `may`, only
/// through what does not resolve (a type that does not, an opaque pointer: an Allocator's or an
/// Io's state), where a writer may sit but none is shown; `none`. A field of the program's own
/// type holds what the program stores in it, which the field's own level says.
const Hold = enum(u2) {
    none,
    may,
    holds,

    fn join(a: Hold, b: Hold) Hold {
        return if (@backingInt(a) >= @backingInt(b)) a else b;
    }
};

fn writerHold(c: *Context, flow: *Flow, value: Facts.Value, depth: usize) Context.Error!Hold {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    // A type nested this deep is read as one that may.
    if (depth > 8) return .may;
    switch (value) {
        .unknown, .reified, .literal => return .may,
        .pointer => |inner| return writerHold(c, flow, inner.child.*, depth + 1),
        .optional, .error_union, .array => |inner| return writerHold(c, flow, inner.*, depth + 1),
        .alternatives => |each| {
            var out: Hold = .none;
            for (each) |one| out = out.join(try writerHold(c, flow, one, depth + 1));
            return out;
        },
        .instance, .container => |k| {
            for (flow.writer_types.items) |writer| if (std.meta.eql(writer, k)) return .holds;
            if (flow.own(k.file)) return if (flow.writer_unknown) .may else .none;
            if (flow.writer_holders.get(k)) |known_holder| return known_holder;
            // A container met again within itself holds nothing more there.
            try flow.writer_holders.put(c.allocator, k, .none);
            var holds: Hold = .none;
            for (try c.facts.heldFields(k)) |field| {
                holds = holds.join(try writerHold(c, flow, field.value, depth + 1));
                if (holds == .holds) break;
            }
            try flow.writer_holders.put(c.allocator, k, holds);
            return holds;
        },
        else => return .none,
    }
}

/// What a place keeps of the peer writer's lane by its type (`Dep.within`): the lanes it
/// carries, and those it lowers to unknown.
const Gate = struct {
    lanes: Mask = all_lanes,
    capped: Mask = none,
};

/// The gate of a place `decl` declares (a local, a parameter, a field, a container-level
/// variable): every lane, the peer writer's only where its type may hold a writer
/// (`writerHold`), and unknown where it only may. A value of a type that holds none (bytes, a
/// number, a record of the program's own, whose fields hold what is stored in them) is no
/// writer, whatever it was made from: a field read of a writer's holder, a call given one, a
/// store through one. One that may hold a writer only through what does not resolve (an
/// Allocator's or an Io's opaque state) is not shown to be one: unknown, never decided.
fn placeGate(c: *Context, flow: *Flow, decl: Facts.Decl) Context.Error!Gate {
    if (flow.masks.peer_writer == none) return .{};
    if (flow.place_gates.get(decl)) |found| return found;
    const gate = holdGate(flow, try writerHold(c, flow, try c.facts.declaration(decl), 0));
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    try flow.place_gates.put(c.allocator, decl, gate);
    return gate;
}

fn holdGate(flow: *const Flow, how: Hold) Gate {
    return switch (how) {
        .none => .{ .lanes = ~flow.masks.peer_writer },
        .may => .{ .capped = flow.masks.peer_writer },
        .holds => .{},
    };
}

/// The gate of a parameter's value slot (`placeGate`) or length slot: a length is a number, no
/// writer.
fn slotGate(c: *Context, flow: *Flow, g: Function, slot: usize) Context.Error!Gate {
    if (slot % 2 == 1) return .{ .lanes = ~flow.masks.peer_writer };
    const index = slot / 2;
    if (index >= g.params.len) return .{};
    const param = g.params[index] orelse return .{};
    return placeGate(c, flow, .{ .file = g.file, .index = param });
}

/// What a call that does not resolve may write into memory of `value`'s type: anything, but a
/// writer that reaches a peer only where the type may hold one.
fn unknownInto(c: *Context, flow: *Flow, value: Facts.Value) Context.Error!Dep {
    const unknown: Dep = .{ .level = .all(.unknown) };
    return if (try writerHold(c, flow, value, 0) != .none) unknown else answered(unknown, flow.masks.peer_writer);
}

/// The containers a configured peer writer's result may be, into `Flow.writer_types`.
fn writerTypes(c: *Context, flow: *Flow, value: Facts.Value) Context.Error!void {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    switch (value) {
        .pointer => |inner| try writerTypes(c, flow, inner.child.*),
        .optional, .error_union => |inner| try writerTypes(c, flow, inner.*),
        .alternatives => |each| for (each) |one| try writerTypes(c, flow, one),
        .instance, .container => |k| try flow.writer_types.append(c.allocator, k),
        .unknown, .reified, .literal => flow.writer_unknown = true,
        else => {},
    }
}

fn declaredAt(model: *const Model, node: Ast.Node.Index) ?Model.Declaration.Id {
    for (model.declarations, 0..) |decl, d| if (decl.node == node and decl.kind == .variable) return @fromBackingInt(@intCast(d));
    return null;
}

fn raiseLocal(c: *Context, flow: *Flow, decl: Facts.Decl, given: Dep) Context.Error!void {
    const value = given.within(try placeGate(c, flow, decl));
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    if (value.clean()) return;
    const entry = try flow.locals.getOrPut(c.allocator, decl);
    const before: Dep = if (entry.found_existing) entry.value_ptr.* else .{};
    // Joined on the caller's memory (a round's), kept on the run's only where it changed.
    const now = try before.join(rule_memory, value);
    if (now.eql(before)) return;
    entry.value_ptr.* = try now.kept(c.allocator);
    flow.changed = true;
}

/// A field or a container-level variable given a value of `level` in memory of `length`.
fn raiseGlobal(c: *Context, flow: *Flow, decl: Facts.Decl, level: Levels, length: Levels) Context.Error!void {
    const gate = try placeGate(c, flow, decl);
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    for ([_]struct { *std.AutoHashMapUnmanaged(Facts.Decl, Levels), Levels }{ .{ &flow.globals, level.gated(gate) }, .{ &flow.lengths, length.masked(~flow.masks.peer_writer) } }) |each| {
        const map, const raised = each;
        if (raised.isClean()) continue;
        const entry = try map.getOrPut(c.allocator, decl);
        const before: Levels = if (entry.found_existing) entry.value_ptr.* else .clean;
        entry.value_ptr.* = before.join(raised);
        if (!entry.value_ptr.eql(before)) flow.changed = true;
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
    switch (formAt(tree, target)) {
        .leaf => {
            if (!spellsName(tree, target)) return;
            // `_ = v` discards; a name that does not resolve may be any memory.
            if (discards(tree, target)) return;
            const ref = model.reference(target) orelse return addPlace(c, out, .unknown);
            const d = ref.declaration orelse return addPlace(c, out, .unknown);
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
                switch (formAt(tree, init)) {
                    .address_of, .slice => try places(c, flow, function, init, out),
                    else => if (tree.fullArrayInit(&buffer, init) != null) {
                        try places(c, flow, function, init, out);
                    } else if (try pointing(c, f.file, target)) {
                        // A pointer a call gives or a conversion makes (`list.addOne()`,
                        // `@ptrFromInt(at)`) is the memory it was made from.
                        try places(c, flow, function, init, out);
                    },
                }
            };
            if (decl.kind == .capture) if (try capturedFrom(c, f.file, decl)) |from| try places(c, flow, function, from, out);
        },
        .member => {
            // The program's own field holds the fact by its declaration; a field of a type
            // outside it (std's writer, a dependency's list) is every instance's everywhere, so
            // the store reaches only the value it belongs to. A container-level variable named
            // through its namespace (`w.limit`) is that variable, as its reads take it, wherever
            // it is declared; the namespace holds no memory the store writes.
            const holder = tree.nodeData(target).node_and_token[0];
            switch (try c.facts.definition(f.file, target)) {
                .decl => |decl| switch (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind) {
                    .field => if (flow.own(decl.file)) return addPlace(c, out, .{ .global = decl }),
                    .variable => if (Facts.accesses.global(c.facts, decl)) return addPlace(c, out, .{ .global = decl }),
                    else => {},
                },
                // A member that does not resolve, or one of a holder whose type does not, is
                // memory no place names: a field it may be reads it there (`throughUnnamed`).
                .unknown => try addPlace(c, out, .unknown),
                .none => if (unresolvedHolder(try c.facts.resolve(f.file, holder))) try addPlace(c, out, .unknown),
            }
            return places(c, flow, function, holder, out);
        },
        .array_access => return places(c, flow, function, tree.nodeData(target).node_and_node[0], out),
        .deref, .address_of, .tried => return places(c, flow, function, tree.nodeData(target).node, out),
        .grouped, .unwrap_optional => return places(c, flow, function, tree.nodeData(target).node_and_token[0], out),
        .slice => return places(c, flow, function, (tree.fullSlice(target) orelse return).ast.sliced, out),
        // Many-item pointer arithmetic stays in the memory it starts from.
        .operator => if (accesses.operatorOf(tree.nodeTag(target))) |operator| {
            if ((operator.op == .add or operator.op == .sub) and operator.overflow != .saturating) return places(c, flow, function, tree.nodeData(target).node_and_node[0], out);
        },
        .@"orelse", .@"catch" => {
            const lhs, const rhs = tree.nodeData(target).node_and_node;
            try places(c, flow, function, lhs, out);
            try places(c, flow, function, rhs, out);
        },
        .@"if" => {
            const branch = tree.fullIf(target).?;
            try places(c, flow, function, branch.ast.then_expr, out);
            if (branch.ast.else_expr.unwrap()) |otherwise| try places(c, flow, function, otherwise, out);
        },
        .@"switch" => for (tree.fullSwitch(target).?.ast.cases) |case| {
            try places(c, flow, function, (tree.fullSwitchCase(case) orelse continue).ast.target_expr, out);
        },
        .builtin => {
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
            // A pointer converted is the memory it was, and a field's parent the memory its field is in.
            for ([_][]const u8{ "@ptrCast", "@alignCast", "@constCast", "@volatileCast", "@as", "@fieldParentPtr" }) |cast| if (std.mem.eql(u8, name, cast) and args.len > 0) {
                return places(c, flow, function, args[args.len - 1], out);
            };
            try addPlace(c, out, .unknown);
        },
        else => {
            var buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullArrayInit(&buffer, target)) |vector| {
                // A vector of buffers: each one it names, by address, part or pointer.
                for (vector.ast.elements) |element| switch (formAt(tree, element)) {
                    .address_of, .slice => try places(c, flow, function, element, out),
                    else => if (try pointing(c, f.file, element)) try places(c, flow, function, element, out),
                };
                return;
            }
            if (try resolveCall(c, flow, f.file, target)) |callee| return resultPlaces(c, flow, function, callee, out);
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
fn resultPlaces(c: *Context, flow: *Flow, function: Function.Id, callee: Callee, out: *std.ArrayList(Place)) Context.Error!void {
    const f = flow.functions.items[@backingInt(function)];
    switch (callee.kind) {
        .program => |target| {
            const g = flow.functions.items[@backingInt(target)];
            for (callee.args, 0..) |arg, position| {
                if (g.returned.has(position)) try places(c, flow, function, arg, out);
            }
            for (g.returned_globals.items) |global| try addPlace(c, out, .{ .global = global });
        },
        // A method's receiver, held by value or not, holds the memory it may give a pointer into
        // (`list.addOne()`).
        .outside, .source, .aegis, .holder => for (callee.args) |arg| {
            if (callee.receiver == arg or try pointing(c, f.file, arg)) try places(c, flow, function, arg, out);
        },
        .choice => |each| for (each) |one| try resultPlaces(c, flow, function, one, out),
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

/// Whether a value handed to a call may hand on a pointer: a pointer itself, or a value
/// whose type holds one in a field, through its fields' types (`.{ .n = &n }`); a typeless
/// literal or a type that does not resolve may.
fn handsPointer(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    if (try pointing(c, file, node)) return true;
    return holdsPointer(c, try c.facts.resolve(file, node), 0);
}

fn holdsPointer(c: *Context, value: Facts.Value, depth: usize) Context.Error!bool {
    // A type nested this deep is read as one that may.
    if (depth > 8) return true;
    switch (value) {
        .pointer, .unknown, .reified, .literal => return true,
        .optional, .error_union, .array => |inner| return holdsPointer(c, inner.*, depth + 1),
        .alternatives => |each| {
            for (each) |one| if (try holdsPointer(c, one, depth + 1)) return true;
            return false;
        },
        .instance => |k| {
            for (try fieldsOf(c, k)) |field| if (try holdsPointer(c, try c.facts.declaration(field), depth + 1)) return true;
            return false;
        },
        else => return false,
    }
}

/// The fields `@field(holder, name)` names: the one a string literal spells, or each field of
/// the holder's type for a name computed as the program compiles.
pub fn namedFields(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error![]const Facts.Decl {
    const tree = &c.project.at(file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len != 2) return &.{};
    var out: std.ArrayList(Facts.Decl) = .empty;
    for (try heldContainers(c, try c.facts.resolve(file, args[0]))) |container| {
        // The one field its name spells (`Facts.fieldName`); any other, each of them.
        switch (try c.facts.fieldName(file, args[1])) {
            .name => |text| {
                const decl = c.facts.member(container, text) orelse continue;
                if (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind != .field) continue;
                try out.append(c.allocator, decl);
            },
            else => try out.appendSlice(c.allocator, try fieldsOf(c, container)),
        }
    }
    return out.items;
}

/// The containers a value's type is, behind pointers and optionals: each part's, of a choice. A
/// part that is no container gives none.
fn heldContainers(c: *Context, value: Facts.Value) Context.Error![]const Facts.Container {
    var out: std.ArrayList(Facts.Container) = .empty;
    try gatherContainers(c, value, &out);
    return out.items;
}

fn gatherContainers(c: *Context, value: Facts.Value, out: *std.ArrayList(Facts.Container)) Context.Error!void {
    switch (value) {
        .pointer => |inner| try gatherContainers(c, inner.child.*, out),
        .optional => |inner| try gatherContainers(c, inner.*, out),
        .instance, .container => |k| try out.append(c.allocator, k),
        .alternatives => |each| for (each) |part| try gatherContainers(c, part, out),
        else => {},
    }
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

/// The store at `node` of `value` into `target`, which `given` gives where one expression
/// does: each of the target's `places`, and the fields of the memory it writes through a
/// pointer as a whole value or as bytes (`Facts.accesses.fieldsThrough`: `h.* = v`,
/// `@memcpy(std.mem.asBytes(h), bytes)`, `std.mem.asBytes(c.h)[0] = b`), which the place's
/// other names read.
fn storeAt(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index, target: Ast.Node.Index, given: ?Ast.Node.Index, value: Dep) Context.Error!void {
    const f = flow.functions.items[@backingInt(function)];
    var found: std.ArrayList(Place) = .empty;
    try places(c, flow, function, target, &found);
    for (found.items) |place| try raise(c, flow, function, place, value);
    // Code outside the program writes the program's fields only through what its callers hand
    // it, which their stores raise: its own stores raise none of them (bay, 2c).
    if (!flow.own(f.file)) return;
    try raiseFields(c, flow, function, try Facts.accesses.fieldsThrough(c.facts, f.file, node), given, value);
}

/// What a call writes through `arg`, an argument it is handed: each of its `places`, and the
/// fields of the memory it reaches through a pointer or as another type
/// (`Facts.accesses.fieldsHanded`: `r.readSliceAll(std.mem.asBytes(h))`). The program's own
/// callee names the fields it writes of memory of their own type in its body, which raises
/// them there: at its call only memory it reads as another type is (`put(std.mem.asBytes(h))`).
fn storeHanded(c: *Context, flow: *Flow, function: Function.Id, callee: Callee, arg: Ast.Node.Index, value: Dep) Context.Error!void {
    const f = flow.functions.items[@backingInt(function)];
    var found: std.ArrayList(Place) = .empty;
    try places(c, flow, function, arg, &found);
    for (found.items) |place| try raise(c, flow, function, place, value);
    if (!flow.own(f.file)) return;
    if (callee.kind == .program and !try Facts.accesses.reinterprets(c.facts, f.file, arg)) return;
    try raiseFields(c, flow, function, try Facts.accesses.fieldsHanded(c.facts, f.file, arg), null, value);
}

/// `value` into each of the program's `fields` a store writes whole. A struct literal of a
/// known type (`given`) gives its own type's fields each its own where it is made; any other
/// memory it covers (through a cast: `w.* = .{ .tag = b }` with `w = @ptrCast(h)`) takes what
/// all its parts hold.
fn raiseFields(c: *Context, flow: *Flow, function: Function.Id, fields: []const Facts.Decl, given: ?Ast.Node.Index, value: Dep) Context.Error!void {
    if (fields.len == 0) return;
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    var parts = value;
    var made: ?Facts.Container = null;
    if (given) |one| {
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullStructInit(&buffer, one)) |literal| {
            switch (try c.facts.resolve(f.file, one)) {
                .instance => |k| made = k,
                // No one type: each field takes what all its parts hold.
                .alternatives => {},
                else => {},
            }
            for (literal.ast.fields) |part| parts = try parts.join(c.allocator, try dep(c, flow, function, part));
        }
    }
    for (fields) |field| {
        if (!flow.own(field.file)) continue;
        if (made) |k| if (k.file == field.file and k.scope == c.project.at(field.file).model.declarations[@backingInt(field.index)].scope) continue;
        try raise(c, flow, function, .{ .global = field }, parts);
    }
}

/// `value` into one place, read in `function`.
fn raise(c: *Context, flow: *Flow, function: Function.Id, place: Place, value: Dep) Context.Error!void {
    const f = flow.functions.items[@backingInt(function)];
    switch (place) {
        .local => |d| try raiseLocal(c, flow, .{ .file = f.file, .index = d }, value),
        .param => |index| {
            // Joined on the caller's memory (a round's), kept on the run's only where it changed.
            const now = try f.writes[index].join(c.allocator, value.within(try slotGate(c, flow, f, valueSlot(index))));
            if (!now.eql(f.writes[index])) {
                f.writes[index] = try now.kept(c.facts.gpa);
                flow.changed = true;
            }
        },
        .global => |decl| try raiseGlobal(c, flow, decl, concrete(flow, function, value), concreteLength(flow, function, value)),
        .unknown => {
            const level = flow.unnamed.join(concrete(flow, function, value));
            const length = flow.unnamed_length.join(concreteLength(flow, function, value));
            if (!level.eql(flow.unnamed) or !length.eql(flow.unnamed_length)) flow.changed = true;
            flow.unnamed = level;
            flow.unnamed_length = length;
        },
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
fn effects(c: *Context, flow: *Flow, function: Function.Id, callee: Callee) Context.Error!void {
    const f = flow.functions.items[@backingInt(function)];
    const node = callee.node;
    switch (callee.kind) {
        .program => |target| {
            const g = flow.functions.items[@backingInt(target)];
            for (callee.args, 0..) |arg, index| {
                if (index >= g.params.len) break;
                if (g.fixed.has(index)) continue;
                const given = try passed(c, flow, function, arg, try dep(c, flow, function, arg));
                for ([_]struct { usize, Levels }{ .{ valueSlot(index), concrete(flow, function, given) }, .{ lengthSlot(index), concreteLength(flow, function, given) } }) |each| {
                    const slot, const given_level = each;
                    const level = given_level.gated(try slotGate(c, flow, g, slot));
                    if (slot >= g.levels.len) continue;
                    if (!level.join(g.levels[slot]).eql(g.levels[slot])) {
                        flow.functions.items[@backingInt(target)].levels[slot] = level.join(g.levels[slot]);
                        flow.changed = true;
                    }
                }
                // What it writes through the argument, under the call's control: a write of the
                // program's own value made where input decides is input's.
                const ruled = try control(c, flow, function, node, arg);
                if (!g.writes[index].clean()) try storeHanded(c, flow, function, callee, arg, try (try summarized(c, flow, function, callee, g.writes[index])).join(c.allocator, ruled)) else if (!ruled.clean() and try pointing(c, f.file, arg)) try storeHanded(c, flow, function, callee, arg, ruled);
            }
        },
        .source => {
            const lanes = try readLanes(c, flow, function, callee.receiver);
            if (lanes == none) return;
            const buffers = try bufferParams(c, callee.decl.?);
            for (callee.args, 0..) |arg, position| if (buffers.has(position)) try fill(c, flow, function, callee, arg, lanes);
        },
        .outside => try outsideWrites(c, flow, function, callee),
        // aegis's functions but its parse are code outside the program as std's are: a
        // bounded array appended to and popped from, an owner taken from.
        .aegis => {
            try parsed(c, flow, f.file, callee.params, callee.decl.?);
            try outsideWrites(c, flow, function, callee);
        },
        .choice => |each| for (each) |one| try effects(c, flow, function, one),
        // A call that does not resolve may write anything into the memory it is given, by a
        // pointer or through one a value it is given holds (`.{ .n = &n }`, a tuple).
        // A writer that reaches a peer it may store only where its type may hold one
        // (`writerHold`): no `*Context` of the program's own becomes a peer's writer.
        .none => for (callee.args) |arg| {
            if (!try handsPointer(c, f.file, arg)) continue;
            const value = try c.facts.resolve(f.file, arg);
            try storeHanded(c, flow, function, callee, arg, try unknownInto(c, flow, value));
            // A pointer the value holds in a field of the program's own type is the field's by
            // its declaration (`Out.n`), which the memory it points at takes in turn.
            for ((try wholeFields(c, value)) orelse &.{}) |field| {
                const held = try c.facts.declaration(field);
                if (flow.own(field.file) and try holdsPointer(c, held, 0)) try raise(c, flow, function, .{ .global = field }, try unknownInto(c, flow, held));
            }
        },
        .holder => try outsideWrites(c, flow, function, callee),
    }
}

/// Whether `node` is one of aegis's limits, budgets or reservations, or a pointer to one.
fn accounting(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    var value = try c.facts.resolve(file, node);
    if (value == .pointer) value = value.pointer.child.*;
    const role = (try c.role(Contract.library, value)) orelse return false;
    return switch (role) {
        .limit, .budget, .reservation => true,
        else => false,
    };
}

/// What a function outside the program is given may go into any memory it is given by a
/// mutable pointer: a list appended to, a map put into, a hasher updated, a writer written
/// to, a destination copied into.
fn outsideWrites(c: *Context, flow: *Flow, function: Function.Id, callee: Callee) Context.Error!void {
    const decl = callee.decl orelse return;
    var given: Dep = .{};
    for (callee.args) |arg| given = try given.join(c.allocator, try passed(c, flow, function, arg, try whole(c, flow, function, arg)));
    const writes = try mutableParams(c, decl);
    const file = flow.functions.items[@backingInt(function)].file;
    for (callee.args, 0..) |arg, position| if (writes.has(position)) {
        // aegis's own accounting (a limit, a budget, a reservation) holds counts it checks,
        // not the program's data: its bound is its capacity, whatever is charged against it.
        if (callee.kind == .aegis and try accounting(c, file, arg)) continue;
        const value = try given.join(c.allocator, try control(c, flow, function, callee.node, arg));
        if (!value.clean()) try storeHanded(c, flow, function, callee, arg, value);
    };
}

/// `Untrusted.parse(context, parser)` calls the program's `parser(context, value)` with the
/// peer's value: the parser reads input, and its own checks are read as any reader's are. Only
/// what it returns, the refined result, is clean.
fn parsed(c: *Context, flow: *Flow, file: Project.FileId, params: []const Ast.Node.Index, decl: Facts.Decl) Context.Error!void {
    const target = (try parserOf(c, flow, file, params, decl)) orelse return;
    const levels = flow.functions.items[@backingInt(target)].levels;
    const value = valueSlot(1);
    const given: Levels = .in(flow.masks.input(), .data);
    if (levels.len <= value or levels[value].join(given).eql(levels[value])) return;
    levels[value] = levels[value].join(given);
    flow.changed = true;
}

/// The program's function an `Untrusted.parse(context, parser)` call hands its value to.
fn parserOf(c: *Context, flow: *Flow, file: Project.FileId, params: []const Ast.Node.Index, decl: Facts.Decl) Context.Error!?Function.Id {
    const origin = ((try c.facts.origin(decl)).orNull()) orelse decl;
    if (params.len == 0 or try c.role(Contract.library, .{ .function = origin }) != .parse) return null;
    const parser = switch (try c.facts.resolve(file, params[params.len - 1])) {
        .function => |function| function,
        .alternatives => return null,
        else => return null,
    };
    return flow.by_node.get(.{ .file = parser.file, .node = fnDecl(c, parser) orelse return null });
}

/// Whether a function outside the program may write through the argument `arg` of a call of
/// it: one whose parameter is a mutable pointer or of a type the declaration does not spell
/// (`mutableParams`), or one whose callee does not resolve.
fn writable(c: *Context, callee: Callee, arg: Ast.Node.Index) Context.Error!bool {
    const decl = callee.decl orelse return true;
    const position = std.mem.findScalar(Ast.Node.Index, callee.args, arg) orelse return true;
    return (try mutableParams(c, decl)).has(position);
}

/// The parameters a function may write through, by position, the receiver first: each one a
/// mutable pointer or slice (`*List`, `[]u8`), or of a type the declaration does not spell
/// (`anytype`). An allocator's `print` takes its receiver by value and writes nothing of it.
fn mutableParams(c: *Context, decl: Facts.Decl) Context.Error!Slots {
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return .{};
    var out: Slots = .{};
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        const kind = param.type_expr orelse {
            out = try out.with(c.allocator, position);
            continue;
        };
        var at = kind;
        if (formAt(tree, at) == .optional_type) at = tree.nodeData(at).node;
        const pointer = tree.fullPtrType(at) orelse continue;
        if (pointer.const_token == null) out = try out.with(c.allocator, position);
    }
    return out;
}

/// The parameters a read writes its bytes into, by position, the receiver first: a mutable
/// byte slice (`[]u8`) or a list of them (`[][]u8`, `[]const []u8`). What else a read is given
/// (a path, an allocator, a limit) it does not fill.
fn bufferParams(c: *Context, decl: Facts.Decl) Context.Error!Slots {
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return .{};
    var out: Slots = .{};
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        const kind = param.type_expr orelse continue;
        const spelled = tree.getNodeSource(kind);
        for ([_][]const u8{ "[]u8", "[][]u8", "[]const []u8" }) |filled| if (std.mem.eql(u8, spelled, filled)) {
            out = try out.with(c.allocator, position);
        };
    }
    return out;
}

/// A read fills `arg`'s memory with input in `lanes`: each place a store into it reaches, a
/// vector's buffers among them, and a parameter's memory in its callers.
fn fill(c: *Context, flow: *Flow, function: Function.Id, callee: Callee, arg: Ast.Node.Index, lanes: Mask) Context.Error!void {
    try storeHanded(c, flow, function, callee, arg, .{ .level = .in(lanes, .data) });
}

/// A dependence read as a level, with what callers give the function's parameters.
fn concrete(flow: *const Flow, function: Function.Id, value: Dep) Levels {
    var level = value.level;
    const f = flow.functions.items[@backingInt(function)];
    for (f.levels, 0..) |given, index| {
        if (value.params.has(index)) level = level.join(given);
        if (value.numbers.has(index)) level = level.join(given.masked(@bitCast(given.v == Levels.all(.data).v)).widened());
        if (value.ranged.has(index)) level = level.join(given.narrowed());
        if (value.maybe.has(index)) level = level.join(given.lowered());
        if (value.ruled.has(index)) level = level.join(given.narrowed().masked(flow.masks.control));
        if (value.counted.has(index)) level = level.join(given.masked(flow.masks.control));
        if (value.counted_numbers.has(index)) level = level.join(given.widened().masked(flow.masks.control));
    }
    return level.gated(.{ .lanes = value.lanes, .capped = value.capped });
}

/// The level of a dependence's length, with what callers give the function's parameters.
fn concreteLength(flow: *const Flow, function: Function.Id, value: Dep) Levels {
    return concrete(flow, function, value.measured());
}

const Callee = struct {
    /// `holder`: a method of an aegis owner or loan (`own.Owned`, `own.OwnedIo`, `own.Lent`).
    /// `choice`: one of several, each known (a function pointer's every store), read as each.
    kind: union(enum) { program: Function.Id, source, outside, aegis, holder, choice: []const Callee, none },
    /// The call: `f(a)`'s node, or `@call`'s.
    node: Ast.Node.Index,
    /// What it calls, as written: `f(a)`'s `f`, `@call`'s second argument.
    callee_expr: Ast.Node.Index,
    /// What the call passes in its callee's parameter order, a bound receiver first; for one
    /// whose parameters' arguments are not known, everything it is written with.
    args: []const Ast.Node.Index = &.{},
    /// The arguments as written, a bound receiver not among them: `f(a)`'s, `@call`'s tuple's.
    params: []const Ast.Node.Index = &.{},
    /// The value `x.f(a)` binds as `f`'s first parameter.
    receiver: ?Ast.Node.Index = null,
    decl: ?Facts.Decl = null,
    /// It gives a writer whose bytes reach a peer: `net.Stream.writer`, or a function the
    /// configuration declares one, wherever it is declared, the program's own among them.
    writer: bool = false,
};

/// What a call reaches, as `Facts.calls` reads it: the program's own function, a read, another
/// function outside the program, aegis, a choice of them, or nothing that resolves (a callee
/// that may be any, or arguments whose parameters are not known). Null where `node` makes no
/// call. Read once per call: what it reaches stays as the flow's functions are.
fn resolveCall(c: *Context, flow: *Flow, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Callee {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const key: Facts.Key = .{ .file = file, .node = node };
    if (flow.callees.get(key)) |known_callee| return known_callee;
    const call = (try instanceCall(c, flow, file, node)) orelse return null;
    var out: Callee = .{ .kind = .none, .node = node, .callee_expr = call.callee_expr };
    switch (call.args) {
        .known => |args| {
            out.args = args;
            if (call.receiver == .bound) out.receiver = call.receiver.bound;
            out.params = if (out.receiver != null) args[1..] else args;
            switch (call.callee) {
                .function => |decl| try into(c, flow, decl, &out),
                .choice => |decls| {
                    const each = try c.allocator.alloc(Callee, decls.len);
                    for (decls, each) |decl, *one| {
                        one.* = out;
                        try into(c, flow, decl, one);
                        out.writer = out.writer or one.writer;
                    }
                    out.kind = .{ .choice = each };
                },
                .any => {},
            }
        },
        // Which parameter takes which argument is not known: everything the call is written
        // with goes to a callee read as none.
        .unknown => {
            out.args = try written(c, file, node);
            out.params = out.args;
        },
    }
    try flow.callees.put(c.allocator, key, out);
    return out;
}

/// The call `node` in `file` makes, as `Facts.calls` reads it in the readings a summary reads
/// its function with (`Function.readings`): where every instantiation's reading leaves its
/// callee or its arguments unknown, each reading's callee, the choice of them, where every one
/// is known and binds its arguments alike. Otherwise every instantiation's.
fn instanceCall(c: *Context, flow: *Flow, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Facts.calls.Call {
    const call = (try Facts.calls.at(c.facts, file, node)) orelse return null;
    if (call.callee != .any and call.args == .known) return call;
    const function = owner(flow, file, node) orelse return call;
    const f = flow.functions.items[@backingInt(function)];
    if (f.every_reading or f.readings.items.len == 0) return call;
    var decls: std.ArrayList(Facts.Decl) = .empty;
    var merged: ?Facts.calls.Call = null;
    for (f.readings.items) |env| {
        const one = (try Facts.calls.under(c.facts, env, file, node)) orelse return call;
        if (one.args != .known) return call;
        switch (one.callee) {
            .function => |decl| try addDecl(c, &decls, decl),
            .choice => |each| for (each) |decl| try addDecl(c, &decls, decl),
            .any => return call,
        }
        if (merged) |first| {
            if (std.meta.activeTag(first.receiver) != std.meta.activeTag(one.receiver) or first.args.known.len != one.args.known.len) return call;
        } else merged = one;
    }
    var out = merged.?; // unreachable: a function read in a reading has at least one
    out.callee = if (decls.items.len == 1) .{ .function = decls.items[0] } else .{ .choice = decls.items };
    return out;
}

fn addDecl(c: *Context, decls: *std.ArrayList(Facts.Decl), decl: Facts.Decl) Context.Error!void {
    for (decls.items) |seen| if (std.meta.eql(seen, decl)) return;
    try decls.append(c.allocator, decl);
}
/// What a call whose arguments' parameters are not known is written with: the holder of
/// `x.f(a)` and its arguments, or `@call`'s tuple.
fn written(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error![]const Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&buffer, node)) |call| {
        const field = formAt(tree, call.ast.fn_expr) == .member;
        const holder = [1]Ast.Node.Index{if (field) tree.nodeData(call.ast.fn_expr).node_and_token[0] else call.ast.fn_expr};
        return std.mem.concat(c.allocator, Ast.Node.Index, &.{ holder[0..@intFromBool(field)], call.ast.params });
    }
    var given_buffer: [2]Ast.Node.Index = undefined;
    const given = Facts.builtinArgs(tree, node, &given_buffer);
    return c.allocator.dupe(Ast.Node.Index, given[@min(2, given.len)..]);
}

/// What calling `decl` reaches, into `out`.
fn into(c: *Context, flow: *Flow, decl: Facts.Decl, out: *Callee) Context.Error!void {
    out.decl = decl;
    if (flow.program.aegis_files.contains(@backingInt(decl.file))) {
        // aegis's whole-file reads give a file's bytes, as std's do.
        const origin = ((try c.facts.origin(decl)).orNull()) orelse decl;
        for (flow.reads.items) |read| if (std.meta.eql(read, origin)) {
            out.kind = .source;
            return;
        };
        // An owner or a loan holds what it is given, no answer to input: a handle the program
        // opened from input is as much input's wrapped as it was bare.
        const container: Facts.Value = .{ .container = .{ .file = origin.file, .scope = c.project.at(origin.file).model.declarations[@backingInt(origin.index)].scope } };
        const role = try c.role(Contract.library, container);
        // What an `input.Untrusted` hands its parser is the peer's value itself: only what the
        // parser makes of it is the answer to input.
        if (try c.role(Contract.library, .{ .function = origin }) == .peer_value) {
            out.kind = .source;
            return;
        }
        out.kind = if (role) |k| switch (k) {
            .owned, .lent => .holder,
            else => .aegis,
        } else .aegis;
        return;
    }
    const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    // A writer the configuration declares a peer's is one wherever it is declared, the
    // program's own among them: the declaration says where its bytes go, not its body.
    for (flow.peer_writers.items) |writer| if (std.meta.eql(writer, decl)) {
        out.writer = true;
    };
    if (flow.stream) |stream| if (memberIs(c, stream, "writer", decl)) {
        out.writer = true;
    };
    if (flow.by_node.get(.{ .file = decl.file, .node = fnDecl(c, decl) orelse record.node })) |target| {
        out.kind = .{ .program = target };
        return;
    }
    // A function of the program the fact does not read (one in a file whose rules read no
    // fact) gives what it does unread: undecided.
    if (flow.own(decl.file)) return;
    out.kind = if (try source(c, flow, decl)) .source else .outside;
}

/// The `fn_decl` node of a function declaration.
fn fnDecl(c: *Context, decl: Facts.Decl) ?Ast.Node.Index {
    const model = &c.project.at(decl.file).model;
    const tree = &c.project.at(decl.file).file.tree;
    const parent = model.parentOf(model.declarations[@backingInt(decl.index)].node) orelse return null;
    return if (tree.nodeTag(parent) == .fn_decl) parent else null;
}

/// std's `Io.Reader` functions that hand over nothing a peer sent: its plumbing, and what moves
/// or discards bytes without giving them. Every other function of the type reads as a read, so
/// one a new Zig adds is input until it is named here, never clean.
const reader_no_reads = [_][]const u8{ "Hashed", "defaultDiscard", "defaultReadVec", "defaultRebase", "discard", "discardAll", "discardAll64", "discardDelimiterExclusive", "discardDelimiterInclusive", "discardDelimiterLimit", "discardRemaining", "discardShort", "fill", "fillMore", "fixed", "hashed", "limited", "rebase", "stream", "streamDelimiter", "streamDelimiterEnding", "streamDelimiterLimit", "streamExact", "streamExact64", "streamExactPreserve", "streamRemaining", "toss", "tossBuffered", "writableVector", "writableVectorPosix", "writableVectorWsa" };

/// std's `Io.Reader` reads that give bytes, no number decoded from them. Every other read decodes
/// (`decodes`), so one a new Zig adds is a peer's number until it is named here.
const reader_byte_reads = [_][]const u8{ "allocRemaining", "allocRemainingAlignedSentinel", "appendExact", "appendRemaining", "appendRemainingAligned", "appendRemainingUnlimited", "buffered", "bufferedLen", "peek", "peekArray", "peekByte", "peekDelimiterExclusive", "peekDelimiterInclusive", "peekGreedy", "peekSentinel", "peekStruct", "peekStructPointer", "readAllocAll", "readAllocShort", "readSliceAll", "readSliceEndian", "readSliceEndianAlloc", "readSliceShort", "readVec", "readVecAll", "take", "takeArray", "takeByte", "takeByteSigned", "takeDelimiter", "takeDelimiterExclusive", "takeDelimiterInclusive", "takeSentinel", "takeStruct", "takeStructPointer" };

/// std's decoders outside `Io.Reader`, by path. A row below holds this list to the std glint is
/// built with: a new one fails the build's tests rather than reading as no decoder.
const std_decoders = [_][]const u8{ "fmt.parseInt", "fmt.parseIntSizeSuffix", "fmt.parseIntWithGenericCharacter", "fmt.parseUnsigned", "mem.readInt", "mem.readPackedInt", "mem.readVarInt" };

/// Whether `decl` is a function `holder` declares itself (a nested type's is not).
fn declaredIn(c: *Context, holder: Facts.Container, decl: Facts.Decl) bool {
    const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    return decl.file == holder.file and record.scope == holder.scope and record.kind == .function;
}

/// Whether `decl` is a read of std's `Io.Reader`: any function of it but `reader_no_reads`.
fn readerRead(c: *Context, flow: *const Flow, decl: Facts.Decl) bool {
    const reader = flow.reader orelse return false;
    if (!declaredIn(c, reader, decl)) return false;
    for (reader_no_reads) |each| if (memberIs(c, reader, each, decl)) return false;
    return true;
}

/// Whether `decl` is the member `name` of the container `holder`, by its declaration.
fn memberIs(c: *Context, holder: Facts.Container, name: []const u8, decl: Facts.Decl) bool {
    const member = c.facts.member(holder, name) orelse return false;
    return std.meta.eql(member, decl);
}

/// Whether a function outside the program reads a peer's input.
fn source(c: *Context, flow: *Flow, decl: Facts.Decl) Context.Error!bool {
    for (flow.reads.items) |read| if (std.meta.eql(read, decl)) return true;
    if (readerRead(c, flow, decl)) return true;
    if (flow.file) |handle| for ([_][]const u8{ "readStreaming", "readPositional", "readPositionalAll" }) |read| if (memberIs(c, handle, read, decl)) return true;
    if (flow.dir) |dir| for ([_][]const u8{ "readFile", "readFileAlloc", "readFileAllocOptions", "readLink" }) |read| if (memberIs(c, dir, read, decl)) return true;
    return false;
}

/// The lanes a read from the reader `receiver` (a read's, or a reader whose `buffer` is read)
/// reads a peer's input in: every peer lane, but where the reader is one std's `Reader.fixed`
/// made over bytes clean in that lane (`fixedBytes`), whose read carries the bytes' fact, not
/// input's.
fn readLanes(c: *Context, flow: *Flow, function: Function.Id, reader: ?Ast.Node.Index) Context.Error!Mask {
    const f = flow.functions.items[@backingInt(function)];
    const receiver = reader orelse return flow.masks.peer;
    const bytes = (try fixedBytes(c, flow, f.file, receiver)) orelse return flow.masks.peer;
    return flow.masks.peer & lanesOf(concrete(flow, function, try dep(c, flow, function, bytes)));
}

/// The lanes a level is other than clean in.
fn lanesOf(levels: Levels) Mask {
    return @bitCast(levels.v != Levels.clean.v);
}

/// Whether some lane is at `level`.
fn anyAt(levels: Levels, level: Level) bool {
    return @reduce(.Or, levels.v == Levels.all(level).v);
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
    const function = owner(flow, file, receiver) orelse return null;
    const d = (nameRef(model, receiver) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(d)];
    if (record.kind != .variable or owner(flow, file, record.node) != function) return null;
    const variable = tree.fullVarDecl(record.node) orelse return null;
    const init = variable.ast.init_node.unwrap() orelse return null;
    var buffer: [1]Ast.Node.Index = undefined;
    const made = tree.fullCall(&buffer, init) orelse return null;
    if (made.ast.params.len != 1) return null;
    const fixed = c.facts.member(reader, "fixed") orelse return null;
    // By the function it calls, a decl literal's (`.fixed(bytes)`) by the type it is given.
    const making = (try Facts.calls.at(c.facts, file, init)) orelse return null;
    const by_std = switch (making.callee) {
        .function => |decl| std.meta.eql(((try c.facts.origin(decl)).orNull()) orelse decl, fixed),
        .choice, .any => false,
    };
    if (!by_std) return null;
    for (flow.functions.items[@backingInt(function)].nodes) |node| {
        switch (formAt(tree, node)) {
            .assign, .compound_assign => {
                if (rootDecl(model, tree, tree.nodeData(node).node_and_node[0]) == d) return null;
            },
            .destructure => for (tree.assignDestructure(node).ast.variables) |each| {
                if (rootDecl(model, tree, each) == d) return null;
            },
            .address_of => {
                if (rootDecl(model, tree, tree.nodeData(node).node) != d) continue;
                // An address discarded (`_ = &rd;`) reaches nothing.
                const parent = model.parentOf(node) orelse return null;
                if (formAt(tree, parent) != .assign) return null;
                const target, const value = tree.nodeData(parent).node_and_node;
                if (value != node or !discards(tree, target)) return null;
            },
            else => {},
        }
    }
    return made.ast.params[0];
}

/// Whether `value` adds to, multiplies or shifts the local `target` names: an assignment that
/// grows it.
fn accumulates(tree: *const Ast, model: *const Model, target: Ast.Node.Index, value: Ast.Node.Index) bool {
    const declared = (nameRef(model, target) orelse return false).declaration orelse return false;
    const first = tree.firstToken(value);
    const last = tree.lastToken(value);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (accesses.formOf(tag) != .operator) continue;
        const operator = accesses.operatorOf(tag) orelse continue;
        if (operator.op != .mul and operator.op != .shl and operator.op != .add) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        for ([_]Ast.Node.Index{ lhs, rhs }) |operand| {
            const ref = nameRef(model, operand) orelse continue;
            if (ref.declaration == declared) return true;
        }
    }
    return false;
}

/// What an expression holds, read in `function`.
fn dep(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    switch (formAt(tree, node)) {
        .leaf => {
            if (spellsName(tree, node)) return declaredDep(c, flow, function, node);
            // An error is its text: what `@errorName` and a format's `{t}` make bytes of.
            if (try c.facts.literalOf(f.file, node)) |spelled| if (spelled == .error_value) return errorText(flow);
        },
        .member => return fieldDep(c, flow, function, node),
        .array_access => return dep(c, flow, function, tree.nodeData(node).node_and_node[0]),
        // A slice holds what it slices, in a length its bounds set: past its start to its end,
        // or to the end of what it slices.
        .slice => {
            const slice = tree.fullSlice(node) orelse return .{};
            const memory = try dep(c, flow, function, slice.ast.sliced);
            var out = try memory.held().join(c.allocator, try (try dep(c, flow, function, slice.ast.start)).sizing(c.allocator));
            if (slice.ast.end.unwrap()) |end| {
                out = try out.join(c.allocator, try (try dep(c, flow, function, end)).sizing(c.allocator));
            } else out = try out.join(c.allocator, memory.lengthOnly());
            return out;
        },
        .grouped, .unwrap_optional => return dep(c, flow, function, tree.nodeData(node).node_and_token[0]),
        .deref, .address_of, .tried => return dep(c, flow, function, tree.nodeData(node).node),
        .operator => {
            if (accesses.unaryOf(tree.nodeTag(node)) != null) return dep(c, flow, function, tree.nodeData(node).node);
            const operator = accesses.operatorOf(tree.nodeTag(node)).?; // unreachable: an operator on two is `operatorOf`'s
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            switch (operator.op) {
                // What is left of a length (`buf.len - at`) is bounded by it.
                .sub => if (operator.overflow != .wrapping) {
                    const out = try (try dep(c, flow, function, lhs)).join(c.allocator, try dep(c, flow, function, rhs));
                    return if (try c.facts.memoryField(f.file, lhs) != .field) try out.narrowed(c.allocator) else out;
                },
                // A mask or a remainder by the program's own value is bounded by it, a peer's
                // value within that range: data.
                .bit_and, .mod => {
                    const left = try dep(c, flow, function, lhs);
                    const right = try dep(c, flow, function, rhs);
                    if (left.clean() or right.clean()) return try (try left.join(c.allocator, right)).narrowed(c.allocator);
                    return try left.join(c.allocator, right);
                },
                // Bytes shifted into place assemble a number; a clean value shifted by data is a
                // mask.
                .shl => {
                    const shifted = try (try dep(c, flow, function, lhs)).widened(c.allocator);
                    return shifted.join(c.allocator, try dep(c, flow, function, rhs));
                },
                else => {},
            }
            // Wrapping arithmetic stays in its type's range, which is the peer's to choose in a
            // wide type: a sink reads it as data only where the result is shown small (a hash
            // shifted to a table's bits).
            return try (try dep(c, flow, function, lhs)).join(c.allocator, try dep(c, flow, function, rhs));
        },
        .concatenation, .@"orelse", .@"catch" => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return try (try dep(c, flow, function, lhs)).join(c.allocator, try dep(c, flow, function, rhs));
        },
        .builtin => return builtinDep(c, flow, function, node),
        .@"if" => {
            const branch = tree.fullIf(node).?;
            // Which branch gives the value is the condition's choice.
            var out = try (try dep(c, flow, function, branch.ast.cond_expr)).ruling(c.allocator, flow.masks);
            out = try out.join(c.allocator, try dep(c, flow, function, branch.ast.then_expr));
            if (branch.ast.else_expr.unwrap()) |e| out = try out.join(c.allocator, try dep(c, flow, function, e));
            return out;
        },
        .@"switch" => {
            var out = try (try dep(c, flow, function, tree.fullSwitch(node).?.ast.condition)).ruling(c.allocator, flow.masks);
            for (tree.fullSwitch(node).?.ast.cases) |case| out = try out.join(c.allocator, try dep(c, flow, function, (tree.fullSwitchCase(case) orelse continue).ast.target_expr));
            return out;
        },
        .body => {
            var buffer: [2]Ast.Node.Index = undefined;
            if (tree.blockStatements(&buffer, node) != null) return labeled(c, flow, function, node);
        },
        .@"while", .@"for" => return loopValue(c, flow, function, node),
        // A comparison's truth is what it compares chose: a bool, data, for the facts that take
        // what they decide.
        .comparison => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const both = try (try dep(c, flow, function, lhs)).join(c.allocator, try dep(c, flow, function, rhs));
            return both.ruling(c.allocator, flow.masks);
        },
        .logic => switch (Facts.conditionOf(tree, node)) {
            .not => |inner| return try (try dep(c, flow, function, inner)).ruling(c.allocator, flow.masks),
            .both, .either => |sides| {
                const both = try (try dep(c, flow, function, sides[0])).join(c.allocator, try dep(c, flow, function, sides[1]));
                return both.ruling(c.allocator, flow.masks);
            },
            .compare, .other => {},
        },
        else => {},
    }
    if (try literalDep(c, flow, function, node)) |out| return out;
    if (try resolveCall(c, flow, f.file, node)) |callee| return result(c, flow, function, callee);
    return composed(c, flow, function, node);
}

/// What a name holds: a parameter's own slots, a global's facts, a local's; and an error's
/// text where it holds an error, whatever gave it one.
fn declaredDep(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!Dep {
    const out = try namedDep(c, flow, function, node);
    if (flow.masks.error_text == none) return out;
    const file = flow.functions.items[@backingInt(function)].file;
    const ref = c.project.at(file).model.reference(node) orelse return out;
    const d = ref.declaration orelse return out;
    if (!try errorDeclared(c, .{ .file = file, .index = d })) return out;
    return out.join(c.allocator, errorText(flow));
}

fn namedDep(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const model = &c.project.at(f.file).model;
    const ref = model.reference(node) orelse return .{};
    const d = ref.declaration orelse return if (ref.unknown) |why| switch (why) {
        // A primitive (`true`, `u8`) or a name a literal's type gives holds no data.
        .primitive, .literal_context => .{},
        // A name that does not resolve may be anything, memory no place names among it.
        .unresolved, .invalid_lowering, .before_declaration => .{ .level = Levels.all(.unknown).join(unnamed(flow).level), .unchecked = unnamed(flow).unchecked },
    } else .{};
    // A parameter's own length is what its callers measured (`concreteLength`).
    if (f.position(d)) |index| return .{ .params = try .of(c.allocator, valueSlot(index)), .bare = try .of(c.allocator, lengthSlot(index)) };
    const decl = model.declarations[@backingInt(d)];
    if (decl.kind == .variable or decl.kind == .capture) {
        const scope = model.scopes[@backingInt(decl.scope)].kind;
        if (scope == .file or scope == .container) {
            const global: Facts.Decl = .{ .file = f.file, .index = d };
            const own: Dep = .{ .level = flow.globals.get(global) orelse .clean, .unchecked = flow.lengths.get(global) orelse .clean };
            return own.join(c.allocator, try throughUnnamed(c, flow, global));
        }
        return flow.locals.get(.{ .file = f.file, .index = d }) orelse .{};
    }
    return .{};
}

/// What a field holds: its receiver's facts and its declaration's.
fn fieldDep(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const receiver, const name = tree.nodeData(node).node_and_token;
    // An address is no number a peer chooses; a length is one within the memory the program
    // holds: data, which a sink judges against what it reaches.
    if (try c.facts.memoryField(f.file, node) != .field) {
        if (try c.facts.languageField(f.file, node) == .ptr) return .{};
        const memory = try dep(c, flow, function, receiver);
        return try (try memory.held().narrowed(c.allocator)).join(c.allocator, memory.measured());
    }
    var out = try dep(c, flow, function, receiver);
    if ((try c.facts.definition(f.file, node)).orNull()) |decl| {
        // A reader's buffer holds what it read, as `buffered()` gives it.
        if (readerBuffer(c, flow, decl)) out = try out.join(c.allocator, .{ .level = .in(try readLanes(c, flow, function, receiver), .data) });
        if (decl.file == flow.zig_ast) if (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind == .field) {
            const field = c.project.at(decl.file).model.containerField(&c.project.at(decl.file).file.tree, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node).?;
            return treeDep(c, flow, decl.file, field.ast.type_expr.unwrap());
        };
        if (flow.globals.get(decl)) |level| out = try out.join(c.allocator, .{ .level = level });
        if (flow.lengths.get(decl)) |length| out = try out.join(c.allocator, Dep.measuredLength(length));
        out = try out.join(c.allocator, try throughUnnamed(c, flow, decl));
        if (flow.zig_text.contains(decl)) out = try out.join(c.allocator, .{ .level = .in(flow.masks.peer, .data) });
        if (flow.masks.error_text != none and try errorDeclared(c, decl)) out = try out.join(c.allocator, errorText(flow));
        // A function or a type named through a value is no part of its data.
        const kind = c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind;
        if (kind == .function) return .{};
        return out.within(try placeGate(c, flow, decl));
    } else out = try out.join(c.allocator, .{ .level = try alternativeFields(c, flow, f.file, receiver, tree.tokenSlice(name)) });
    return out;
}

/// Whether `decl` is std's reader's `buffer` field: the bytes its reads fill, a peer's where
/// the reader reads one.
fn readerBuffer(c: *Context, flow: *const Flow, decl: Facts.Decl) bool {
    const reader = flow.reader orelse return false;
    return memberIs(c, reader, "buffer", decl);
}

/// What a struct or an array literal holds, or null where `node` is neither.
fn literalDep(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!?Dep {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, node)) |literal| {
        // A literal of the program's own type holds its fields' facts by their declarations,
        // which its stores raise; a tuple, a literal of a type outside the program (whose
        // fields no store raises: `.{ .stack_size = n }`) or one whose type does not resolve
        // holds what it is given. A parser's result holds its numbers itself: clean through
        // the parse, input through a direct call.
        if (try literalFields(c, f.file, node, literal)) |fields| if (flow.own(fields[0].file)) {
            if (!f.parser or !returned(tree, model, node)) return .{};
            var out: Dep = .{};
            for (literal.ast.fields, fields) |value, field| if (try shownField(c, f.file, value, field)) {
                out = try out.join(c.allocator, try dep(c, flow, function, value));
            };
            return out;
        };
        var out: Dep = .{};
        for (literal.ast.fields) |field| out = try out.join(c.allocator, try dep(c, flow, function, field));
        return out;
    }
    if (tree.fullArrayInit(&buffer, node)) |literal| {
        var out: Dep = .{};
        for (literal.ast.elements) |element| out = try out.join(c.allocator, try dep(c, flow, function, element));
        return out;
    }
    return null;
}

/// What a builtin's result holds: nothing for one the program fixes as it compiles (a size, a
/// type, a name), what its operands hold for any other.
fn builtinDep(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!Dep {
    const file = flow.functions.items[@backingInt(function)].file;
    const tree = &c.project.at(file).file.tree;
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    // `@call` is a call as `f(a)` is.
    if (try resolveCall(c, flow, file, node)) |callee| return result(c, flow, function, callee);
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    // An error's name is its text; a tag's name is what chose the tag, an error's text where an
    // error did, and no other fact's (the names are the program's own). An error made from an
    // integer is an error; its integer no text.
    if (std.mem.eql(u8, name, "@errorName") or std.mem.eql(u8, name, "@errorFromInt")) return errorText(flow);
    if (std.mem.eql(u8, name, "@tagName") and args.len == 1) return answered(try dep(c, flow, function, args[0]), ~flow.masks.error_text);
    if (std.mem.eql(u8, name, "@intFromError") and args.len == 1) return answered(try whole(c, flow, function, args[0]), flow.masks.int_from_error & flow.masks.error_text);
    for ([_][]const u8{ "@sizeOf", "@alignOf", "@bitSizeOf", "@TypeOf", "@typeInfo", "@tagName", "@typeName", "@import", "@This", "@src", "@hasDecl", "@hasField" }) |clean| if (std.mem.eql(u8, name, clean)) return .{};
    // A field `@field` names is read by its declaration, as `x.name` is.
    if (std.mem.eql(u8, name, "@field") and args.len == 2) {
        var out = try dep(c, flow, function, args[0]);
        for (try namedFields(c, flow.functions.items[@backingInt(function)].file, node)) |field| {
            out = try (try out.join(c.allocator, .{ .level = flow.globals.get(field) orelse .clean, .unchecked = flow.lengths.get(field) orelse .clean })).join(c.allocator, try throughUnnamed(c, flow, field));
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
        out = try out.join(c.allocator, each);
    }
    // A count of bits, a bool's integer and a least under a clean bound stay in a range
    // the program chose: data, which a sink judges against what it reaches. A
    // truncation keeps the bits its type holds, a peer's choice in a wide one: a sink
    // reads it as data only where the type is shown small.
    for ([_][]const u8{ "@intFromBool", "@ctz", "@clz", "@popCount" }) |count| bounded = bounded or std.mem.eql(u8, name, count);
    if (bounded) return out.narrowed(c.allocator);
    // Bytes reinterpreted put themselves together into numbers, as a copy's do (input's
    // `[4]u8` cast to a `u32` is a peer's count; a pointer cast reads its memory as the new
    // type's).
    // A reinterpretation may make a writer of what held none by its type (a pointer kept as
    // an integer or as bytes, a parent found from its field): unknown in the peer writer's lane.
    const remade: Dep = .{ .level = .in(flow.masks.peer_writer, .unknown) };
    if (std.mem.eql(u8, name, "@fieldParentPtr")) return out.join(c.allocator, remade);
    for ([_][]const u8{ "@bitCast", "@ptrCast" }) |cast| if (std.mem.eql(u8, name, cast)) return (try out.widened(c.allocator)).join(c.allocator, remade);
    // A pointer made from an integer reaches memory no place names.
    if (std.mem.eql(u8, name, "@ptrFromInt")) return (try out.join(c.allocator, unnamed(flow))).join(c.allocator, remade);
    return out;
}

/// An error's text, in the lanes that follow it.
fn errorText(flow: *const Flow) Dep {
    return .{ .level = .in(flow.masks.error_text, .data) };
}

/// Whether a declaration holds an error by its type: a parameter's or a variable's written
/// type, a field's, a capture's (`catch |err|`). A variable with no written type holds what
/// its initializer gives, which the flow reads.
fn errorDeclared(c: *Context, decl: Facts.Decl) Context.Error!bool {
    const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    const tree = &c.project.at(decl.file).file.tree;
    const value: Facts.Value = switch (record.kind) {
        .capture, .field => try c.facts.declaration(decl),
        .parameter => try c.facts.resolve(decl.file, record.node),
        .variable => typed: {
            const variable = tree.fullVarDecl(record.node) orelse return false;
            break :typed try c.facts.resolve(decl.file, variable.ast.type_node.unwrap() orelse return false);
        },
        else => return false,
    };
    return errorIn(value, .declared) == .yes;
}

/// Whether a value of `value`'s type holds an error (`anyerror`, an error set, an optional of
/// one), or, `.written`, may show one's name as it is formatted (an error union too).
fn errorIn(value: Facts.Value, as: enum { declared, written }) enum { no, yes, unknown } {
    return switch (value) {
        .error_set => .yes,
        .primitive => |p| if (std.mem.eql(u8, p, "anyerror")) .yes else .no,
        .optional => |inner| errorIn(inner.*, as),
        // A union's value is its payload's, read where it is unwrapped: only formatted whole
        // does it show the error.
        .error_union => if (as == .written) .yes else .no,
        .unknown => .unknown,
        .alternatives => |each| for (each) |one| {
            if (errorIn(one, as) == .yes) break .yes;
        } else .no,
        else => .no,
    };
}

/// What memory no place names may hold (`Flow.unnamed`). A writer there is one only through what
/// does not resolve (a store through a holder whose type does not, a pointer made from an
/// integer): no writer shown, unknown in the peer writer's lane (`Gate.capped`).
fn unnamed(flow: *const Flow) Dep {
    const held: Dep = .{ .level = flow.unnamed, .unchecked = flow.unnamed_length };
    return held.within(.{ .capped = flow.masks.peer_writer });
}

/// What any other expression holds: what its parts hold (`a ** n`, an `asm`'s inputs, a loop's
/// value), but for one the program fixes as it compiles: a type, a declaration, a `comptime`
/// block, a literal.
fn composed(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    switch (formAt(tree, node)) {
        // What the program computes as it compiles is no input, but an error's text it names
        // is still the error's (`comptime @errorName(error.Full)`).
        .@"comptime" => return answered(try dep(c, flow, function, tree.nodeData(node).node), ~flow.masks.error_text),
        // A declaration or a type holds no value.
        .fn_decl, .prototype, .pointer_type, .array_type, .optional_type, .error_union, .merged_errors, .anyframe_type => return .{},
        // A test or a container, as `dep` reads a block before it comes here.
        .body => return .{},
        .leaf => if (tree.tokenTag(tree.nodeMainToken(node)) == .keyword_error) return .{},
        else => {},
    }
    var out: Dep = .{};
    for (try children(c, f.file, node)) |part| out = try out.join(c.allocator, try dep(c, flow, function, part));
    return out;
}

/// A field read through a value whose type is one of several (a generic's result over each
/// of its instantiations, `Untrusted.parse` over each parser): what the program stores in the
/// field of that name in each of them. Through one whose type does not resolve, unknown, with
/// what memory no place names holds, as a read of memory that does not resolve is.
fn alternativeFields(c: *Context, flow: *Flow, file: Project.FileId, receiver: Ast.Node.Index, name: []const u8) Context.Error!Levels {
    var out: Levels = .clean;
    const value = try c.facts.resolve(file, receiver);
    for (if (value == .alternatives) value.alternatives else &.{value}) |each| {
        var held = each;
        while (true) held = switch (held) {
            .pointer => |inner| inner.child.*,
            .optional, .error_union => |inner| inner.*,
            .alternatives => break,
            else => break,
        };
        const container = switch (held) {
            .container, .instance => |k| k,
            .unknown => |why| {
                if (why != .zig_own and why != .absent) out = out.join(Levels.all(.unknown).join(unnamed(flow).level));
                continue;
            },
            // A pointer to a choice: read as what does not resolve.
            .alternatives => {
                out = out.join(Levels.all(.unknown).join(unnamed(flow).level));
                continue;
            },
            else => continue,
        };
        const decl = c.facts.member(container, name) orelse continue;
        if (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind != .field) continue;
        out = out.join(flow.globals.get(decl) orelse .clean).join((try throughUnnamed(c, flow, decl)).level);
    }
    return out;
}

/// Whether a holder's type does not resolve, itself or behind pointers and optionals: std's own
/// and code the build does not compile are no program's struct.
fn unresolvedHolder(value: Facts.Value) bool {
    var current = value;
    while (true) current = switch (current) {
        .pointer => |inner| inner.child.*,
        .optional, .error_union => |inner| inner.*,
        .unknown => |why| return why != .zig_own and why != .absent,
        // Where any part does not resolve.
        .alternatives => |parts| {
            for (parts) |part| if (unresolvedHolder(part)) return true;
            return false;
        },
        else => return false,
    };
}

/// What a field or a container-level variable `decl` takes from memory no place names
/// (`unnamed`): what every store there put, where Facts.accesses finds a write that may reach
/// it through such memory (a member so spelled on a holder whose type does not resolve, memory
/// that does not resolve); nothing elsewhere. Found once per declaration.
fn throughUnnamed(c: *Context, flow: *Flow, decl: Facts.Decl) Context.Error!Dep {
    if (!try reachedUnnamed(c, flow, decl)) return .{};
    // As the declaration's place keeps it by its type (`placeGate`): memory no place names has
    // no type, so what it holds is a writer there only where the declaration may hold one.
    return unnamed(flow).within(try placeGate(c, flow, decl));
}

fn reachedUnnamed(c: *Context, flow: *Flow, decl: Facts.Decl) Context.Error!bool {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    if (flow.unnamed_reach.get(decl)) |found| return found;
    const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    const place: Facts.accesses.Place = if (record.kind == .field) .{ .field = decl } else .{ .declaration = decl };
    const files = flow.own_files orelse files: {
        var own: std.ArrayList(Project.FileId) = .empty;
        for (c.project.sources) |*each| if (flow.own(each.id)) try own.append(c.allocator, each.id);
        const listed = try own.toOwnedSlice(c.allocator);
        flow.own_files = listed;
        break :files listed;
    };
    var sites = Facts.accesses.writes(c.facts, place, files);
    const through = while (try sites.next()) |site| {
        if (site.kind == .read or site.kind == .init) continue;
        if (site.reach == .named or site.reach == .unresolved) break true;
    } else false;
    try flow.unnamed_reach.put(c.allocator, decl, through);
    return through;
}

/// The field declarations a struct literal's values initialize, in order, when its type
/// resolves and names each of them.
fn literalFields(c: *Context, file: Project.FileId, node: Ast.Node.Index, literal: Ast.full.StructInit) Context.Error!?[]const Facts.Decl {
    if (literal.ast.fields.len == 0) return null;
    var holder = try c.facts.literalType(file, node);
    while (true) holder = switch (holder) {
        .pointer => |inner| inner.child.*,
        .optional, .error_union => |inner| inner.*,
        .alternatives => break,
        else => break,
    };
    const container = switch (holder) {
        .container, .instance => |k| k,
        .alternatives => return null,
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
        switch (formAt(tree, parent)) {
            .@"return" => return true,
            .grouped => {},
            .@"if" => {
                const branch = tree.fullIf(parent).?;
                if (at != branch.ast.then_expr and at.toOptional() != branch.ast.else_expr) return false;
            },
            .prong => if (at != tree.fullSwitchCase(parent).?.ast.target_expr) return false,
            .@"switch" => if (at == tree.fullSwitch(parent).?.ast.condition) return false,
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
    const field = c.project.at(decl.file).model.containerField(tree, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return false;
    const declared = field.ast.type_expr.unwrap() orelse return false;
    if (!spellsName(tree, declared) or !Model.primitive(tree.tokenSlice(tree.nodeMainToken(declared)))) return false;
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
    if (formAt(tree, value) == .grouped) return unrefined(c, flow, function, tree.nodeData(value).node_and_token[0]);
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, value)) |literal| if (try literalFields(c, f.file, value, literal) != null) return;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buffer, tree.nodeData(f.node).node_and_node[0]) orelse return;
    var payload = proto.ast.return_type.unwrap() orelse return;
    if (formAt(tree, payload) == .error_union) payload = tree.nodeData(payload).node_and_node[1];
    // A tuple's numbers are read one by one, each against its field's type; a tuple the parser
    // holds in a value of its own gives every number it holds.
    var container_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_buffer, payload)) |container| {
        var elements_buffer: [2]Ast.Node.Index = undefined;
        const elements: ?[]const Ast.Node.Index = if (tree.fullArrayInit(&elements_buffer, value)) |literal| literal.ast.elements else null;
        var position: usize = 0;
        for (container.ast.members) |member| {
            const field = c.project.at(f.file).model.containerField(tree, member) orelse continue;
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
    if (shown) level = level.narrowed();
    const now = flow.functions.items[@backingInt(function)].unrefined.join(level);
    if (!now.eql(flow.functions.items[@backingInt(function)].unrefined)) {
        flow.functions.items[@backingInt(function)].unrefined = now;
        flow.changed = true;
    }
}

/// A labeled block's value: what its `break`s give it.
fn labeled(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!Dep {
    const tree = &c.project.at(flow.functions.items[@backingInt(function)].file).file.tree;
    const lbrace = tree.nodeMainToken(node);
    if (lbrace < 2 or tree.tokenTag(lbrace - 1) != .colon) return .{};
    return breaksTo(c, flow, function, node);
}

/// A loop's value: which pass ends it is its condition's choice (a `for`'s, its inputs'
/// lengths), and it gives what a `break` that leaves it gives, or its `else`.
fn loopValue(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!Dep {
    const tree = &c.project.at(flow.functions.items[@backingInt(function)].file).file.tree;
    var out = try breaksTo(c, flow, function, node);
    if (tree.fullWhile(node)) |loop| {
        out = try out.join(c.allocator, try (try dep(c, flow, function, loop.ast.cond_expr)).ruling(c.allocator, flow.masks));
        if (loop.ast.else_expr.unwrap()) |e| out = try out.join(c.allocator, try dep(c, flow, function, e));
    } else if (tree.fullFor(node)) |loop| {
        for (loop.ast.inputs) |input| {
            const count = if (tree.nodeTag(input) == .for_range) try composed(c, flow, function, input) else (try dep(c, flow, function, input)).measured();
            out = try out.join(c.allocator, try count.ruling(c.allocator, flow.masks));
        }
        if (loop.ast.else_expr.unwrap()) |e| out = try out.join(c.allocator, try dep(c, flow, function, e));
    }
    return out;
}

/// What the `break`s that leave `target` (a labeled block, a loop) give it, each with the
/// conditions that choose it.
fn breaksTo(c: *Context, flow: *Flow, function: Function.Id, target: Ast.Node.Index) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    var out: Dep = .{};
    const first = tree.firstToken(target);
    const last = tree.lastToken(target);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"break") continue;
        const brk: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(brk);
        if (token < first or token > last) continue;
        if (jumpTarget(tree, model, brk) != target) continue;
        if (tree.nodeData(brk).opt_token_and_opt_node[1].unwrap()) |v| out = try out.join(c.allocator, try dep(c, flow, function, v));
        // Which `break` runs is the conditions' choice.
        out = try out.join(c.allocator, try controlWithin(c, flow, function, brk, target));
    }
    return out;
}

/// A summary of the program's callee (what it returns, or what it stores through a parameter),
/// read at a call with its arguments: an argument's value in its slot, and its length in the
/// length's, each as the summary holds it, as a value or as a length. From the 32nd parameter
/// on the slots are shared (`valueSlot`), each argument read in them.
fn summarized(c: *Context, flow: *Flow, function: Function.Id, callee: Callee, summary: Dep) Context.Error!Dep {
    var out: Dep = .{ .level = summary.level, .length = summary.length, .unchecked = summary.unchecked };
    for (callee.args, 0..) |arg, index| {
        const given = try passed(c, flow, function, arg, try dep(c, flow, function, arg));
        for ([_]struct { usize, Dep }{ .{ valueSlot(index), given }, .{ lengthSlot(index), given.measured() } }) |each| {
            const slot, const held_there = each;
            if (summary.params.has(slot)) out = try out.join(c.allocator, held_there);
            if (summary.numbers.has(slot)) out = try out.join(c.allocator, try held_there.widened(c.allocator));
            if (summary.ranged.has(slot)) out = try out.join(c.allocator, try held_there.narrowed(c.allocator));
            if (summary.maybe.has(slot)) out = try out.join(c.allocator, try held_there.lowered(c.allocator));
            if (summary.lengths.has(slot)) out = try out.join(c.allocator, try held_there.sizing(c.allocator));
            if (summary.bare.has(slot)) out = try out.join(c.allocator, try held_there.written(c.allocator));
            if (summary.bare_numbers.has(slot)) out = try out.join(c.allocator, try (try held_there.widened(c.allocator)).written(c.allocator));
            if (summary.ruled.has(slot)) out = try out.join(c.allocator, try held_there.ruling(c.allocator, flow.masks));
            if (summary.ruled_lengths.has(slot)) out = try out.join(c.allocator, try (try held_there.ruling(c.allocator, flow.masks)).sizing(c.allocator));
            if (summary.counted.has(slot)) out = try out.join(c.allocator, try held_there.counting(c.allocator, flow.masks));
            if (summary.counted_numbers.has(slot)) out = try out.join(c.allocator, try held_there.unbounded(c.allocator, flow.masks));
        }
    }
    return out.within(.{ .lanes = summary.lanes, .capped = summary.capped });
}

/// Whether a ceiling the program fixes holds `node` where it is read (`Range.ceilings`, on every
/// path to it: `if (n > max) return` before it): a limit clean where it is read, its parameters as
/// their callers give them (`concrete`), in the fact's `lane`, or in every lane where the value
/// is given whole (null: a call narrows every lane at once); or a value Range holds to a
/// short's count (`Range.small`: a clamp on both branches, a 16-bit type). A value so held is
/// within a range the program chose: data, no peer's number. The one reading of a bound at a
/// call given the value (`passed`) and at a sink (`capped`); a sink reads Bounds' counts besides
/// (`Proof.counts`: a `const` limit, a count within memory the function holds), which a call
/// does not: a call is read inside the run's solve, whose budget is the run's, and what Bounds
/// spends there would spill one file's budget into every other's. What it does not claim:
/// memory grown by such amounts in a loop input drives (a list appended to n at a time, each n
/// held) holds data, as `@min`'s narrowing gives today.
fn ceilingHeld(c: *Context, flow: *Flow, file: Project.FileId, node: Ast.Node.Index, lane: ?u8) Context.Error!bool {
    if (!flow.in_ceiling) {
        flow.in_ceiling = true;
        defer flow.in_ceiling = false;
        for (try Range.ceilings(c, file, node)) |limit| {
            const function = owner(flow, file, limit) orelse continue;
            const level = concrete(flow, function, try dep(c, flow, function, limit));
            if (if (lane) |one| level.at(one) == .clean else level.isClean()) return true;
        }
    }
    // Range reads no fact, so a limit read through a call given the value reads it too.
    return Range.small(c, file, node);
}

/// Whether a ceiling the program fixes holds `node` where a rule's sink reads it (`ceilingHeld`).
pub fn capped(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    return ceilingHeld(c, fact.flow, file, node, fact.lane);
}

/// What a call is given at `arg` (`value`, as `dep` or `whole` reads it): narrowed where a ceiling
/// the program fixes holds it at the call (`ceilingHeld`), as a sink reads it there.
fn passed(c: *Context, flow: *Flow, function: Function.Id, arg: Ast.Node.Index, value: Dep) Context.Error!Dep {
    if (value.clean()) return value;
    if (!try ceilingHeld(c, flow, flow.functions.items[@backingInt(function)].file, arg, null)) return value;
    return value.narrowed(c.allocator);
}

/// What a function outside the program may make of an argument: what it holds, and its length,
/// which a search's position or a count is within (`std.mem.indexOfScalar(u8, buf[0..n], 0)`).
fn outsideArg(c: *Context, flow: *Flow, function: Function.Id, arg: Ast.Node.Index) Context.Error!Dep {
    const value = try passed(c, flow, function, arg, try whole(c, flow, function, arg));
    return try value.join(c.allocator, value.measured());
}

/// A call's result: the program's callee's summary read with these arguments, a read's input,
/// what a function outside the program makes of what it is given, aegis's answer clean, and
/// unknown from a callee that does not resolve.
fn result(c: *Context, flow: *Flow, function: Function.Id, callee: Callee) Context.Error!Dep {
    const made = try resultOf(c, flow, function, callee);
    // A writer that reaches a peer, whatever else the call gives.
    return if (callee.writer) try made.join(c.allocator, .{ .level = .in(flow.masks.peer_writer, .data) }) else made;
}

fn resultOf(c: *Context, flow: *Flow, function: Function.Id, callee: Callee) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    switch (callee.kind) {
        // A parse gives what its parser returns refined, but for the values it showed no range
        // of. aegis's other functions give what they are given: a conversion (`int.cast`), a
        // checked sum or an id's `raw` holds the peer's choice as much as its operand did,
        // though the checks the conversion makes are aegis's.
        //
        // Where aegis answers the fact, the parse's refinement is the answer; an error's text
        // aegis gives is its answer to the error's. Where it does not, the parse gives what its
        // parser returns.
        .aegis => {
            if (try parserOf(c, flow, f.file, callee.params, callee.decl.?)) |target| {
                const parser = flow.functions.items[@backingInt(target)];
                return .{ .level = parser.unrefined.masked(flow.masks.aegis).join(concrete(flow, target, parser.ret).masked(~flow.masks.aegis)) };
            }
            var out: Dep = .{};
            for (callee.args) |arg| out = try out.join(c.allocator, try outsideArg(c, flow, function, arg));
            return answered(out, flow.masks.aegis & flow.masks.error_text);
        },
        // What it holds: `init`'s value, the receiver of `lend`, `get`, `borrow` and `move`.
        .holder => {
            var out: Dep = .{};
            for (callee.args) |arg| out = try out.join(c.allocator, try dep(c, flow, function, arg));
            return out;
        },
        .program => |target| {
            return summarized(c, flow, function, callee, flow.functions.items[@backingInt(target)].ret);
        },
        .choice => |each| {
            var out: Dep = .{};
            for (each) |one| out = try out.join(c.allocator, try resultOf(c, flow, function, one));
            return out;
        },
        .source => {
            const lanes = try readLanes(c, flow, function, callee.receiver);
            const decl = callee.decl.?;
            // A read into the caller's buffer returns how much it read: a count the buffer
            // bounds, a peer's within it.
            if (!(try bufferParams(c, decl)).empty() and returnsCount(c, decl)) return .{ .level = .in(lanes, .data) };
            if (try decodes(c, flow, decl)) return .{ .level = .in(lanes, if (narrow(c, f.file, callee.params)) .data else .number) };
            return .{ .level = .in(lanes, .data) };
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
                // indexes the tree's own tables. What else is read of the tree (`treeValue`)
                // stays input.
                if (f.parser and flow.zig_parse.contains(decl)) return .{};
                if (flow.zig_text.contains(decl)) return .{ .level = .in(flow.masks.peer, .data) };
            }
            // A function outside the program gives what it is given, its receiver among it.
            var out: Dep = .{};
            for (callee.args) |arg| out = try out.join(c.allocator, try outsideArg(c, flow, function, arg));
            const decl = callee.decl orelse return out;
            if (!flow.program.std_files.contains(@backingInt(decl.file))) return out;
            if (decl.file == flow.zig_ast) return treeDep(c, flow, decl.file, returnType(c, decl));
            // A std function that answers a `usize` (a container's `count`, a position it finds
            // in data) answers a count of memory the program holds: a peer's within it.
            if (returnsCount(c, decl)) return try out.narrowed(c.allocator);
            // A std function outside its data namespaces (`mem`, `fmt`, `ascii`, `unicode`,
            // `math`, `base64`), or one of them that decodes an integer, may make any number of
            // what it is given (`std.json` parsing a struct, a hash of the bytes). A decode of 16
            // bits or fewer stays in their range.
            if (callee.receiver == null and (!flow.data_files.contains(@backingInt(decl.file)) or try decodes(c, flow, decl))) return if (narrow(c, f.file, callee.params)) out else try out.widened(c.allocator);
            // A value clamped between the program's own bounds is held to them.
            if (try Governed.isStd(c, decl, "math.clamp") == .yes and callee.params.len == 3) {
                if ((try dep(c, flow, function, callee.params[1])).clean() and (try dep(c, flow, function, callee.params[2])).clean()) return try out.narrowed(c.allocator);
            }
            return out;
        },
        // What none resolving gives may be anything, the peer's input among it, whatever it
        // is given (a vtable's read handed the reader); and it may point into memory no place
        // names.
        .none => {
            var out: Dep = .{ .level = .all(.unknown) };
            for (callee.args) |arg| out = try out.join(c.allocator, try outsideArg(c, flow, function, arg));
            return try (try out.lowered(c.allocator)).join(c.allocator, unnamed(flow));
        },
    }
}

/// What a call gives, clean in the lanes `lanes` its callee answers. A parameter's part of it
/// is read in every lane, as the parameters a value depends on are the same for every fact:
/// an answer in some lanes clears only what the function itself gives.
fn answered(given: Dep, lanes: Mask) Dep {
    if (lanes == none) return given;
    var out = given;
    out.level = given.level.masked(~lanes);
    out.length = given.length.masked(~lanes);
    out.unchecked = given.unchecked.masked(~lanes);
    return out;
}

/// Whether a function's result is a count or a position: its declared result is `usize`, or
/// an optional or error union of one.
/// The type a function's declaration says it returns.
fn returnType(c: *Context, decl: Facts.Decl) ?Ast.Node.Index {
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return null;
    return proto.ast.return_type.unwrap();
}

fn returnsCount(c: *Context, decl: Facts.Decl) bool {
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return false;
    const result_type = proto.ast.return_type.unwrap() orelse return false;
    return std.mem.endsWith(u8, tree.getNodeSource(result_type), "usize");
}

/// Whether a decode's spelled type (its first argument, `readInt(u16, ...)`) is at most 16 bits
/// wide: what it gives stays in a range no wider sum or product of it overflows.
fn narrow(c: *Context, file: Project.FileId, params: []const Ast.Node.Index) bool {
    if (params.len == 0) return false;
    const tree = &c.project.at(file).file.tree;
    const spelled = tree.getNodeSource(params[0]);
    if (spelled.len < 2 or (spelled[0] != 'u' and spelled[0] != 'i')) return false;
    const bits = std.fmt.parseUnsigned(u16, spelled[1..], 10) catch return false;
    return bits <= 16;
}

/// Whether a std function decodes an integer from bytes or text: `readInt` and its forms,
/// `parseInt`, `parseUnsigned`, a reader's `takeInt`, `peekInt`, `takeVarInt`, `takeLeb128`,
/// `takeEnum`.
fn decodes(c: *Context, flow: *const Flow, decl: Facts.Decl) Context.Error!bool {
    if (readerRead(c, flow, decl)) {
        const reader = flow.reader.?; // unreachable: `readerRead` holds it
        for (reader_byte_reads) |each| if (memberIs(c, reader, each, decl)) return false;
        return true;
    }
    for (std_decoders) |decoder| if (try Governed.isStd(c, decl, decoder) == .yes) return true;
    return false;
}

/// The level of `node` in its file as the fact reads it, or clean outside the functions it
/// reads.
pub fn levelAt(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index) Context.Error!Level {
    const function = owner(fact.flow, file, node) orelse return .clean;
    return concrete(fact.flow, function, try dep(c, fact.flow, function, node)).at(fact.lane);
}

/// A sink a rule reads in a function of a file the run does not select, and what its value
/// takes from that function's parameters (`given`, the function's own input left out: that
/// input is the dependency's own lint's), judged at each call a selected file makes into it with
/// what the call gives (main's provenance ruling, designs/glint-provenance.md part 1).
/// `undecided` where what it takes is not read: a sink of a generic, which its binding decides,
/// or one met through a call back into a file being read.
pub const PassedSink = struct {
    at: Site,
    /// The function whose parameters `given` is in (`functionKey`): the sink's own, or a caller
    /// in the file the sink was reached through.
    holder: u32,
    given: Dep,
    least: Level,
    message: []const u8,
    undecided: bool = false,
    /// Input of its function's own reaches it, beside what `given` takes from the parameters
    /// (`ownAt`): the dependency's own lint's, but where the program holds input a function of
    /// a file the run does not select may read beside its parameters (`inputBeside`), it may be
    /// the program's.
    own_input: bool = false,
    /// A018: its function writes an error of its own (`errorShown`), whatever the call gives, to
    /// a writer its caller decides; whether that writer is a peer's the reading does not keep,
    /// so the sink is undecided at every call for that, not for what its value takes.
    own_error: bool = false,

    /// What a rule says of a sink it records, beside what its value takes (`recordSink`).
    pub const Recorded = struct { undecided: bool = false, own_input: bool = false, own_error: bool = false };

    /// The same sink, what it holds (its Dep's slots' tails, its message) on `gpa`: kept past the
    /// memory the reading that found it is given back with.
    pub fn kept(sink: PassedSink, gpa: Allocator) Allocator.Error!PassedSink {
        var out = sink;
        out.given = try sink.given.kept(gpa);
        out.message = try gpa.dupe(u8, sink.message);
        return out;
    }
};

/// Whether the call `node` gives its callee nothing input may reach the callee by: each
/// argument, a bound receiver first, clean and plain (`plainValue`: a number, a truth value, an
/// error, an enum's tag, the program's own constant text, or arrays, optionals and records of
/// them), and no input held where a function of a file the run does not select may read it
/// beside its parameters (`besideParameters`). What such a callee then meets of input is its own
/// package's, which that package's own lint judges (designs/glint-provenance.md part 1). A
/// function, a pointer, a type or a record holding one may hand the callee input its level here
/// does not show: a function reading a peer, memory input fills, a type's declarations.
pub fn plainClean(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    if (try inputBeside(c, fact)) return false;
    const callee = (try resolveCall(c, fact.flow, file, node)) orelse return false;
    if (callee.kind != .program) return false;
    for (callee.args) |arg| {
        if (!try plainValue(c, try c.facts.resolve(file, arg), 0)) return false;
        if (try levelAt(c, fact, file, arg) != .clean) return false;
    }
    return true;
}

/// Whether a value of `value`'s type holds nothing but plain data: a number (a literal's
/// `scalar`, the program's own constant text among them), a truth value, an error, an enum's
/// tag, a primitive type other than `type` and `anyopaque`, and arrays, optionals, error unions
/// and records of them, by each field the record holds. A pointer, a function, a type (whose
/// declarations a callee may read), an opaque, a literal or a value that does not resolve may
/// hold more.
fn plainValue(c: *Context, value: Facts.Value, depth: usize) Context.Error!bool {
    // A type nested this deep is read as one that may hold more.
    if (depth > 8) return false;
    switch (value) {
        .scalar, .error_set => return true,
        .primitive => |name| return !std.mem.eql(u8, name, "type") and !std.mem.eql(u8, name, "anyopaque"),
        .optional, .error_union, .array => |inner| return plainValue(c, inner.*, depth + 1),
        .alternatives => |each| {
            for (each) |one| if (!try plainValue(c, one, depth + 1)) return false;
            return true;
        },
        .instance => |k| {
            if (k.symbolic and k.made_by == null) return false;
            switch (c.facts.kindOf(k) orelse return false) {
                .keyword_enum => return true,
                .keyword_struct, .keyword_union => {},
                else => return false,
            }
            for (try c.facts.heldFields(k)) |field| if (!try plainValue(c, field.value, depth + 1)) return false;
            return true;
        },
        else => return false,
    }
}

/// What a function of a file the run does not select may read of input other than through its
/// parameters, per lane: a field or a container-level variable that file's package declares,
/// what any file stores into one included; one a selected file declares where a file the run
/// does not select imports that file (`@import("root")`, say); and memory no place names. The
/// whole program's solve gives each its level, so a store of the program's input into one shows
/// here. Read once the solve is done.
pub fn inputBeside(c: *Context, fact: Fact) Context.Error!bool {
    return (try besideParameters(c, fact)).at(fact.lane) != .clean;
}

/// `inputBeside`'s levels, every lane.
fn besideParameters(c: *Context, fact: Fact) Context.Error!Levels {
    const flow = fact.flow;
    if (flow.beside) |found| return found;
    var imported: std.AutoHashMapUnmanaged(Project.FileId, void) = .empty;
    defer imported.deinit(c.facts.gpa);
    for (c.project.imports) |mapping| {
        if (judged(c, mapping.from) or !try c.facts.program(mapping.from)) continue;
        if (judged(c, mapping.target)) try imported.put(c.facts.gpa, mapping.target, {});
    }
    var out = unnamed(flow).level.join(unnamed(flow).unchecked);
    for ([_]*const std.AutoHashMapUnmanaged(Facts.Decl, Levels){ &flow.globals, &flow.lengths }) |map| {
        var it = map.iterator();
        while (it.next()) |entry| {
            const decl = entry.key_ptr.*;
            if (judged(c, decl.file) and !imported.contains(decl.file)) continue;
            out = out.join(entry.value_ptr.*);
        }
    }
    flow.beside = out;
    return out;
}

/// A call a function of the file being read makes into a function of that file.
pub const PassedCall = struct { node: Ast.Node.Index, decl: Facts.Decl };

/// Whether a rule reads `node` now: every node outside a reading of a file the run does not
/// select; within one, a node of the functions it takes (`Flow.recording_within`).
pub fn readHere(fact: Fact, file: Project.FileId, node: Ast.Node.Index) bool {
    const within = fact.flow.recording_within orelse return true;
    const function = owner(fact.flow, file, node) orelse return false;
    return within.contains(@backingInt(function));
}

/// Where a rule reads a file the run does not select (`Flow.recording`), the sink at `node`
/// kept with what it takes from its function's parameters (`given`, as `givenAt` keeps it), to
/// be judged at the calls into that function. A sink outside a function is kept by none: a
/// container's declarations are evaluated as the program compiles, so no input reaches them.
pub fn recordSink(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index, given: Dep, recorded: PassedSink.Recorded, least: Level, message: []const u8) Allocator.Error!void {
    const list = fact.flow.recording orelse return;
    const function = functionKey(fact, file, node) orelse return;
    try list.append(c.allocator, .{ .at = .{ .file = file, .node = node }, .holder = function, .given = given, .least = least, .message = message, .undecided = recorded.undecided or recorded.own_error, .own_input = recorded.own_input, .own_error = recorded.own_error });
}

/// Whether the value `node` holds takes input of its function's own, beside what it takes from
/// the parameters (what `givenAt` leaves out): a read in the function, or a field, a
/// container-level variable or memory no place names that holds input.
pub fn ownAt(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const function = owner(fact.flow, file, node) orelse return false;
    const given = try dep(c, fact.flow, function, node);
    return given.level.at(fact.lane) != .clean or given.length.at(fact.lane) != .clean or given.unchecked.at(fact.lane) != .clean;
}

/// The function holding `node`, as an id the fact keeps for the run; null outside them.
pub fn functionKey(fact: Fact, file: Project.FileId, node: Ast.Node.Index) ?u32 {
    return if (owner(fact.flow, file, node)) |function| @backingInt(function) else null;
}

/// `held` joined with `more`: whether that added any slot or level.
pub fn joinInto(gpa: Allocator, held: *Dep, more: Dep) Allocator.Error!bool {
    const joined = try held.join(gpa, more);
    const same = joined.eql(held.*);
    held.* = joined;
    return !same;
}

/// What `node`'s value takes from the parameters of the function holding it, the function's
/// own input left out; every parameter at its most where it passed through a call that does
/// not resolve (`throughUnknown`), which may hand it any of them. Null outside the functions
/// the fact reads.
pub fn givenAt(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Dep {
    const function = owner(fact.flow, file, node) orelse return null;
    return try fromParameters(c, fact, function, try dep(c, fact.flow, function, node));
}

/// `given`, a Dep of `function`, as `givenAt` keeps it.
fn fromParameters(c: *Context, fact: Fact, function: Function.Id, given: Dep) Context.Error!Dep {
    if (!throughUnknown(fact, given)) return parametersOnly(given);
    var out = parametersOnly(given);
    for (0..fact.flow.functions.items[@backingInt(function)].levels.len) |slot| {
        out.params = try out.params.with(c.allocator, slot);
        out.numbers = try out.numbers.with(c.allocator, slot);
        out.counted_numbers = try out.counted_numbers.with(c.allocator, slot);
    }
    return out;
}

/// `given` read through the call `node` makes (`throughCall`), kept as `givenAt` keeps a Dep
/// of the function holding the call; null where the call reaches no one function of the
/// program whose parameters its arguments are known for.
pub fn givenThrough(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index, given: Dep) Context.Error!?Dep {
    const function = owner(fact.flow, file, node) orelse return null;
    const read = (try throughCall(c, fact, file, node, given)) orelse return null;
    return try fromParameters(c, fact, function, read);
}

/// Whether the value `node` holds passed through a call that does not resolve (`throughUnknown`).
pub fn unknownAt(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const function = owner(fact.flow, file, node) orelse return false;
    return throughUnknown(fact, try dep(c, fact.flow, function, node));
}

/// Whether `given` passed through a call that does not resolve in the fact's lane: what it
/// takes from the parameters is not known, which `parametersOnly` would drop.
pub fn throughUnknown(fact: Fact, given: Dep) bool {
    return given.level.at(fact.lane) == .unknown or given.length.at(fact.lane) == .unknown or given.unchecked.at(fact.lane) == .unknown;
}

/// `given` without the function's own input: only what its parameters give.
pub fn parametersOnly(given: Dep) Dep {
    var out = given;
    out.level = .clean;
    out.length = .clean;
    out.unchecked = .clean;
    return out;
}

/// `given`, in the parameters' terms of the callee of the call `node` makes, read in the
/// terms of the function holding the call: each slot as the call's argument there, the
/// arguments' own facts with them. Null where the call reaches no one function of the program
/// whose parameters its arguments are known for.
pub fn throughCall(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index, given: Dep) Context.Error!?Dep {
    const function = owner(fact.flow, file, node) orelse return null;
    const callee = (try resolveCall(c, fact.flow, file, node)) orelse return null;
    if (callee.kind != .program) return null;
    return try summarized(c, fact.flow, function, callee, given);
}

/// The level `given`, a Dep in the terms of the function holding `node`, has as its callers
/// give that function's parameters.
pub fn levelOf(fact: Fact, file: Project.FileId, node: Ast.Node.Index, given: Dep) Level {
    const function = owner(fact.flow, file, node) orelse return given.level.at(fact.lane);
    return concrete(fact.flow, function, given).at(fact.lane);
}

/// The function `decl` declares, as an id the fact keeps for the run (`functionKey`); null
/// where the fact reads no body of it.
pub fn functionOf(c: *Context, fact: Fact, decl: Facts.Decl) ?u32 {
    const body = fnDecl(c, decl) orelse return null;
    const function = fact.flow.by_node.get(.{ .file = decl.file, .node = body }) orelse return null;
    return @backingInt(function);
}

/// A Dep taking every parameter of `decl` at its most (as given, as a number, as a count's
/// number): what a sink takes where the reading cannot tell which.
pub fn everyParameter(c: *Context, decl: Facts.Decl) Context.Error!Dep {
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return .{};
    var count: usize = 0;
    var it = proto.iterate(tree);
    while (it.next()) |_| count += 1;
    return everySlot(c, count);
}

/// A Dep taking each of `count` parameters at its most (`everyParameter`).
fn everySlot(c: *Context, count: usize) Context.Error!Dep {
    var out: Dep = .{};
    for (0..count) |position| {
        for ([_]usize{ valueSlot(position), lengthSlot(position) }) |slot| {
            out.params = try out.params.with(c.allocator, slot);
            out.numbers = try out.numbers.with(c.allocator, slot);
            out.counted_numbers = try out.counted_numbers.with(c.allocator, slot);
        }
    }
    return out;
}

/// A Dep taking every parameter of the function `function` (`functionKey`) at its most.
pub fn everyParameterOf(c: *Context, fact: Fact, function: u32) Context.Error!Dep {
    return everySlot(c, fact.flow.functions.items[function].params.len);
}

/// The function a site at the source position `start` of `file` belongs to, as an id the fact
/// keeps for the run, with a Dep taking each of its parameters at its most: the innermost
/// function the fact reads around it, by the file's scopes. Null outside any (a container's
/// declarations, a `comptime` block).
pub fn functionAround(c: *Context, fact: Fact, file: Project.FileId, start: u32) Context.Error!?struct { id: u32, node: Ast.Node.Index, every: Dep } {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const starts = tree.tokens.items(.start);
    // The last token starting at or before `start`.
    var low: usize = 0;
    var high: usize = starts.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (starts[mid] <= start) low = mid + 1 else high = mid;
    }
    if (low == 0) return null;
    var scope: ?Model.Scope.Id = model.scopeOf(@intCast(low - 1));
    while (scope) |s| : (scope = model.scopes[@backingInt(s)].parent) {
        const each = model.scopes[@backingInt(s)];
        if (each.kind != .function) continue;
        const function = fact.flow.by_node.get(.{ .file = file, .node = each.node }) orelse continue;
        return .{ .id = @backingInt(function), .node = each.node, .every = try everyParameterOf(c, fact, @backingInt(function)) };
    }
    return null;
}

/// The level of a counter `loop` steps, as it decides how many passes the loop takes: what it
/// holds on entry (each assignment outside the loop, under its own conditions) and what each
/// pass steps it by. Whether a pass steps it is the loop's to decide, which its bound answers.
/// Null where `operand` names no local the loop assigns.
pub fn counterLevel(c: *Context, fact: Fact, file: Project.FileId, loop: Ast.Node.Index, operand: Ast.Node.Index) Context.Error!?Level {
    const flow = fact.flow;
    const function = owner(flow, file, operand) orelse return null;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const d = (nameRef(model, operand) orelse return null).declaration orelse return null;
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
        out = try (try out.join(c.allocator, try dep(c, flow, function, init))).join(c.allocator, try control(c, flow, function, decl.node, null));
    };
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const form = accesses.formOf(tag);
        if (form != .assign and form != .compound_assign) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const target, const value = tree.nodeData(node).node_and_node;
        const ref = nameRef(model, target) orelse continue;
        if (ref.declaration != d) continue;
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) {
            out = try (try out.join(c.allocator, try dep(c, flow, function, value))).join(c.allocator, try control(c, flow, function, node, target));
            continue;
        }
        stepped = true;
        out = try out.join(c.allocator, try dep(c, flow, function, stepOf(tree, model, d, tag, value)));
    }
    if (!stepped) return null;
    return concrete(flow, function, out).at(fact.lane);
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
    _ = tree;
    const ref = nameRef(model, node) orelse return false;
    return ref.declaration == d;
}

/// The program's call or the function outside it that a call reaches, for a sink reading its
/// arguments by the callee's parameters.
/// Null where `node` makes no call.
pub const Reached = struct { decl: ?Facts.Decl, args: []const Ast.Node.Index, std: bool };
pub fn reached(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Reached {
    const flow = fact.flow;
    const callee = (try resolveCall(c, flow, file, node)) orelse return null;
    const decl = callee.decl;
    const in_std = if (decl) |d| flow.program.std_files.contains(@backingInt(d.file)) else false;
    return .{ .decl = decl, .args = callee.args, .std = in_std };
}

/// The level of what a condition reads: its comparisons' and its logic's operands, each as
/// the fact reads it (a comparison's own result is clean; what it compares is not).
pub fn conditionAt(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index) Context.Error!Level {
    const tree = &c.project.at(file).file.tree;
    switch (Facts.conditionOf(tree, node)) {
        .both, .either => |sides| return (try conditionAt(c, fact, file, sides[0])).join(try conditionAt(c, fact, file, sides[1])),
        .compare => |compared| return (try conditionAt(c, fact, file, compared.left)).join(try conditionAt(c, fact, file, compared.right)),
        .not => |inner| return conditionAt(c, fact, file, inner),
        .other => |value| return levelAt(c, fact, file, value),
    }
}

/// Whether a call reads a peer's input.
pub fn isRead(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const callee = (try resolveCall(c, fact.flow, file, node)) orelse return false;
    return callee.kind == .source;
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

/// The types of an index into std's Zig tree's own tables: a token's, a node's, an extra datum's.
const zig_index = [_][]const u8{ "zig.Ast.TokenIndex", "zig.Ast.OptionalTokenIndex", "zig.Ast.ExtraIndex", "zig.Ast.Node.Index", "zig.Ast.Node.OptionalIndex" };

/// What std's Zig lowering gives of the file's text: a peer's bytes, wherever its structure
/// is the lowering's.
const zig_text = [_][]const u8{ "zig.Zir.string_bytes", "zig.Zir.nullTerminatedString" };

/// What a value std's Zig tree gives holds, by the type std declares it with: `index`, an
/// index into the tree's own tables (or an optional, slice or pointer of them), which std's
/// parse makes only within them; `container`, a struct or union the tree declares (a node's
/// `Data`, a `full` view), each field of it read by its own type; `data`, anything else (the
/// text, a byte offset, a line, a count, a tag), the peer's within the memory the tree holds.
const TreeValue = enum { index, container, data };

fn treeValue(c: *Context, flow: *const Flow, file: Project.FileId, type_node: Ast.Node.Index) Context.Error!TreeValue {
    const tree = &c.project.at(file).file.tree;
    switch (formAt(tree, type_node)) {
        .optional_type => return treeValue(c, flow, file, tree.nodeData(type_node).node),
        .error_union => return treeValue(c, flow, file, tree.nodeData(type_node).node_and_node[1]),
        .pointer_type => return treeValue(c, flow, file, tree.fullPtrType(type_node).?.ast.child_type),
        .leaf, .member => {
            if (formAt(tree, type_node) == .leaf and !spellsName(tree, type_node)) return .data;
            const decl = ((try c.facts.definition(file, type_node)).orNull()) orelse return .data;
            if (flow.zig_index.contains(decl)) return .index;
            if (decl.file != flow.zig_ast) return .data;
            const model = &c.project.at(decl.file).model;
            const declaring = &c.project.at(decl.file).file.tree;
            const variable = declaring.fullVarDecl(model.declarations[@backingInt(decl.index)].node) orelse return .data;
            const init = variable.ast.init_node.unwrap() orelse return .data;
            return treeValue(c, flow, decl.file, init);
        },
        else => {
            var buffer: [2]Ast.Node.Index = undefined;
            const container = tree.fullContainerDecl(&buffer, type_node) orelse return .data;
            return switch (tree.tokenTag(container.ast.main_token)) {
                .keyword_struct, .keyword_union => .container,
                else => .data,
            };
        },
    }
}

/// What a value of std's Zig tree of type `type_node` holds: an index or a container of them
/// is the parse's, its length (of a slice) the peer's; anything else is the peer's, within
/// the source the tree holds, whatever it was given.
fn treeDep(c: *Context, flow: *const Flow, file: Project.FileId, type_node: ?Ast.Node.Index) Context.Error!Dep {
    const data: Levels = .in(flow.masks.peer, .data);
    const t = type_node orelse return .{ .level = data, .length = data };
    return switch (try treeValue(c, flow, file, t)) {
        .index, .container => .{ .length = data },
        .data => .{ .level = data, .length = data },
    };
}

/// Whether `decl` is std's declaration at one of `paths`.
/// Whether a function outside the program is one of std's.
pub fn inStd(flow: *const Flow, decl: Facts.Decl) bool {
    return flow.program.std_files.contains(@backingInt(decl.file));
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
pub fn sourceOf(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Origin {
    const function = owner(fact.flow, file, node) orelse return null;
    var walk: Walk = .{ .c = c, .flow = fact.flow, .lane = fact.lane };
    return walk.from(function, node, 0);
}

/// The reads input reaching `node` comes from, at most `most` of them, each found as
/// `sourceOf` finds one with those already found left out: where several reads reach it, a
/// finding names more than the first, so no reader takes one source for the only one.
pub fn sourcesOf(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index, most: usize) Context.Error![]const Origin {
    const function = owner(fact.flow, file, node) orelse return &.{};
    var found: std.ArrayList(Origin) = .empty;
    while (found.items.len < most) {
        var walk: Walk = .{ .c = c, .flow = fact.flow, .lane = fact.lane, .excluded = found.items };
        try found.append(c.allocator, (try walk.from(function, node, 0)) orelse break);
    }
    return found.items;
}

const Walk = struct {
    c: *Context,
    flow: *Flow,
    /// The fact walked back.
    lane: u8,
    seen: std.AutoHashMapUnmanaged(struct { Function.Id, Ast.Node.Index }, void) = .empty,
    steps: u32 = 0,
    /// Reads already found: the walk looks past them for another.
    excluded: []const Origin = &.{},

    const step_limit = 4000;

    /// The read at `node`, unless it is one already found.
    fn read(w: *const Walk, file: Project.FileId, node: Ast.Node.Index) ?Origin {
        for (w.excluded) |each| if (each.file == file and each.node == node) return null;
        return .{ .file = file, .node = node };
    }

    fn carries(w: *Walk, function: Function.Id, node: Ast.Node.Index) Context.Error!bool {
        return concrete(w.flow, function, try dep(w.c, w.flow, function, node)).at(w.lane) != .clean;
    }

    fn from(w: *Walk, function: Function.Id, node: Ast.Node.Index, depth: u8) Context.Error!?Origin {
        if (depth > 48 or w.steps >= step_limit) return null;
        w.steps += 1;
        if ((try w.seen.getOrPut(w.c.allocator, .{ function, node })).found_existing) return null;
        const f = w.flow.functions.items[@backingInt(function)];
        const tree = &w.c.project.at(f.file).file.tree;
        const model = &w.c.project.at(f.file).model;
        if (try resolveCall(w.c, w.flow, f.file, node)) |callee| return w.throughCall(function, node, callee, depth);
        if (spellsName(tree, node)) {
            const ref = model.reference(node) orelse return null;
            const d = ref.declaration orelse return null;
            if (f.position(d)) |index| return w.callers(function, index, depth);
            const decl = model.declarations[@backingInt(d)];
            const scope = model.scopes[@backingInt(decl.scope)].kind;
            if (scope == .file or scope == .container) return w.stored(.{ .file = f.file, .index = d }, depth);
            return w.local(function, d, depth);
        }
        // A field holds what the program stores in it anywhere, by its declaration.
        if (formAt(tree, node) == .member) if ((try w.c.facts.definition(f.file, node)).orNull()) |decl| {
            if ((w.flow.globals.get(decl) orelse Levels.clean).at(w.lane) != .clean) if (try w.stored(decl, depth)) |found| return found;
        };
        // Memory's length holds what was written to it (`s.len = n`), where its contents carry
        // nothing: the receiver is walked back for the write, whatever it carries itself.
        if (try w.c.facts.lengthOf(f.file, node)) |memory| {
            if (try w.from(function, memory, depth + 1)) |found| return found;
        }
        for (try children(w.c, f.file, node)) |child| {
            if (!try w.carries(function, child)) continue;
            if (try w.from(function, child, depth + 1)) |found| return found;
        }
        return null;
    }

    fn throughCall(w: *Walk, function: Function.Id, node: Ast.Node.Index, callee: Callee, depth: u8) Context.Error!?Origin {
        const f = w.flow.functions.items[@backingInt(function)];
        switch (callee.kind) {
            .source => return w.read(f.file, node),
            .aegis => if (try parserOf(w.c, w.flow, f.file, callee.params, callee.decl.?) != null) return null,
            .program => |target| if (try w.returnedBy(function, node, target, depth)) |found| return found,
            .choice => |each| for (each) |one| switch (one.kind) {
                .source => if (w.read(f.file, node)) |found| return found,
                .program => |target| if (try w.returnedBy(function, node, target, depth)) |found| return found,
                else => {},
            },
            .holder, .outside, .none => {},
        }
        for (callee.args) |arg| {
            if (!try w.carries(function, arg)) continue;
            if (try w.from(function, arg, depth + 1)) |found| return found;
        }
        return null;
    }

    /// What the program's `target`, called at `node` of `function`, returns, walked back.
    fn returnedBy(w: *Walk, function: Function.Id, node: Ast.Node.Index, target: Function.Id, depth: u8) Context.Error!?Origin {
        const f = w.flow.functions.items[@backingInt(function)];
        const g = w.flow.functions.items[@backingInt(target)];
        const tree = &w.c.project.at(g.file).file.tree;
        for (try children(w.c, g.file, g.node)) |part| if (try w.returned(target, tree, part, depth)) |found| {
            // The innermost call into the function that holds the read names it; a read the
            // walk found back out through the function's callers is not in it.
            var named = found;
            if (named.via == null and owner(w.flow, named.file, named.node) == target) named.via = .{ .file = f.file, .node = node };
            return named;
        };
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
        for (f.nodes) |node| {
            if (formAt(tree, node) == .assign) {
                const target, const value = tree.nodeData(node).node_and_node;
                if (rootDecl(model, tree, target) != d or !try w.carries(function, value)) continue;
                if (try w.from(function, value, depth + 1)) |found| return found;
                continue;
            }
            const callee = (try resolveCall(w.c, w.flow, f.file, node)) orelse continue;
            for (callee.params) |arg| if (rootDecl(model, tree, arg) == d) {
                if (callee.kind == .source) if (w.read(f.file, node)) |found| return found;
            };
        }
        return null;
    }

    /// What the program stores in a field or a container-level variable, each write
    /// `Facts.accesses` finds: a value assigned or given in a literal, or a read that fills it
    /// (a source given its address or memory it holds).
    fn stored(w: *Walk, decl: Facts.Decl, depth: u8) Context.Error!?Origin {
        const place: Facts.accesses.Place = switch (w.c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind) {
            .field => .{ .field = decl },
            else => .{ .declaration = decl },
        };
        var found_sites = Facts.accesses.writes(w.c.facts, place, try ownerFiles(w.c, w.flow));
        while (try found_sites.next()) |site| {
            const function = owner(w.flow, site.file, site.node) orelse continue;
            switch (site.kind) {
                .init, .set, .update => {
                    const value = site.value orelse writtenFrom(&w.c.project.at(site.file).file.tree, site.node) orelse continue;
                    if (!try w.carries(function, value)) continue;
                    if (try w.from(function, value, depth + 1)) |found| return found;
                },
                .address, .covered => if (try w.sourceArgument(site.file, site.node)) |call| if (w.read(site.file, call)) |found| return found,
                // No site of the unit's shows where it came from.
                .read, .open => {},
            }
        }
        return null;
    }

    /// What a store with no one value of its place reads what it writes from: a copy's or a
    /// fill's source (`@memcpy(std.mem.asBytes(h), bytes)`), an assignment's value written
    /// through a view (`std.mem.asBytes(h)[0] = b`), a destructure's value.
    fn writtenFrom(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
        if (filler(tree, node)) |writes| {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            return if (writes.value < args.len) args[writes.value] else null;
        }
        return switch (formAt(tree, node)) {
            .assign => tree.nodeData(node).node_and_node[1],
            .destructure => tree.assignDestructure(node).ast.value_expr,
            else => null,
        };
    }

    /// The call of a source `node` is an argument of, or an element of a vector argument of.
    fn sourceArgument(w: *Walk, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
        const model = &w.c.project.at(file).model;
        // An outside function handed a pointer is the site itself.
        var at = node;
        for (0..3) |_| {
            if (try resolveCall(w.c, w.flow, file, at)) |callee| return if (callee.kind == .source) at else null;
            at = model.parentOf(at) orelse return null;
        }
        return null;
    }

    /// What the program's callers of `function` give its parameter `index`.
    fn callers(w: *Walk, function: Function.Id, index: usize, depth: u8) Context.Error!?Origin {
        const sites = try callSites(w.c, w.flow);
        for ((sites.map.get(function) orelse return null).items) |site| {
            const f = w.flow.functions.items[@backingInt(site.caller)];
            const callee = (try resolveCall(w.c, w.flow, f.file, site.node)) orelse continue;
            if (index >= callee.args.len) continue;
            const arg = callee.args[index];
            if (!try w.carries(site.caller, arg)) continue;
            if (try w.from(site.caller, arg, depth + 1)) |found| return found;
        }
        return null;
    }
};

/// The declaration an expression is rooted at: `x`, `x.field`, `x[i]`, `&x`, `x[a..b]`.
fn rootDecl(model: *const Model, tree: *const Ast, node: Ast.Node.Index) ?Model.Declaration.Id {
    var at = node;
    while (true) switch (formAt(tree, at)) {
        .leaf => return (nameRef(model, at) orelse return null).declaration,
        .member, .unwrap_optional, .grouped => at = tree.nodeData(at).node_and_token[0],
        .array_access => at = tree.nodeData(at).node_and_node[0],
        .address_of, .deref => at = tree.nodeData(at).node,
        .slice => at = (tree.fullSlice(at) orelse return null).ast.sliced,
        else => return null,
    };
}

/// Each node's children, by file, built once from the parent table.
/// Each node's children, in node order, in one list for the file: `starts[n]` up to `starts[n + 1]`.
const FileChildren = struct { starts: []const u32, nodes: []const Ast.Node.Index };
const Children = struct { map: std.AutoHashMapUnmanaged(Project.FileId, FileChildren) = .empty };

fn children(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error![]const Ast.Node.Index {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Children);
    const all = memo.map.get(file) orelse blk: {
        const parents = c.project.at(file).model.node_parents;
        const starts = try c.allocator.alloc(u32, parents.len + 1);
        @memset(starts, 0);
        var total: u32 = 0;
        for (parents) |parent| if (parent) |p| {
            starts[@backingInt(p)] += 1;
            total += 1;
        };
        // Each node's count, made its start; each child then placed in node order.
        var sum: u32 = 0;
        for (starts) |*start| {
            const count = start.*;
            start.* = sum;
            sum += count;
        }
        const nodes = try c.allocator.alloc(Ast.Node.Index, total);
        const next = try c.allocator.dupe(u32, starts);
        for (parents, 0..) |parent, i| if (parent) |p| {
            nodes[next[@backingInt(p)]] = @fromBackingInt(@intCast(i));
            next[@backingInt(p)] += 1;
        };
        const made: FileChildren = .{ .starts = starts, .nodes = nodes };
        try memo.map.put(c.allocator, file, made);
        break :blk made;
    };
    const index = @backingInt(node);
    if (index + 1 >= all.starts.len) return &.{};
    return all.nodes[all.starts[index]..all.starts[index + 1]];
}

/// The program's calls of each of its functions, by callee, built once per flow.
const CallSites = struct {
    built: bool = false,
    map: std.AutoHashMapUnmanaged(Function.Id, std.ArrayList(struct { caller: Function.Id, node: Ast.Node.Index })) = .empty,
};

fn callSites(c: *Context, flow: *Flow) Context.Error!*CallSites {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(CallSites);
    if (memo.built) return memo;
    memo.built = true;
    var files = flow.owners.iterator();
    while (files.next()) |entry| {
        const file = entry.key_ptr.*;
        for (0..entry.value_ptr.syntax.of.len) |i| {
            const caller = entry.value_ptr.at(i) orelse continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const callee = (try resolveCall(c, flow, file, node)) orelse continue;
            const one = [1]Callee{callee};
            for (if (callee.kind == .choice) callee.kind.choice else &one) |each| {
                const target = switch (each.kind) {
                    .program => |t| t,
                    else => continue,
                };
                const list = try memo.map.getOrPut(c.allocator, target);
                if (!list.found_existing) list.value_ptr.* = .empty;
                try list.value_ptr.append(c.allocator, .{ .caller = caller, .node = node });
            }
        }
    }
    return memo;
}

/// The union fields a `switch` prong's capture binds: the one each tag it names declares, or
/// every field of the union for `else` or a value that is no tag.
fn prongFields(c: *Context, file: Project.FileId, operand: Ast.Node.Index, case_node: Ast.Node.Index) Context.Error![]const Facts.Decl {
    const tree = &c.project.at(file).file.tree;
    const case = tree.fullSwitchCase(case_node) orelse return &.{};
    var out: std.ArrayList(Facts.Decl) = .empty;
    for (try heldContainers(c, try c.facts.resolve(file, operand))) |container| try prongFieldsOf(c, file, case, container, &out);
    return out.items;
}

/// `prongFields` of one union.
fn prongFieldsOf(c: *Context, file: Project.FileId, case: Ast.full.SwitchCase, container: Facts.Container, out: *std.ArrayList(Facts.Decl)) Context.Error!void {
    if (case.ast.values.len == 0) return out.appendSlice(c.allocator, try fieldsOf(c, container));
    for (case.ast.values) |item| {
        const named_tag = (try c.facts.literalOf(file, item)) orelse return out.appendSlice(c.allocator, try fieldsOf(c, container));
        if (named_tag != .enum_literal) return out.appendSlice(c.allocator, try fieldsOf(c, container));
        const decl = c.facts.member(container, named_tag.enum_literal) orelse return out.appendSlice(c.allocator, try fieldsOf(c, container));
        if (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind != .field) continue;
        try out.append(c.allocator, decl);
    }
}

/// Every `Link` the program makes: each pointer-valued expression kept somewhere, by the places
/// it points into and the places it is kept in. What each function returns a pointer into
/// (`Function.returned`) is found with them, until none changes. Each pass reads every function
/// again on memory of its own, given back when the pass ends; the run's memory keeps only what
/// a pass raises (the links, what a function returns a pointer into).
fn linksOf(c: *Context, flow: *Flow) Context.Error!void {
    var pass: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer pass.deinit();
    const run_memory = c.allocator;
    defer c.allocator = run_memory;
    while (true) {
        flow.links.clearRetainingCapacity();
        _ = pass.reset(.free_all);
        c.allocator = pass.allocator();
        var changed = false;
        for (flow.functions.items, 0..) |f, i| {
            if (f.settled) continue;
            const function: Function.Id = @fromBackingInt(@intCast(i));
            const tree = &c.project.at(f.file).file.tree;
            const model = &c.project.at(f.file).model;
            for (f.nodes) |node| {
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
    return switch (formAt(tree, parent)) {
        .variable => true,
        .assign => tree.nodeData(parent).node_and_node[1] == node,
        .destructure, .@"return", .@"break" => true,
        .call => true,
        .struct_literal, .array_literal => true,
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
    switch (formAt(tree, parent)) {
        .variable => {
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
            .param => |index| if (!f.returned.has(index)) {
                f.returned = try f.returned.with(c.facts.gpa, index);
                grew = true;
            },
            .global => |decl| if (!for (f.returned_globals.items) |each| {
                if (std.meta.eql(each, decl)) break true;
            } else false) {
                try f.returned_globals.append(c.facts.gpa, decl);
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
        .grouped, .unwrap_optional, .tried, .@"orelse", .@"catch", .@"if", .prong, .@"switch" => {
            // A switch's operand or a branch's condition is read, not passed on.
            if (tree.fullIf(parent)) |branch| if (branch.ast.cond_expr == node) return false;
            if (tree.fullSwitch(parent)) |choice| if (choice.ast.condition == node) return false;
            const up = if (tree.fullSwitchCase(parent) != null) model.parentOf(parent) orelse return false else parent;
            return hold(c, flow, function, owners, up);
        },
        else => {
            var literal_buffer: [2]Ast.Node.Index = undefined;
            if (try resolveCall(c, flow, f.file, parent)) |callee| {
                if (callee.callee_expr == node) return false;
                switch (callee.kind) {
                    // The program's callee keeps what it is given where its own links say: in
                    // its callers' memory (`writes`), or in what it returns (`returned`).
                    .program => return false,
                    // A function outside the program may keep a pointer in what it returns
                    // and in the other memory it is given (`map.put(gpa, &key, v)`); one it
                    // takes as a pointer to constant memory (`writeAll(w, bytes)`'s `bytes`)
                    // writes nothing through, wherever it keeps it.
                    .outside, .source, .aegis, .holder => {
                        if (try writable(c, callee, node)) for (callee.args) |arg| if (arg != node and try pointing(c, f.file, arg)) try places(c, flow, function, arg, &holders);
                        grew = try hold(c, flow, function, owners, parent);
                    },
                    // One of several: any of them may keep it.
                    .choice, .none => try holders.append(c.allocator, .unknown),
                }
            } else if (tree.fullStructInit(&literal_buffer, parent)) |literal| {
                if (literal.ast.type_expr.unwrap() == node) return false;
                if (try literalFields(c, f.file, parent, literal)) |fields| {
                    for (literal.ast.fields, fields) |value, field| if (value == node) try holders.append(c.allocator, .{ .global = field });
                } else return hold(c, flow, function, owners, parent);
            } else if (tree.fullArrayInit(&literal_buffer, parent)) |literal| {
                if (literal.ast.type_expr.unwrap() == node) return false;
                return hold(c, flow, function, owners, parent);
            } else if (formAt(tree, parent) == .destructure) {
                try holders.append(c.allocator, .unknown);
            } else switch (formAt(tree, parent)) {
                // A use that reads through it keeps nothing.
                .member, .array_access, .deref, .slice, .comparison, .@"for", .@"while", .deferred => {},
                .body => {
                    var block_buffer: [2]Ast.Node.Index = undefined;
                    if (tree.blockStatements(&block_buffer, parent) == null) try holders.append(c.allocator, .unknown);
                },
                .builtin => {
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
            try flow.links.append(c.facts.gpa, .{ .function = function, .owner = owner_place, .holder = holder });
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
            .global => |decl| try (Dep{ .level = flow.globals.get(decl) orelse .clean, .unchecked = flow.lengths.get(decl) orelse .clean }).join(c.allocator, try throughUnnamed(c, flow, decl)),
            .param, .unknown => .{ .level = .all(.unknown) },
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
        return try out.join(c.allocator, .{ .level = .all(.unknown) });
    };
    for (fields) |field| out = try (try out.join(c.allocator, .{ .level = flow.globals.get(field) orelse .clean, .unchecked = flow.lengths.get(field) orelse .clean })).join(c.allocator, try throughUnnamed(c, flow, field));
    return out;
}

/// The fields a value of a type holds, through its fields' types in turn, found once per type;
/// null where the type does not resolve.
const Wholes = struct { map: std.AutoHashMapUnmanaged(Facts.Container, []const Facts.Decl) = .empty };

pub fn wholeFields(c: *Context, value: Facts.Value) Context.Error!?[]const Facts.Decl {
    // The walk is on the rule's memory for the file; what the memo keeps is copied to the run's.
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
    if (roots.items.len != 1) return out.items;
    const kept = try c.facts.gpa.dupe(Facts.Decl, out.items);
    try memo.map.put(c.facts.gpa, roots.items[0], kept);
    return kept;
}

/// The containers a value's type is or holds (through pointers, optionals, error unions,
/// arrays and choices); false where the type does not resolve.
fn containersOf(c: *Context, value: Facts.Value, out: *std.ArrayList(Facts.Container)) Context.Error!bool {
    switch (value) {
        .instance => |k| try out.append(c.allocator, k),
        .pointer => |inner| return containersOf(c, inner.child.*, out),
        .optional, .error_union, .array => |inner| return containersOf(c, inner.*, out),
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
    return (try controlUpTo(c, flow, function, node, boundOf(c, flow, function, target))).ruling(c.allocator, flow.masks);
}

/// Where the variable an assignment's `target` stores into is declared: a local's or a
/// capture's token; none for a field, a global or a parameter's memory, which outlive the
/// function.
fn boundOf(c: *Context, flow: *Flow, function: Function.Id, target: ?Ast.Node.Index) ?Ast.TokenIndex {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    var root = target orelse return null;
    while (true) root = switch (formAt(tree, root)) {
        .member, .unwrap_optional, .grouped => tree.nodeData(root).node_and_token[0],
        .array_access => tree.nodeData(root).node_and_node[0],
        else => break,
    };
    const d = (nameRef(model, root) orelse return null).declaration orelse return null;
    const decl = model.declarations[@backingInt(d)];
    const scope = model.scopes[@backingInt(decl.scope)].kind;
    if ((decl.kind == .variable or decl.kind == .capture) and scope != .file and scope != .container) return decl.token;
    return null;
}

/// What the loops around the sum `node` gives its target by their passes (implicit flow, as
/// `control`, but counted): each pass steps it again, so it goes as far as each loop's bound
/// where the loop counts against one (a `for`'s range or inputs, a `while` comparing a counter
/// it steps by a sum), and as far as input says where nothing counts the passes (a `while` on
/// what it reads, a labeled switch): a number. A loop whose every counter steps by a factor
/// passes as often as its type has digits.
fn counts(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index, target: Ast.Node.Index) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    const bound = boundOf(c, flow, function, target);
    var out: Dep = .{};
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (bound) |token| if (token >= tree.firstToken(parent) and token <= tree.lastToken(parent)) break;
        switch (tree.nodeTag(parent)) {
            .fn_decl => break,
            .@"for", .for_simple => out = try out.join(c.allocator, try (try forBound(c, flow, function, parent)).counting(c.allocator, flow.masks)),
            .@"while", .while_simple, .while_cont => {
                const w = tree.fullWhile(parent).?; // unreachable: the tag is a while's
                if (at == w.ast.cond_expr) continue;
                switch (try stepsOf(c, flow, function, parent, w.ast.cond_expr)) {
                    .sum => out = try out.join(c.allocator, try (try operands(c, flow, function, w.ast.cond_expr)).counting(c.allocator, flow.masks)),
                    .factor => {},
                    .other => out = try out.join(c.allocator, try (try passes(c, flow, function, parent)).unbounded(c.allocator, flow.masks)),
                }
            },
            .@"switch", .switch_comma => if (tree.fullSwitch(parent).?.label_token != null) {
                out = try out.join(c.allocator, try (try passes(c, flow, function, parent)).unbounded(c.allocator, flow.masks));
            },
            else => {},
        }
    }
    return out;
}

/// What bounds a `for`'s passes: its ranges' ends and its inputs' lengths.
fn forBound(c: *Context, flow: *Flow, function: Function.Id, loop: Ast.Node.Index) Context.Error!Dep {
    const tree = &c.project.at(flow.functions.items[@backingInt(function)].file).file.tree;
    var out: Dep = .{};
    for (tree.fullFor(loop).?.ast.inputs) |input| { // unreachable: the caller's loop is a for
        if (tree.nodeTag(input) == .for_range) {
            const start, const end = tree.nodeData(input).node_and_opt_node;
            out = try out.join(c.allocator, (try dep(c, flow, function, start)).held());
            if (end.unwrap()) |last| out = try out.join(c.allocator, (try dep(c, flow, function, last)).held());
        } else out = try out.join(c.allocator, (try dep(c, flow, function, input)).measured());
    }
    return out;
}

const Steps = enum { sum, factor, other };

/// How a `while`'s counters step, read once per loop: the places its condition `condition`
/// reads and what each write of them does (`Facts.accesses`). `sum` where the loop steps one by
/// a sum, each in one direction (`i += 1`, `i = i + 2`), and writes no other place the
/// condition reads: it counts against what they are compared with; `factor` where it steps
/// every one it writes by a product, a quotient or a shift (`a /= 10`): it passes as often as
/// the type has digits; `other` otherwise: a counter reset or stepped both ways, a bound the
/// loop changes (`list.items.len` with `list.append` in the loop), memory the condition reads
/// that does not resolve, or no counter: nothing counts its passes.
fn stepsOf(c: *Context, flow: *Flow, function: Function.Id, loop: Ast.Node.Index, condition: Ast.Node.Index) Context.Error!Steps {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const f = flow.functions.items[@backingInt(function)];
    const key: Facts.Key = .{ .file = f.file, .node = loop };
    if (flow.steps.get(key)) |known_steps| return known_steps;
    const steps = try stepsRead(c, flow, function, loop, condition);
    try flow.steps.put(c.allocator, key, steps);
    return steps;
}

fn stepsRead(c: *Context, flow: *Flow, function: Function.Id, loop: Ast.Node.Index, condition: Ast.Node.Index) Context.Error!Steps {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const reads = try Facts.accesses.readsOf(c.facts, f.file);
    const in_condition: Span = .of(tree, condition);
    if (in_condition.any(tree, reads.unresolved.items)) return .other;
    var named = reads.named.valueIterator();
    while (named.next()) |sites| if (in_condition.any(tree, sites.items)) return .other;
    var shapes = reads.shapes.valueIterator();
    while (shapes.next()) |sites| if (in_condition.any(tree, sites.items)) return .other;
    var up = false;
    var down = false;
    var factor = false;
    var read = reads.places.iterator();
    while (read.next()) |entry| {
        if (!in_condition.any(tree, entry.value_ptr.items)) continue;
        switch (try placeSteps(c, flow, function, loop, entry.key_ptr.*)) {
            .none => {},
            .up => up = true,
            .down => down = true,
            .factor => factor = true,
            .other => return .other,
        }
    }
    if (up != down) return if (factor) .other else .sum;
    if (factor and !up) return .factor;
    return .other;
}

/// The tokens of a node, for the sites within it.
const Span = struct {
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,

    fn of(tree: *const Ast, node: Ast.Node.Index) Span {
        return .{ .first = tree.firstToken(node), .last = tree.lastToken(node) };
    }
    fn has(span: Span, tree: *const Ast, node: Ast.Node.Index) bool {
        const at = tree.nodeMainToken(node);
        return at >= span.first and at <= span.last;
    }
    fn any(span: Span, tree: *const Ast, sites: []const Facts.accesses.Site) bool {
        for (sites) |site| if (span.has(tree, site.node)) return true;
        return false;
    }
};

/// What a loop does to a place its condition reads (`placeSteps`).
const Step = enum { none, up, down, factor, other };

/// What the loop `loop` does to a place its condition reads, by each write `Facts.accesses`
/// finds: none, steps it up or down by a sum, by a factor, or otherwise (a reset, a store of
/// another value, a pointer that may write it, a write in a function the loop may call).
fn placeSteps(c: *Context, flow: *Flow, function: Function.Id, loop: Ast.Node.Index, place: Facts.accesses.Place) Context.Error!Step {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    const in_loop: Span = .of(tree, loop);
    const local: ?Model.Declaration.Id = switch (place) {
        .declaration => |d| if (d.file == f.file and !Facts.accesses.global(c.facts, d)) d.index else null,
        .field => null,
    };
    var steps: Step = .none;
    var elsewhere = false;
    const in_file = [_]Project.FileId{f.file};
    var found_sites = Facts.accesses.writes(c.facts, place, if (local != null) &in_file else try ownerFiles(c, flow));
    while (try found_sites.next()) |site| {
        if (site.kind == .init or site.kind == .read) continue;
        const inside = site.file == f.file and in_loop.has(tree, site.node);
        if (!inside) {
            // A local's address may step it wherever the pointer goes; another function's
            // write of other memory changes it where the loop calls that function.
            if (local != null and (site.kind == .address or site.kind == .covered)) return .other;
            if (local == null and owner(flow, site.file, site.node) != function) elsewhere = true;
            continue;
        }
        if (site.reach != .exact) return .other;
        const step: Step = switch (site.kind) {
            .update => if (accesses.operatorOf(tree.nodeTag(site.node))) |update| switch (update.op) {
                .add => .up,
                .sub => .down,
                .mul, .div, .shl, .shr => .factor,
                else => .other,
            } else .other,
            .set => set: {
                const d = local orelse break :set .other;
                const value = site.value orelse break :set .other;
                if (stepOf(tree, model, d, .assign, value) != value) break :set switch (tree.nodeTag(value)) {
                    .add, .add_wrap, .add_sat => .up,
                    else => .down,
                };
                break :set if (scaled(tree, model, d, value)) .factor else .other;
            },
            else => .other,
        };
        if (step == .other) return .other;
        // Stepped up and down, or by a sum and a factor: no one direction counts.
        if (steps != .none and steps != step) return .other;
        steps = step;
    }
    if (elsewhere and try callsWithin(c, flow, function, loop)) return .other;
    return steps;
}

/// Whether a loop makes a call.
fn callsWithin(c: *Context, flow: *Flow, function: Function.Id, loop: Ast.Node.Index) Context.Error!bool {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const in_loop: Span = .of(tree, loop);
    for (f.nodes) |node| if (in_loop.has(tree, node) and try Facts.calls.at(c.facts, f.file, node) != null) return true;
    return false;
}

/// The files whose functions the flow reads.
fn ownerFiles(c: *Context, flow: *Flow) Context.Error![]const Project.FileId {
    var files: std.ArrayList(Project.FileId) = .empty;
    var each = flow.owners.keyIterator();
    while (each.next()) |file| try files.append(c.allocator, file.*);
    return files.items;
}

/// `control` of a `break` up to the labeled block it leaves.
fn controlWithin(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index, block: Ast.Node.Index) Context.Error!Dep {
    const tree = &c.project.at(flow.functions.items[@backingInt(function)].file).file.tree;
    return (try controlUpTo(c, flow, function, node, tree.firstToken(block))).ruling(c.allocator, flow.masks);
}

fn controlUpTo(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index, bound: ?Ast.TokenIndex) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    var out: Dep = .{};
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (bound) |token| if (token >= tree.firstToken(parent) and token <= tree.lastToken(parent)) break;
        switch (formAt(tree, parent)) {
            .fn_decl => break,
            // A statement before it that may jump past it (`leaves`) decides whether it runs.
            .body => {
                var buffer: [2]Ast.Node.Index = undefined;
                for (tree.blockStatements(&buffer, parent) orelse &.{}) |statement| {
                    if (statement == at) break;
                    out = try out.join(c.allocator, try leaves(c, flow, function, statement, bound));
                }
            },
            // A deferred write runs on whichever exit is taken: what decides each exit after it
            // decides what it reads.
            .deferred => out = try out.join(c.allocator, try exitsAfter(c, flow, function, parent)),
            // The right side of `and` and `or` runs as the left decides.
            .logic => switch (Facts.conditionOf(tree, parent)) {
                .both, .either => |sides| if (at == sides[1]) {
                    out = try out.join(c.allocator, try (try dep(c, flow, function, sides[0])).held().narrowed(c.allocator));
                },
                .not, .compare, .other => {},
            },
            .@"if" => {
                const branch = tree.fullIf(parent).?; // unreachable: the form is an if's
                if (at != branch.ast.cond_expr) out = try out.join(c.allocator, try (try dep(c, flow, function, branch.ast.cond_expr)).held().narrowed(c.allocator));
            },
            .@"switch" => {
                const choice = tree.fullSwitch(parent).?; // unreachable: the form is a switch's
                if (at != choice.ast.condition) out = try out.join(c.allocator, try (try dep(c, flow, function, choice.ast.condition)).held().narrowed(c.allocator));
                // A labeled switch is a loop: `continue :label value` dispatches again.
                if (choice.label_token != null) out = try out.join(c.allocator, try passes(c, flow, function, parent));
            },
            .@"catch", .@"orelse" => {
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                if (at == rhs) out = try out.join(c.allocator, try (try dep(c, flow, function, lhs)).held().narrowed(c.allocator));
            },
            .@"while", .@"for" => out = try out.join(c.allocator, try passes(c, flow, function, parent)),
            else => {},
        }
    }
    return out;
}

/// What decides how many passes a loop takes, and so how far what it steps goes: its
/// condition's operands or its inputs' bounds and lengths, and every condition inside it, any
/// of which may end a pass or the loop. Read once per round.
fn passes(c: *Context, flow: *Flow, function: Function.Id, loop: Ast.Node.Index) Context.Error!Dep {
    // Read once per round: on the round's memory while the rounds run, else the run's.
    const rule_memory = c.allocator;
    c.allocator = flow.round orelse c.facts.gpa;
    defer c.allocator = rule_memory;
    const f = flow.functions.items[@backingInt(function)];
    const key: Facts.Key = .{ .file = f.file, .node = loop };
    if (flow.loops.get(key)) |known_dep| return known_dep;
    // A loop read while it is being read gives what is known so far; the rounds settle it.
    try flow.loops.put(c.allocator, key, .{});
    const tree = &c.project.at(f.file).file.tree;
    var out: Dep = .{};
    if (tree.fullWhile(loop)) |w| out = try out.join(c.allocator, try operands(c, flow, function, w.ast.cond_expr));
    if (tree.fullSwitch(loop)) |choice| out = try out.join(c.allocator, (try dep(c, flow, function, choice.ast.condition)).held());
    if (tree.fullFor(loop)) |l| for (l.ast.inputs) |input| {
        if (tree.nodeTag(input) == .for_range) {
            const start, const end = tree.nodeData(input).node_and_opt_node;
            out = try out.join(c.allocator, (try dep(c, flow, function, start)).held());
            if (end.unwrap()) |last| out = try out.join(c.allocator, (try dep(c, flow, function, last)).held());
        } else out = try out.join(c.allocator, (try dep(c, flow, function, input)).measured());
    };
    const first = tree.firstToken(loop);
    const last = tree.lastToken(loop);
    for (f.nodes) |node| {
        const token = tree.nodeMainToken(node);
        if (token < first or token > last or node == loop) continue;
        switch (tree.nodeTag(node)) {
            .@"if", .if_simple => out = try out.join(c.allocator, try operands(c, flow, function, tree.fullIf(node).?.ast.cond_expr)),
            .@"while", .while_simple, .while_cont => out = try out.join(c.allocator, try operands(c, flow, function, tree.fullWhile(node).?.ast.cond_expr)),
            .@"switch", .switch_comma => out = try out.join(c.allocator, (try dep(c, flow, function, tree.fullSwitch(node).?.ast.condition)).held()),
            .@"catch", .@"orelse" => out = try out.join(c.allocator, try (try dep(c, flow, function, tree.nodeData(node).node_and_node[0])).held().narrowed(c.allocator)),
            // `continue :label value` of a labeled switch: the value it dispatches on next.
            .@"continue" => if (tree.nodeData(node).opt_token_and_opt_node[1].unwrap()) |value| {
                out = try out.join(c.allocator, (try dep(c, flow, function, value)).held());
            },
            else => {},
        }
    }
    try flow.loops.put(c.allocator, key, out);
    return out;
}

/// What decides whether `statement` jumps past what follows it, for a store to what `bound`
/// declares (none: what outlives the function): each jump in it that leaves it and is seen
/// there (a `return` or a `try`'s error, where the store outlives the function; a `break` or
/// `continue` to a block or loop around it that does not hold the declaration), what decides
/// that the jump is taken (`controlUpTo` within the statement), and whether a `try`'s operand
/// is an error. Read once per round.
fn leaves(c: *Context, flow: *Flow, function: Function.Id, statement: Ast.Node.Index, bound: ?Ast.TokenIndex) Context.Error!Dep {
    // Read once per round: on the round's memory while the rounds run, else the run's.
    const rule_memory = c.allocator;
    c.allocator = flow.round orelse c.facts.gpa;
    defer c.allocator = rule_memory;
    const f = flow.functions.items[@backingInt(function)];
    const key = .{ Facts.Key{ .file = f.file, .node = statement }, bound };
    if (flow.leaving.get(key)) |known_dep| return known_dep;
    // A statement read while it is being read gives what is known so far; the rounds settle it.
    try flow.leaving.put(c.allocator, key, .{});
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    const first = tree.firstToken(statement);
    const last = tree.lastToken(statement);
    const owners = flow.owners.get(f.file).?; // unreachable: the function's file is read
    const jumps = try jumpsOf(c, flow, f.file);
    var out: Dep = .{};
    // The first jump at or after the statement's first token.
    var low: usize = 0;
    var high: usize = jumps.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (tree.nodeMainToken(jumps[middle]) < first) low = middle + 1 else high = middle;
    }
    for (jumps[low..]) |node| {
        if (tree.nodeMainToken(node) > last) break;
        if (owners.at(@backingInt(node)) != function) continue;
        const seen = switch (tree.nodeTag(node)) {
            .@"return", .@"try" => bound == null,
            .@"break", .@"continue" => if (jumpTarget(tree, model, node)) |target| tree.firstToken(target) < first and (bound == null or bound.? < tree.firstToken(target)) else true,
            else => false,
        };
        if (!seen) continue;
        if (tree.nodeTag(node) == .@"try") out = try out.join(c.allocator, try (try dep(c, flow, function, tree.nodeData(node).node)).held().narrowed(c.allocator));
        out = try out.join(c.allocator, try controlUpTo(c, flow, function, node, first - 1));
    }
    try flow.leaving.put(c.allocator, key, out);
    return out;
}

/// A file's jumps in source order, found once.
fn jumpsOf(c: *Context, flow: *Flow, file: Project.FileId) Context.Error![]const Ast.Node.Index {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    if (flow.jumps.get(file)) |found_before| return found_before;
    const tree = &c.project.at(file).file.tree;
    var found: std.ArrayList(Ast.Node.Index) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| switch (tag) {
        .@"return", .@"try", .@"break", .@"continue" => try found.append(c.allocator, @fromBackingInt(@intCast(i))),
        else => {},
    };
    std.mem.sort(Ast.Node.Index, found.items, tree, struct {
        fn before(t: *const Ast, a: Ast.Node.Index, b: Ast.Node.Index) bool {
            return t.nodeMainToken(a) < t.nodeMainToken(b);
        }
    }.before);
    try flow.jumps.put(c.allocator, file, found.items);
    return found.items;
}

/// What decides each exit after a deferred write (`defer`, `errdefer`): every jump of the
/// statements after it, in each block around it.
fn exitsAfter(c: *Context, flow: *Flow, function: Function.Id, deferred: Ast.Node.Index) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    var out: Dep = .{};
    var at = deferred;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl) break;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, parent) orelse continue;
        var after = false;
        for (statements) |statement| {
            if (after) out = try out.join(c.allocator, try leaves(c, flow, function, statement, null));
            if (statement == at) after = true;
        }
    }
    return out;
}

/// The block, loop or labeled switch a `break` or `continue` goes to: the one its label names,
/// or the innermost loop.
fn jumpTarget(tree: *const Ast, model: *const Model, jump: Ast.Node.Index) ?Ast.Node.Index {
    const label = tree.nodeData(jump).opt_token_and_opt_node[0].unwrap();
    var at = jump;
    while (model.parentOf(at)) |parent| : (at = parent) {
        const named: ?Ast.TokenIndex = if (tree.fullWhile(parent)) |loop| loop.label_token else if (tree.fullFor(parent)) |loop| loop.label_token else if (tree.fullSwitch(parent)) |choice| choice.label_token else switch (tree.nodeTag(parent)) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => if (tree.tokenTag(tree.nodeMainToken(parent) -| 1) == .colon) tree.nodeMainToken(parent) - 2 else null,
            else => null,
        };
        if (label) |wanted| {
            if (named) |name| if (std.mem.eql(u8, tree.tokenSlice(name), tree.tokenSlice(wanted))) return parent;
        } else if (tree.fullWhile(parent) != null or tree.fullFor(parent) != null) return parent;
    }
    return null;
}

/// A condition's operands as they are: a counter compared with a bound runs as far as the bound.
fn operands(c: *Context, flow: *Flow, function: Function.Id, condition: Ast.Node.Index) Context.Error!Dep {
    const tree = &c.project.at(flow.functions.items[@backingInt(function)].file).file.tree;
    switch (Facts.conditionOf(tree, condition)) {
        .not => |inner| return operands(c, flow, function, inner),
        .both, .either => |sides| return try (try operands(c, flow, function, sides[0])).join(c.allocator, try operands(c, flow, function, sides[1])),
        .compare => |compared| return try (try operands(c, flow, function, compared.left)).join(c.allocator, try operands(c, flow, function, compared.right)),
        .other => |value| return (try dep(c, flow, function, value)).held(),
    }
}

//======================================================================
// Sinks: where a rule asks whether a fact reaches.
//======================================================================

/// A value a call gives a sink: `value` (its length, where `length`) is what the rule judges,
/// at the call `at`. Undecided (`decided` false) where the value may reach the sink through a
/// call that does not resolve.
pub const SinkSite = struct {
    file: Project.FileId,
    value: Ast.Node.Index,
    at: Ast.Node.Index,
    /// What the call calls, as written: `f(a)`'s `f`, `@call`'s second argument.
    callee_expr: Ast.Node.Index,
    callee: ?Facts.Decl,
    /// The parameter, the receiver first.
    position: usize,
    length: bool = false,
    /// The sink takes the value only kept to a range or as a comparison decides: a peer's
    /// number is data there.
    narrowed: bool = false,
    decided: bool = true,
    /// Every instantiation's summary takes it through a call that does not resolve: the
    /// instantiation this call makes may decide it (`decidedSite`), read only where asked.
    refine: bool = false,
};

/// `site` as the instantiation its call makes reads it (`instanceSizes`), where every
/// instantiation's summary leaves a size undecided (`SinkSite.refine`): null where that one
/// sizes nothing by it. Asked of a site whose value is input, never of every site.
pub fn decidedSite(c: *Context, fact: Fact, site: SinkSite) Context.Error!?SinkSite {
    if (!site.refine) return site;
    const sized = fact.flow.sized.?; // unreachable: a site to refine was found through the summary
    const summary = try instanceSizes(c, sized, site.file, site.at, site.callee.?); // unreachable: one to refine has a summary, so a callee
    const slot = if (site.length) lengthSlot(site.position) else valueSlot(site.position);
    const sure, const ranged, const maybe = switch (summary) {
        .read => |read| if (read.fixed.has(site.position)) return null else .{ read.sure.has(slot), read.ranged.has(slot), read.maybe.has(slot) },
        .allocation => .{ site.position > 0 and !site.length, false, false },
        .unknown => .{ false, false, true },
    };
    if (!sure and !ranged and !maybe) return null;
    var out = site;
    out.narrowed = !sure and ranged and !maybe;
    out.decided = sure or (ranged and !maybe);
    out.refine = false;
    return out;
}

/// The sites of the sinks `fact`'s spec judges in `file` (`Spec.sinks`), read once per run.
/// `size`: what the program hands a function outside it that sizes memory or work by it, found
/// by meaning: what its body gives an allocation (std's `Allocator.rawAlloc`, `rawResize`,
/// `rawRemap`) or counts a loop's passes by, through every call it makes. `peer_write`: what
/// a call outside the program writes with a writer whose bytes reach a peer (`peerSites`).
pub fn sinkSites(c: *Context, fact: Fact, file: Project.FileId) Context.Error![]const SinkSite {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    if (!fact.spec.sinks.size and !fact.spec.sinks.peer_write) return &.{};
    const flow = fact.flow;
    if (flow.sink_sites.get(.{ fact.lane, file })) |known_sites| return known_sites;
    var calls: std.ArrayList(Callee) = .empty;
    if (flow.owners.get(file)) |owners| for (0..owners.syntax.of.len) |i| {
        if (owners.at(i) == null) continue;
        try calls.append(c.allocator, (try resolveCall(c, flow, file, @fromBackingInt(@intCast(i)))) orelse continue);
    };
    var out: std.ArrayList(SinkSite) = .empty;
    if (fact.spec.sinks.size) {
        // Only a call given what the fact follows is read: a clean argument is no site a rule
        // judges, and the summary reads no body for it.
        var given: std.ArrayList(Callee) = .empty;
        for (calls.items) |callee| if (try carries(c, fact, file, callee)) try given.append(c.allocator, callee);
        const sized = try sizesFlow(c, flow, given.items);
        for (given.items) |callee| try sizeSites(c, sized, file, callee, &out);
    }
    if (fact.spec.sinks.peer_write) for (calls.items) |callee| try peerSites(c, flow, file, callee, &out);
    const sites = try out.toOwnedSlice(c.allocator);
    try flow.sink_sites.put(c.allocator, .{ fact.lane, file }, sites);
    return sites;
}

/// What a call outside the program writes where a peer reads it: given a writer whose bytes
/// reach one (the peer-writer fact's, `Spec.Source.peer_writer`), each other argument, each
/// part of a literal one apart (`w.print("{s}", .{name})`'s `name`). Undecided where the
/// writer may reach a peer through a call that does not resolve, or the callee itself does
/// not. The program's own callee writes in its own body, where its parameters hold the writer.
fn peerSites(c: *Context, flow: *Flow, file: Project.FileId, callee: Callee, out: *std.ArrayList(SinkSite)) Context.Error!void {
    switch (callee.kind) {
        .program, .aegis, .holder, .source => return,
        .choice => |each| {
            for (each) |one| try peerSites(c, flow, file, one, out);
            return;
        },
        .outside, .none => {},
    }
    // The writer is an argument the callee takes as a pointer to one value it writes through
    // (`self: *Writer`), or untyped and not a literal; every other one is written, whatever
    // memory it shares with the writer (`.{ name }`, `&parts`).
    const params = if (callee.decl) |decl| try writerParams(c, decl) else null;
    var writer: Level = .clean;
    var taken: Slots = .{};
    for (callee.args, 0..) |arg, position| {
        const single = if (params) |p| p.single.has(position) else false;
        const untyped = if (params) |p| p.untyped.has(position) else true;
        if (!single and (!untyped or madeAtCall(c, file, arg))) continue;
        // Only a value whose type may hold a writer is one (`writerHold`): bytes, a list or a
        // number the fact reached through std's writes or a branch are written, never the
        // writer. One that may hold a writer only through what does not resolve (an
        // allocator's opaque state) is no writer shown: unknown at most.
        const held = try writerHold(c, flow, try c.facts.resolve(file, arg), 0);
        if (held == .none) continue;
        const writer_level = try levelIn(c, flow, file, arg, flow.masks.peer_writer);
        const level: Level = if (held == .may and writer_level != .clean) .unknown else writer_level;
        if (level == .clean) continue;
        writer = writer.join(level);
        taken = try taken.with(c.allocator, position);
    }
    if (writer == .clean) return;
    const decided = writer.reaches(.data) and callee.kind != .none;
    for (callee.args, 0..) |arg, position| if (!taken.has(position)) try writtenParts(c, file, callee, arg, position, decided, out);
}

/// The parameters a function may be handed its writer by, by position, the receiver first: a
/// pointer to one mutable value (`*Writer`), and one of a type the declaration does not spell
/// (`anytype`).
fn writerParams(c: *Context, decl: Facts.Decl) Context.Error!struct { single: Slots, untyped: Slots } {
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return .{ .single = .{}, .untyped = .{} };
    var single: Slots = .{};
    var untyped: Slots = .{};
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        const kind = param.type_expr orelse {
            untyped = try untyped.with(c.allocator, position);
            continue;
        };
        var at = kind;
        if (formAt(tree, at) == .optional_type) at = tree.nodeData(at).node;
        const pointer = tree.fullPtrType(at) orelse continue;
        if (pointer.size == .one and pointer.const_token == null) single = try single.with(c.allocator, position);
    }
    return .{ .single = single, .untyped = untyped };
}

/// Whether `node` is a struct or an array literal: a value made at the call, no writer.
fn madeAtCall(c: *Context, file: Project.FileId, node: Ast.Node.Index) bool {
    const tree = &c.project.at(file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    return tree.fullStructInit(&buffer, node) != null or tree.fullArrayInit(&buffer, node) != null;
}

fn writtenParts(c: *Context, file: Project.FileId, callee: Callee, node: Ast.Node.Index, position: usize, decided: bool, out: *std.ArrayList(SinkSite)) Context.Error!void {
    const tree = &c.project.at(file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, node)) |literal| {
        for (literal.ast.fields) |field| try writtenParts(c, file, callee, field, position, decided, out);
        return;
    }
    if (tree.fullArrayInit(&buffer, node)) |literal| {
        for (literal.ast.elements) |element| try writtenParts(c, file, callee, element, position, decided, out);
        return;
    }
    try out.append(c.allocator, .{ .file = file, .value = node, .at = callee.node, .callee_expr = callee.callee_expr, .callee = callee.decl, .position = position, .decided = decided });
}

/// The most a value is in the lanes `mask` holds, or clean outside the functions the flow reads.
fn levelIn(c: *Context, flow: *Flow, file: Project.FileId, node: Ast.Node.Index, mask: Mask) Context.Error!Level {
    const function = owner(flow, file, node) orelse return .clean;
    const lanes: [lane_count]u2 = concrete(flow, function, try dep(c, flow, function, node)).masked(mask).v;
    var most: Level = .clean;
    for (lanes) |lane| most = most.join(@fromBackingInt(lane));
    return most;
}

/// What a value written whole shows of an error by its type: an error's name where it holds
/// one or may (an error union formatted whole), unknown where its type does not resolve. A
/// literal, a slice, an address or an operator's result holds no error value of its own.
pub fn errorShown(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!Level {
    const tree = &c.project.at(file).file.tree;
    switch (formAt(tree, node)) {
        .leaf => if (!spellsName(tree, node)) return .clean,
        .member, .call, .unwrap_optional, .deref, .array_access, .@"orelse", .@"catch", .grouped => {},
        .builtin => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            if (!std.mem.eql(u8, name, "@as") and !std.mem.eql(u8, name, "@errorCast") and !std.mem.eql(u8, name, "@field")) return .clean;
        },
        else => return .clean,
    }
    return switch (errorIn(try c.facts.resolve(file, node), .written)) {
        .yes => .data,
        .no => .clean,
        .unknown => .unknown,
    };
}

/// Whether a call outside the program is given a value, or memory whose length, the fact
/// reaches its sinks with (`Spec.reaches`), or may.
fn carries(c: *Context, fact: Fact, file: Project.FileId, callee: Callee) Context.Error!bool {
    switch (callee.kind) {
        .holder => return false,
        .program => if (judged(c, callee.decl.?.file)) return false, // unreachable: a program callee has its declaration
        .choice => |each| {
            for (each) |one| if (try carries(c, fact, file, one)) return true;
            return false;
        },
        .none, .source, .outside, .aegis => {},
    }
    for (callee.args) |arg| for ([_]Level{ try levelAt(c, fact, file, arg), try lengthAt(c, fact, file, arg) }) |level| {
        if (level == .unknown or level.reaches(fact.spec.reaches)) return true;
    };
    return false;
}

/// The level of the length of the memory `node` gives, as the fact reads it.
pub fn lengthAt(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index) Context.Error!Level {
    const function = owner(fact.flow, file, node) orelse return .clean;
    return concreteLength(fact.flow, function, try dep(c, fact.flow, function, node)).at(fact.lane);
}

pub const Unlimited = enum { yes, no, unknown };

/// Whether a call reads with no limit: it is given std's `Io.Limit.unlimited`, or calls a
/// function outside the program whose body gives it, through every call it makes
/// (`streamRemaining`'s `stream(w, .unlimited)`): how much it reads is the peer's to choose.
/// Unknown where std's `Io.Limit` does not resolve.
pub fn unlimitedRead(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index) Context.Error!Unlimited {
    const limits = switch (try Governed.declarations(c, "std", "Io.Limit")) {
        .decls => |decls| decls,
        .none => return .no,
        .unknown => return .unknown,
    };
    const callee = (try resolveCall(c, fact.flow, file, node)) orelse return .no;
    if (try givesUnlimited(c, limits, file, callee)) return .yes;
    const sized = try sizesFlow(c, fact.flow, &.{callee});
    try unlimitedIn(c, sized, limits);
    const one = [1]Callee{callee};
    for (if (callee.kind == .choice) callee.kind.choice else &one) |each| {
        const decl = each.decl orelse continue;
        const at = fnDecl(c, decl) orelse continue;
        const id = sized.by_node.get(.{ .file = decl.file, .node = at }) orelse continue;
        if (sized.unlimited.contains(id)) return .yes;
    }
    return .no;
}

/// The summary's functions that read with no limit (`Flow.unlimited`): each that gives a call
/// std's `Io.Limit.unlimited` or calls one that does, read again as the summary grows.
fn unlimitedIn(c: *Context, sized: *Flow, limits: []const Facts.Decl) Context.Error!void {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    if (sized.unlimited_read == sized.functions.items.len) return;
    sized.unlimited_read = sized.functions.items.len;
    var changed = true;
    while (changed) {
        changed = false;
        for (sized.functions.items, 0..) |f, i| {
            const id: Function.Id = @fromBackingInt(@intCast(i));
            if (sized.unlimited.contains(id)) continue;
            for (f.nodes) |node| {
                const callee = (try resolveCall(c, sized, f.file, node)) orelse continue;
                const one = [1]Callee{callee};
                const reads = for (if (callee.kind == .choice) callee.kind.choice else &one) |each| switch (each.kind) {
                    .program => |target| if (sized.unlimited.contains(target)) break true,
                    else => {},
                } else try givesUnlimited(c, limits, f.file, callee);
                if (!reads) continue;
                try sized.unlimited.put(c.allocator, id, {});
                changed = true;
                break;
            }
        }
    }
}

/// Whether a call is given std's `Io.Limit.unlimited` (`limits` declares the type): an argument
/// that names that tag (`Facts.tagNamed`).
fn givesUnlimited(c: *Context, limits: []const Facts.Decl, file: Project.FileId, callee: Callee) Context.Error!bool {
    for (callee.args) |arg| {
        const tag = (try c.facts.tagNamed(file, arg)) orelse continue;
        const unlimited = c.facts.member(tag.container, "unlimited") orelse continue;
        if (!memberIs(c, tag.container, tag.name, unlimited)) continue;
        for (limits) |limit| switch (try c.facts.declaration(limit)) {
            .container => |k| if (k.file == tag.container.file and k.scope == tag.container.scope) return true,
            .alternatives => {},
            else => {},
        };
    }
    return false;
}

/// Whether the run judges the sites in `file`: one it selects. What a file of the package it
/// does not select, or a dependency's, sizes by is read only where a judged file calls it.
fn judged(c: *Context, file: Project.FileId) bool {
    return c.project.at(file).input.selected;
}

/// The sizes a call of the program gives a function outside it: each argument whose value or
/// length the callee's body sizes work by. The program's own callee in a file the run judges is
/// read at its own calls; one in a file it does not (a dependency's) is read by its body here,
/// and so is aegis's, which allocates what it is given (`SecretBytes.init(gpa, n)`).
fn sizeSites(c: *Context, sized: *Flow, file: Project.FileId, callee: Callee, out: *std.ArrayList(SinkSite)) Context.Error!void {
    switch (callee.kind) {
        .holder => return,
        .choice => |each| {
            for (each) |one| try sizeSites(c, sized, file, one, out);
            return;
        },
        .program => if (judged(c, callee.decl.?.file)) return, // unreachable: a program callee has its declaration
        .none, .source, .outside, .aegis => {},
    }
    const summary = try sizesOf(c, sized, callee.decl);
    // Taken through a call every instantiation does not resolve: the one this call makes may
    // decide it, read where a rule asks (`decidedSite`).
    const refine = summary == .read and !summary.read.maybe.empty();
    for (callee.args, 0..) |arg, position| {
        // A comptime parameter is fixed when the program is compiled: no input sizes by it.
        if (summary == .read and summary.read.fixed.has(position)) continue;
        for ([_]bool{ false, true }) |length| {
            const slot = if (length) lengthSlot(position) else valueSlot(position);
            const sure, const ranged, const maybe = switch (summary) {
                .read => |read| .{ read.sure.has(slot), read.ranged.has(slot), read.maybe.has(slot) },
                // An allocation's first parameter is the allocator itself.
                .allocation => .{ position > 0 and !length, false, false },
                .unknown => .{ false, false, true },
            };
            if (!sure and !ranged and !maybe) continue;
            // Kept to a range on one path and taken through a call that does not resolve on
            // another, it may be taken whole: undecided, not data.
            try out.append(c.allocator, .{ .file = file, .value = arg, .at = callee.node, .callee_expr = callee.callee_expr, .callee = callee.decl, .position = position, .length = length, .narrowed = !sure and ranged and !maybe, .decided = sure or (ranged and !maybe), .refine = refine });
        }
    }
}

/// What a function outside the program sizes by, by slot: an allocation every argument but the
/// allocator; another what its body sizes by as the summary reads it; one with no body read,
/// or none at all, anything, undecided.
fn sizesOf(c: *Context, sized: *Flow, decl: ?Facts.Decl) Context.Error!Summary {
    const d = decl orelse return .unknown;
    if (!sized.allocations_known) return .unknown;
    switch (try allocation(c, sized, d)) {
        .yes => return .allocation,
        .no => {},
        .unknown => return .unknown,
    }
    const node = fnDecl(c, d) orelse return .unknown;
    // std's, read as its record answers for it (`Facts.read_records`).
    if (c.facts.read_records and sized.shared == null) if (try openSizes(c, d)) |summary| return summary;
    const id = sized.by_node.get(.{ .file = d.file, .node = node }) orelse return .unknown;
    const f = sized.functions.items[@backingInt(id)];
    return .{ .read = .{ .sure = f.sizes, .ranged = f.ranged_sizes, .maybe = f.maybe_sizes, .fixed = f.fixed } };
}

/// What std's open-world record of `decl` sizes work by (`OpenUnit`), read and closed there the
/// first time it is asked; null for a function outside std.
fn openSizes(c: *Context, decl: Facts.Decl) Context.Error!?Summary {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const unit = try openUnit(c);
    const file = unit.in_unit[@backingInt(decl.file)] orelse return null;
    const in_unit: Facts.Decl = .{ .file = file, .index = decl.index };
    const unit_flow = try openFlow(unit);
    const node = fnDecl(&unit.context, in_unit) orelse return .unknown;
    if (unit_flow.by_node.get(.{ .file = file, .node = node }) == null) {
        var next: std.ArrayList(Queued) = .empty;
        const first = unit_flow.functions.items.len;
        try reach(&unit.context, unit_flow, in_unit, null, &next);
        try closeOpen(c, unit, unit_flow, &next, first);
    }
    const id = unit_flow.by_node.get(.{ .file = file, .node = node }) orelse return .unknown;
    const f = unit_flow.functions.items[@backingInt(id)];
    if (f.exhausted) return .unknown;
    return .{ .read = .{ .sure = f.sizes, .ranged = f.ranged_sizes, .maybe = f.maybe_sizes, .fixed = f.fixed } };
}

/// Closes what `next` holds in std's open-world summary on a budget of its own, a file's as the
/// run gives each file: an answer does not hang on what was read before it. Where the budget
/// runs out, each function first read here (from `first` on) is `exhausted`.
fn closeOpen(c: *Context, unit: *OpenUnit, unit_flow: *Flow, next: *std.ArrayList(Queued), first: usize) Context.Error!void {
    if (next.items.len == 0) return;
    const asker = unit.facts.enter(c.config.fact_budget);
    const closed = closeSummary(&unit.context, unit_flow, next);
    const short = unit.facts.leave(asker);
    try closed;
    if (!short) return;
    // What std's Facts built short of the budget (an index, a memo) would answer a later
    // closing as if complete, as the Runner's `Facts.forget` knows of a file's: later closings
    // read on a Facts of their own. This one is left whole, for what the summary already holds
    // (its program, its readings) points into it.
    const fresh = try c.facts.gpa.create(Facts);
    fresh.* = .{ .project = &unit.project, .gpa = c.facts.gpa, .open_world = true };
    unit.facts = fresh;
    unit.context.facts = fresh;
    // Each may size work by any of its parameters' values and lengths: what a function read
    // later and calling one takes from it is undecided wherever it reaches.
    for (unit_flow.functions.items[first..]) |*f| {
        f.exhausted = true;
        for (0..f.params.len) |i| {
            f.maybe_sizes = try f.maybe_sizes.with(c.facts.gpa, valueSlot(i));
            f.maybe_sizes = try f.maybe_sizes.with(c.facts.gpa, lengthSlot(i));
        }
    }
}

/// The open unit's summary of every instantiation, made the first time it is asked.
fn openFlow(unit: *OpenUnit) Context.Error!*Flow {
    if (unit.flow) |made| return made;
    const made = try summaryFlow(&unit.context, try Program.get(&unit.context));
    unit.flow = made;
    return made;
}

/// A closed size summary's record (designs/glint-summaries.md step 4): each function it holds,
/// by its `fn_decl`, with the slots whose value or length it sizes work by, surely, kept to a
/// range, maybe, and its comptime ones. A function's sizes are by parameter, the same whoever
/// calls it (`closeSummary`), so the record is the summary's whole answer for it.
const SizeRecord = struct { at: Facts.Key, exhausted: bool = false, sure: Slots, ranged: Slots, maybe: Slots, fixed: Slots };

fn writeSizes(w: *Records.Writer, flow: *const Flow) Records.WriteError!void {
    try w.number(@intCast(flow.functions.items.len));
    for (flow.functions.items) |f| {
        try w.key(.{ .file = f.file, .node = f.node });
        try w.number(@intFromBool(f.exhausted));
        for ([_]Slots{ f.sizes, f.ranged_sizes, f.maybe_sizes, f.fixed }) |set| {
            try w.wide(set.word);
            try w.number(@intCast(set.tail.len));
            for (set.tail) |word| try w.wide(word);
        }
    }
}

fn readSizes(r: *Records.Reader, gpa: Allocator) Records.ReadError![]const SizeRecord {
    const out = try gpa.alloc(SizeRecord, try r.count());
    for (out) |*one| {
        const at = try r.key();
        const exhausted = switch (try r.number()) {
            0 => false,
            1 => true,
            else => return error.Malformed,
        };
        var sets: [4]Slots = undefined;
        for (&sets) |*set| {
            const word = try r.wide();
            const tail = try gpa.alloc(u64, try r.count());
            for (tail) |*t| t.* = try r.wide();
            set.* = .{ .word = word, .tail = tail };
        }
        one.* = .{ .at = at, .exhausted = exhausted, .sure = sets[0], .ranged = sets[1], .maybe = sets[2], .fixed = sets[3] };
    }
    return out;
}

/// Summaries' cross-check (`Facts.check_records`) of a closed size summary: written and read
/// back, each function's record is what the flow holds for it.
fn checkSizes(c: *Context, flow: *const Flow) Context.Error!void {
    var w = try Records.checkWriter(c.facts);
    defer w.deinit();
    writeSizes(&w, flow) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unnamed => unreachable, // unreachable: every file of the run is named
    };
    var r = Records.Reader.init(c.facts, w.names, w.bytes.items) catch |err| std.debug.panic("summary cross-check: a size summary does not read back: {t}", .{err});
    defer r.deinit();
    const back = readSizes(&r, c.facts.gpa) catch |err| std.debug.panic("summary cross-check: a size summary does not read back: {t}", .{err});
    if (!r.done() or back.len != flow.functions.items.len) std.debug.panic("summary cross-check: a size summary reads back other functions", .{});
    for (back) |one| {
        const id = flow.by_node.get(one.at) orelse std.debug.panic("summary cross-check: a size summary reads back a function it does not hold", .{});
        const f = flow.functions.items[@backingInt(id)];
        if (!one.sure.eql(f.sizes) or !one.ranged.eql(f.ranged_sizes) or !one.maybe.eql(f.maybe_sizes) or !one.fixed.eql(f.fixed)) std.debug.panic("summary cross-check: a size summary reads back other sizes", .{});
    }
    // The summary of every instantiation is what a unit's record answers for. One closed short
    // of the file's budget (`Facts.short`) is no measure of it: what came back unknown(budget) sizes as it may, so
    // std's record, closed on a budget of its own, may decide further than it; the file is
    // exhausted, and the Runner's `Facts.forget` drops the summary before another file reads it.
    if (flow.shared == null and !c.facts.short) try checkOpen(c, flow);
}

/// std read alone, in the open world (`Facts.open_world`): what a unit's size record holds, for
/// every program that may import it (designs/glint-summaries.md, step 4). Its files are the
/// run's std files, read from the run's store, under the names they have in the run.
const OpenUnit = struct {
    built: bool = false,
    project: Project = undefined,
    facts: *Facts = undefined,
    context: Context = undefined,
    /// Each file of the run's in the unit, where it is std's.
    in_unit: []?Project.FileId = &.{},
    /// Per unit file, each function by its `fn_decl`.
    functions: std.AutoHashMapUnmanaged(Facts.Key, Facts.Decl) = .empty,
    flow: ?*Flow = null,
    /// The names each run writes and reads the unit's files by: the same names in both.
    unit_names: Records.Names = undefined,
    run_names: Records.Names = undefined,
    /// The run's functions whose live sizes a record was checked against.
    checked: std.AutoHashMapUnmanaged(Facts.Key, void) = .empty,
};

fn openUnit(c: *Context) Context.Error!*OpenUnit {
    const unit = try c.facts.memo(OpenUnit);
    if (unit.built) return unit;
    unit.built = true;
    const gpa = c.facts.gpa;
    var inputs: std.ArrayList(Project.Input) = .empty;
    unit.in_unit = try gpa.alloc(?Project.FileId, c.project.sources.len);
    @memset(unit.in_unit, null);
    for (c.project.sources) |*each| {
        if (!try c.facts.standard(each.id)) continue;
        unit.in_unit[@backingInt(each.id)] = @fromBackingInt(@intCast(inputs.items.len));
        var input = each.input;
        input.selected = false;
        try inputs.append(gpa, input);
    }
    var imports: std.ArrayList(Project.Import) = .empty;
    var root: ?Project.FileId = null;
    var named = false;
    for (c.project.imports) |edge| {
        const target = unit.in_unit[@backingInt(edge.target)] orelse continue;
        const by_name = std.mem.eql(u8, edge.spelling, "std");
        if (by_name) root = target;
        const from = unit.in_unit[@backingInt(edge.from)] orelse continue;
        named = named or by_name;
        try imports.append(gpa, .{ .from = @backingInt(from), .spelling = edge.spelling, .target = @backingInt(target), .compilation = edge.in });
    }
    // std's module may import itself by its name: where no file of std does, its root does, so
    // std alone knows its files (`Facts.outside`) as a program importing it does.
    if (!named) if (root) |file| try imports.append(gpa, .{ .from = @backingInt(file), .spelling = "std", .target = @backingInt(file) });
    unit.project = Project.init(gpa, inputs.items, imports.items, .{ .store = c.project.store }) catch |err| std.debug.panic("summary cross-check: std alone does not make a project: {t}", .{err});
    unit.facts = try gpa.create(Facts);
    unit.facts.* = .{ .project = &unit.project, .gpa = gpa, .open_world = true };
    unit.context = c.*;
    unit.context.project = &unit.project;
    unit.context.facts = unit.facts;
    unit.context.allocator = gpa;
    if (unit.project.sources.len > 0) unit.context.file = unit.project.sources[0].id;
    unit.unit_names = try Records.Names.byInput(gpa, &unit.project);
    unit.run_names = try Records.Names.byInput(gpa, c.project);
    for (unit.project.sources) |*each| for (each.model.declarations, 0..) |record, d| {
        if (record.kind != .function) continue;
        const decl: Facts.Decl = .{ .file = each.id, .index = @fromBackingInt(@intCast(d)) };
        const node = fnDecl(&unit.context, decl) orelse continue;
        try unit.functions.put(gpa, .{ .file = each.id, .node = node }, decl);
    };
    return unit;
}

/// Summaries' cross-check of the open world: each std function of the run's closed summary of
/// every instantiation is read again in std alone (`OpenUnit`), and its record, read back into
/// the run, must be decided no further than the live summary for any slot. Where the live
/// summary sizes work by a slot, surely or as it may, the record does too, surely or as it may;
/// where only kept to a range, the record does at least that; and a slot the record holds
/// comptime is comptime here. A record decided further would clear a site in this program, so
/// it stops the run.
fn checkOpen(c: *Context, flow: *const Flow) Context.Error!void {
    const unit = try openUnit(c);
    var next: std.ArrayList(Queued) = .empty;
    const unit_flow = try openFlow(unit);
    const first = unit_flow.functions.items.len;
    for (flow.functions.items) |f| {
        if (unit.checked.contains(.{ .file = f.file, .node = f.node })) continue;
        const file = unit.in_unit[@backingInt(f.file)] orelse continue;
        const decl = unit.functions.get(.{ .file = file, .node = f.node }) orelse continue;
        try reach(&unit.context, unit_flow, decl, null, &next);
    }
    try closeOpen(c, unit, unit_flow, &next, first);
    var w = Records.Writer.init(c.facts.gpa, unit.facts, &unit.unit_names) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unnamed => unreachable, // unreachable: every file of the unit is named
    };
    defer w.deinit();
    writeSizes(&w, unit_flow) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unnamed => unreachable, // unreachable: every file of the unit is named
    };
    var r = Records.Reader.init(c.facts, &unit.run_names, w.bytes.items) catch |err| std.debug.panic("summary cross-check: std's size records do not read into the run: {t}", .{err});
    defer r.deinit();
    const back = readSizes(&r, c.facts.gpa) catch |err| std.debug.panic("summary cross-check: std's size records do not read into the run: {t}", .{err});
    for (back) |one| {
        const id = flow.by_node.get(one.at) orelse continue;
        if ((try unit.checked.getOrPut(c.facts.gpa, one.at)).found_existing) continue;
        // An exhausted record answers unknown: undecided, whatever the run finds.
        if (one.exhausted) continue;
        const f = flow.functions.items[@backingInt(id)];
        const sized_by = try one.sure.unite(c.facts.gpa, one.maybe);
        const at_most = try sized_by.unite(c.facts.gpa, one.ranged);
        if (!f.sizes.subset(sized_by) or !f.maybe_sizes.subset(sized_by) or !f.ranged_sizes.subset(at_most) or !one.fixed.subset(f.fixed)) {
            const tree = &c.project.at(f.file).file.tree;
            const location = tree.tokenLocation(0, tree.firstToken(f.node));
            std.debug.panic("summary cross-check: std's open-world size record of {s}:{d} is decided further than the run's summary (sure, ranged, maybe, fixed: record {x} {x} {x} {x}, run {x} {x} {x} {x})", .{ c.project.at(f.file).input.name, location.line + 1, one.sure.word, one.ranged.word, one.maybe.word, one.fixed.word, f.sizes.word, f.ranged_sizes.word, f.maybe_sizes.word, f.fixed.word });
        }
    }
}

/// What a function outside the program sizes by, by slot (`sizesOf`).
const Summary = union(enum) { read: struct { sure: Slots, ranged: Slots, maybe: Slots, fixed: Slots }, allocation, unknown };

const Allocation = enum { yes, no, unknown };

/// Whether `decl` is one of std's allocations (`Flow.allocations`), by what it aliases:
/// not known where the alias does not resolve.
fn allocation(c: *Context, flow: *const Flow, decl: Facts.Decl) Context.Error!Allocation {
    const origin = switch (try c.facts.origin(decl)) {
        .decl => |found| found,
        .none => decl,
        .unknown => return .unknown,
    };
    return if (flow.allocations.contains(origin)) .yes else .no;
}

/// The summary of the code outside the program that `main`'s calls reach, grown by `calls`:
/// from each function outside the program one of them calls, through each function that one
/// calls, what each body sizes work by, as every instantiation reads it. A function read is
/// closed under its calls, so one read for an earlier call is not changed by a later one.
fn sizesFlow(c: *Context, main: *Flow, calls: []const Callee) Context.Error!*Flow {
    const flow = main.sized orelse made: {
        const made = try summaryFlow(c, main.program);
        main.sized = made;
        break :made made;
    };
    var next: std.ArrayList(Queued) = .empty;
    for (calls) |callee| {
        const one = [1]Callee{callee};
        for (if (callee.kind == .choice) callee.kind.choice else &one) |each| switch (each.kind) {
            .source, .outside, .aegis => try reach(c, flow, each.decl.?, null, &next),
            .program => if (!judged(c, each.decl.?.file)) try reach(c, flow, each.decl.?, null, &next),
            .holder, .choice, .none => {},
        };
    }
    if (next.items.len == 0) return flow;
    try closeSummary(c, flow, &next);
    return flow;
}

/// A summary's flow, read for no fact, over the program `program`.
fn summaryFlow(c: *Context, program: *const Program) Context.Error!*Flow {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const made = try c.allocator.create(Flow);
    made.* = .{};
    made.program = program;
    try known(c, made);
    return made;
}

/// What the program's call `callee` in `file` hands a generic outside the program sizes work
/// by in the one instantiation the call makes (`Facts.bind`): a summary of its own, each
/// function in it read with the bindings its chain of calls gives (`Function.readings`), so a
/// call on what a generic's parameter binds (`ctx.hash(key)` in std's `HashMap`) calls what
/// this instantiation is given. One summary per instantiation, closed as it is read.
fn instanceSizes(c: *Context, sized: *Flow, file: Project.FileId, node: Ast.Node.Index, decl: Facts.Decl) Context.Error!Summary {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const tree = &c.project.at(file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return sizesOf(c, sized, decl);
    const env = try c.facts.bind(file, call, decl, null);
    for (sized.instances.items) |instance| if (sameReading(instance.env, env)) return sizesOf(c, instance.flow, decl);
    const flow = try summaryFlow(c, sized.program);
    flow.shared = sized;
    try sized.instances.append(c.allocator, .{ .env = env, .flow = flow });
    var next: std.ArrayList(Queued) = .empty;
    try reach(c, flow, decl, env, &next);
    try closeSummary(c, flow, &next);
    return sizesOf(c, flow, decl);
}

/// Whether two readings bind one instantiation: one function, its arguments' values alike.
fn sameReading(a: *const Facts.Env, b: *const Facts.Env) bool {
    if (!std.meta.eql(a.function, b.function) or a.args.len != b.args.len) return false;
    for (a.args, b.args) |one, other| if (!Facts.sameValue(one, other)) return false;
    return true;
}

/// A function a summary reads, and the reading it is reached with (none: every
/// instantiation's).
const Queued = struct { id: Function.Id, env: ?*const Facts.Env };

/// Reads each function `next` holds and each it calls, then what each sizes work by, until no
/// round changes it.
fn closeSummary(c: *Context, flow: *Flow, next: *std.ArrayList(Queued)) Context.Error!void {
    while (next.pop()) |item| {
        const f = flow.functions.items[@backingInt(item.id)];
        const tree = &c.project.at(f.file).file.tree;
        for (f.nodes) |node| {
            // A call the reading's bindings never run (another prong of a `switch` on
            // `@typeInfo(T)`) makes no reading of its callee: read, it would bind the callee to
            // types this reading never holds, each making more (Stringify's `.array =>
            // self.write(&v)` read for a pointer `v`). Asked before its callee is read.
            if (item.env != null and Facts.calls.written(tree, node) and !try c.facts.reachedUnder(item.env, f.file, node)) continue;
            const call = (try Facts.calls.under(c.facts, item.env, f.file, node)) orelse continue;
            switch (call.callee) {
                .function => |decl| try reach(c, flow, decl, try readingFor(c, flow, f.file, node, decl, item.env), next),
                .choice => |decls| for (decls) |decl| try reach(c, flow, decl, try readingFor(c, flow, f.file, node, decl, item.env), next),
                .any => {},
            }
        }
    }
    try linksOf(c, flow);
    try rounds(c, flow, .sizes);
    // Closed: each function's callees are read, and what a function sizes by is its slots',
    // which only its own body and its callees' sizes give (a container's variable holds a
    // level, no slot). A function a later call reaches reads these; none of these reads it, so
    // none is read again (`Function.settled`), unless a reading of its own reaches it.
    for (flow.functions.items) |*f| f.settled = true;
    if (c.facts.check_records != null) try checkSizes(c, flow);
}

/// The reading a summary of one instantiation reads `decl` in, called at `node` in `file` in
/// the reading `env`: its own (`readingAt`) where every instantiation's summary of it leaves a
/// size it may take undecided (`maybe`, as `sizeSites` reads the program's call in its own);
/// none, every instantiation's alike, where that summary decides each.
fn readingFor(c: *Context, flow: *Flow, file: Project.FileId, node: Ast.Node.Index, decl: Facts.Decl, env: ?*const Facts.Env) Context.Error!?*const Facts.Env {
    if (env == null) return null;
    if (flow.shared) |shared| switch (try sizesOf(c, shared, decl)) {
        .read => |summary| if (summary.maybe.empty()) return null,
        .allocation, .unknown => {},
    };
    return readingAt(c, file, node, decl, env);
}

/// The reading the call at `node` in `file` makes of `decl`, made in `env`: none where `env`
/// is none, an `@call`'s arguments are not known, or the chain is past 32 calls deep (each
/// binding's then).
fn readingAt(c: *Context, file: Project.FileId, node: Ast.Node.Index, decl: Facts.Decl, env: ?*const Facts.Env) Context.Error!?*const Facts.Env {
    return c.facts.readingAt(file, node, decl, env);
}

/// Adds the function `decl` declares to a summary, its nodes owned, unless it is an
/// allocation (a sink itself), the program's own in a file the run judges (read at its own
/// calls), or has no body; one already read is read again only in a reading it was not read in.
fn reach(c: *Context, flow: *Flow, decl: Facts.Decl, env: ?*const Facts.Env, next: *std.ArrayList(Queued)) Context.Error!void {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    // An allocation is a sink itself; one whose alias does not resolve has no body read.
    if (try allocation(c, flow, decl) != .no) return;
    if (flow.own(decl.file) and judged(c, decl.file)) return;
    const node = fnDecl(c, decl) orelse return;
    if (flow.by_node.get(.{ .file = decl.file, .node = node })) |known_id| return readIn(c, flow, known_id, env, next);
    const id = (try addFunction(c, flow, decl.file, node)) orelse return;
    const entry = try flow.owners.getOrPut(c.allocator, decl.file);
    if (!entry.found_existing) {
        const syntax = try functionsIn(c, decl.file);
        const ids = try c.allocator.alloc(?Function.Id, syntax.decls.len);
        @memset(ids, null);
        entry.value_ptr.* = .{ .syntax = syntax, .ids = ids };
    }
    const at = entry.value_ptr.syntax.position(node).?; // unreachable: `fnDecl` gives a `fn_decl`
    entry.value_ptr.ids[at] = id;
    flow.functions.items[@backingInt(id)].nodes = entry.value_ptr.syntax.bodies[at];
    // Reached with no reading in a summary of one instantiation, it is what the summary of
    // every instantiation found, closed there: taken whole, not read again.
    if (env == null) if (flow.shared) |shared| if (shared.by_node.get(.{ .file = decl.file, .node = node })) |kept| {
        try settle(c, flow, id, shared.functions.items[@backingInt(kept)]);
        return;
    };
    try readIn(c, flow, id, env, next);
}

/// Gives a summary's function `id` what `kept`, the same function in the summary of every
/// instantiation, found (`Function.settled`).
fn settle(c: *Context, flow: *Flow, id: Function.Id, kept: Function) Context.Error!void {
    const f = &flow.functions.items[@backingInt(id)];
    f.levels = try c.allocator.dupe(Levels, kept.levels);
    f.writes = try c.allocator.dupe(Dep, kept.writes);
    f.ret = kept.ret;
    f.returned = kept.returned;
    f.returned_globals = try kept.returned_globals.clone(c.allocator);
    f.parser = kept.parser;
    f.unrefined = kept.unrefined;
    f.sizes = kept.sizes;
    f.ranged_sizes = kept.ranged_sizes;
    f.maybe_sizes = kept.maybe_sizes;
    f.every_reading = true;
    f.settled = true;
}

/// Records that a summary reads `id` in `env` (none: every instantiation's), and queues it to
/// be read so, unless it already is.
fn readIn(c: *Context, flow: *Flow, id: Function.Id, env: ?*const Facts.Env, next: *std.ArrayList(Queued)) Context.Error!void {
    const f = &flow.functions.items[@backingInt(id)];
    // A settled function a reading of its own reaches is read again, as every instantiation
    // reads it too: what it calls with none is reached here.
    if (env != null and f.settled) {
        f.settled = false;
        try next.append(c.allocator, .{ .id = id, .env = null });
    }
    if (env) |e| {
        for (f.readings.items) |reading| if (sameReading(reading, e)) return;
        try f.readings.append(c.allocator, e);
    } else {
        if (f.every_reading) return;
        f.every_reading = true;
    }
    try next.append(c.allocator, .{ .id = id, .env = env });
}

/// What a function of a summary sizes work by (`Function.sizes`): every argument of an
/// allocation; through a callee the summary reads, what it is given where that one sizes by;
/// a loop's pass count where a counter steps toward a bound by a sum (`i += 1`), or a range or
/// an input's length decides it. A call that does not resolve, or a loop counted otherwise,
/// may size by what it is given (`maybe_sizes`); one whose counter shrinks or grows by a
/// factor (`a /= 10`, `n <<= 1`) passes as often as its type has digits.
fn sizing(c: *Context, flow: *Flow, function: Function.Id) Context.Error!void {
    const f = flow.functions.items[@backingInt(function)];
    var sizes: Sizes = .{ .sure = f.sizes, .ranged = f.ranged_sizes, .maybe = f.maybe_sizes };
    for (f.nodes) |node| {
        if (try resolveCall(c, flow, f.file, node)) |callee| {
            try sizedBy(c, flow, function, callee, &sizes);
            continue;
        }
        const counted = try countOf(c, flow, function, node) orelse continue;
        switch (counted.kind) {
            .sure => try sizes.add(c.allocator, counted.by),
            .maybe => try sizes.addMaybe(c.allocator, counted.by),
        }
    }
    if (!sizes.sure.eql(f.sizes) or !sizes.ranged.eql(f.ranged_sizes) or !sizes.maybe.eql(f.maybe_sizes)) {
        // Found on the round's memory, kept on the run's.
        flow.functions.items[@backingInt(function)].sizes = try sizes.sure.kept(c.facts.gpa);
        flow.functions.items[@backingInt(function)].ranged_sizes = try sizes.ranged.kept(c.facts.gpa);
        flow.functions.items[@backingInt(function)].maybe_sizes = try sizes.maybe.kept(c.facts.gpa);
        flow.changed = true;
    }
}

/// What a summary's function sizes work by, by slot (`Function.sizes`, `ranged_sizes`,
/// `maybe_sizes`).
const Sizes = struct {
    sure: Slots,
    ranged: Slots,
    maybe: Slots,

    /// A size that holds `d`: by the slots it holds whole, surely; by those it holds kept to a
    /// range or as a comparison decides, as data at most; by those it holds through a call
    /// that does not resolve, maybe.
    fn add(s: *Sizes, gpa: Allocator, d: Dep) Allocator.Error!void {
        s.sure = try s.sure.unite(gpa, try Slots.all(gpa, &.{ d.params, d.numbers, d.counted, d.counted_numbers }));
        s.ranged = try s.ranged.unite(gpa, try Slots.all(gpa, &.{ d.ranged, d.ruled }));
        s.maybe = try s.maybe.unite(gpa, d.maybe);
    }
    /// A size that holds `d` kept to a range: by every slot it holds, as data at most.
    fn addRanged(s: *Sizes, gpa: Allocator, d: Dep) Allocator.Error!void {
        s.ranged = try s.ranged.unite(gpa, try slotsOf(gpa, d));
        s.maybe = try s.maybe.unite(gpa, d.maybe);
    }
    /// A size that may hold `d`: through a call that does not resolve, or a loop nothing counts.
    fn addMaybe(s: *Sizes, gpa: Allocator, d: Dep) Allocator.Error!void {
        s.maybe = try s.maybe.unite(gpa, try (try slotsOf(gpa, d)).unite(gpa, d.maybe));
    }
};

/// What a call in a summary's `function` sizes work by, into `sizes`.
fn sizedBy(c: *Context, flow: *Flow, function: Function.Id, callee: Callee, sizes: *Sizes) Context.Error!void {
    switch (callee.kind) {
        .holder => {},
        .choice => |each| for (each) |one| try sizedBy(c, flow, function, one, sizes),
        .program, .aegis => {
            // aegis's function is read by its body as any other the summary reaches.
            const target = switch (callee.kind) {
                .program => |id| id,
                else => (if (fnDecl(c, callee.decl.?)) |node| flow.by_node.get(.{ .file = callee.decl.?.file, .node = node }) else null) orelse return sizedOutside(c, flow, function, callee, sizes), // unreachable: aegis's callee has its declaration
            };
            const g = flow.functions.items[@backingInt(target)];
            for (callee.args, 0..) |arg, index| {
                for ([_]bool{ false, true }) |length| {
                    const slot = if (length) lengthSlot(index) else valueSlot(index);
                    const sure = g.sizes.has(slot);
                    const ranged = g.ranged_sizes.has(slot);
                    if (!sure and !ranged and !g.maybe_sizes.has(slot)) continue;
                    var given = try dep(c, flow, function, arg);
                    if (length) given = given.measured();
                    if (sure) {
                        try sizes.add(c.allocator, given);
                    } else if (ranged and !g.maybe_sizes.has(slot)) {
                        try sizes.addRanged(c.allocator, given);
                    } else try sizes.addMaybe(c.allocator, given);
                }
            }
        },
        .source, .outside, .none => try sizedOutside(c, flow, function, callee, sizes),
    }
}

/// What a call outside the summary's functions sizes by: an allocation every argument but the
/// allocator; any other, or one whose body is not read, each argument, maybe.
fn sizedOutside(c: *Context, flow: *Flow, function: Function.Id, callee: Callee, sizes: *Sizes) Context.Error!void {
    // The program's own function in a file the run judges (a context's `hash` std calls)
    // sizes its work in its own body, judged there with what it is handed: none here.
    if (callee.decl) |d| if (flow.own(d.file) and judged(c, d.file)) return;
    const allocates: Allocation = if (callee.decl) |d| try allocation(c, flow, d) else .unknown;
    for (callee.args, 0..) |arg, position| {
        // An allocation's first parameter is the allocator itself.
        if (allocates == .yes and position == 0) continue;
        const given = try whole(c, flow, function, arg);
        if (allocates == .yes and flow.allocations_known) {
            try sizes.add(c.allocator, given);
        } else try sizes.addMaybe(c.allocator, given);
    }
}

/// The slots a value depends on: what a sink takes is a value (a length it takes is one
/// `measured` first).
fn slotsOf(gpa: Allocator, d: Dep) Allocator.Error!Slots {
    return Slots.all(gpa, &.{ d.params, d.numbers, d.ranged, d.ruled, d.counted, d.counted_numbers });
}

/// What decides how many passes a loop takes, where it counts: a range's ends and an input's
/// length (`for`), or a `while` whose condition compares a counter the loop steps by a sum;
/// undecided (`maybe`) for one whose counter steps otherwise or that has none, and none for one
/// whose every counter steps by a factor.
fn countOf(c: *Context, flow: *Flow, function: Function.Id, loop: Ast.Node.Index) Context.Error!?struct { kind: enum { sure, maybe }, by: Dep } {
    const tree = &c.project.at(flow.functions.items[@backingInt(function)].file).file.tree;
    if (tree.fullFor(loop) != null) return .{ .kind = .sure, .by = try forBound(c, flow, function, loop) };
    if (tree.fullSwitch(loop)) |choice| {
        if (choice.label_token == null) return null;
        return .{ .kind = .maybe, .by = try passes(c, flow, function, loop) };
    }
    const w = tree.fullWhile(loop) orelse return null;
    const by = try operands(c, flow, function, w.ast.cond_expr);
    if (by.clean()) return null;
    return switch (try stepsOf(c, flow, function, loop, w.ast.cond_expr)) {
        .sum => .{ .kind = .sure, .by = by },
        .factor => null,
        .other => .{ .kind = .maybe, .by = by },
    };
}

/// Whether `value` takes the counter `d` by a factor: a product, a quotient or a shift of it
/// (`a * 2`, `@divTrunc(a, 10)`, `n >> 1`).
fn scaled(tree: *const Ast, model: *const Model, d: Model.Declaration.Id, value: Ast.Node.Index) bool {
    if (formAt(tree, value) == .operator) {
        const operator = accesses.operatorOf(tree.nodeTag(value)) orelse return false;
        if (operator.op != .mul and operator.op != .div and operator.op != .shl and operator.op != .shr) return false;
        const lhs, const rhs = tree.nodeData(value).node_and_node;
        return namesDeclaration(tree, model, lhs, d) or namesDeclaration(tree, model, rhs, d);
    }
    if (formAt(tree, value) != .builtin) return false;
    const name = tree.tokenSlice(tree.nodeMainToken(value));
    for ([_][]const u8{ "@divTrunc", "@divFloor", "@divExact", "@shrExact", "@shlExact" }) |each| if (std.mem.eql(u8, name, each)) {
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, value, &buffer);
        return args.len > 0 and namesDeclaration(tree, model, args[0], d);
    };
    return false;
}

test "the lists of std's reads and decoders are this std's: a function they do not name fails here, as glint reads it as input until it is named" {
    @setEvalBranchQuota(100_000);
    const named = struct {
        fn among(comptime name: []const u8, comptime list: []const []const u8) bool {
            for (list) |each| if (std.mem.eql(u8, each, name)) return true;
            return false;
        }
    }.among;
    // Each entry is one of this std's, so a list cannot name what it lost.
    inline for (reader_no_reads ++ reader_byte_reads) |name| try std.testing.expect(@hasDecl(std.Io.Reader, name));
    // Every decoder `mem` and `fmt` declare by these stems is on the list.
    inline for (.{ std.mem, std.fmt }, .{ "mem.", "fmt." }) |namespace, prefix| {
        inline for (@typeInfo(namespace).@"struct".decl_names) |name| {
            const decoder = comptime for ([_][]const u8{ "readInt", "readVarInt", "readPackedInt", "parseInt", "parseUnsigned" }) |stem| {
                if (std.mem.startsWith(u8, name, stem)) break true;
            } else false;
            if (decoder) try std.testing.expect(comptime named(prefix ++ name, &std_decoders));
        }
    }
}

test "the aegis pack's facts fit one solve's lanes, and a set that needs more does not" {
    // `get` solves every enabled rule's fact in one run, a lane each: the pack declares no more.
    try std.testing.expect(fits(&@import("AegisPack.zig").rules));
    var many: [lane_count + 1]Spec = undefined;
    const sources = [_]FactSpec.Source{ .peer_writer, .error_text, .{ .input = .{ .peer = true, .operator = false } } };
    for (&many, 0..) |*spec, i| spec.* = .{ .source = sources[i % 3], .control = true, .answers = .{ .aegis = (i / 3) & 1 != 0, .int_from_error = (i / 3) & 2 != 0 } };
    const check = struct {
        fn check(_: *Context) Context.Error!void {}
    }.check;
    const rule: Context.Rule = .{ .definition = .{ .id = @import("AegisRules.zig").untrusted_input, .name = "A009", .group = .family_policy, .purpose = "input" }, .check = check, .facts = &many };
    try std.testing.expect(!fits(&.{rule}));
}

test "the size sink is what a function outside the program allocates or counts by, through its calls, and not a digit loop" {
    const gpa = std.testing.allocator;
    const program =
        \\const std = @import("std");
        \\pub fn f(gpa: std.mem.Allocator, n: usize, x: u64, b: u8, bytes: []const u8, more: *const fn (usize) void) !void {
        \\    _ = try gpa.alloc(u8, n);
        \\    _ = std.mem.digits(x);
        \\    _ = std.mem.repeat(b, n);
        \\    _ = std.mem.sum(bytes);
        \\    more(n);
        \\}
        \\// Handed on, f is called with what no call shows: its parameters are input's.
        \\pub const handed = &f;
    ;
    const mem =
        \\pub const Allocator = struct {
        \\    ptr: *anyopaque,
        \\    vtable: *const VTable,
        \\    pub const VTable = struct { alloc: *const fn (*anyopaque, usize) ?[*]u8 };
        \\    pub fn rawAlloc(a: Allocator, len: usize) ?[*]u8 {
        \\        return a.vtable.alloc(a.ptr, len);
        \\    }
        \\    pub fn alloc(a: Allocator, comptime T: type, n: usize) ![]T {
        \\        const p = a.rawAlloc(n * @sizeOf(T)) orelse return error.OutOfMemory;
        \\        _ = p;
        \\        return undefined;
        \\    }
        \\};
        \\pub fn digits(x: u64) usize {
        \\    var a = x;
        \\    var n: usize = 0;
        \\    while (a >= 10) : (a /= 10) n += 1;
        \\    return n;
        \\}
        \\pub fn repeat(byte: u8, n: usize) u64 {
        \\    var i: usize = 0;
        \\    var t: u64 = 0;
        \\    while (i < n) : (i += 1) t +%= byte;
        \\    return t;
        \\}
        \\pub fn sum(bytes: []const u8) u64 {
        \\    var t: u64 = 0;
        \\    for (bytes) |b| t +%= b;
        \\    return t;
        \\}
    ;
    const seen = try sizeSitesText(gpa, program, mem);
    defer gpa.free(seen);
    try std.testing.expectEqualStrings(
        \\alloc 2 n value sure
        \\repeat 1 n value sure
        \\sum 0 bytes length sure
        \\? 0 n value maybe
        \\? 0 n length maybe
        \\
    , seen);
}

/// The size sinks A012's fact finds in `program`, with `mem` as std's `mem.zig`: each as
/// `callee position value|length sure|maybe` on a line, in order. The caller owns the text.
fn sizeSitesText(gpa: Allocator, program: []const u8, mem: []const u8) ![]u8 {
    var project = try Project.init(gpa, &.{
        .{ .name = "root", .bytes = program },
        .{ .name = "std/std.zig", .bytes = "pub const mem = @import(\"mem.zig\");\n", .selected = false },
        .{ .name = "std/mem.zig", .bytes = mem, .selected = false },
    }, &.{ .{ .from = 0, .spelling = "std", .target = 1 }, .{ .from = 1, .spelling = "mem.zig", .target = 2 } }, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const Quiet = struct {
        const config: @import("Rule.zig").Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = @import("AegisRules.zig").bounded_work, .level = .report }} };
        fn diagnostic(_: *Context.Sink, _: @import("Rule.zig").Rule, _: u32, _: u32, _: []const u8, _: []const @import("Report.zig").Span, _: []const @import("Report.zig").Edit) Context.Error!void {}
        fn coverage(_: *Context.Sink, _: @import("Report.zig").Coverage) Context.Error!void {}
        fn configOf(_: *Context.Sink, _: Project.FileId) @import("Rule.zig").Config {
            return config;
        }
        fn check(_: *Context) Context.Error!void {}
    };
    const bounded_input = @import("Danger.zig").bounded_input;
    const rule: Context.Rule = .{ .definition = .{ .id = @import("AegisRules.zig").bounded_work, .name = "A012", .group = .family_policy, .purpose = "work" }, .check = Quiet.check, .facts = &.{bounded_input} };
    var sink: Context.Sink = .{ .diagnostic = Quiet.diagnostic, .coverage = Quiet.coverage, .config = Quiet.configOf };
    var c: Context = .{ .allocator = arena.allocator(), .project = &project, .file = project.sources[0].id, .config = Quiet.config, .facts = &facts, .definitions = &.{}, .sink = &sink, .compiled = &.{rule} };
    const fact = try get(&c, bounded_input);
    const tree = &project.sources[0].file.tree;
    var seen: std.ArrayList(u8) = .empty;
    errdefer seen.deinit(gpa);
    for (try sinkSites(&c, fact, project.sources[0].id)) |found| {
        const site = (try decidedSite(&c, fact, found)) orelse continue;
        const name = if (site.callee) |d| project.at(d.file).model.declarations[@backingInt(d.index)].name else "?";
        try seen.print(gpa, "{s} {d} {s} {s} {s}\n", .{ name, site.position, tree.getNodeSource(site.value), if (site.length) "length" else "value", if (site.decided) "sure" else "maybe" });
    }
    return seen.toOwnedSlice(gpa);
}

test "the sizes fact reads a std file's bodies once, however many of its functions a call reaches" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // A chain of 64 functions, the last one allocating what the first is given.
    var mem: std.ArrayList(u8) = .empty;
    try mem.appendSlice(a,
        \\pub const Allocator = struct {
        \\    pub fn rawAlloc(self: Allocator, len: usize) void {
        \\        _ = self;
        \\        _ = len;
        \\    }
        \\};
        \\
    );
    const chain = 63;
    for (0..chain) |i| try mem.print(a, "pub fn step{d}(gpa: Allocator, n: usize) void {{\n    step{d}(gpa, n);\n}}\n", .{ i, i + 1 });
    try mem.print(a, "pub fn step{d}(gpa: Allocator, n: usize) void {{\n    gpa.rawAlloc(n);\n}}\n", .{chain});
    const program =
        \\const std = @import("std");
        \\pub fn f(gpa: std.mem.Allocator, n: usize) void {
        \\    std.mem.step0(gpa, n);
        \\}
        \\pub const handed = &f;
    ;
    var project = try Project.init(gpa, &.{
        .{ .name = "root", .bytes = program },
        .{ .name = "std/std.zig", .bytes = "pub const mem = @import(\"mem.zig\");\n", .selected = false },
        .{ .name = "std/mem.zig", .bytes = mem.items, .selected = false },
    }, &.{ .{ .from = 0, .spelling = "std", .target = 1 }, .{ .from = 1, .spelling = "mem.zig", .target = 2 } }, .{});
    defer project.deinit();
    var facts: Facts = .{ .project = &project, .gpa = a };
    defer facts.deinit();
    const Quiet = struct {
        const config: @import("Rule.zig").Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = @import("AegisRules.zig").bounded_work, .level = .report }} };
        fn diagnostic(_: *Context.Sink, _: @import("Rule.zig").Rule, _: u32, _: u32, _: []const u8, _: []const @import("Report.zig").Span, _: []const @import("Report.zig").Edit) Context.Error!void {}
        fn coverage(_: *Context.Sink, _: @import("Report.zig").Coverage) Context.Error!void {}
        fn configOf(_: *Context.Sink, _: Project.FileId) @import("Rule.zig").Config {
            return config;
        }
        fn check(_: *Context) Context.Error!void {}
    };
    const bounded_input = @import("Danger.zig").bounded_input;
    const rule: Context.Rule = .{ .definition = .{ .id = @import("AegisRules.zig").bounded_work, .name = "A012", .group = .family_policy, .purpose = "work" }, .check = Quiet.check, .facts = &.{bounded_input} };
    var sink: Context.Sink = .{ .diagnostic = Quiet.diagnostic, .coverage = Quiet.coverage, .config = Quiet.configOf };
    var c: Context = .{ .allocator = a, .project = &project, .file = project.sources[0].id, .config = Quiet.config, .facts = &facts, .definitions = &.{}, .sink = &sink, .compiled = &.{rule} };
    const fact = try get(&c, bounded_input);
    const sites = try sinkSites(&c, fact, project.sources[0].id);
    try std.testing.expectEqual(1, sites.len);
    try std.testing.expect(!sites[0].refine and sites[0].decided and !sites[0].length and sites[0].position == 1);
    const sized = fact.flow.sized.?;
    try std.testing.expectEqual(64, sized.functions.items.len);
    // One pass over the file's nodes, not one per function reached (64 here).
    const walked = (try facts.memo(Functions)).walked;
    try std.testing.expect(walked > 0 and walked <= project.at(project.sources[0].id).file.tree.nodes.len + project.at(project.sources[2].id).file.tree.nodes.len);
}

test "the input fact asks a governed name once per run, however many places read a field" {
    // Every round reads every field, and each read asks whether the field is one of std's
    // text accessors (`zig_text`). Those are resolved once, as the fact starts: the lookups
    // asked are the same for 8 reads as for 64 (they grew with the reads times the rounds).
    try std.testing.expectEqual(try lookupsFor(8), try lookupsFor(64));
}

/// The governed lookups the input fact asks over `n` functions that each read a field.
fn lookupsFor(n: usize) !usize {
    const gpa = std.testing.allocator;
    var program: std.ArrayList(u8) = .empty;
    defer program.deinit(gpa);
    try program.appendSlice(gpa, "const S = struct { a: u8 };\n");
    for (0..n) |i| try program.print(gpa, "pub fn read{d}(s: S) u8 {{ return s.a; }}\n", .{i});
    var project = try Project.init(gpa, &.{.{ .name = "root", .bytes = program.items }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const Quiet = struct {
        const config: @import("Rule.zig").Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = @import("AegisRules.zig").untrusted_input, .level = .report }} };
        fn diagnostic(_: *Context.Sink, _: @import("Rule.zig").Rule, _: u32, _: u32, _: []const u8, _: []const @import("Report.zig").Span, _: []const @import("Report.zig").Edit) Context.Error!void {}
        fn coverage(_: *Context.Sink, _: @import("Report.zig").Coverage) Context.Error!void {}
        fn configOf(_: *Context.Sink, _: Project.FileId) @import("Rule.zig").Config {
            return config;
        }
        fn check(_: *Context) Context.Error!void {}
    };
    const peer_input = @import("Danger.zig").peer_input;
    const rule: Context.Rule = .{ .definition = .{ .id = @import("AegisRules.zig").untrusted_input, .name = "A009", .group = .family_policy, .purpose = "input" }, .check = Quiet.check, .facts = &.{peer_input} };
    var sink: Context.Sink = .{ .diagnostic = Quiet.diagnostic, .coverage = Quiet.coverage, .config = Quiet.configOf };
    var c: Context = .{ .allocator = arena.allocator(), .project = &project, .file = project.sources[0].id, .config = Quiet.config, .facts = &facts, .definitions = &.{}, .sink = &sink, .compiled = &.{rule} };
    _ = try get(&c, peer_input);
    return (try facts.memo(Governed.Lookups)).asked;
}

test "the input fact's solve keeps what its rounds raise, not each round's work: a chain input reaches a round per call holds what the same chain declared callee first does" {
    // Declared caller first, `step0` reads what `step1` returns before the round that raises
    // it: the input takes a round per call (34 rounds over 32 calls), callee first 4. Each
    // round's work is given back when the round ends, so the run holds the same either way;
    // it grew with the calls times the rounds (relic's odb: 18 rounds, 24.8 GB, 11-04).
    const forward = try solveBytes(32, false);
    const callee_first = try solveBytes(32, true);
    try std.testing.expect(forward > 0);
    try std.testing.expectEqual(callee_first, forward);
}

/// The bytes the input fact's solve asks of the run's memory over a chain of `n` calls, the
/// last returning input, each function binding 48 values (a slot set past one word).
fn solveBytes(n: usize, callee_first: bool) !usize {
    const gpa = std.testing.allocator;
    var program: std.ArrayList(u8) = .empty;
    defer program.deinit(gpa);
    try program.appendSlice(gpa, "const std = @import(\"std\");\npub fn main(r: *std.Io.Reader, s: []const u8) u8 {\n    return s[step0(r, s)];\n}\n");
    for (0..n + 1) |at| {
        const i = if (callee_first) n - at else at;
        if (i == n) {
            try program.print(gpa, "fn step{d}(r: *std.Io.Reader, s: []const u8) u32 {{\n    _ = s;\n    return r.takeInt(u32, 0) catch 0;\n}}\n", .{n});
            continue;
        }
        try program.print(gpa, "fn step{d}(r: *std.Io.Reader, s: []const u8) u32 {{\n    var t: u32 = 0;\n    for (s) |b| t +%= b;\n    const a0 = step{d}(r, s) +% t;\n", .{ i, i + 1 });
        for (1..48) |k| try program.print(gpa, "    const a{d} = a{d} +% {d};\n", .{ k, k - 1, k });
        try program.appendSlice(gpa, "    for (0..a47) |_| t +%= 1;\n    return a47 +% t;\n}\n");
    }
    return solveAsks(program.items);
}

test "the links' passes keep what they raise, not each pass's work: a chain whose returns a pass per call finds holds what the same chain declared callee first does" {
    // Declared caller first, `step0` reads what `step1` returns a pointer into before the pass
    // that finds it: a pass per call (34 over 32 calls), callee first 2. Each pass's work is
    // given back when the pass ends, so the run holds the same either way.
    const forward = try linksBytes(32, false);
    const callee_first = try linksBytes(32, true);
    try std.testing.expect(forward > 0);
    try std.testing.expectEqual(callee_first, forward);
}

/// The bytes the input fact's solve asks of the run's memory over a chain of `n` calls, each
/// returning a part of what the next returns, the last a part of its parameter, each function
/// keeping 16 parts of it in locals.
fn linksBytes(n: usize, callee_first: bool) !usize {
    const gpa = std.testing.allocator;
    var program: std.ArrayList(u8) = .empty;
    defer program.deinit(gpa);
    try program.appendSlice(gpa, "const std = @import(\"std\");\npub fn main(r: *std.Io.Reader, s: []u8) u8 {\n    _ = r;\n    return step0(s)[0];\n}\n");
    for (0..n + 1) |at| {
        const i = if (callee_first) n - at else at;
        try program.print(gpa, "fn step{d}(s: []u8) []u8 {{\n    const a0 = s[1..];\n", .{i});
        for (1..16) |k| try program.print(gpa, "    const a{d} = a{d}[1..];\n", .{ k, k - 1 });
        if (i == n) try program.appendSlice(gpa, "    return a15;\n}\n") else try program.print(gpa, "    return step{d}(a15);\n}}\n", .{i + 1});
    }
    return solveAsks(program.items);
}

/// The bytes the input fact's solve asks of the run's memory over `program`, whose `std` has
/// a reader whose `takeInt` returns input.
fn solveAsks(program: []const u8) !usize {
    const gpa = std.testing.allocator;
    var project = try readerProject(gpa, program);
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // The run's memory, the bytes asked of it counted.
    var run_memory: std.testing.FailingAllocator = .init(arena.allocator(), .{});
    var facts: Facts = .{ .project = &project, .gpa = run_memory.allocator() };
    defer facts.deinit();
    // A rule's own memory for the file, as the Runner gives it: not the run's.
    var own: std.heap.ArenaAllocator = .init(gpa);
    defer own.deinit();
    var sink = InputRun.sink;
    var c = InputRun.context(&project, &facts, own.allocator(), &sink, InputRun.config);
    _ = try get(&c, InputRun.peer_input);
    return run_memory.allocated_bytes;
}

/// `program` as the root of a project whose `std` has a reader whose `takeInt` returns input.
fn readerProject(gpa: Allocator, program: []const u8) !Project {
    const inputs = [_]Project.Input{
        .{ .name = "root", .bytes = program },
        .{ .name = "std/std.zig", .bytes = "pub const Io = @import(\"Io.zig\");\n", .selected = false },
        .{ .name = "std/Io.zig", .bytes = "pub const Reader = @import(\"Io/Reader.zig\");\n", .selected = false },
        .{ .name = "std/Io/Reader.zig", .bytes = "buffer: []u8 = &.{},\npub fn takeInt(r: *@This(), comptime T: type, endian: u1) !T { _ = r; _ = endian; return 0; }\n", .selected = false },
    };
    const imports = [_]Project.Import{ .{ .from = 0, .spelling = "std", .target = 1 }, .{ .from = 1, .spelling = "Io.zig", .target = 2 }, .{ .from = 2, .spelling = "Io/Reader.zig", .target = 3 } };
    return Project.init(gpa, &inputs, &imports, .{});
}

/// A run of A009 alone, whose findings and coverage go nowhere: what the input fact's solve does.
const InputRun = struct {
    const config: @import("Rule.zig").Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = @import("AegisRules.zig").untrusted_input, .level = .report }} };
    const peer_input = @import("Danger.zig").peer_input;
    const rule: Context.Rule = .{ .definition = .{ .id = @import("AegisRules.zig").untrusted_input, .name = "A009", .group = .family_policy, .purpose = "input" }, .check = check, .facts = &.{peer_input} };
    const sink: Context.Sink = .{ .diagnostic = diagnostic, .coverage = coverage, .config = configOf };
    fn diagnostic(_: *Context.Sink, _: @import("Rule.zig").Rule, _: u32, _: u32, _: []const u8, _: []const @import("Report.zig").Span, _: []const @import("Report.zig").Edit) Context.Error!void {}
    fn coverage(_: *Context.Sink, _: @import("Report.zig").Coverage) Context.Error!void {}
    fn configOf(_: *Context.Sink, _: Project.FileId) @import("Rule.zig").Config {
        return config;
    }
    fn check(_: *Context) Context.Error!void {}
    /// The root's check, a rule's own memory `own`.
    fn context(project: *const Project, facts: *Facts, own: Allocator, reports: *Context.Sink, with: @import("Rule.zig").Config) Context {
        return .{ .allocator = own, .project = project, .file = project.sources[0].id, .config = with, .facts = facts, .definitions = &.{}, .sink = reports, .compiled = &.{rule} };
    }
};

test "the program's solve is a unit of its own: never charged to the file that asks, and once complete, kept through a forget with nothing it holds dropped" {
    const gpa = std.testing.allocator;
    var project = try readerProject(gpa, "const std = @import(\"std\");\npub fn main(r: *std.Io.Reader, s: []const u8) u8 {\n    const n = step(r);\n    return s[n];\n}\nfn step(r: *std.Io.Reader) u32 {\n    return r.takeInt(u32, 0) catch 0;\n}\n");
    defer project.deinit();
    // The run's memory, each allocation on pages of its own, unmapped when it is freed: a flow
    // holding a part of an index `forget` frees faults where it is read afterwards. What the
    // run keeps (its memos) is the process's until it ends, as a Runner's arena holds it.
    var facts: Facts = .{ .project = &project, .gpa = std.heap.page_allocator };
    var own: std.heap.ArenaAllocator = .init(gpa);
    defer own.deinit();
    var sink = InputRun.sink;
    var c = InputRun.context(&project, &facts, own.allocator(), &sink, InputRun.config);
    // The asking file's budget is its own whatever the solve spends.
    facts.remaining = 7;
    const fact = try get(&c, InputRun.peer_input);
    try std.testing.expectEqual(7, facts.remaining);
    try std.testing.expect(!facts.short);
    const file = project.sources[0].id;
    const nodes = project.at(file).file.tree.nodes.len;
    var before: std.ArrayList(Level) = .empty;
    defer before.deinit(gpa);
    for (0..nodes) |i| try before.append(gpa, try levelAt(&c, fact, file, @fromBackingInt(@intCast(i))));
    try std.testing.expect(std.mem.findScalar(Level, before.items, .number) != null);
    facts.forget();
    const kept = try get(&c, InputRun.peer_input);
    try std.testing.expectEqual(fact.flow, kept.flow);
    for (before.items, 0..) |level, i| try std.testing.expectEqual(level, try levelAt(&c, kept, file, @fromBackingInt(@intCast(i))));
}

test "a solve that runs short of its budget is marked and never redone: each file that asks is told so, and the asking file's budget is untouched" {
    const gpa = std.testing.allocator;
    var project = try readerProject(gpa, "const std = @import(\"std\");\npub fn main(r: *std.Io.Reader, s: []const u8) u8 {\n    return s[r.takeInt(u32, 0) catch 0];\n}\n");
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    var own: std.heap.ArenaAllocator = .init(gpa);
    defer own.deinit();
    var sink = InputRun.sink;
    var config = InputRun.config;
    config.fact_budget = 1;
    var c = InputRun.context(&project, &facts, own.allocator(), &sink, config);
    facts.remaining = 7;
    try std.testing.expectError(error.SolveShort, get(&c, InputRun.peer_input));
    try std.testing.expectEqual(7, facts.remaining);
    // What the short solve built, no later file reads; the mark stays.
    try std.testing.expect(facts.short);
    facts.forget();
    try std.testing.expect(!facts.short);
    c.config.fact_budget = 100_000;
    try std.testing.expectError(error.SolveShort, get(&c, InputRun.peer_input));
    try std.testing.expect(!facts.short);
}

test "a file whose own work ran short does not solve: what it built would answer the solve as if complete" {
    const gpa = std.testing.allocator;
    var project = try readerProject(gpa, "const std = @import(\"std\");\npub fn main(r: *std.Io.Reader, s: []const u8) u8 {\n    return s[r.takeInt(u32, 0) catch 0];\n}\n");
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    var own: std.heap.ArenaAllocator = .init(gpa);
    defer own.deinit();
    var sink = InputRun.sink;
    var c = InputRun.context(&project, &facts, own.allocator(), &sink, InputRun.config);
    facts.short = true;
    try std.testing.expectError(error.SolveShort, get(&c, InputRun.peer_input));
    // The Runner forgets at the file's end; the next file solves.
    facts.forget();
    _ = try get(&c, InputRun.peer_input);
}

/// How many functions of the closed size summary `program` reaches in std's `mem.zig` size work;
/// with `cross_check`, under summaries' cross-check, how many of std's open-world records size work
/// only as they may (`checkOpen`); with `records`, std's summaries read from those records
/// (`Facts.read_records`); and how many of the program's size sites are undecided.
fn summarySizing(gpa: Allocator, program: []const u8, mem: []const u8, how: struct { cross_check: bool = false, records: bool = false, unit_budget: ?usize = null, file_budget: ?usize = null }) !struct { live: usize, open_maybe: usize, undecided: usize, exhausted: usize = 0, exhausted_short: usize = 0, checked: bool = false } {
    var project = try Project.init(gpa, &.{
        .{ .name = "root", .bytes = program },
        .{ .name = "std/std.zig", .bytes = "pub const mem = @import(\"mem.zig\");\n", .selected = false },
        .{ .name = "std/mem.zig", .bytes = mem, .selected = false },
    }, &.{ .{ .from = 0, .spelling = "std", .target = 1 }, .{ .from = 1, .spelling = "mem.zig", .target = 2 } }, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator(), .check_records = if (how.cross_check) &Records.check else null, .read_records = how.records };
    defer facts.deinit();
    const Quiet = struct {
        const config: @import("Rule.zig").Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = @import("AegisRules.zig").bounded_work, .level = .report }} };
        fn diagnostic(_: *Context.Sink, _: @import("Rule.zig").Rule, _: u32, _: u32, _: []const u8, _: []const @import("Report.zig").Span, _: []const @import("Report.zig").Edit) Context.Error!void {}
        fn coverage(_: *Context.Sink, _: @import("Report.zig").Coverage) Context.Error!void {}
        fn configOf(_: *Context.Sink, _: Project.FileId) @import("Rule.zig").Config {
            return config;
        }
        fn check(_: *Context) Context.Error!void {}
    };
    const bounded_input = @import("Danger.zig").bounded_input;
    const rule: Context.Rule = .{ .definition = .{ .id = @import("AegisRules.zig").bounded_work, .name = "A012", .group = .family_policy, .purpose = "work" }, .check = Quiet.check, .facts = &.{bounded_input} };
    var sink: Context.Sink = .{ .diagnostic = Quiet.diagnostic, .coverage = Quiet.coverage, .config = Quiet.configOf };
    var own: std.heap.ArenaAllocator = .init(gpa);
    defer own.deinit();
    var c: Context = .{ .allocator = own.allocator(), .project = &project, .file = project.sources[0].id, .config = Quiet.config, .facts = &facts, .definitions = &.{}, .sink = &sink, .compiled = &.{rule} };
    // The file's budget, which its size summaries close on.
    if (how.file_budget) |budget| facts.remaining = budget;
    const fact = try get(&c, bounded_input);
    // The closings' budget, a file's: the program's solve has its own, made of the files'.
    if (how.unit_budget) |budget| c.config.fact_budget = budget;
    var undecided: usize = 0;
    for (try sinkSites(&c, fact, project.sources[0].id)) |site| if (!site.decided) {
        undecided += 1;
    };
    const sized = fact.flow.sized orelse return .{ .live = 0, .open_maybe = 0, .undecided = undecided };
    var live: usize = 0;
    for (sized.functions.items) |f| if (!f.sizes.empty() or !f.maybe_sizes.empty()) {
        live += 1;
    };
    var open_maybe: usize = 0;
    // No unit is made where the file's budget ran out before its summary was checked.
    if (how.cross_check) if ((try facts.memo(OpenUnit)).flow) |unit_flow| for (unit_flow.functions.items) |f| if (f.sizes.empty() and !f.maybe_sizes.empty()) {
        open_maybe += 1;
    };
    // Of std's open-world summary, the functions closed past their budget, and those of them
    // that do not size as they may by every parameter's value and length.
    var exhausted: usize = 0;
    var exhausted_short: usize = 0;
    if (how.records or how.cross_check) if ((try facts.memo(OpenUnit)).flow) |unit_flow| for (unit_flow.functions.items) |f| if (f.exhausted) {
        exhausted += 1;
        for (0..f.params.len) |i| if (!f.maybe_sizes.has(valueSlot(i)) or !f.maybe_sizes.has(lengthSlot(i))) {
            exhausted_short += 1;
            break;
        };
    };
    const checked = (try facts.memo(OpenUnit)).flow != null;
    return .{ .live = live, .open_maybe = open_maybe, .undecided = undecided, .exhausted = exhausted, .exhausted_short = exhausted_short, .checked = checked };
}

test "a std function's closed sizes in a lint are the program's: what it calls through a std field is what the program stores there, so a record is built in the open world" {
    const grows = try summarySizing(std.testing.allocator, grow_stored, mem_through_field, .{});
    const stays = try summarySizing(std.testing.allocator, none_stored, mem_through_field, .{});
    // `call` and `grow` with `grow` stored; none with `none`.
    try std.testing.expectEqual(2, grows.live);
    try std.testing.expectEqual(0, stays.live);
}

const mem_through_field = "pub const VT = struct { f: *const fn (usize) void };\npub fn call(vt: *const VT, n: usize) void {\n    vt.f(n);\n}\npub fn grow(n: usize) void {\n    var i: usize = 0;\n    while (i < n) : (i += 1) {}\n}\npub fn none(n: usize) void {\n    _ = n;\n}\n";
const grow_stored = "const std = @import(\"std\");\nconst vt: std.mem.VT = .{ .f = std.mem.grow };\npub fn f(n: usize) void {\n    std.mem.call(&vt, n);\n}\npub const handed = &f;\n";
const none_stored = "const std = @import(\"std\");\nconst vt: std.mem.VT = .{ .f = std.mem.none };\npub fn f(n: usize) void {\n    std.mem.call(&vt, n);\n}\npub const handed = &f;\n";

test "a std size record is read in the open world: what std calls through a field any program may store into sizes as it may, and covers each program's summary" {
    // Under the cross-check, each program's live summary is covered by std's records
    // (`checkOpen`, which stops the run otherwise); in both, `call` sizes by `n` only as it
    // may, whatever the program stores.
    const grows = try summarySizing(std.testing.allocator, grow_stored, mem_through_field, .{ .cross_check = true });
    const stays = try summarySizing(std.testing.allocator, none_stored, mem_through_field, .{ .cross_check = true });
    try std.testing.expectEqual(2, grows.live);
    try std.testing.expectEqual(0, stays.live);
    try std.testing.expectEqual(1, grows.open_maybe);
    try std.testing.expectEqual(1, stays.open_maybe);
}

test "std's size summaries read from its open-world records leave undecided what the program's stores decide live" {
    // Live, the call into std's `call` sizes by `n` (`grow` stored): a site, decided. Read from
    // std's record, `call` sizes by `n` only as it may: the site is undecided.
    const live = try summarySizing(std.testing.allocator, grow_stored, mem_through_field, .{});
    const read = try summarySizing(std.testing.allocator, grow_stored, mem_through_field, .{ .records = true });
    try std.testing.expectEqual(0, live.undecided);
    try std.testing.expectEqual(1, read.undecided);
}

test "a std size record covers a call std chooses by a comptime parameter (std.unicode's calcUtf16LeLen): what the chosen decoder sizes by, the value's and its length" {
    // `lenOf` hands `implOf` a comptime kind, which picks the decoder by a `switch`; each
    // decoder loops over its slice's length. Under the cross-check (`checkOpen`, which stops
    // the run where the record is decided further), std's record answers as the run does.
    const mem = "pub const Kind = enum { a, b };\nfn decodeA(s: []const u8) usize {\n    var j: usize = 0;\n    while (j < s.len) : (j += 1) {}\n    return j;\n}\nfn decodeB(s: []const u8) usize {\n    return s.len;\n}\npub fn implOf(s: []const u8, comptime kind: Kind) usize {\n    const decode = switch (kind) {\n        .a => decodeA,\n        .b => decodeB,\n    };\n    var i: usize = 0;\n    var n: usize = 0;\n    while (i < s.len) : (i += 1) n += decode(s[i..]);\n    return n;\n}\npub fn lenOf(s: []const u8) usize {\n    return implOf(s, .a);\n}\n";
    const program = "const std = @import(\"std\");\npub fn f(s: []const u8) usize {\n    return std.mem.lenOf(s);\n}\npub const handed = &f;\n";
    const live = try summarySizing(std.testing.allocator, program, mem, .{ .cross_check = true });
    const read = try summarySizing(std.testing.allocator, program, mem, .{ .records = true });
    try std.testing.expectEqual(live.undecided, read.undecided);
}

test "a std size record whose closing ran out of budget is unknown: the site it answers is undecided, never decided by a short reading" {
    const direct = "const std = @import(\"std\");\npub fn f(n: usize) void {\n    std.mem.grow(n);\n}\npub const handed = &f;\n";
    const live = try summarySizing(std.testing.allocator, direct, mem_through_field, .{});
    const read = try summarySizing(std.testing.allocator, direct, mem_through_field, .{ .records = true });
    const short = try summarySizing(std.testing.allocator, direct, mem_through_field, .{ .records = true, .unit_budget = 1 });
    try std.testing.expectEqual(0, live.undecided);
    try std.testing.expectEqual(0, read.undecided);
    // Unknown, `grow` may size by `n`'s value and its length: two sites, each undecided.
    try std.testing.expectEqual(2, short.undecided);
    // Each function the short closing read is exhausted, and each sizes as it may by every
    // slot: never a smaller answer than an unknown one.
    try std.testing.expect(short.exhausted > 0);
    try std.testing.expectEqual(0, short.exhausted_short);
    try std.testing.expectEqual(0, read.exhausted);
}

test "a live size summary closed past the file's budget is not held to std's records: what came back unknown sizes as it may, never a soundness case" {
    // std's record, closed on a budget of its own, keeps `clamped`'s loop to a range of `n`;
    // read live on a budget that runs out, it sizes by `n` as it may. The cross-check
    // (`checkOpen`) stopped the run there (bay's std/hash/crc.zig:991, conduit's
    // std/Io/Writer.zig:1609 under the full pack); the file is exhausted instead.
    const mem = "pub fn clamped(n: usize) void {\n    const m = @min(n, 64);\n    var i: usize = 0;\n    while (i < m) : (i += 1) {}\n}\n";
    const program = "const std = @import(\"std\");\npub fn f(n: usize) void {\n    std.mem.clamped(n);\n}\npub const handed = &f;\n";
    const full = try summarySizing(std.testing.allocator, program, mem, .{ .cross_check = true });
    // On 5 facts, the live closing ends with the budget spent.
    const short = try summarySizing(std.testing.allocator, program, mem, .{ .cross_check = true, .file_budget = 5 });
    try std.testing.expectEqual(0, full.undecided);
    try std.testing.expect(short.undecided >= full.undecided);
    // Checked against std's records on the whole budget; not past it.
    try std.testing.expect(full.checked);
    try std.testing.expect(!short.checked);
}

test "a closed size summary's record reads back as the summary holds it: each function's slots, by its fn_decl" {
    const gpa = std.testing.allocator;
    var project = try Project.init(gpa, &.{
        .{ .name = "root", .bytes = "const std = @import(\"std\");\npub fn f(gpa: std.mem.Allocator, n: usize, m: usize) void {\n    std.mem.grow(gpa, n, m);\n}\npub const handed = &f;\n" },
        .{ .name = "std/std.zig", .bytes = "pub const mem = @import(\"mem.zig\");\n", .selected = false },
        .{ .name = "std/mem.zig", .bytes = "pub const Allocator = struct {\n    pub fn rawAlloc(self: Allocator, len: usize) void {\n        _ = self;\n        _ = len;\n    }\n};\npub fn grow(gpa: Allocator, n: usize, m: usize) void {\n    var i: usize = 0;\n    while (i < m) : (i += 1) {}\n    twice(gpa, n);\n}\nfn twice(gpa: Allocator, k: usize) void {\n    gpa.rawAlloc(k);\n    gpa.rawAlloc(k);\n}\n", .selected = false },
    }, &.{ .{ .from = 0, .spelling = "std", .target = 1 }, .{ .from = 1, .spelling = "mem.zig", .target = 2 } }, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator(), .check_records = &Records.check };
    defer facts.deinit();
    const Quiet = struct {
        const config: @import("Rule.zig").Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = @import("AegisRules.zig").bounded_work, .level = .report }} };
        fn diagnostic(_: *Context.Sink, _: @import("Rule.zig").Rule, _: u32, _: u32, _: []const u8, _: []const @import("Report.zig").Span, _: []const @import("Report.zig").Edit) Context.Error!void {}
        fn coverage(_: *Context.Sink, _: @import("Report.zig").Coverage) Context.Error!void {}
        fn configOf(_: *Context.Sink, _: Project.FileId) @import("Rule.zig").Config {
            return config;
        }
        fn check(_: *Context) Context.Error!void {}
    };
    const bounded_input = @import("Danger.zig").bounded_input;
    const rule: Context.Rule = .{ .definition = .{ .id = @import("AegisRules.zig").bounded_work, .name = "A012", .group = .family_policy, .purpose = "work" }, .check = Quiet.check, .facts = &.{bounded_input} };
    var sink: Context.Sink = .{ .diagnostic = Quiet.diagnostic, .coverage = Quiet.coverage, .config = Quiet.configOf };
    var own: std.heap.ArenaAllocator = .init(gpa);
    defer own.deinit();
    var c: Context = .{ .allocator = own.allocator(), .project = &project, .file = project.sources[0].id, .config = Quiet.config, .facts = &facts, .definitions = &.{}, .sink = &sink, .compiled = &.{rule} };
    const fact = try get(&c, bounded_input);
    // Closing the summary for the sites runs the cross-check (`checkSizes`).
    _ = try sinkSites(&c, fact, project.sources[0].id);
    const sized = fact.flow.sized.?;
    var w = try Records.checkWriter(&facts);
    defer w.deinit();
    try writeSizes(&w, sized);
    var r = try Records.Reader.init(&facts, w.names, w.bytes.items);
    defer r.deinit();
    const back = try readSizes(&r, arena.allocator());
    try std.testing.expect(r.done());
    try std.testing.expectEqual(sized.functions.items.len, back.len);
    // `grow` sizes by `n` (through `twice`) and its loop by `m`; `twice` by `k`.
    var sized_by: usize = 0;
    for (back) |one| if (!one.sure.empty() or !one.maybe.empty()) {
        sized_by += 1;
    };
    try std.testing.expectEqual(2, sized_by);
}

test "a summary closed for one file is not read again for the next: what a later file's sites ask is what that file reaches anew" {
    // Each file calls std's chain, closed for the first file, and a function of std's of its
    // own. The second file's sites read only its own function: as many bytes whether the
    // chain holds 8 functions or 64 (every file read the whole summary again, 11-04's
    // shakedown: 100 to 1200 MB a file).
    try std.testing.expectEqual(try laterSitesBytes(8), try laterSitesBytes(64));
}

/// The bytes the size sites of a program's second file ask of the run's memory, its first
/// file's read, where each file calls a chain of `chain` std functions, each with a loop, the
/// last allocating what it is given, and one function of std's of its own.
fn laterSitesBytes(chain: usize) !usize {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var mem: std.ArrayList(u8) = .empty;
    try mem.appendSlice(a, "pub const Allocator = struct {\n    pub fn rawAlloc(self: Allocator, len: usize) void {\n        _ = self;\n        _ = len;\n    }\n};\n");
    for (0..chain - 1) |i| {
        try mem.print(a, "pub fn step{d}(gpa: Allocator, n: usize) void {{\n    const a0 = n +% 1;\n", .{i});
        for (1..8) |k| try mem.print(a, "    const a{d} = a{d} +% {d};\n", .{ k, k - 1, k });
        try mem.print(a, "    var i: usize = 0;\n    while (i < a7) : (i += 1) if (i == n) break;\n    step{d}(gpa, a7);\n}}\n", .{i + 1});
    }
    try mem.print(a, "pub fn step{d}(gpa: Allocator, n: usize) void {{\n    gpa.rawAlloc(n);\n}}\n", .{chain - 1});
    for (0..2) |i| try mem.print(a, "pub fn own{d}(gpa: Allocator, n: usize) void {{\n    var i: usize = 0;\n    while (i < n) : (i += 1) gpa.rawAlloc(i);\n}}\n", .{i});
    var programs: [2][]const u8 = undefined;
    for (&programs, 0..) |*program, i| program.* = try a.print("const std = @import(\"std\");\npub fn f(gpa: std.mem.Allocator, n: usize) void {{\n    std.mem.step0(gpa, n);\n    std.mem.own{d}(gpa, n);\n}}\npub const handed = &f;\n", .{i});
    var project = try Project.init(gpa, &.{
        .{ .name = "first", .bytes = programs[0] },
        .{ .name = "second", .bytes = programs[1] },
        .{ .name = "std/std.zig", .bytes = "pub const mem = @import(\"mem.zig\");\n", .selected = false },
        .{ .name = "std/mem.zig", .bytes = mem.items, .selected = false },
    }, &.{ .{ .from = 0, .spelling = "std", .target = 2 }, .{ .from = 1, .spelling = "std", .target = 2 }, .{ .from = 2, .spelling = "mem.zig", .target = 3 } }, .{});
    defer project.deinit();
    // The run's memory, the bytes asked of it counted.
    var run_memory: std.testing.FailingAllocator = .init(a, .{});
    var facts: Facts = .{ .project = &project, .gpa = run_memory.allocator() };
    defer facts.deinit();
    const Quiet = struct {
        const config: @import("Rule.zig").Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = @import("AegisRules.zig").bounded_work, .level = .report }} };
        fn diagnostic(_: *Context.Sink, _: @import("Rule.zig").Rule, _: u32, _: u32, _: []const u8, _: []const @import("Report.zig").Span, _: []const @import("Report.zig").Edit) Context.Error!void {}
        fn coverage(_: *Context.Sink, _: @import("Report.zig").Coverage) Context.Error!void {}
        fn configOf(_: *Context.Sink, _: Project.FileId) @import("Rule.zig").Config {
            return config;
        }
        fn check(_: *Context) Context.Error!void {}
    };
    const bounded_input = @import("Danger.zig").bounded_input;
    const rule: Context.Rule = .{ .definition = .{ .id = @import("AegisRules.zig").bounded_work, .name = "A012", .group = .family_policy, .purpose = "work" }, .check = Quiet.check, .facts = &.{bounded_input} };
    var sink: Context.Sink = .{ .diagnostic = Quiet.diagnostic, .coverage = Quiet.coverage, .config = Quiet.configOf };
    // A rule's own memory for the file, as the Runner gives it: not the run's.
    var own: std.heap.ArenaAllocator = .init(gpa);
    defer own.deinit();
    var c: Context = .{ .allocator = own.allocator(), .project = &project, .file = project.sources[0].id, .config = Quiet.config, .facts = &facts, .definitions = &.{}, .sink = &sink, .compiled = &.{rule} };
    const fact = try get(&c, bounded_input);
    // Each file's sites: the chain's allocation and its own function's loop.
    try std.testing.expectEqual(2, (try sinkSites(&c, fact, project.sources[0].id)).len);
    const before = run_memory.allocated_bytes;
    c.file = project.sources[1].id;
    try std.testing.expectEqual(2, (try sinkSites(&c, fact, project.sources[1].id)).len);
    return run_memory.allocated_bytes - before;
}

test "a summary settled for one file gives a later file the sites it gives that file read alone" {
    // Both files call std's `grow`; the second also hands it a length the first does not, and
    // reaches std's `widen`, which writes the container variable `grow`'s loop counts to. Read
    // after the first file, `grow` is settled: the second file's sites are the same as when it
    // is read first, so settling hid nothing its later call changes.
    const gpa = std.testing.allocator;
    const after = try secondSites(gpa, true);
    defer gpa.free(after);
    const alone = try secondSites(gpa, false);
    defer gpa.free(alone);
    try std.testing.expectEqualStrings("grow 1 n value sure\ngrow 2 s length sure\nwiden 1 m value sure\n", alone);
    try std.testing.expectEqualStrings(alone, after);
}

/// The size sites of the second of two files that call std's `grow`, read after the first
/// file's or alone, one per line as `sizeSitesText` writes them.
fn secondSites(gpa: Allocator, first: bool) ![]u8 {
    const mem =
        \\pub const Allocator = struct {
        \\    pub fn rawAlloc(self: Allocator, len: usize) void {
        \\        _ = self;
        \\        _ = len;
        \\    }
        \\};
        \\var limit: usize = 0;
        \\pub fn grow(gpa: Allocator, n: usize, s: []const u8) void {
        \\    gpa.rawAlloc(n);
        \\    for (s) |_| {}
        \\    var i: usize = 0;
        \\    while (i < limit) : (i += 1) {}
        \\}
        \\pub fn widen(gpa: Allocator, n: usize) void {
        \\    _ = gpa;
        \\    limit = n;
        \\    var i: usize = 0;
        \\    while (i != n) : (i += 1) {}
        \\}
    ;
    var project = try Project.init(gpa, &.{
        .{ .name = "first", .bytes = "const std = @import(\"std\");\npub fn f(gpa: std.mem.Allocator, n: usize) void {\n    std.mem.grow(gpa, n, \"abc\");\n}\npub const handed = &f;\n" },
        .{ .name = "second", .bytes = "const std = @import(\"std\");\npub fn g(gpa: std.mem.Allocator, n: usize, s: []const u8, m: usize) void {\n    std.mem.grow(gpa, n, s);\n    std.mem.widen(gpa, m);\n}\npub const handed = &g;\n" },
        .{ .name = "std/std.zig", .bytes = "pub const mem = @import(\"mem.zig\");\n", .selected = false },
        .{ .name = "std/mem.zig", .bytes = mem, .selected = false },
    }, &.{ .{ .from = 0, .spelling = "std", .target = 2 }, .{ .from = 1, .spelling = "std", .target = 2 }, .{ .from = 2, .spelling = "mem.zig", .target = 3 } }, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const Quiet = struct {
        const config: @import("Rule.zig").Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = @import("AegisRules.zig").bounded_work, .level = .report }} };
        fn diagnostic(_: *Context.Sink, _: @import("Rule.zig").Rule, _: u32, _: u32, _: []const u8, _: []const @import("Report.zig").Span, _: []const @import("Report.zig").Edit) Context.Error!void {}
        fn coverage(_: *Context.Sink, _: @import("Report.zig").Coverage) Context.Error!void {}
        fn configOf(_: *Context.Sink, _: Project.FileId) @import("Rule.zig").Config {
            return config;
        }
        fn check(_: *Context) Context.Error!void {}
    };
    const bounded_input = @import("Danger.zig").bounded_input;
    const rule: Context.Rule = .{ .definition = .{ .id = @import("AegisRules.zig").bounded_work, .name = "A012", .group = .family_policy, .purpose = "work" }, .check = Quiet.check, .facts = &.{bounded_input} };
    var sink: Context.Sink = .{ .diagnostic = Quiet.diagnostic, .coverage = Quiet.coverage, .config = Quiet.configOf };
    var c: Context = .{ .allocator = arena.allocator(), .project = &project, .file = project.sources[0].id, .config = Quiet.config, .facts = &facts, .definitions = &.{}, .sink = &sink, .compiled = &.{rule} };
    const fact = try get(&c, bounded_input);
    if (first) try std.testing.expect((try sinkSites(&c, fact, project.sources[0].id)).len > 0);
    c.file = project.sources[1].id;
    const tree = &project.sources[1].file.tree;
    var seen: std.ArrayList(u8) = .empty;
    errdefer seen.deinit(gpa);
    for (try sinkSites(&c, fact, project.sources[1].id)) |found| {
        const site = (try decidedSite(&c, fact, found)) orelse continue;
        const name = if (site.callee) |d| project.at(d.file).model.declarations[@backingInt(d.index)].name else "?";
        try seen.print(gpa, "{s} {d} {s} {s} {s}\n", .{ name, site.position, tree.getNodeSource(site.value), if (site.length) "length" else "value", if (site.decided) "sure" else "maybe" });
    }
    return seen.toOwnedSlice(gpa);
}

test "a size a generic takes through its context is read in the instantiation the program's call makes" {
    const gpa = std.testing.allocator;
    const mem =
        \\pub const Allocator = struct {
        \\    pub fn rawAlloc(self: Allocator, len: usize) void {
        \\        _ = self;
        \\        _ = len;
        \\    }
        \\};
        \\pub const Plain = struct {
        \\    pub fn hash(_: Plain, key: usize) u64 {
        \\        return key *% 3;
        \\    }
        \\};
        \\pub const Counting = struct {
        \\    pub fn hash(_: Counting, key: usize) u64 {
        \\        var i: usize = 0;
        \\        var t: u64 = 0;
        \\        while (i < key) : (i += 1) t +%= 1;
        \\        return t;
        \\    }
        \\};
        \\pub fn Map(comptime Context: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        ctx: Context,
        \\        pub fn get(self: Self, key: usize) u64 {
        \\            return self.getAdapted(key, self.ctx);
        \\        }
        \\        pub fn getAdapted(self: Self, key: anytype, ctx: anytype) u64 {
        \\            _ = self;
        \\            return ctx.hash(key);
        \\        }
        \\    };
        \\}
    ;
    const program =
        \\const std = @import("std");
        \\const Fast = std.mem.Map(std.mem.Plain);
        \\const Slow = std.mem.Map(std.mem.Counting);
        \\const Own = struct {
        \\    pub fn hash(_: Own, key: usize) u64 {
        \\        return key;
        \\    }
        \\};
        \\pub fn f(fast: Fast, slow: Slow, own: std.mem.Map(Own), k: usize) void {
        \\    _ = fast.get(k);
        \\    _ = slow.get(k);
        \\    _ = own.get(k);
        \\}
        \\pub const handed = &f;
    ;
    const seen = try sizeSitesText(gpa, program, mem);
    defer gpa.free(seen);
    // The plain context's map sizes nothing by the key, the counting one's passes by it, and
    // the program's own context sizes in its own body, judged there.
    try std.testing.expectEqualStrings(
        \\get 1 k value sure
        \\
    , seen);
}
