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

    pub fn join(a: Dep, gpa: Allocator, b: Dep) Allocator.Error!Dep {
        return .{ .level = a.level.join(b.level), .params = try a.params.unite(gpa, b.params), .numbers = try a.numbers.unite(gpa, b.numbers), .ranged = try a.ranged.unite(gpa, b.ranged), .maybe = try a.maybe.unite(gpa, b.maybe), .ruled = try a.ruled.unite(gpa, b.ruled), .length = a.length.join(b.length), .lengths = try a.lengths.unite(gpa, b.lengths), .ruled_lengths = try a.ruled_lengths.unite(gpa, b.ruled_lengths), .counted = try a.counted.unite(gpa, b.counted), .counted_numbers = try a.counted_numbers.unite(gpa, b.counted_numbers), .unchecked = a.unchecked.join(b.unchecked), .bare = try a.bare.unite(gpa, b.bare) };
    }
    fn lowered(a: Dep, gpa: Allocator) Allocator.Error!Dep {
        return .{ .level = a.level.lowered(), .maybe = try Slots.all(gpa, &.{ a.params, a.numbers, a.ranged, a.maybe }), .ruled = a.ruled, .counted = a.counted, .counted_numbers = a.counted_numbers, .length = a.length, .lengths = a.lengths, .ruled_lengths = a.ruled_lengths, .unchecked = a.unchecked, .bare = a.bare };
    }
    /// Data made a number: a shift or a product of it, or what std decodes from it.
    fn widened(a: Dep, gpa: Allocator) Allocator.Error!Dep {
        return .{ .level = a.level.widened(), .params = a.params, .numbers = try Slots.all(gpa, &.{ a.numbers, a.params, a.ranged }), .maybe = a.maybe, .ruled = a.ruled, .counted_numbers = try a.counted.unite(gpa, a.counted_numbers), .length = a.length, .lengths = a.lengths, .ruled_lengths = a.ruled_lengths, .unchecked = a.unchecked, .bare = a.bare };
    }
    /// A value kept to a range the program chose: a number is data there.
    fn narrowed(a: Dep, gpa: Allocator) Allocator.Error!Dep {
        return .{ .level = a.level.narrowed(), .ranged = try Slots.all(gpa, &.{ a.params, a.numbers, a.ranged }), .maybe = a.maybe, .ruled = try Slots.all(gpa, &.{ a.ruled, a.counted, a.counted_numbers }), .length = a.length, .lengths = a.lengths, .ruled_lengths = a.ruled_lengths, .unchecked = a.unchecked, .bare = a.bare };
    }
    /// What a condition reading this value decides: data held to the choice, for the facts
    /// that take what they decide (`Masks.control`); for the others nothing.
    fn ruling(a: Dep, gpa: Allocator, masks: Masks) Allocator.Error!Dep {
        return .{ .level = a.level.narrowed().masked(masks.control), .ruled = try Slots.all(gpa, &.{ a.params, a.numbers, a.ranged, a.maybe, a.ruled, a.counted, a.counted_numbers }) };
    }
    /// What a loop whose passes this value decides counts into a sum each pass steps (`total
    /// += 1`), where the loop counts against it (a `for`'s range or input, a `while` comparing a
    /// counter it steps by a sum): as far as the value goes, for the facts control takes.
    fn counting(a: Dep, gpa: Allocator, masks: Masks) Allocator.Error!Dep {
        return .{ .level = a.level.masked(masks.control), .counted = try a.params.unite(gpa, a.counted), .counted_numbers = try a.numbers.unite(gpa, a.counted_numbers), .ruled = try Slots.all(gpa, &.{ a.ranged, a.maybe, a.ruled }) };
    }
    /// The same where nothing counts the loop's passes (a `while` on what it reads, a labeled
    /// switch): each pass steps the sum again as long as the value says, so a number.
    fn unbounded(a: Dep, gpa: Allocator, masks: Masks) Allocator.Error!Dep {
        return .{ .level = a.level.widened().masked(masks.control), .counted_numbers = try Slots.all(gpa, &.{ a.params, a.numbers, a.ranged, a.maybe, a.ruled, a.counted, a.counted_numbers }) };
    }
    /// Its length read as a value (`.len`): within the memory, so data at most, unless no
    /// build holds it there (`unchecked`). A parameter's own length (its `lengthSlot`) is
    /// what its callers measured; a parameter's value bounding a slice is data.
    fn measured(a: Dep) Dep {
        return .{ .level = a.length.narrowed().join(a.unchecked), .params = a.bare, .ranged = a.lengths, .ruled = a.ruled_lengths };
    }
    /// Memory whose length is this value written in place (`s.len = n`), which no build
    /// checks against the memory: the value's level, and a parameter's as its callers give it
    /// (a number where it was made one).
    fn written(a: Dep, gpa: Allocator) Allocator.Error!Dep {
        return .{ .unchecked = a.level.join(if (!a.numbers.empty() or !a.counted_numbers.empty()) Levels.all(.number) else .clean), .bare = try a.params.unite(gpa, a.counted), .lengths = try a.ranged.unite(gpa, a.maybe), .ruled_lengths = a.ruled };
    }
    /// Memory whose length a measure gave (`concreteLength`), read back.
    fn measuredLength(level: Levels) Dep {
        return .{ .unchecked = level };
    }
    /// Memory whose length is this value (a slice's bound): data at most.
    fn sizing(a: Dep, gpa: Allocator) Allocator.Error!Dep {
        return .{ .length = a.level.narrowed(), .lengths = try Slots.all(gpa, &.{ a.params, a.numbers, a.ranged, a.maybe }), .ruled_lengths = try Slots.all(gpa, &.{ a.ruled, a.counted, a.counted_numbers }) };
    }
    /// What it holds, with no length.
    fn held(a: Dep) Dep {
        return .{ .level = a.level, .params = a.params, .numbers = a.numbers, .ranged = a.ranged, .maybe = a.maybe, .ruled = a.ruled, .counted = a.counted, .counted_numbers = a.counted_numbers };
    }
    /// Its length alone: what a slice to the end of this memory keeps of it.
    fn lengthOnly(a: Dep) Dep {
        return .{ .length = a.length, .lengths = a.lengths, .ruled_lengths = a.ruled_lengths, .unchecked = a.unchecked, .bare = a.bare };
    }
    fn clean(a: Dep) bool {
        return a.level.isClean() and a.params.empty() and a.numbers.empty() and a.ranged.empty() and a.maybe.empty() and a.ruled.empty() and a.length.isClean() and a.lengths.empty() and a.ruled_lengths.empty() and a.counted.empty() and a.counted_numbers.empty() and a.unchecked.isClean() and a.bare.empty();
    }
    fn eql(a: Dep, b: Dep) bool {
        return a.level.eql(b.level) and a.params.eql(b.params) and a.numbers.eql(b.numbers) and a.ranged.eql(b.ranged) and a.maybe.eql(b.maybe) and a.ruled.eql(b.ruled) and a.length.eql(b.length) and a.lengths.eql(b.lengths) and a.ruled_lengths.eql(b.ruled_lengths) and a.counted.eql(b.counted) and a.counted_numbers.eql(b.counted_numbers) and a.unchecked.eql(b.unchecked) and a.bare.eql(b.bare);
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
    /// Per file, each node's nearest enclosing function, by its index in `functions`.
    owners: std.AutoHashMapUnmanaged(Project.FileId, []?Function.Id) = .empty,
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
    /// std's accessors of a Zig tree's text (`zig_text`) and its parser, resolved once.
    zig_text: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty,
    zig_parse: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty,
    /// std's Zig tree's file, and the types of an index into its own tables (`treeValue`).
    zig_ast: ?Project.FileId = null,
    zig_index: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty,
    /// What decides how many passes each loop takes, read once per round (`passes`).
    loops: std.AutoHashMapUnmanaged(Facts.Key, Dep) = .empty,
    /// What decides that each statement jumps past what follows it (`leaves`), read once per
    /// round, by the statement and the declaration a store's target is (none: one outliving
    /// the function).
    leaving: std.AutoHashMapUnmanaged(struct { Facts.Key, ?Ast.TokenIndex }, Dep) = .empty,
    changed: bool = false,
    /// What the functions outside the program its calls reach size work by (`sizesFlow`): a
    /// flow of its own over them, read for no fact.
    sized: ?*Flow = null,
    /// The size sink's sites per file (`sinkSites`).
    size_sites: std.AutoHashMapUnmanaged(Project.FileId, []const SinkSite) = .empty,
    /// std's allocations: `Allocator.rawAlloc`, `rawResize` and `rawRemap`, each argument but
    /// the allocator a size; not known where std's allocator does not resolve.
    allocations: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty,
    allocations_known: bool = true,
    /// A summary's files, each one's functions' bodies grouped once (`bodies`), and the nodes
    /// that grouping read: a count a test holds to the files, not the functions.
    bodies: std.AutoHashMapUnmanaged(Project.FileId, std.AutoHashMapUnmanaged(Ast.Node.Index, []const Ast.Node.Index)) = .empty,
    walked: usize = 0,

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

/// The run's solve: the facts the enabled rules declare, and any other a rule asked since.
const Solved = struct { flow: ?*Flow = null };

/// The fact `spec` describes, solved with every other the run's enabled rules declare the
/// first time one is asked. A rule asks only the facts it declares (`Context.Rule.facts`);
/// another is `error.InvalidSelection`.
pub fn get(c: *Context, spec: Spec) Context.Error!Fact {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Solved);
    const flow = memo.flow orelse solved: {
        var specs: std.ArrayList(Spec) = .empty;
        for (c.compiled) |rule| {
            if (!try enabled(c, rule)) continue;
            for (rule.facts) |each| if (laneOf(specs.items, each) == null) try specs.append(c.allocator, each);
        }
        // The run's rules fit the lanes (`fits`): the Runner refuses a set that does not.
        const flow = try c.allocator.create(Flow);
        flow.* = .{ .specs = specs.items, .masks = masksOf(specs.items) };
        try solve(c, flow);
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
    flow.program = try Program.get(c);
    try known(c, flow);
    for (c.project.sources) |*each| {
        if (each.input.classification == .@"test") continue;
        const file = each.id;
        if (!flow.own(file)) continue;
        // A file whose rules ask no fact (a tool the package develops with) is no part of the
        // program the facts describe.
        if (!asks(c, c.configOf(file))) continue;
        try functionsOf(c, flow, file);
    }
    try parsers(c, flow);
    try escaped(c, flow);
    try linksOf(c, flow);
    // Every step joins, and each level and set is finite: the rounds end when one changes
    // nothing, however long a chain of calls the fact runs through.
    while (true) {
        flow.changed = false;
        flow.loops.clearRetainingCapacity();
        flow.leaving.clearRetainingCapacity();
        for (flow.functions.items, 0..) |_, i| try bindings(c, flow, @fromBackingInt(@intCast(i)));
        try takeHeld(c, flow);
        if (!flow.changed) break;
    }
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
        for (entry.value_ptr.*, 0..) |own, i| {
            if (own == null) continue;
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
    const tree = &c.project.at(file).file.tree;
    const owners = try c.allocator.alloc(?Function.Id, tree.nodes.len);
    @memset(owners, null);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .fn_decl) continue;
        _ = try addFunction(c, flow, file, @fromBackingInt(@intCast(i)));
    }
    var held: std.AutoHashMapUnmanaged(Function.Id, std.ArrayList(Ast.Node.Index)) = .empty;
    for (0..tree.nodes.len) |i| {
        const function = enclosing(c, file, @fromBackingInt(@intCast(i))) orelse continue;
        owners[i] = flow.by_node.get(.{ .file = file, .node = function });
        const id = owners[i] orelse continue;
        const entry = try held.getOrPut(c.allocator, id);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(c.allocator, @fromBackingInt(@intCast(i)));
    }
    var each = held.iterator();
    while (each.next()) |entry| flow.functions.items[@backingInt(entry.key_ptr.*)].nodes = try entry.value_ptr.toOwnedSlice(c.allocator);
    try flow.owners.put(c.allocator, file, owners);
}

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
    const index = @backingInt(node);
    return if (index < owners.len) owners[index] else null;
}

/// One round over a function's bindings: what each local, field, parameter and result takes.
fn bindings(c: *Context, flow: *Flow, function: Function.Id) Context.Error!void {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    for (f.nodes) |node| {
        switch (tree.nodeTag(node)) {
            .simple_var_decl, .local_var_decl, .aligned_var_decl, .global_var_decl => {
                const init = (tree.fullVarDecl(node) orelse continue).ast.init_node.unwrap() orelse continue;
                const d = declaredAt(model, node) orelse continue;
                try raiseLocal(c, flow, .{ .file = f.file, .index = d }, try dep(c, flow, function, init));
            },
            .assign, .assign_add, .assign_sub, .assign_div, .assign_mod, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_add_sat, .assign_sub_sat => {
                const target, const value = tree.nodeData(node).node_and_node;
                var given = try dep(c, flow, function, value);
                const ruled = try control(c, flow, function, node, target);
                // A sum or a product that feeds its own target accumulates a number past any
                // range what it adds holds (`n = n * 10 + d`, `total += b`).
                const accumulating = tree.nodeTag(node) == .assign and accumulates(tree, model, target, value);
                switch (tree.nodeTag(node)) {
                    .assign_add, .assign_add_wrap, .assign_add_sat => given = try given.widened(c.allocator),
                    else => if (accumulating) {
                        given = try given.widened(c.allocator);
                    },
                }
                var held = try given.join(c.allocator, ruled);
                // A sum each pass steps again counts the passes of the loops around it.
                const stepped = accumulating or switch (tree.nodeTag(node)) {
                    .assign_add, .assign_add_wrap, .assign_add_sat, .assign_sub, .assign_sub_wrap, .assign_sub_sat => true,
                    else => false,
                };
                if (stepped) held = try held.join(c.allocator, try counts(c, flow, function, node, target));
                // A slice's length written (`s.len = n`): the memory's length is the value. What
                // decides whether it is written chooses between it and the length it had, which
                // was within the memory; one taken from (`s.len -= k`, which a safe build checks)
                // stays within it.
                if (std.mem.eql(u8, tree.tokenSlice(tree.lastToken(target)), "len") and try c.facts.memoryField(f.file, target) != .field) {
                    held = if (tree.nodeTag(node) == .assign_sub) try ruled.sizing(c.allocator) else try (try given.written(c.allocator)).join(c.allocator, try ruled.sizing(c.allocator));
                }
                try storeAt(c, flow, function, node, target, value, held);
            },
            .assign_mul, .assign_shl, .assign_mul_wrap, .assign_mul_sat, .assign_shl_sat => {
                const target, const value = tree.nodeData(node).node_and_node;
                const grown = try (try dep(c, flow, function, target)).widened(c.allocator);
                const given = try grown.join(c.allocator, try dep(c, flow, function, value));
                try store(c, flow, function, target, try given.join(c.allocator, try control(c, flow, function, node, target)));
            },
            .assign_destructure => {
                const parts = tree.assignDestructure(node);
                const all = try dep(c, flow, function, parts.ast.value_expr);
                // A literal of as many elements gives each variable its own (`x, y = .{ 5, n }`).
                var buffer: [2]Ast.Node.Index = undefined;
                const elements: ?[]const Ast.Node.Index = if (tree.fullArrayInit(&buffer, parts.ast.value_expr)) |literal| (if (literal.ast.elements.len == parts.ast.variables.len) literal.ast.elements else null) else null;
                for (parts.ast.variables, 0..) |variable, at| {
                    const value = try (if (elements) |each| try dep(c, flow, function, each[at]) else all).join(c.allocator, try control(c, flow, function, node, variable));
                    if (declaredAt(model, variable)) |d| try raiseLocal(c, flow, .{ .file = f.file, .index = d }, value) else try store(c, flow, function, variable, value);
                }
            },
            .@"return" => {
                const value = tree.nodeData(node).opt_node.unwrap() orelse continue;
                const now = try (try flow.functions.items[@backingInt(function)].ret.join(c.allocator, try dep(c, flow, function, value))).join(c.allocator, try control(c, flow, function, node, null));
                if (!now.eql(flow.functions.items[@backingInt(function)].ret)) {
                    flow.functions.items[@backingInt(function)].ret = now;
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
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            if (std.mem.eql(u8, name, "@memcpy") or std.mem.eql(u8, name, "@memmove")) return .{ .destination = 0, .value = 1, .kind = .copy };
            if (std.mem.eql(u8, name, "@memset")) return .{ .destination = 0, .value = 1, .kind = .fill };
            if (std.mem.eql(u8, name, "@atomicStore")) return .{ .destination = 1, .value = 2, .kind = .fill };
            if (std.mem.eql(u8, name, "@cmpxchgWeak") or std.mem.eql(u8, name, "@cmpxchgStrong")) return .{ .destination = 1, .value = 3, .kind = .fill };
            if (std.mem.eql(u8, name, "@atomicRmw")) return .{ .destination = 1, .value = 3, .kind = .combine };
            return null;
        },
        else => return null,
    }
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
            out = try out.join(c.allocator, .{ .level = flow.globals.get(field) orelse .clean, .unchecked = flow.lengths.get(field) orelse .clean });
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

/// The declaration a `var`/`const` node declares.
/// A function of the program code outside it may call (`Facts.escapes`: std's sort given
/// `less`, a hash map's context, a spawned thread's worker, an exported name) is called with
/// values no call of the program shows: each parameter a comptime one does not fix, and each
/// one's length, may hold the fact at its most.
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
        for (f.levels, 0..) |*level, slot| {
            if (!f.fixed.has(slot / 2)) level.* = .all(.number);
        }
    }
}

fn declaredAt(model: *const Model, node: Ast.Node.Index) ?Model.Declaration.Id {
    for (model.declarations, 0..) |decl, d| if (decl.node == node and decl.kind == .variable) return @fromBackingInt(@intCast(d));
    return null;
}

fn raiseLocal(c: *Context, flow: *Flow, decl: Facts.Decl, value: Dep) Context.Error!void {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    if (value.clean()) return;
    const entry = try flow.locals.getOrPut(c.allocator, decl);
    const before: Dep = if (entry.found_existing) entry.value_ptr.* else .{};
    const now = try before.join(c.allocator, value);
    entry.value_ptr.* = now;
    if (!now.eql(before)) flow.changed = true;
}

/// A field or a container-level variable given a value of `level` in memory of `length`.
fn raiseGlobal(c: *Context, flow: *Flow, decl: Facts.Decl, level: Levels, length: Levels) Context.Error!void {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    for ([_]struct { *std.AutoHashMapUnmanaged(Facts.Decl, Levels), Levels }{ .{ &flow.globals, level }, .{ &flow.lengths, length } }) |each| {
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
    switch (tree.nodeTag(target)) {
        .identifier => {
            // `_ = v` discards; a name that does not resolve may be any memory.
            if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_")) return;
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
                switch (tree.nodeTag(init)) {
                    .address_of, .slice_open, .slice, .slice_sentinel => try places(c, flow, function, init, out),
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
        .field_access => {
            // The program's own field holds the fact by its declaration; a field of a type
            // outside it (std's writer, a dependency's list) is every instance's everywhere, so
            // the store reaches only the value it belongs to.
            const holder, const name = tree.nodeData(target).node_and_token;
            switch (try c.facts.definition(f.file, target)) {
                .decl => |decl| if (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind == .field and flow.own(decl.file)) return addPlace(c, out, .{ .global = decl }),
                // A member that does not resolve, or one of a holder whose type does not, may be
                // any of the program's fields so named.
                .unknown => for (try fieldsNamed(c, flow, tree.tokenSlice(name))) |decl| try addPlace(c, out, .{ .global = decl }),
                .none => if (unresolvedHolder(try c.facts.resolve(f.file, holder))) for (try fieldsNamed(c, flow, tree.tokenSlice(name))) |decl| try addPlace(c, out, .{ .global = decl }),
            }
            return places(c, flow, function, holder, out);
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
                for (vector.ast.elements) |element| switch (tree.nodeTag(element)) {
                    .address_of, .slice_open, .slice, .slice_sentinel => try places(c, flow, function, element, out),
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

/// The store at `node` of `value` into `target`, which `given` gives where one expression
/// does: the places `store` names, and where none is a field or a container-level variable,
/// the fields of the memory it writes through a pointer as a whole value or as bytes
/// (`Facts.accesses.fieldsThrough`: `h.* = v`, `@memcpy(std.mem.asBytes(h), bytes)`): the
/// place's other names reach that memory by those fields alone. A struct literal's fields
/// are given each its own.
fn storeAt(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index, target: Ast.Node.Index, given: ?Ast.Node.Index, value: Dep) Context.Error!void {
    const f = flow.functions.items[@backingInt(function)];
    var found: std.ArrayList(Place) = .empty;
    try places(c, flow, function, target, &found);
    for (found.items) |place| try raise(c, flow, function, place, value);
    for (found.items) |place| if (place == .global) return;
    // Code outside the program writes the program's fields only through what its callers hand
    // it, which their stores raise: its own stores raise none of them (bay, 2c).
    if (!flow.own(f.file)) return;
    if (given) |one| {
        var buffer: [2]Ast.Node.Index = undefined;
        if (c.project.at(f.file).file.tree.fullStructInit(&buffer, one) != null) return;
    }
    for (try Facts.accesses.fieldsThrough(c.facts, f.file, node)) |field| {
        if (flow.own(field.file)) try raise(c, flow, function, .{ .global = field }, value);
    }
}

/// `value` into one place, read in `function`.
fn raise(c: *Context, flow: *Flow, function: Function.Id, place: Place, value: Dep) Context.Error!void {
    const f = flow.functions.items[@backingInt(function)];
    switch (place) {
        .local => |d| try raiseLocal(c, flow, .{ .file = f.file, .index = d }, value),
        .param => |index| {
            const now = try f.writes[index].join(c.allocator, value);
            if (!now.eql(f.writes[index])) {
                f.writes[index] = now;
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
                const given = try dep(c, flow, function, arg);
                for ([_]struct { usize, Levels }{ .{ valueSlot(index), concrete(flow, function, given) }, .{ lengthSlot(index), concreteLength(flow, function, given) } }) |each| {
                    const slot, const level = each;
                    if (slot >= g.levels.len) continue;
                    if (!level.join(g.levels[slot]).eql(g.levels[slot])) {
                        flow.functions.items[@backingInt(target)].levels[slot] = level.join(g.levels[slot]);
                        flow.changed = true;
                    }
                }
                // What it writes through the argument, under the call's control: a write of the
                // program's own value made where input decides is input's.
                const ruled = try control(c, flow, function, node, arg);
                if (!g.writes[index].clean()) try store(c, flow, function, arg, try (try summarized(c, flow, function, callee, g.writes[index])).join(c.allocator, ruled)) else if (!ruled.clean() and try pointing(c, f.file, arg)) try store(c, flow, function, arg, ruled);
            }
        },
        .source => {
            const lanes = try readLanes(c, flow, function, callee);
            if (lanes == none) return;
            const buffers = try bufferParams(c, callee.decl.?);
            for (callee.args, 0..) |arg, position| if (buffers.has(position)) try fill(c, flow, function, arg, lanes);
        },
        .outside => {
            // What a function outside the program is given may go into any memory it is given
            // by a mutable pointer: a list appended to, a map put into, a hasher updated, a
            // writer written to, a destination copied into.
            const decl = callee.decl orelse return;
            var given: Dep = .{};
            for (callee.args) |arg| given = try given.join(c.allocator, try whole(c, flow, function, arg));
            const writes = try mutableParams(c, decl);
            for (callee.args, 0..) |arg, position| if (writes.has(position)) {
                const value = try given.join(c.allocator, try control(c, flow, function, node, arg));
                if (!value.clean()) try store(c, flow, function, arg, value);
            };
        },
        .aegis => try parsed(c, flow, f.file, callee.params, callee.decl.?),
        .choice => |each| for (each) |one| try effects(c, flow, function, one),
        // A call that does not resolve may write anything into the memory it is given.
        .none => for (callee.args) |arg| {
            if (try pointing(c, f.file, arg)) try store(c, flow, function, arg, .{ .level = .all(.unknown) });
        },
        .holder => {},
    }
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
    const record = c.project.at(origin.file).model.declarations[@backingInt(origin.index)];
    if (!std.mem.eql(u8, record.name, "parse") or params.len == 0) return null;
    const container: Facts.Value = .{ .container = .{ .file = origin.file, .scope = record.scope } };
    if (try c.role(Contract.library, container) != .untrusted) return null;
    const parser = switch (try c.facts.resolve(file, params[params.len - 1])) {
        .function => |function| function,
        else => return null,
    };
    return flow.by_node.get(.{ .file = parser.file, .node = fnDecl(c, parser) orelse return null });
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
        if (tree.nodeTag(at) == .optional_type) at = tree.nodeData(at).node;
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
fn fill(c: *Context, flow: *Flow, function: Function.Id, arg: Ast.Node.Index, lanes: Mask) Context.Error!void {
    try store(c, flow, function, arg, .{ .level = .in(lanes, .data) });
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
    return level;
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
    const call = (try Facts.calls.at(c.facts, file, node)) orelse return null;
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

/// What a call whose arguments' parameters are not known is written with: the holder of
/// `x.f(a)` and its arguments, or `@call`'s tuple.
fn written(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error![]const Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&buffer, node)) |call| {
        const field = tree.nodeTag(call.ast.fn_expr) == .field_access;
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
        if (role == .untrusted and std.mem.eql(u8, c.project.at(origin.file).model.declarations[@backingInt(origin.index)].name, "readForParse")) {
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
    if (flow.stream) |stream| if (stream.file == decl.file and std.mem.eql(u8, record.name, "writer")) {
        out.writer = true;
    };
    if (flow.by_node.get(.{ .file = decl.file, .node = fnDecl(c, decl) orelse record.node })) |target| {
        out.kind = .{ .program = target };
        return;
    }
    // A function of the program the fact does not read (one in a file whose rules read no
    // fact) gives what it does unread: undecided.
    if (flow.own(decl.file)) return;
    out.kind = if (try source(c, flow, decl, record.name)) .source else .outside;
}

/// The `fn_decl` node of a function declaration.
fn fnDecl(c: *Context, decl: Facts.Decl) ?Ast.Node.Index {
    const model = &c.project.at(decl.file).model;
    const tree = &c.project.at(decl.file).file.tree;
    const parent = model.parentOf(model.declarations[@backingInt(decl.index)].node) orelse return null;
    return if (tree.nodeTag(parent) == .fn_decl) parent else null;
}

/// Whether a function outside the program reads a peer's input.
fn source(c: *Context, flow: *Flow, decl: Facts.Decl, name: []const u8) Context.Error!bool {
    _ = c;
    const file = decl.file;
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
}

/// The lanes a read reads a peer's input in: every peer lane, but where the reader is one
/// std's `Reader.fixed` made over bytes clean in that lane (`fixedBytes`), whose read carries
/// the bytes' fact, not input's.
fn readLanes(c: *Context, flow: *Flow, function: Function.Id, callee: Callee) Context.Error!Mask {
    const f = flow.functions.items[@backingInt(function)];
    const receiver = callee.receiver orelse return flow.masks.peer;
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
            .function => |decl| std.meta.eql(((try c.facts.origin(decl)).orNull()) orelse decl, fixed),
            else => false,
        },
    };
    if (!by_std) return null;
    for (flow.functions.items[@backingInt(function)].nodes) |node| {
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

/// What an expression holds, read in `function`.
fn dep(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    switch (tree.nodeTag(node)) {
        .identifier => return declaredDep(c, flow, function, node),
        .field_access => return fieldDep(c, flow, function, node),
        .array_access => return dep(c, flow, function, tree.nodeData(node).node_and_node[0]),
        // A slice holds what it slices, in a length its bounds set: past its start to its end,
        // or to the end of what it slices.
        .slice_open, .slice, .slice_sentinel => {
            const slice = tree.fullSlice(node) orelse return .{};
            const memory = try dep(c, flow, function, slice.ast.sliced);
            var out = try memory.held().join(c.allocator, try (try dep(c, flow, function, slice.ast.start)).sizing(c.allocator));
            if (slice.ast.end.unwrap()) |end| {
                out = try out.join(c.allocator, try (try dep(c, flow, function, end)).sizing(c.allocator));
            } else out = try out.join(c.allocator, memory.lengthOnly());
            return out;
        },
        .grouped_expression, .unwrap_optional => return dep(c, flow, function, tree.nodeData(node).node_and_token[0]),
        .deref, .address_of, .@"try", .negation, .negation_wrap, .bit_not => return dep(c, flow, function, tree.nodeData(node).node),
        // What is left of a length (`buf.len - at`) is bounded by it; a mask or a remainder by
        // the program's own value is bounded by it, a peer's value within that range: data.
        .sub, .sub_sat => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const out = try (try dep(c, flow, function, lhs)).join(c.allocator, try dep(c, flow, function, rhs));
            return if (try c.facts.memoryField(f.file, lhs) != .field) try out.narrowed(c.allocator) else out;
        },
        .bit_and, .mod => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const left = try dep(c, flow, function, lhs);
            const right = try dep(c, flow, function, rhs);
            if (left.clean() or right.clean()) return try (try left.join(c.allocator, right)).narrowed(c.allocator);
            return try left.join(c.allocator, right);
        },
        // Wrapping arithmetic stays in its type's range, which is the peer's to choose in a wide
        // type: a sink reads it as data only where the result is shown small (a hash shifted to
        // a table's bits).
        .add_wrap, .sub_wrap, .mul_wrap, .add, .div, .shr, .bit_or, .bit_xor, .add_sat, .array_cat, .@"orelse", .@"catch" => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return try (try dep(c, flow, function, lhs)).join(c.allocator, try dep(c, flow, function, rhs));
        },
        .mul, .mul_sat => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return try (try dep(c, flow, function, lhs)).join(c.allocator, try dep(c, flow, function, rhs));
        },
        // Bytes shifted into place assemble a number; a clean value shifted by data is a mask.
        .shl, .shl_sat => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const shifted = try (try dep(c, flow, function, lhs)).widened(c.allocator);
            return shifted.join(c.allocator, try dep(c, flow, function, rhs));
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => return builtinDep(c, flow, function, node),
        .@"if", .if_simple => {
            const branch = tree.fullIf(node).?;
            // Which branch gives the value is the condition's choice.
            var out = try (try dep(c, flow, function, branch.ast.cond_expr)).ruling(c.allocator, flow.masks);
            out = try out.join(c.allocator, try dep(c, flow, function, branch.ast.then_expr));
            if (branch.ast.else_expr.unwrap()) |e| out = try out.join(c.allocator, try dep(c, flow, function, e));
            return out;
        },
        .@"switch", .switch_comma => {
            var out = try (try dep(c, flow, function, tree.fullSwitch(node).?.ast.condition)).ruling(c.allocator, flow.masks);
            for (tree.fullSwitch(node).?.ast.cases) |case| out = try out.join(c.allocator, try dep(c, flow, function, (tree.fullSwitchCase(case) orelse continue).ast.target_expr));
            return out;
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => return labeled(c, flow, function, node),
        .while_simple, .while_cont, .@"while", .for_simple, .@"for" => return loopValue(c, flow, function, node),
        // A comparison's truth is what it compares chose: a bool, data, for the facts that take
        // what they decide.
        .less_than, .less_or_equal, .greater_than, .greater_or_equal, .equal_equal, .bang_equal, .bool_and, .bool_or => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const both = try (try dep(c, flow, function, lhs)).join(c.allocator, try dep(c, flow, function, rhs));
            return both.ruling(c.allocator, flow.masks);
        },
        .bool_not => return try (try dep(c, flow, function, tree.nodeData(node).node)).ruling(c.allocator, flow.masks),
        else => {},
    }
    if (try literalDep(c, flow, function, node)) |out| return out;
    if (try resolveCall(c, flow, f.file, node)) |callee| return result(c, flow, function, callee);
    return composed(c, flow, function, node);
}

/// What a name holds: a parameter's own slots, a global's facts, a local's.
fn declaredDep(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!Dep {
    const f = flow.functions.items[@backingInt(function)];
    const model = &c.project.at(f.file).model;
    const ref = model.reference(node) orelse return .{};
    const d = ref.declaration orelse return if (ref.unknown) |why| switch (why) {
        // A primitive (`true`, `u8`) or a name a literal's type gives holds no data.
        .primitive, .literal_context => .{},
        // A name that does not resolve may be anything, memory no place names among it.
        .unresolved, .invalid_lowering, .before_declaration => .{ .level = Levels.all(.unknown).join(flow.unnamed), .unchecked = flow.unnamed_length },
    } else .{};
    // A parameter's own length is what its callers measured (`concreteLength`).
    if (f.position(d)) |index| return .{ .params = try .of(c.allocator, valueSlot(index)), .bare = try .of(c.allocator, lengthSlot(index)) };
    const decl = model.declarations[@backingInt(d)];
    if (decl.kind == .variable or decl.kind == .capture) {
        const scope = model.scopes[@backingInt(decl.scope)].kind;
        if (scope == .file or scope == .container) return .{ .level = flow.globals.get(.{ .file = f.file, .index = d }) orelse .clean, .unchecked = flow.lengths.get(.{ .file = f.file, .index = d }) orelse .clean };
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
        if (std.mem.eql(u8, tree.tokenSlice(name), "ptr")) return .{};
        const memory = try dep(c, flow, function, receiver);
        return try (try memory.held().narrowed(c.allocator)).join(c.allocator, memory.measured());
    }
    var out = try dep(c, flow, function, receiver);
    if ((try c.facts.definition(f.file, node)).orNull()) |decl| {
        if (decl.file == flow.zig_ast) if (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind == .field) {
            const field = c.project.at(decl.file).file.tree.fullContainerField(c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node).?;
            return treeDep(c, flow, decl.file, field.ast.type_expr.unwrap());
        };
        if (flow.globals.get(decl)) |level| out = try out.join(c.allocator, .{ .level = level });
        if (flow.lengths.get(decl)) |length| out = try out.join(c.allocator, Dep.measuredLength(length));
        if (flow.zig_text.contains(decl)) out = try out.join(c.allocator, .{ .level = .in(flow.masks.peer, .data) });
        // A function or a type named through a value is no part of its data.
        const kind = c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind;
        if (kind == .function) return .{};
    } else out = try out.join(c.allocator, .{ .level = try alternativeFields(c, flow, f.file, receiver, tree.tokenSlice(name)) });
    return out;
}

/// What a struct or an array literal holds, or null where `node` is neither.
fn literalDep(c: *Context, flow: *Flow, function: Function.Id, node: Ast.Node.Index) Context.Error!?Dep {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, node)) |literal| {
        // A literal of a known type holds its fields' facts by their declarations; a tuple or
        // a literal whose type does not resolve holds what it is given. A parser's result
        // holds its numbers itself: clean through the parse, input through a direct call.
        if (try literalFields(c, f.file, node, literal)) |fields| {
            if (!f.parser or !returned(tree, model, node)) return .{};
            var out: Dep = .{};
            for (literal.ast.fields, fields) |value, field| if (try shownField(c, f.file, value, field)) {
                out = try out.join(c.allocator, try dep(c, flow, function, value));
            };
            return out;
        }
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
    for ([_][]const u8{ "@sizeOf", "@alignOf", "@bitSizeOf", "@TypeOf", "@typeInfo", "@errorName", "@tagName", "@typeName", "@import", "@This", "@src", "@hasDecl", "@hasField" }) |clean| if (std.mem.eql(u8, name, clean)) return .{};
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    // A field `@field` names is read by its declaration, as `x.name` is.
    if (std.mem.eql(u8, name, "@field") and args.len == 2) {
        var out = try dep(c, flow, function, args[0]);
        for (try namedFields(c, flow.functions.items[@backingInt(function)].file, node)) |field| {
            out = try out.join(c.allocator, .{ .level = flow.globals.get(field) orelse .clean, .unchecked = flow.lengths.get(field) orelse .clean });
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
    for ([_][]const u8{ "@bitCast", "@ptrCast" }) |cast| if (std.mem.eql(u8, name, cast)) return out.widened(c.allocator);
    // A pointer made from an integer reaches memory no place names.
    if (std.mem.eql(u8, name, "@ptrFromInt")) return out.join(c.allocator, unnamed(flow));
    return out;
}

/// What memory no place names may hold (`Flow.unnamed`).
fn unnamed(flow: *const Flow) Dep {
    return .{ .level = flow.unnamed, .unchecked = flow.unnamed_length };
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
    for (try children(c, f.file, node)) |part| out = try out.join(c.allocator, try dep(c, flow, function, part));
    return out;
}

/// A field read through a value whose type is one of several (a generic's result over each
/// of its instantiations, `Untrusted.parse` over each parser): what the program stores in the
/// field of that name in each of them. Through one whose type does not resolve, what it stores
/// in any of its fields so named.
fn alternativeFields(c: *Context, flow: *Flow, file: Project.FileId, receiver: Ast.Node.Index, name: []const u8) Context.Error!Levels {
    var out: Levels = .clean;
    const value = try c.facts.resolve(file, receiver);
    for (if (value == .alternatives) value.alternatives else &.{value}) |each| {
        var held = each;
        while (true) held = switch (held) {
            .pointer, .optional, .error_union => |inner| inner.*,
            else => break,
        };
        const container = switch (held) {
            .container, .instance => |k| k,
            .unknown => |why| {
                if (why != .zig_own and why != .absent) for (try fieldsNamed(c, flow, name)) |decl| {
                    out = out.join(flow.globals.get(decl) orelse .clean);
                };
                continue;
            },
            else => continue,
        };
        const decl = c.facts.member(container, name) orelse continue;
        if (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind != .field) continue;
        out = out.join(flow.globals.get(decl) orelse .clean);
    }
    return out;
}

/// Whether a holder's type does not resolve, itself or behind pointers and optionals: std's own
/// and code the build does not compile are no program's struct.
fn unresolvedHolder(value: Facts.Value) bool {
    var current = value;
    while (true) current = switch (current) {
        .pointer, .optional, .error_union => |inner| inner.*,
        .unknown => |why| return why != .zig_own and why != .absent,
        else => return false,
    };
}

/// The program's own fields, by name, found once.
const FieldsNamed = struct {
    built: bool = false,
    map: std.StringHashMapUnmanaged(std.ArrayList(Facts.Decl)) = .empty,
};

/// The program's own fields named `name`: those a member of a holder whose type does not
/// resolve may be.
fn fieldsNamed(c: *Context, flow: *const Flow, name: []const u8) Context.Error![]const Facts.Decl {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(FieldsNamed);
    if (!memo.built) {
        memo.built = true;
        for (c.project.sources) |*each| {
            if (!flow.own(each.id)) continue;
            for (each.model.declarations, 0..) |record, d| {
                if (record.kind != .field) continue;
                const entry = try memo.map.getOrPut(c.allocator, record.name);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(c.allocator, .{ .file = each.id, .index = @fromBackingInt(@intCast(d)) });
            }
        }
    }
    return if (memo.map.get(name)) |found| found.items else &.{};
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
        const given = try dep(c, flow, function, arg);
        for ([_]struct { usize, Dep }{ .{ valueSlot(index), given }, .{ lengthSlot(index), given.measured() } }) |each| {
            const slot, const held_there = each;
            if (summary.params.has(slot)) out = try out.join(c.allocator, held_there);
            if (summary.numbers.has(slot)) out = try out.join(c.allocator, try held_there.widened(c.allocator));
            if (summary.ranged.has(slot)) out = try out.join(c.allocator, try held_there.narrowed(c.allocator));
            if (summary.maybe.has(slot)) out = try out.join(c.allocator, try held_there.lowered(c.allocator));
            if (summary.lengths.has(slot)) out = try out.join(c.allocator, try held_there.sizing(c.allocator));
            if (summary.bare.has(slot)) out = try out.join(c.allocator, try held_there.written(c.allocator));
            if (summary.ruled.has(slot)) out = try out.join(c.allocator, try held_there.ruling(c.allocator, flow.masks));
            if (summary.ruled_lengths.has(slot)) out = try out.join(c.allocator, try (try held_there.ruling(c.allocator, flow.masks)).sizing(c.allocator));
            if (summary.counted.has(slot)) out = try out.join(c.allocator, try held_there.counting(c.allocator, flow.masks));
            if (summary.counted_numbers.has(slot)) out = try out.join(c.allocator, try held_there.unbounded(c.allocator, flow.masks));
        }
    }
    return out;
}

/// What a function outside the program may make of an argument: what it holds, and its length,
/// which a search's position or a count is within (`std.mem.indexOfScalar(u8, buf[0..n], 0)`).
fn outsideArg(c: *Context, flow: *Flow, function: Function.Id, arg: Ast.Node.Index) Context.Error!Dep {
    const value = try whole(c, flow, function, arg);
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
            const lanes = try readLanes(c, flow, function, callee);
            const decl = callee.decl.?;
            // A read into the caller's buffer returns how much it read: a count the buffer
            // bounds, a peer's within it.
            if (!(try bufferParams(c, decl)).empty() and returnsCount(c, decl)) return .{ .level = .in(lanes, .data) };
            if (decodes(c, decl)) return .{ .level = .in(lanes, if (narrow(c, f.file, callee.params)) .data else .number) };
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
            if (callee.receiver == null and (!flow.data_files.contains(@backingInt(decl.file)) or decodes(c, decl))) return if (narrow(c, f.file, callee.params)) out else try out.widened(c.allocator);
            // A value clamped between the program's own bounds is held to them.
            if (std.mem.eql(u8, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].name, "clamp") and callee.params.len == 3) {
                if ((try dep(c, flow, function, callee.params[1])).clean() and (try dep(c, flow, function, callee.params[2])).clean()) return try out.narrowed(c.allocator);
            }
            return out;
        },
        .none => {
            var out: Dep = .{};
            for (callee.args) |arg| out = try out.join(c.allocator, try outsideArg(c, flow, function, arg));
            // What it gives may point into memory no place names.
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
fn decodes(c: *Context, decl: Facts.Decl) bool {
    const name = c.project.at(decl.file).model.declarations[@backingInt(decl.index)].name;
    for ([_][]const u8{ "readInt", "readVarInt", "readPackedInt", "parseInt", "parseUnsigned", "takeInt", "peekInt", "takeVarInt", "takeLeb128", "takeEnum" }) |decoder| {
        if (std.mem.startsWith(u8, name, decoder)) return true;
    }
    return false;
}

/// The level of `node` in its file as the fact reads it, or clean outside the functions it
/// reads.
pub fn levelAt(c: *Context, fact: Fact, file: Project.FileId, node: Ast.Node.Index) Context.Error!Level {
    const function = owner(fact.flow, file, node) orelse return .clean;
    return concrete(fact.flow, function, try dep(c, fact.flow, function, node)).at(fact.lane);
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
        out = try (try out.join(c.allocator, try dep(c, flow, function, init))).join(c.allocator, try control(c, flow, function, decl.node, null));
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
    if (tree.nodeTag(node) != .identifier) return false;
    const ref = model.reference(node) orelse return false;
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
    switch (tree.nodeTag(node)) {
        .less_than, .less_or_equal, .greater_than, .greater_or_equal, .equal_equal, .bang_equal, .bool_and, .bool_or => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return (try conditionAt(c, fact, file, lhs)).join(try conditionAt(c, fact, file, rhs));
        },
        .bool_not, .grouped_expression => return conditionAt(c, fact, file, if (tree.nodeTag(node) == .bool_not) tree.nodeData(node).node else tree.nodeData(node).node_and_token[0]),
        else => return levelAt(c, fact, file, node),
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
    switch (tree.nodeTag(type_node)) {
        .optional_type => return treeValue(c, flow, file, tree.nodeData(type_node).node),
        .error_union => return treeValue(c, flow, file, tree.nodeData(type_node).node_and_node[1]),
        .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => return treeValue(c, flow, file, tree.fullPtrType(type_node).?.ast.child_type),
        .identifier, .field_access => {
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
        if (tree.nodeTag(node) == .field_access) if ((try w.c.facts.definition(f.file, node)).orNull()) |decl| {
            if ((w.flow.globals.get(decl) orelse Levels.clean).at(w.lane) != .clean) if (try w.stored(decl, depth)) |found| return found;
        };
        // Memory's length holds what was written to it (`s.len = n`), where its contents carry
        // nothing: the receiver is walked back for the write, whatever it carries itself.
        if (tree.nodeTag(node) == .field_access and std.mem.eql(u8, tree.tokenSlice(tree.lastToken(node)), "len") and try w.c.facts.memoryField(f.file, node) == .memory) {
            if (try w.from(function, tree.nodeData(node).node_and_token[0], depth + 1)) |found| return found;
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
            if (tree.nodeTag(node) == .assign) {
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
        var files: std.ArrayList(Project.FileId) = .empty;
        var each = w.flow.owners.keyIterator();
        while (each.next()) |file| try files.append(w.c.allocator, file.*);
        for (try Facts.accesses.writes(w.c.facts, place, files.items)) |site| {
            const function = owner(w.flow, site.file, site.node) orelse continue;
            switch (site.kind) {
                .init, .set, .update => {
                    const value = site.value orelse writtenFrom(&w.c.project.at(site.file).file.tree, site.node) orelse continue;
                    if (!try w.carries(function, value)) continue;
                    if (try w.from(function, value, depth + 1)) |found| return found;
                },
                .address, .covered => if (try w.sourceArgument(site.file, site.node)) |call| if (w.read(site.file, call)) |found| return found,
                .read => {},
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
        return switch (tree.nodeTag(node)) {
            .assign => tree.nodeData(node).node_and_node[1],
            .assign_destructure => tree.assignDestructure(node).ast.value_expr,
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
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
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
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(CallSites);
    if (memo.built) return memo;
    memo.built = true;
    var files = flow.owners.iterator();
    while (files.next()) |entry| {
        const file = entry.key_ptr.*;
        for (entry.value_ptr.*, 0..) |own, i| {
            const caller = own orelse continue;
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
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
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
            .param => |index| if (!f.returned.has(index)) {
                f.returned = try f.returned.with(c.allocator, index);
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
            var literal_buffer: [2]Ast.Node.Index = undefined;
            if (try resolveCall(c, flow, f.file, parent)) |callee| {
                if (callee.callee_expr == node) return false;
                switch (callee.kind) {
                    // The program's callee keeps what it is given where its own links say: in
                    // its callers' memory (`writes`), or in what it returns (`returned`).
                    .program => return false,
                    // A function outside the program may keep a pointer in what it returns
                    // and in the other memory it is given (`map.put(gpa, &key, v)`).
                    .outside, .source, .aegis, .holder => {
                        for (callee.args) |arg| if (arg != node and try pointing(c, f.file, arg)) try places(c, flow, function, arg, &holders);
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
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
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
            .global => |decl| .{ .level = flow.globals.get(decl) orelse .clean, .unchecked = flow.lengths.get(decl) orelse .clean },
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
    for (fields) |field| out = try out.join(c.allocator, .{ .level = flow.globals.get(field) orelse .clean, .unchecked = flow.lengths.get(field) orelse .clean });
    return out;
}

/// The fields a value of a type holds, through its fields' types in turn, found once per type;
/// null where the type does not resolve.
const Wholes = struct { map: std.AutoHashMapUnmanaged(Facts.Container, []const Facts.Decl) = .empty };

pub fn wholeFields(c: *Context, value: Facts.Value) Context.Error!?[]const Facts.Decl {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
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
    while (true) root = switch (tree.nodeTag(root)) {
        .field_access, .unwrap_optional, .grouped_expression => tree.nodeData(root).node_and_token[0],
        .array_access => tree.nodeData(root).node_and_node[0],
        else => break,
    };
    if (tree.nodeTag(root) != .identifier) return null;
    const d = (model.reference(root) orelse return null).declaration orelse return null;
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

/// How a `while`'s counters step: the locals its condition `condition` reads that the loop
/// assigns. `sum` where one steps by a sum (`i += 1`, `i = i + 2`): the loop counts against
/// what it is compared with; `factor` where every one steps by a product, a quotient or a
/// shift (`a /= 10`): it passes as often as the type has digits; `other` otherwise, or with
/// none: nothing counts its passes.
fn stepsOf(c: *Context, flow: *Flow, function: Function.Id, loop: Ast.Node.Index, condition: Ast.Node.Index) Context.Error!enum { sum, factor, other } {
    const f = flow.functions.items[@backingInt(function)];
    const tree = &c.project.at(f.file).file.tree;
    const model = &c.project.at(f.file).model;
    var counters: std.ArrayList(Model.Declaration.Id) = .empty;
    const cond_first = tree.firstToken(condition);
    const cond_last = tree.lastToken(condition);
    for (f.nodes) |node| {
        if (tree.nodeTag(node) != .identifier) continue;
        const at = tree.nodeMainToken(node);
        if (at < cond_first or at > cond_last) continue;
        const d = localOf(model, node) orelse continue;
        if (std.mem.findScalar(Model.Declaration.Id, counters.items, d) == null) try counters.append(c.allocator, d);
    }
    var sum = false;
    var factor = false;
    var other = false;
    const first = tree.firstToken(loop);
    const last = tree.lastToken(loop);
    for (f.nodes) |node| {
        const at = tree.nodeMainToken(node);
        if (at < first or at > last) continue;
        const tag = tree.nodeTag(node);
        for (counters.items) |d| {
            const step: enum { none, sum, factor, other } = switch (tag) {
                .assign_add, .assign_sub, .assign_add_wrap, .assign_sub_wrap, .assign_add_sat, .assign_sub_sat => .sum,
                .assign_mul, .assign_div, .assign_shl, .assign_shr, .assign_mul_wrap, .assign_mul_sat, .assign_shl_sat => .factor,
                .assign => assigned: {
                    const value = tree.nodeData(node).node_and_node[1];
                    if (stepOf(tree, model, d, tag, value) != value) break :assigned .sum;
                    break :assigned if (scaled(tree, model, d, value)) .factor else .other;
                },
                .assign_mod, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_destructure => .other,
                else => .none,
            };
            if (step == .none) continue;
            const names = if (tag == .assign_destructure) destructures(tree, model, node, d) else namesDeclaration(tree, model, tree.nodeData(node).node_and_node[0], d);
            if (!names) continue;
            switch (step) {
                .sum => sum = true,
                .factor => factor = true,
                else => other = true,
            }
        }
    }
    if (sum) return .sum;
    if (factor and !other) return .factor;
    return .other;
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
        switch (tree.nodeTag(parent)) {
            .fn_decl => break,
            // A statement before it that may jump past it (`leaves`) decides whether it runs.
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                var buffer: [2]Ast.Node.Index = undefined;
                for (tree.blockStatements(&buffer, parent) orelse &.{}) |statement| {
                    if (statement == at) break;
                    out = try out.join(c.allocator, try leaves(c, flow, function, statement, bound));
                }
            },
            // A deferred write runs on whichever exit is taken: what decides each exit after it
            // decides what it reads.
            .@"defer", .@"errdefer" => out = try out.join(c.allocator, try exitsAfter(c, flow, function, parent)),
            // The right side of `and` and `or` runs as the left decides.
            .bool_and, .bool_or => {
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                if (at == rhs) out = try out.join(c.allocator, try (try dep(c, flow, function, lhs)).held().narrowed(c.allocator));
            },
            .@"if", .if_simple => {
                const branch = tree.fullIf(parent).?; // unreachable: the tag is an if's
                if (at != branch.ast.cond_expr) out = try out.join(c.allocator, try (try dep(c, flow, function, branch.ast.cond_expr)).held().narrowed(c.allocator));
            },
            .@"switch", .switch_comma => {
                const choice = tree.fullSwitch(parent).?; // unreachable: the tag is a switch's
                if (at != choice.ast.condition) out = try out.join(c.allocator, try (try dep(c, flow, function, choice.ast.condition)).held().narrowed(c.allocator));
                // A labeled switch is a loop: `continue :label value` dispatches again.
                if (choice.label_token != null) out = try out.join(c.allocator, try passes(c, flow, function, parent));
            },
            .@"catch", .@"orelse" => {
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                if (at == rhs) out = try out.join(c.allocator, try (try dep(c, flow, function, lhs)).held().narrowed(c.allocator));
            },
            .@"while", .while_simple, .while_cont, .@"for", .for_simple => out = try out.join(c.allocator, try passes(c, flow, function, parent)),
            else => {},
        }
    }
    return out;
}

/// What decides how many passes a loop takes, and so how far what it steps goes: its
/// condition's operands or its inputs' bounds and lengths, and every condition inside it, any
/// of which may end a pass or the loop. Read once per round.
fn passes(c: *Context, flow: *Flow, function: Function.Id, loop: Ast.Node.Index) Context.Error!Dep {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
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
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
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
        if (owners[@backingInt(node)] != function) continue;
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
    switch (tree.nodeTag(condition)) {
        .grouped_expression => return operands(c, flow, function, tree.nodeData(condition).node_and_token[0]),
        .bool_not => return operands(c, flow, function, tree.nodeData(condition).node),
        .bool_and, .bool_or, .less_than, .less_or_equal, .greater_than, .greater_or_equal, .equal_equal, .bang_equal => {
            const lhs, const rhs = tree.nodeData(condition).node_and_node;
            return try (try operands(c, flow, function, lhs)).join(c.allocator, try operands(c, flow, function, rhs));
        },
        else => return (try dep(c, flow, function, condition)).held(),
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
    callee: ?Facts.Decl,
    /// The parameter, the receiver first.
    position: usize,
    length: bool = false,
    /// The sink takes the value only kept to a range or as a comparison decides: a peer's
    /// number is data there.
    narrowed: bool = false,
    decided: bool = true,
};

/// The sites of the sinks `fact`'s spec judges in `file` (`Spec.sinks`), read once per run.
/// `size`: what the program hands a function outside it that sizes memory or work by it, found
/// by meaning: what its body gives an allocation (std's `Allocator.rawAlloc`, `rawResize`,
/// `rawRemap`) or counts a loop's passes by, through every call it makes.
pub fn sinkSites(c: *Context, fact: Fact, file: Project.FileId) Context.Error![]const SinkSite {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    if (!fact.spec.sinks.size) return &.{};
    const flow = fact.flow;
    if (flow.size_sites.get(file)) |known_sites| return known_sites;
    // Only a call given what the fact follows is read: a clean argument is no site a rule
    // judges, and the summary reads no body for it.
    var given: std.ArrayList(Callee) = .empty;
    if (flow.owners.get(file)) |owners| for (owners, 0..) |own, i| {
        if (own == null) continue;
        const callee = (try resolveCall(c, flow, file, @fromBackingInt(@intCast(i)))) orelse continue;
        if (try carries(c, fact, file, callee)) try given.append(c.allocator, callee);
    };
    const sized = try sizesFlow(c, flow, given.items);
    var out: std.ArrayList(SinkSite) = .empty;
    for (given.items) |callee| try sizeSites(c, sized, file, callee, &out);
    const sites = try out.toOwnedSlice(c.allocator);
    try flow.size_sites.put(c.allocator, file, sites);
    return sites;
}

/// Whether a call outside the program is given a value, or memory whose length, the fact
/// reaches its sinks with (`Spec.reaches`), or may.
fn carries(c: *Context, fact: Fact, file: Project.FileId, callee: Callee) Context.Error!bool {
    switch (callee.kind) {
        .program, .aegis, .holder => return false,
        .choice => |each| {
            for (each) |one| if (try carries(c, fact, file, one)) return true;
            return false;
        },
        .none, .source, .outside => {},
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

/// The sizes a call of the program gives a function outside it: each argument whose value or
/// length the callee's body sizes work by. The program's own callee is read at its own calls;
/// aegis is the limit itself.
fn sizeSites(c: *Context, sized: *Flow, file: Project.FileId, callee: Callee, out: *std.ArrayList(SinkSite)) Context.Error!void {
    switch (callee.kind) {
        .program, .aegis, .holder => return,
        .choice => |each| {
            for (each) |one| try sizeSites(c, sized, file, one, out);
            return;
        },
        .none, .source, .outside => {},
    }
    const summary = try sizesOf(c, sized, callee.decl);
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
            try out.append(c.allocator, .{ .file = file, .value = arg, .at = callee.node, .callee = callee.decl, .position = position, .length = length, .narrowed = !sure and ranged, .decided = sure or ranged });
        }
    }
}

/// What a function outside the program sizes by, by slot: an allocation every argument but the
/// allocator; another what its body sizes by as the summary reads it; one with no body read,
/// or none at all, anything, undecided.
fn sizesOf(c: *Context, sized: *Flow, decl: ?Facts.Decl) Context.Error!union(enum) { read: struct { sure: Slots, ranged: Slots, maybe: Slots, fixed: Slots }, allocation, unknown } {
    const d = decl orelse return .unknown;
    if (!sized.allocations_known) return .unknown;
    switch (try allocation(c, sized, d)) {
        .yes => return .allocation,
        .no => {},
        .unknown => return .unknown,
    }
    const node = fnDecl(c, d) orelse return .unknown;
    const id = sized.by_node.get(.{ .file = d.file, .node = node }) orelse return .unknown;
    const f = sized.functions.items[@backingInt(id)];
    return .{ .read = .{ .sure = f.sizes, .ranged = f.ranged_sizes, .maybe = f.maybe_sizes, .fixed = f.fixed } };
}

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
/// calls, what each body sizes work by. A function read is closed under its calls, so one read
/// for an earlier call is not changed by a later one.
fn sizesFlow(c: *Context, main: *Flow, calls: []const Callee) Context.Error!*Flow {
    const flow = main.sized orelse made: {
        const made = try c.allocator.create(Flow);
        made.* = .{};
        main.sized = made;
        made.program = main.program;
        try known(c, made);
        break :made made;
    };
    var next: std.ArrayList(Function.Id) = .empty;
    for (calls) |callee| {
        const one = [1]Callee{callee};
        for (if (callee.kind == .choice) callee.kind.choice else &one) |each| switch (each.kind) {
            .source, .outside => try reach(c, flow, each.decl.?, &next),
            else => {},
        };
    }
    if (next.items.len == 0) return flow;
    while (next.pop()) |id| {
        const f = flow.functions.items[@backingInt(id)];
        for (f.nodes) |node| {
            const call = (try Facts.calls.at(c.facts, f.file, node)) orelse continue;
            switch (call.callee) {
                .function => |decl| try reach(c, flow, decl, &next),
                .choice => |decls| for (decls) |decl| try reach(c, flow, decl, &next),
                .any => {},
            }
        }
    }
    try linksOf(c, flow);
    while (true) {
        flow.changed = false;
        flow.loops.clearRetainingCapacity();
        flow.leaving.clearRetainingCapacity();
        for (flow.functions.items, 0..) |_, i| {
            try bindings(c, flow, @fromBackingInt(@intCast(i)));
            try sizing(c, flow, @fromBackingInt(@intCast(i)));
        }
        try takeHeld(c, flow);
        if (!flow.changed) break;
    }
    return flow;
}

/// Adds the function `decl` declares to a summary, its nodes owned, unless it is an
/// allocation (a sink itself), aegis's (the limit), the program's own, already read, or has
/// no body.
fn reach(c: *Context, flow: *Flow, decl: Facts.Decl, next: *std.ArrayList(Function.Id)) Context.Error!void {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    // An allocation is a sink itself; one whose alias does not resolve has no body read.
    if (try allocation(c, flow, decl) != .no) return;
    if (flow.program.aegis_files.contains(@backingInt(decl.file))) return;
    if (flow.own(decl.file)) return;
    const node = fnDecl(c, decl) orelse return;
    if (flow.by_node.contains(.{ .file = decl.file, .node = node })) return;
    const id = (try addFunction(c, flow, decl.file, node)) orelse return;
    const tree = &c.project.at(decl.file).file.tree;
    const entry = try flow.owners.getOrPut(c.allocator, decl.file);
    if (!entry.found_existing) {
        const owners = try c.allocator.alloc(?Function.Id, tree.nodes.len);
        @memset(owners, null);
        entry.value_ptr.* = owners;
    }
    const nodes = (try bodies(c, flow, decl.file)).get(node) orelse &.{};
    for (nodes) |at| entry.value_ptr.*[@backingInt(at)] = id;
    flow.functions.items[@backingInt(id)].nodes = nodes;
    try next.append(c.allocator, id);
}

/// Each `fn_decl` of a file a summary reads, by its node, with the nodes its body holds outside
/// any function nested in it: grouped once per file, however many of its functions are read.
fn bodies(c: *Context, flow: *Flow, file: Project.FileId) Context.Error!*const std.AutoHashMapUnmanaged(Ast.Node.Index, []const Ast.Node.Index) {
    // What it keeps in the run's solve stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const entry = try flow.bodies.getOrPut(c.allocator, file);
    if (entry.found_existing) return entry.value_ptr;
    var grouped: std.AutoHashMapUnmanaged(Ast.Node.Index, std.ArrayList(Ast.Node.Index)) = .empty;
    const tree = &c.project.at(file).file.tree;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const function = enclosing(c, file, node) orelse continue;
        const group = try grouped.getOrPut(c.allocator, function);
        if (!group.found_existing) group.value_ptr.* = .empty;
        try group.value_ptr.append(c.allocator, node);
        flow.walked += 1;
    }
    var out: std.AutoHashMapUnmanaged(Ast.Node.Index, []const Ast.Node.Index) = .empty;
    var each = grouped.iterator();
    while (each.next()) |group| try out.put(c.allocator, group.key_ptr.*, try group.value_ptr.toOwnedSlice(c.allocator));
    entry.value_ptr.* = out;
    return entry.value_ptr;
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
        flow.functions.items[@backingInt(function)].sizes = sizes.sure;
        flow.functions.items[@backingInt(function)].ranged_sizes = sizes.ranged;
        flow.functions.items[@backingInt(function)].maybe_sizes = sizes.maybe;
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
        .aegis, .holder => {},
        .choice => |each| for (each) |one| try sizedBy(c, flow, function, one, sizes),
        .program => |target| {
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
                    } else if (ranged) {
                        try sizes.addRanged(c.allocator, given);
                    } else try sizes.addMaybe(c.allocator, given);
                }
            }
        },
        .source, .outside, .none => {
            const allocates: Allocation = if (callee.decl) |d| try allocation(c, flow, d) else .unknown;
            for (callee.args, 0..) |arg, position| {
                // An allocation's first parameter is the allocator itself.
                if (allocates == .yes and position == 0) continue;
                const given = try whole(c, flow, function, arg);
                if (allocates == .yes and flow.allocations_known) {
                    try sizes.add(c.allocator, given);
                } else try sizes.addMaybe(c.allocator, given);
            }
        },
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

/// The local variable an identifier names.
fn localOf(model: *const Model, node: Ast.Node.Index) ?Model.Declaration.Id {
    const d = (model.reference(node) orelse return null).declaration orelse return null;
    const decl = model.declarations[@backingInt(d)];
    if (decl.kind != .variable) return null;
    return switch (model.scopes[@backingInt(decl.scope)].kind) {
        .file, .container => null,
        else => d,
    };
}

/// Whether `value` takes the counter `d` by a factor: a product, a quotient or a shift of it
/// (`a * 2`, `@divTrunc(a, 10)`, `n >> 1`).
fn scaled(tree: *const Ast, model: *const Model, d: Model.Declaration.Id, value: Ast.Node.Index) bool {
    switch (tree.nodeTag(value)) {
        .mul, .mul_wrap, .mul_sat, .div, .shl, .shl_sat, .shr => {
            const lhs, const rhs = tree.nodeData(value).node_and_node;
            return namesDeclaration(tree, model, lhs, d) or namesDeclaration(tree, model, rhs, d);
        },
        .builtin_call_two, .builtin_call_two_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(value));
            for ([_][]const u8{ "@divTrunc", "@divFloor", "@divExact", "@shrExact", "@shlExact" }) |each| if (std.mem.eql(u8, name, each)) {
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, value, &buffer);
                return args.len > 0 and namesDeclaration(tree, model, args[0], d);
            };
            return false;
        },
        else => return false,
    }
}

/// Whether a destructure assigns the declaration `d` among its variables.
fn destructures(tree: *const Ast, model: *const Model, node: Ast.Node.Index, d: Model.Declaration.Id) bool {
    for (tree.assignDestructure(node).ast.variables) |variable| if (namesDeclaration(tree, model, variable, d)) return true;
    return false;
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
    // Each site as `callee position value|length sure|maybe`, in order.
    var seen: std.ArrayList(u8) = .empty;
    for (try sinkSites(&c, fact, project.sources[0].id)) |site| {
        const name = if (site.callee) |d| project.at(d.file).model.declarations[@backingInt(d.index)].name else "?";
        try seen.print(arena.allocator(), "{s} {d} {s} {s} {s}\n", .{ name, site.position, tree.getNodeSource(site.value), if (site.length) "length" else "value", if (site.decided) "sure" else "maybe" });
    }
    try std.testing.expectEqualStrings(
        \\alloc 2 n value sure
        \\repeat 1 n value sure
        \\sum 0 bytes length sure
        \\? 0 n value maybe
        \\? 0 n length maybe
        \\
    , seen.items);
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
    try std.testing.expect(sites[0].decided and !sites[0].length and sites[0].position == 1);
    const sized = fact.flow.sized.?;
    try std.testing.expectEqual(64, sized.functions.items.len);
    // One pass over the file's nodes, not one per function reached (64 here).
    try std.testing.expect(sized.walked > 0 and sized.walked <= project.at(project.sources[2].id).file.tree.nodes.len);
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
