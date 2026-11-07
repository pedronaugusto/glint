//! A019's `undefined` reads (designs/aegis.md §7): a `var` declared `undefined` in a function's
//! body, read, or handed on, before every path to that point writes the whole of it.
//!
//! What writes it whole: an assignment to it; an `asm` output bound to it, written once the
//! `asm` has read its inputs; all of it given to `@memset` or `@memcpy`, to a `for` whose first
//! act each pass is to set the element it points at, to one of std's calls named in `std_fills`
//! (`Io.Reader.readSliceAll`), or to the program's own function whose body writes the whole of
//! that parameter before any read on every path that returns. A call that may fail writes only
//! where its failure leaves (`try`). What a part of it takes (a slice of it filled) writes that
//! part only, and what std's calls named in `std_keeps` are given (a writer's buffer) they keep
//! without reading what they have not written: neither writes it whole, and neither reads it.
//! Handed anywhere else (a call nothing shows writing it whole, a pointer kept in a local) it
//! is read there.
//!
//! Its parts, where it is a struct of 64 fields at most or an array of a literal length up to
//! 64: a field set (`x.a = v`, `@field(x, "a") = v`) or an element by a literal index (`x[0] =
//! v`) is written, and reading it reads nothing undefined; every part written on every path
//! writes it whole, as does an `inline for` over its own type's fields that sets the field each
//! pass is on from what does not read it, with nothing skipping a pass. A field used in place
//! (its address, a method on it) reaches the local itself where some `@fieldParentPtr` in the
//! project may give the local's struct from a field of that name. Handed to the program's
//! function through a pointer to its type, it is read as the parts that function may read
//! before writing them, where every use of the pointer there is a part's or another such
//! function's.
//!
//! A branch that writes it on some paths only, a write in a part of an expression that runs on
//! some paths only, and a loop that may run no pass, leave it unwritten for what follows; a
//! branch that leaves (`return`, `unreachable`) reaches nothing after it, a `break` or
//! `continue` reaches the end of where it goes with what it holds, and a `for` over a range or
//! memory of a known length above zero runs at least once. A deferred statement runs where its
//! block is left after it: at its end, at a `return` or a failing `try` (an `errdefer` there
//! only), at a jump out of it; it reads the local as it is there, and what it writes holds past.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Governed = @import("Governed.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Danger = @import("Danger.zig");
const ParentPointer = @import("ParentPointer.zig");
const CContract = @import("CContract.zig");
const Program = @import("Program.zig");
const Range = @import("Range.zig");
const Rule = @import("Rule.zig").Rule;
const Ast = std.zig.Ast;

/// std's calls that write the whole of the memory they are given at a parameter (the receiver
/// first), or fail.
const std_fills = [_]Named{
    .{ .path = "Io.Reader.readSliceAll", .param = 1 },
    .{ .path = "Io.random", .param = 1 },
    // A hash's one-shot form and its `final` write the whole `*[digest_length]u8` out; each
    // name stands for the generic it is made by (Sha256 for every Sha2x32, Sha512 for Sha2x64).
    .{ .path = "crypto.hash.sha2.Sha256.hash", .param = 1 },
    .{ .path = "crypto.hash.sha2.Sha256.final", .param = 1 },
    .{ .path = "crypto.hash.sha2.Sha512.hash", .param = 1 },
    .{ .path = "crypto.hash.sha2.Sha512.final", .param = 1 },
    .{ .path = "crypto.hash.Sha1.hash", .param = 1 },
    .{ .path = "crypto.hash.Sha1.final", .param = 1 },
    .{ .path = "crypto.hash.Md5.hash", .param = 1 },
    .{ .path = "crypto.hash.Md5.final", .param = 1 },
    .{ .path = "crypto.hash.blake2.Blake2s256.hash", .param = 1 },
    .{ .path = "crypto.hash.blake2.Blake2s256.final", .param = 1 },
    .{ .path = "crypto.hash.blake2.Blake2b512.hash", .param = 1 },
    .{ .path = "crypto.hash.blake2.Blake2b512.final", .param = 1 },
    .{ .path = "crypto.hash.sha3.Sha3_256.hash", .param = 1 },
    .{ .path = "crypto.hash.sha3.Sha3_256.final", .param = 1 },
    // An HMAC's `final` and its one-shot `create` write the whole `*[mac_length]u8` out; the
    // name stands for the `Hmac` generic every hash's is made by.
    .{ .path = "crypto.auth.hmac.sha2.HmacSha256.final", .param = 1 },
    .{ .path = "crypto.auth.hmac.sha2.HmacSha256.create", .param = 0 },
    .{ .path = "mem.writeInt", .param = 1 },
    // A generator's bytes, every one of the buffer.
    .{ .path = "Random.ChaCha.fill", .param = 1 },
    .{ .path = "Random.bytes", .param = 1 },
    .{ .path = "crypto.secureZero", .param = 1 },
    // Each operation of the batch, then the last one's link.
    .{ .path = "Io.Batch.init", .param = 0 },
    // `mr.* = .{ … }`, after the streams' contexts.
    .{ .path = "Io.File.MultiReader.init", .param = 0 },
};

/// std's calls that write a prefix of the memory they are given at a parameter and return its
/// length: they keep it, and `buf[0..n]` with that count reads what they wrote. A vector names
/// each buffer it holds.
const std_counts = [_]Named{
    .{ .path = "Io.File.readStreaming", .param = 2 },
    .{ .path = "Io.File.readPositional", .param = 2 },
    .{ .path = "Io.Dir.readLink", .param = 3 },
    .{ .path = "Io.Reader.readSliceShort", .param = 1 },
    .{ .path = "fmt.printInt", .param = 0 },
};

/// std's calls that keep the memory they are given at a parameter as storage, or write a part
/// of it, and read only what they have written there.
const std_keeps = [_]Named{
    .{ .path = "Io.Writer.fixed", .param = 0 },
    .{ .path = "Io.File.reader", .param = 2 },
    .{ .path = "Io.File.readerStreaming", .param = 2 },
    .{ .path = "Io.File.writer", .param = 2 },
    .{ .path = "Io.File.writerStreaming", .param = 2 },
    .{ .path = "Io.net.Stream.reader", .param = 2 },
    .{ .path = "Io.net.Stream.writer", .param = 2 },
    .{ .path = "heap.FixedBufferAllocator.init", .param = 0 },
    .{ .path = "heap.BufferFirstAllocator.init", .param = 0 },
    .{ .path = "fmt.bufPrint", .param = 0 },
    .{ .path = "fmt.bufPrintSentinel", .param = 0 },
    .{ .path = "mem.print", .param = 0 },
    .{ .path = "mem.printSentinel", .param = 0 },
    .{ .path = "zig.Ast.fullFnProto", .param = 1 },
    .{ .path = "zig.Ast.fullStructInit", .param = 1 },
    .{ .path = "zig.Ast.fullArrayInit", .param = 1 },
    .{ .path = "zig.Ast.fullContainerDecl", .param = 1 },
    .{ .path = "zig.Ast.fullCall", .param = 1 },
    .{ .path = "zig.Ast.builtinCallParams", .param = 1 },
    .{ .path = "zig.Ast.blockStatements", .param = 1 },
    // A queue's ring: a get takes only what a put wrote.
    .{ .path = "Io.Queue.init", .param = 0 },
    .{ .path = "Io.Select.init", .param = 1 },
    // A limited reader's buffer, its end and seek at 0.
    .{ .path = "Io.Reader.limited", .param = 2 },
    // A writer's or a reader's buffer, its end and seek at 0.
    .{ .path = "debug.lockStderr", .param = 0 },
    .{ .path = "compress.flate.Decompress.init", .param = 2 },
    // The file's bytes into a prefix, returned as the slice they fill.
    .{ .path = "Io.Dir.readFile", .param = 3 },
    // A prefix as long as the input, returned as the slice it fills.
    .{ .path = "ascii.lowerString", .param = 0 },
    .{ .path = "ascii.upperString", .param = 0 },
    .{ .path = "base64.Base64Encoder.encode", .param = 1 },
    // As many bytes as the source decodes to, which the caller sized `dest` by.
    .{ .path = "base64.Base64Decoder.decode", .param = 1 },
    // The streams' length set, their contexts and storage for MultiReader.init to write.
    .{ .path = "Io.File.MultiReader.Buffer.toStreams", .param = 0 },
};

const Named = struct { path: []const u8, param: usize };

/// Of `std_keeps`, those whose result holds the memory: a writer, a reader, an allocator, a
/// queue. What it holds is kept only while nothing hands it back unwritten (`holderKept`).
const std_holders = [_]Named{
    .{ .path = "Io.Writer.fixed", .param = 0 },
    .{ .path = "Io.File.reader", .param = 2 },
    .{ .path = "Io.File.readerStreaming", .param = 2 },
    .{ .path = "Io.File.writer", .param = 2 },
    .{ .path = "Io.File.writerStreaming", .param = 2 },
    .{ .path = "Io.net.Stream.reader", .param = 2 },
    .{ .path = "Io.net.Stream.writer", .param = 2 },
    .{ .path = "heap.FixedBufferAllocator.init", .param = 0 },
    .{ .path = "heap.BufferFirstAllocator.init", .param = 0 },
    .{ .path = "Io.Queue.init", .param = 0 },
    .{ .path = "Io.Select.init", .param = 1 },
    .{ .path = "Io.Reader.limited", .param = 2 },
    .{ .path = "debug.lockStderr", .param = 0 },
    .{ .path = "compress.flate.Decompress.init", .param = 2 },
    .{ .path = "Io.File.MultiReader.Buffer.toStreams", .param = 0 },
};

/// std's functions that hand back a writer's or a reader's memory past what it holds: its room,
/// to be written.
const std_room = [_][]const u8{
    "Io.Writer.unusedCapacitySlice",
    "Io.Writer.writableArray",
    "Io.Writer.writableSlice",
    "Io.Writer.writableSliceGreedy",
    "Io.Writer.writableSliceGreedyPreserve",
    "Io.Writer.writableSlicePreserve",
    "Io.Reader.writableVector",
    "Io.Reader.writableVectorPosix",
    "Io.Reader.writableVectorWsa",
};

/// std's calls that, succeeding, write the memory at `param` from the front for half the length
/// of their input at `input`, and read none of it: all of it where that input is twice its
/// length.
const std_halving = [_]struct { path: []const u8, param: usize, input: usize }{
    // Two hex digits a byte; odd input fails, and out.len * 2 < input.len does too.
    .{ .path = "fmt.hexToBytes", .param = 0, .input = 1 },
};

/// How deep the program's callees are read, each handing the memory to the next.
const depth_limit = 8;
/// How deep one reading of `undefines` follows what a function hands its parameter to before
/// it takes a function at what it is assumed to leave, read from the top after (`readDeferred`).
const undefines_depth_limit = 16;
/// How many times a call is asked again while those assumptions grow; one still growing after
/// leaves the call undecided.
const undefines_rounds = 32;

/// `follows`: whether another rule follows a local from its acquisition through its cleanup
/// (A003), and reads a use of it after a call that gives it `undefined` in this one's place.
pub fn reads(c: *Context, rule: Rule, follows: *const fn (*Context, Model.Declaration) Context.Error!bool) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    // The mentions that give a call a local, or a part of it, as its receiver or by address:
    // where a call may give it `undefined` (a `deinit`), read as each local is.
    // A local's alias (`const p = &x`) hands it as a pointer does, as it is (`f(p)`).
    var handed: std.AutoHashMapUnmanaged(Model.Declaration.Id, std.ArrayList(Ast.Node.Index)) = .empty;
    var pointing: std.AutoHashMapUnmanaged(Model.Declaration.Id, std.ArrayList(Ast.Node.Index)) = .empty;
    for (model.references) |ref| {
        const node = ref.node;
        const id = (try nameOf(c.facts, c.file, node)) orelse continue;
        if (model.declarations[@backingInt(id)].kind != .variable) continue;
        for ([_]bool{ false, true }, [_]*@TypeOf(handed){ &handed, &pointing }) |pointer, map| {
            if (try handedPlace(c.facts, c.file, node, pointer) == null) continue;
            const entry = try map.getOrPutValue(c.allocator, id, .empty);
            try entry.value_ptr.append(c.allocator, node);
        }
    }
    for (model.declarations, 0..) |decl, d| {
        if (decl.kind != .variable or c.inTest(decl.token)) continue;
        const variable = tree.fullVarDecl(decl.node) orelse continue;
        if (tree.tokenTag(variable.ast.mut_token) != .keyword_var) continue;
        const init = variable.ast.init_node.unwrap() orelse continue;
        if (!Danger.atRuntime(c, decl.node)) continue;
        // An array of no elements has no memory to leave undefined.
        if (variable.ast.type_node.unwrap()) |kind| if (try c.facts.arrayType(c.file, kind)) |array_type| if (array_type.length) |length| if ((try Range.constantValue(c, array_type.file, length)) == 0) continue;
        const block = model.parentOf(decl.node) orelse continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, block) orelse continue;
        const start = std.mem.findScalar(Ast.Node.Index, statements, decl.node) orelse continue;
        // Undefined where it is declared so, in whole or in part, or where it is given
        // `undefined` again.
        const declared = try holdsUndefined(c.facts, c.file, init);
        const local: Model.Declaration.Id = @fromBackingInt(@intCast(d));
        var given: std.ArrayList(Ast.Node.Index) = .empty;
        if (handed.get(local)) |list| try given.appendSlice(c.allocator, list.items);
        for (try aliasesOf(c.allocator, c.facts, c.file, local, false)) |alias| if (pointing.get(alias)) |list| try given.appendSlice(c.allocator, list.items);
        const calls = given.items;
        if (!declared and !spellsUndefined(tree, block) and calls.len == 0) continue;
        var walk: Walk = .init(c, c.file, local, false, 0);
        try walk.collect();
        var found: ?Ast.TokenIndex = null;
        if (declared) {
            _ = try walk.sequence(block, statements[start + 1 ..], .{ .at = .unwritten, .parts = walk.everyPart() & ~try walk.undefinedIn(init) });
            if (walk.read) |token| {
                found = token;
                try c.at(rule, token, if (walk.handed)
                    try c.allocator.print("'{s}' is handed on here while still undefined on a path from its declaration, where nothing shows it written whole before it is read: a read of undefined memory, which no build checks; write it whole first, or keep a filled prefix in aegis bounded.Array", .{decl.name})
                else
                    try c.allocator.print("'{s}' is read here while still undefined on a path from its declaration: a read of undefined memory, which no build checks", .{decl.name}));
            }
        }
        for (try walk.undefinings()) |again| {
            var from: Walk = .init(c, c.file, local, false, 0);
            try from.collect();
            _ = try from.onFrom(again.mention, again.left, block);
            const token = from.read orelse continue;
            if (found == token) continue;
            found = token;
            const line = tree.tokenLocation(0, tree.nodeMainToken(again.mention)).line + 1;
            try c.at(rule, token, if (from.handed)
                try c.allocator.print("'{s}' is handed on here while undefined again on a path from line {d}, which gives it `undefined`, where nothing shows it written whole since: a read of undefined memory, which no build checks", .{ decl.name, line })
            else
                try c.allocator.print("'{s}' is read here while undefined again on a path from line {d}, which gives it `undefined`: a read of undefined memory, which no build checks", .{ decl.name, line }));
        }
        // A call that gives it `undefined` (`x.deinit(gpa)`): undefined from there until it is
        // written whole again. A local A003 follows from its acquisition is A003's to read
        // after its cleanup.
        if (calls.len != 0 and try follows(c, decl)) continue;
        for (calls) |call| {
            const memo = try c.facts.memo(Calls);
            var cuts = memo.cuts;
            walk.unknown = false;
            var left = try walk.undoneBy(call);
            // A reading cut at the depth took each function it left unread at what it is
            // assumed to leave, from nothing. Those are read from the top (`readDeferred`),
            // whose answers hold for any caller, and the call is asked again until every
            // assumption holds: the least answer, as a recursion's. One that does not settle
            // leaves all of it, so a read after it is undecided, never clean.
            var rounds: usize = 0;
            const settled = while (memo.cuts != cuts) : (rounds += 1) {
                if (rounds == undefines_rounds) break false;
                const grew = (try readDeferred(c)) orelse break false;
                if (!grew) break true;
                cuts = memo.cuts;
                walk.unknown = false;
                left = try walk.undoneBy(call);
            } else true;
            memo.deferred.clearRetainingCapacity();
            if (!settled) left = std.math.maxInt(u64);
            const unknown = walk.unknown;
            if (left == 0) continue;
            const line = tree.tokenLocation(0, tree.nodeMainToken(call)).line + 1;
            if (try walk.aliasAfter(call, block)) |alias| {
                try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(call)), .unsupported, try c.allocator.print("'{s}' is given `undefined` here by the call, and an alias of it taken at line {d} may read it after: no read of it through that alias is followed", .{ decl.name, tree.tokenLocation(0, alias).line + 1 }));
                continue;
            }
            var from: Walk = .init(c, c.file, local, false, 0);
            try from.collect();
            _ = try from.onFrom(call, left, block);
            const token = from.read orelse continue;
            if (found == token) continue;
            if (unknown) {
                try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(call)), .unsupported, try c.allocator.print("'{s}' is handed here to a call that reaches a function not known here (a function pointer, a field its callers fill): whether it gives it `undefined` before the read at line {d} is not known", .{ decl.name, tree.tokenLocation(0, token).line + 1 }));
                continue;
            }
            if (!settled) {
                try c.undecided(rule, tree.tokenStart(tree.nodeMainToken(call)), .budget_exhausted, try c.allocator.print("'{s}' is handed to a call here whose calls' readings did not settle within {d} rounds: whether it gives it `undefined` before the read at line {d} is not known", .{ decl.name, undefines_rounds, tree.tokenLocation(0, token).line + 1 }));
                continue;
            }
            found = token;
            try c.at(rule, token, if (from.handed)
                try c.allocator.print("'{s}' is handed on here while undefined on a path from line {d}, whose call gives it `undefined` (as a `deinit` does), where nothing shows it written whole since: a read of undefined memory, which no build checks", .{ decl.name, line })
            else
                try c.allocator.print("'{s}' is read here while undefined on a path from line {d}, whose call gives it `undefined` (as a `deinit` does): a read of undefined memory, which no build checks", .{ decl.name, line }));
        }
    }
}

/// Where the walk stands: the local unwritten, written, a read found (`done`), or the path left
/// before what follows (`left`). While it is unwritten, `parts` holds what of it every path here
/// has written: its fields, by their place in its struct, or its elements, by index.
const State = struct {
    at: enum { unwritten, written, done, left },
    parts: u64 = 0,
    /// A call outside the program given all of it, which writes it when its result checks
    /// (`CContract`): the walk takes it written where a test of that result shows it did.
    guard: ?Guard = null,

    const unwritten: State = .{ .at = .unwritten };
    const written: State = .{ .at = .written };
    const done: State = .{ .at = .done };
    const left: State = .{ .at = .left };

    /// The parts it holds written: all of them, once it is written whole.
    fn have(state: State) u64 {
        return if (state.at == .written) std.math.maxInt(u64) else state.parts;
    }
};

/// What every alternative of a per-build choice of functions does with what it is given: a fill
/// (one of them, for how its failure leaves), a keep or a count, or a contract.
const Choice = union(enum) { fill: Facts.Decl, keep, contract: *const CContract.Entry };

/// A call that writes the local when its result checks, and the constant holding that result,
/// where one does (`const rc = f(&x);`).
/// One of std's counts given all of the local: written whole where its count is all of it.
const counted_whole: CContract.Entry = .{ .name = "", .writes = &.{}, .types = &.{}, .success = .length };

const Guard = struct { call: Ast.Node.Index, entry: *const CContract.Entry, binding: ?Model.Declaration.Id };

/// What a mention does: reads the local, hands it on, writes it whole, or sets or reads one of
/// its parts, by index; or is given whole to a call that writes it where its result checks.
/// `undefined` given to it writes nothing: `unset` makes the parts in its set undefined again
/// (all of them, every bit set), and `reset` assigns all of it but those.
const Effect = union(enum) { read, handed, write, set: u6, get: u6, needs: u64, guarded: Guard, unset: u64, reset: u64 };
const Use = struct { key: Ast.TokenIndex, effect: Effect };
/// A mention that gives the local `undefined`, and the parts that leaves undefined.
const Undefining = struct { mention: Ast.Node.Index, left: u64 };

/// A local's parts, where they are known and 64 at most: its struct's fields, by name, or its
/// array's elements, by count.
const Shape = union(enum) { none, fields: []const []const u8, elements: u7 };

/// One local's walk, or one parameter's (`param`): the memory a function's pointer parameter
/// points at, which the walk shows written whole on every path that returns.
const Walk = struct {
    c: *Context,
    file: Project.FileId,
    tree: *const Ast,
    model: *const Model,
    local: Model.Declaration.Id,
    param: bool,
    depth: u8,
    /// The identifiers that name the local, or one of its aliases (`aliases`), in source order.
    mentions: []const Ast.Node.Index = &.{},
    /// The locals that hold the local's memory's address as it is (`aliasesOf`): a mention of
    /// one names that memory as a parameter's pointer does.
    aliases: []const Model.Declaration.Id = &.{},
    /// Whether a call the local was handed to reaches a function not known here (a pointer, a
    /// value the program's callers give): what it leaves undefined is not known (`undoneBy`).
    unknown: bool = false,
    /// The `asm` outputs bound to the local, by the token naming it, with the `asm` they are in.
    outputs: std.ArrayList(struct { token: Ast.TokenIndex, asm_node: Ast.Node.Index }) = .empty,
    /// The function's `return`s, for a parameter's walk.
    returns: []const Ast.Node.Index = &.{},
    read: ?Ast.TokenIndex = null,
    /// Whether the read is the local handed on rather than read in place.
    handed: bool = false,
    /// Whether a path returns with a parameter's memory not yet written whole.
    exit_unwritten: bool = false,
    /// Of those, whether one returns an error (`return error.X`, a `try`), and whether one
    /// returns otherwise: what the memory is on each exit (`leftExits`).
    exit_failure: bool = false,
    exit_success: bool = false,
    /// The `try`s of a parameter's function: each leaves it with an error.
    tries: []const Ast.Node.Index = &.{},
    /// What of the memory a call handed it leaves `undefined` where the call's failure leaves
    /// the function: by an error (`try`, `failing`), or by a `return` that may be either
    /// (`catch return`, `leaving`) (`undoneBy`).
    failing: u64 = 0,
    leaving: u64 = 0,
    /// Whether an error's `return` counts as any other for `exit_unwritten`: where the walk
    /// asks what a caller's `catch` may go on with (`undefines`), not what a call writes.
    every_exit: bool = false,
    /// The constructs being walked that a `break` or `continue` in them may leave for their end
    /// (a loop, a labeled block or `switch`), innermost last, each with what the jumps to it
    /// so far take there, and for a labeled `switch`, what its `continue`s dispatch again with.
    targets: std.ArrayList(struct { node: Ast.Node.Index, exit: ?State = null, again: ?State = null }) = .empty,
    /// The local's parts: each written, it is written whole.
    shape: Shape = .none,
    /// The call read as succeeding, where its success is what a branch takes.
    succeeding: ?Ast.Node.Index = null,
    /// The deferred statements that mention the local, met on the path being walked, each with
    /// the block whose exits run it, outermost first (`ended`, `exiting`).
    deferred: std.ArrayList(struct { block: Ast.Node.Index, node: Ast.Node.Index }) = .empty,
    /// The `bool` constants walked, each with what the local holds where it is true.
    flags: std.ArrayList(struct { decl: Model.Declaration.Id, state: State }) = .empty,
    /// What the parts are of: the struct, or the array's length.
    owner: ?Owner = null,
    /// For a parameter's walk asking what of its memory the function reads (`needing`): the
    /// parts read before every path to them wrote them, which a read of no part adds to.
    needing: bool = false,
    needed: u64 = 0,
    /// The calls of one of std's errno decoders on a guarding call's result, by declaration:
    /// which decoder each is (`noteErrnos`).
    errnos: std.AutoHashMapUnmanaged(Ast.Node.Index, CContract.Errno) = .empty,

    fn init(c: *Context, file: Project.FileId, local: Model.Declaration.Id, param: bool, depth: u8) Walk {
        return .{ .c = c, .file = file, .tree = &c.project.at(file).file.tree, .model = &c.project.at(file).model, .local = local, .param = param, .depth = depth };
    }

    fn collect(w: *Walk) Context.Error!void {
        const name = w.model.declarations[@backingInt(w.local)].name;
        w.aliases = try aliasesOf(w.c.allocator, w.c.facts, w.file, w.local, w.param);
        const index = try indexOf(w.c.facts, w.file);
        if (w.param) {
            // Its function's own: a `return` or `try` in a function declared within it leaves
            // that one.
            const function = ownFunction(w.tree, w.model, w.model.declarations[@backingInt(w.local)].node);
            if (index.exits.get(function)) |own| {
                w.returns = own.returns;
                w.tries = own.tries;
            }
        }
        for (index.outputs.items) |node| {
            // `[a] "b" (c)` names its variable by the token before `)`; `(-> T)` returns one.
            const lhs, const rparen = w.tree.nodeData(node).opt_node_and_token;
            if (lhs != .none or !std.mem.eql(u8, w.tree.tokenSlice(rparen - 1), name)) continue;
            const asm_node = w.enclosingAsm(rparen) orelse continue;
            try w.outputs.append(w.c.allocator, .{ .token = rparen - 1, .asm_node = asm_node });
        }
        // The local's identifiers and its aliases', in node order: the index's own list, where
        // it has no alias to merge.
        const own_names: []const Ast.Node.Index = if (index.named.get(w.local)) |list| list.items else &.{};
        if (w.aliases.len == 0) {
            w.mentions = own_names;
        } else {
            var merged: std.ArrayList(Ast.Node.Index) = .empty;
            try merged.appendSlice(w.c.allocator, own_names);
            for (w.aliases) |alias| if (index.named.get(alias)) |list| try merged.appendSlice(w.c.allocator, list.items);
            std.mem.sort(Ast.Node.Index, merged.items, {}, struct {
                fn less(_: void, a: Ast.Node.Index, b: Ast.Node.Index) bool {
                    return @backingInt(a) < @backingInt(b);
                }
            }.less);
            w.mentions = merged.items;
        }
        w.shape = try w.partsOf();
    }

    /// Whether `mention` names the memory through a pointer to it: a parameter's, or an
    /// alias's (`aliases`), where the local itself names it as it is.
    fn viaPointer(w: *const Walk, mention: Ast.Node.Index) bool {
        if (w.param) return true;
        const ref = w.model.reference(mention) orelse return false;
        return ref.declaration != w.local;
    }

    /// Whether `access`, a place a mention starts (a field, an element, a slice, `.?`, `.*`),
    /// reaches the memory through a pointer: by the name its path starts at (`viaPointer`,
    /// `accesses.pathOf`).
    fn throughPointer(w: *const Walk, access: Ast.Node.Index) Context.Error!bool {
        const path = try Facts.accesses.pathOf(w.c.facts, w.file, access);
        const root = path.steps[path.steps.len - 1].node;
        if (w.model.reference(root) == null) return w.param;
        return w.viaPointer(root);
    }

    /// The parts of what the local is, or a parameter's single-item pointer points at: an
    /// array's elements by its literal length, or a struct's fields.
    fn partsOf(w: *Walk) Context.Error!Shape {
        const tree = w.tree;
        var kind = if (w.param)
            w.c.facts.parameterTypeNode(.{ .file = w.file, .index = w.local }) orelse return .none
        else kind: {
            const variable = tree.fullVarDecl(w.model.declarations[@backingInt(w.local)].node) orelse return .none;
            // With no type written, the type of what it is made from (`var s = list.pop().?`).
            break :kind variable.ast.type_node.unwrap() orelse return w.partsOfValue(variable.ast.init_node.unwrap() orelse return .none);
        };
        if (w.param) {
            const pointer = tree.fullPtrType(kind) orelse return .none;
            if (pointer.size != .one) return .none;
            kind = pointer.ast.child_type;
        }
        if (try w.c.facts.arrayType(w.file, kind)) |array_type| {
            const length = (try Range.constantValue(w.c, array_type.file, array_type.length orelse return .none)) orelse return .none;
            if (length == 0 or length > 64) return .none;
            w.owner = .{ .elements = @intCast(length) };
            return .{ .elements = @intCast(length) };
        }
        const container = switch (try w.c.facts.resolve(w.file, kind)) {
            .container => |container| container,
            // A choice of types has no one list of parts: the local is read whole
            // (`Shape.none`), a part it sets counting for nothing and a part read a read of it.
            .alternatives => return .none,
            else => return .none,
        };
        const shape = try fieldsOf(w.c, container);
        if (shape != .none) w.owner = .{ .container = .{ .file = container.file, .scope = container.scope } };
        return shape;
    }

    /// The parts of a struct instance `first` makes, the local's first value.
    fn partsOfValue(w: *Walk, first: Ast.Node.Index) Context.Error!Shape {
        const container = switch (try w.c.facts.resolve(w.file, first)) {
            .instance => |container| container,
            // A choice of types, read whole as `partsOf` reads one.
            .alternatives => return .none,
            else => return .none,
        };
        const shape = try fieldsOf(w.c, container);
        if (shape != .none) w.owner = .{ .container = .{ .file = container.file, .scope = container.scope } };
        return shape;
    }

    /// Where the local, or a part of it, is given `undefined` (`x = undefined`, `x.a = undefined`,
    /// `@memset(&x, undefined)`), with what of it that leaves undefined.
    fn undefinings(w: *Walk) Context.Error![]const Undefining {
        var list: std.ArrayList(Undefining) = .empty;
        for (w.mentions) |mention| {
            // Only a statement that spells `undefined` gives it.
            var at = mention;
            while (w.model.parentOf(at)) |up| : (at = up) if (isBlock(w.tree, up)) break;
            if (!spellsUndefined(w.tree, at)) continue;
            const use = (try w.classify(mention)) orelse continue;
            const left = switch (use.effect) {
                .unset, .reset => |left| left,
                else => continue,
            };
            try list.append(w.c.allocator, .{ .mention = mention, .left = left });
        }
        return list.items;
    }

    /// Walks on from `mention`, which gives the local `undefined` and leaves undefined the parts
    /// in `left` (every other part taken as written: the walks from where each was left
    /// undefined read those), to the end of `scope`, the block it lives in or a parameter's
    /// function's body. The rest of the statement holding it is not walked, but a loop in that
    /// statement runs the statement again; what follows it in each block around it is, each
    /// loop around it runs again from what a pass ends with, a `switch` its `continue`s
    /// dispatch again is entered again, and a jump goes where it goes. A deferred one leaves it
    /// undefined at its block's end.
    fn onFrom(w: *Walk, mention: Ast.Node.Index, left: u64, scope: Ast.Node.Index) Context.Error!State {
        const tree = w.tree;
        const start: State = .{ .at = .unwritten, .parts = w.everyPart() & ~left };
        // What holds the mention, innermost first, up to `scope`.
        var around: std.ArrayList(Ast.Node.Index) = .empty;
        defer around.deinit(w.c.allocator);
        var at = mention;
        while (at != scope) {
            at = w.model.parentOf(at) orelse return start;
            try around.append(w.c.allocator, at);
        }
        // The statement of the innermost block that holds it.
        const inner = for (around.items, 0..) |each, i| {
            if (isBlock(tree, each)) break i;
        } else return start;
        const statement_at = if (inner == 0) mention else around.items[inner - 1];
        // What each block around it deferred before it runs where that block is left.
        var j = around.items.len;
        while (j > inner) {
            j -= 1;
            if (!isBlock(tree, around.items[j])) continue;
            const holder = if (j == inner) statement_at else around.items[j - 1];
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, around.items[j]).?;
            for (statements[0..std.mem.findScalar(Ast.Node.Index, statements, holder).?]) |each| switch (tree.nodeTag(each)) {
                .@"defer", .@"errdefer" => if (w.mentioned(each)) try w.deferred.append(w.c.allocator, .{ .block = around.items[j], .node = each }),
                else => {},
            };
        }
        // A `return` that holds it (`orelse return giveUp(&x)`) leaves with it so: nothing after
        // it is reached but what it runs.
        for (around.items[0..inner]) |each| if (tree.nodeTag(each) == .@"return") {
            const past = try w.exiting(each, start);
            if (past.at == .done) return .done;
            if (w.param and past.at == .unwritten and try w.exitsBy(each)) try w.exited(each);
            return .left;
        };
        // The constructs a jump from the rest may go to, outermost first.
        var i = around.items.len;
        while (i > inner) {
            i -= 1;
            if (jumpable(tree, around.items[i])) try w.enter(around.items[i]);
        }
        var state = start;
        for (around.items[0..inner]) |each| {
            if (tree.fullWhile(each) != null or tree.fullFor(each) != null) {
                state = try w.statement(statement_at, start);
                break;
            }
        }
        var child = statement_at;
        for (around.items[inner..]) |up| {
            if (state.at == .done) return .done;
            if (isBlock(tree, up)) {
                var buffer: [2]Ast.Node.Index = undefined;
                const statements = tree.blockStatements(&buffer, up).?;
                const position = std.mem.findScalar(Ast.Node.Index, statements, child).?;
                // A deferred one runs at the block's end, after what follows it, before what was
                // deferred ahead of it.
                state = try w.sequence(up, switch (tree.nodeTag(child)) {
                    .@"defer", .@"errdefer" => &.{},
                    else => statements[position + 1 ..],
                }, state);
                if (blockLabel(tree, up) != null) state = w.leave(state);
            } else if (tree.fullWhile(up)) |loop| {
                state = w.leave(state);
                if (child == loop.ast.then_expr or child.toOptional() == loop.ast.cont_expr) {
                    // The pass ends: its continue expression, then the loop again.
                    if (child == loop.ast.then_expr) if (loop.ast.cont_expr.unwrap()) |more| if (state.at == .unwritten) {
                        state = try w.statement(more, state);
                    };
                    if (state.at == .unwritten) state = try w.statement(up, state);
                }
            } else if (tree.fullFor(up)) |loop| {
                state = w.leave(state);
                if (child == loop.ast.then_expr and state.at == .unwritten) state = try w.statement(up, state);
            } else if (tree.fullSwitch(up) != null) {
                const again = w.targets.items[w.targets.items.len - 1].again;
                state = w.leave(state);
                if (again) |dispatched| if (dispatched.at == .unwritten) {
                    state = merge(state, try w.statement(up, dispatched));
                };
            }
            child = up;
        }
        return state;
    }

    /// What of the local a call leaves `undefined` where `mention` gives the call the local, or
    /// a field or element of it, as its receiver or by address (`x.deinit(gpa)`, `f(&x)`,
    /// `x.list.deinit(gpa)`; a parameter's pointer as it is, `f(p)`), and the function it
    /// reaches gives what that parameter points at `undefined` on a path that returns
    /// (`undefines`): those parts, or all of it where the part handed is not one known; 0 for
    /// any other mention. A receiver held through a pointer hands on what it points at.
    fn undoneBy(w: *Walk, mention: Ast.Node.Index) Context.Error!u64 {
        const tree = w.tree;
        const all = std.math.maxInt(u64);
        const pointer = w.viaPointer(mention);
        const place = try handedPlace(w.c.facts, w.file, mention, pointer) orelse return 0;
        if (!try w.inMemory(mention, place)) return 0;
        // A field or element handed: the part its first step names.
        const part_handed: ?u64 = if (place == mention) null else part: {
            const first = w.model.parentOf(mention).?;
            const index = try w.partAt(first, try Facts.accesses.useOf(w.c.facts, w.file, mention) == .member) orelse break :part all;
            break :part @as(u64, 1) << index;
        };
        const holder = w.model.parentOf(place).?;
        var buffer: [1]Ast.Node.Index = undefined;
        const place_use = try Facts.accesses.useOf(w.c.facts, w.file, place);
        const receiver = place_use == .member;
        const argument = if (place_use == .address) holder else place;
        // `@call(modifier, f, .{&x})` calls f with the tuple's elements as its arguments.
        const at_call = if (receiver) null else try atCall(w.c.facts, w.file, argument);
        const node = if (at_call) |at| at.node else if (receiver) w.model.parentOf(holder).? else w.model.parentOf(argument).?;
        const call: ?Ast.full.Call = if (at_call != null) null else tree.fullCall(&buffer, node).?;
        // A local that is a pointer gives a method, or a field's address, what it points at.
        if (!pointer and (receiver or place != mention)) {
            if (try w.c.facts.resolve(w.file, mention) == .pointer) return 0;
        }
        if (receiver and place != mention and try w.c.facts.resolve(w.file, place) != .instance) return 0;
        // What a call reaches that is not known here (a pointer, a field a caller fills) may
        // give it `undefined`: all of what it is handed, and the read after it undecided.
        const decls = (try w.callees(node, if (at_call) |at| at.function else call.?.ast.fn_expr, call)) orelse {
            w.unknown = true;
            return part_handed orelse all;
        };
        var left: u64 = 0;
        // A per-build choice gives what any of its functions gives.
        for (decls) |origin| {
            const index = if (receiver) 0 else if (at_call) |at| at.position else try parameterAt(w.c, w.file, call.?, std.mem.findScalar(Ast.Node.Index, call.?.ast.params, argument).?) orelse {
                w.unknown = true;
                return part_handed orelse all;
            };
            const found = try undefines(w.c, origin, index, w.depth + 1);
            if (!found.known) w.unknown = true;
            // The path past the call goes on from its success where its failure leaves (`try`,
            // `catch return`), which takes what the failure leaves with it; else from either.
            const failure = try w.failureExit(node, origin);
            const going = if (failure == .goes_on) found.mask | found.failing else found.mask;
            left |= w.fitted(going, found.owner, part_handed);
            switch (failure) {
                .goes_on, .stops => {},
                .fails => w.failing |= w.fitted(found.failing, found.owner, part_handed),
                .returns => w.leaving |= w.fitted(found.failing, found.owner, part_handed),
            }
        }
        return left;
    }

    /// What of the local `found`, parts of the callee's parameter's memory (of `theirs`), is:
    /// the part handed where one is, those parts where the memory is the local's own type,
    /// else all of it.
    fn fitted(w: *const Walk, found: u64, theirs: ?Owner, part_handed: ?u64) u64 {
        const all = std.math.maxInt(u64);
        if (found == 0) return 0;
        if (part_handed) |handed| return handed;
        if (found == all) return all;
        const owner = w.owner orelse return all;
        return if (std.meta.eql(owner, theirs orelse return all)) found else all;
    }

    /// Where a call's failure goes: on past the call (a `catch` that goes on), out of the
    /// function by its error (`try`), out by a `return` (`catch return`), or nowhere (`catch
    /// unreachable`, a call that cannot fail).
    fn failureExit(w: *const Walk, node: Ast.Node.Index, function: Facts.Decl) Context.Error!enum { goes_on, fails, returns, stops } {
        if (w.succeeding == node) return .stops;
        const tree = &w.c.project.at(function.file).file.tree;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, w.c.project.at(function.file).model.declarations[@backingInt(function.index)].node) orelse return .goes_on;
        const result = proto.ast.return_type.unwrap() orelse return .goes_on;
        if (!try mayFail(w.c.facts, function.file, result)) return .stops;
        const parent = w.model.parentOf(node) orelse return .goes_on;
        return switch (w.tree.nodeTag(parent)) {
            .@"try" => .fails,
            .@"catch" => {
                const lhs, const rhs = w.tree.nodeData(parent).node_and_node;
                if (lhs != node) return .goes_on;
                return switch (w.tree.nodeTag(rhs)) {
                    .@"return" => .returns,
                    .unreachable_literal => .stops,
                    else => .goes_on,
                };
            },
            else => .goes_on,
        };
    }

    /// The functions a call may reach: the one it names (`callee`), or each of a per-build
    /// choice, through a pointer to them too; null where what it reaches is not known here
    /// (a function pointer the program's callers give, a field nothing here fills).
    fn callees(w: *Walk, node: Ast.Node.Index, function: Ast.Node.Index, call: ?Ast.full.Call) Context.Error!?[]const Facts.Decl {
        var found: std.ArrayList(Facts.Decl) = .empty;
        if (call) |full| if (try w.callee(node, full)) |decl| {
            try found.append(w.c.allocator, decl);
            return found.items;
        };
        if (try functionsOf(w.c.allocator, try w.c.facts.resolve(w.file, function), &found)) return found.items;
        // Through std's Io.Reader or Io.Writer vtable (`w.vtable.drain(w, …)`): std's own
        // implementations leave neither the interface nor its buffer `undefined`
        // (`std_interface_implementations`), and the program's are read where it installs them.
        const slot = (try vtableSlot(w.c, w.file, function)) orelse return null;
        return installed(w.c, slot);
    }

    /// Whether `place`, reached from `mention` by fields and elements, lies in the local's own
    /// memory (or a parameter's pointee): no step passes through a pointer it holds (`w.c.facts`
    /// with `c: *Context`, a slice's element).
    fn inMemory(w: *Walk, mention: Ast.Node.Index, place: Ast.Node.Index) Context.Error!bool {
        const path = try Facts.accesses.pathOf(w.c.facts, w.file, place);
        for (path.steps, 0..) |step, at| {
            if (step.node == mention) return true;
            switch (step.kind) {
                .field, .index => {},
                .slice, .unwrap, .deref, .root => return false,
            }
            const inner = path.steps[at + 1].node;
            // A parameter's pointer is how its memory is reached.
            if (!(w.viaPointer(mention) and inner == mention) and try w.pointerAt(inner)) return false;
        }
        return false;
    }

    /// Whether `node`, the local or a part of it, holds a pointer (a slice too), whose fields
    /// and elements are what it points at: by its value, or where that does not resolve (std's
    /// own, read without its instantiation), a field of the local by the type its struct
    /// spells for it (`[]T`, `*T`, or a constant of one, `Slice = if (a) |x| []align(x) T else
    /// []T`).
    fn pointerAt(w: *Walk, node: Ast.Node.Index) Context.Error!bool {
        switch (try w.c.facts.resolve(w.file, node)) {
            .pointer, .optional => return true,
            .instance, .array, .primitive, .scalar, .error_union, .error_set, .container, .function, .literal => return false,
            .alternatives => |each| for (each) |one| {
                if (one != .pointer) break;
            } else return true,
            else => {},
        }
        const read = (try Facts.accesses.memberRead(w.c.facts, w.file, node)) orelse return false;
        if (std.mem.findScalar(Ast.Node.Index, w.mentions, read.receiver.?) == null) return false; // unreachable: a member's step has its holder
        const name = read.name orelse return false;
        const owner = w.owner orelse return false;
        if (owner != .container) return false;
        const source = w.c.project.at(owner.container.file);
        const tree = &source.file.tree;
        for (source.model.declarations) |decl| {
            if (decl.kind != .field or decl.scope != owner.container.scope or !std.mem.eql(u8, decl.name, name)) continue;
            const field = source.model.containerField(tree, decl.node) orelse return false;
            const kind = field.ast.type_expr.unwrap() orelse return false;
            return try spelledPointer(w.c.facts, owner.container.file, owner.container.scope, kind, true);
        }
        return false;
    }

    /// The exits of a parameter's function that leave its memory `undefined`, the parts in
    /// `left`, walking on from `mention`, which leaves them so, to the end of `body`: one that
    /// returns an error (`return error.X`, a `try`), and one that returns otherwise (running off
    /// the end too). An `errdefer` runs at the first only. One that reads it there (its own
    /// fault) is taken as leaving it on both.
    fn leftExits(w: *Walk, mention: Ast.Node.Index, left: u64, body: Ast.Node.Index) Context.Error!struct { success: bool, failure: bool } {
        var at = mention;
        while (w.model.parentOf(at)) |up| : (at = up) {
            if (at == body) break;
            if (w.tree.nodeTag(up) == .@"errdefer") return .{ .success = false, .failure = true };
        }
        var from: Walk = .init(w.c, w.file, w.local, true, w.depth);
        from.every_exit = true;
        try from.collect();
        const past = try from.onFrom(mention, left, body);
        const both = from.read != null or past.at == .done;
        return .{ .success = both or from.exit_success or past.at == .unwritten, .failure = both or from.exit_failure };
    }

    /// A path leaves by `node`, a `return` or a `try`, with the memory not written whole.
    fn exited(w: *Walk, node: Ast.Node.Index) Context.Error!void {
        w.exit_unwritten = true;
        if (w.tree.nodeTag(node) == .@"try" or try errorReturn(w.c.facts, w.file, node)) w.exit_failure = true else w.exit_success = true;
    }

    /// Where an alias of the local, taken before `origin` (a call that leaves it `undefined`),
    /// may read it after: its address, or a field's or element's (`const p = &x`), or what a
    /// method given its address returns that may hold it (`var it = x.iterator()`), bound to
    /// a name mentioned after `origin`, or again within a loop around it, or stored anywhere
    /// else. The alias's token, or null.
    fn aliasAfter(w: *Walk, origin: Ast.Node.Index, scope: Ast.Node.Index) Context.Error!?Ast.TokenIndex {
        const tree = w.tree;
        const at = tree.nodeMainToken(origin);
        var buffer: [1]Ast.Node.Index = undefined;
        for (w.mentions) |mention| {
            if (tree.nodeMainToken(mention) >= at) continue;
            const place = try placeOf(w.c.facts, w.file, mention);
            if (!try w.inMemory(mention, place)) continue;
            const value = switch (try Facts.accesses.useOf(w.c.facts, w.file, place)) {
                .address => |taken| taken,
                .member => |holder| value: {
                    const node = w.model.parentOf(holder) orelse continue;
                    const call = tree.fullCall(&buffer, node) orelse continue;
                    if (call.ast.fn_expr != holder) continue;
                    if (!holdsResult(try w.c.facts.resolve(w.file, node))) continue;
                    // Given by value, the method holds a copy.
                    const decl = (try w.callee(node, call)) orelse break :value node;
                    if (try parameter(w.c, decl, 0, false) == null) continue;
                    break :value node;
                },
                else => continue,
            };
            // Through `try`, `catch`'s and `orelse`'s payload and grouping to where the value goes.
            var result = value;
            while (true) switch (try Facts.accesses.useOf(w.c.facts, w.file, result)) {
                .carried => |carried| switch (carried.how) {
                    .grouped, .tried, .payload => result = carried.into,
                    else => break,
                },
                else => break,
            };
            const goes = w.model.parentOf(result) orelse continue;
            if (tree.fullCall(&buffer, goes) != null or isBlock(tree, goes)) continue;
            const binding = w.declaredAt(goes) orelse return tree.nodeMainToken(value);
            if (tree.fullVarDecl(goes).?.ast.init_node.unwrap() != result) return tree.nodeMainToken(value);
            // An alias the walk follows (`aliases`): its mentions are the local's.
            if (std.mem.findScalar(Model.Declaration.Id, w.aliases, binding) != null) continue;
            if (try w.mentionedAfter(binding, origin, scope)) return tree.nodeMainToken(value);
        }
        return null;
    }

    /// Whether the declaration `binding` is mentioned after `origin`, or anywhere in a loop
    /// that holds `origin` within `scope`, the local's block.
    fn mentionedAfter(w: *const Walk, binding: Model.Declaration.Id, origin: Ast.Node.Index, scope: Ast.Node.Index) Context.Error!bool {
        const tree = w.tree;
        const at = tree.nodeMainToken(origin);
        var first = at;
        var up = origin;
        while (w.model.parentOf(up)) |next| : (up = next) {
            if (next == scope) break;
            if (tree.fullWhile(next) != null or tree.fullFor(next) != null) first = @min(first, tree.firstToken(next));
        }
        for (w.model.references) |ref| {
            if (try nameOf(w.c.facts, w.file, ref.node) != binding) continue;
            const token = tree.nodeMainToken(ref.node);
            if (token > at or token >= first) return true;
        }
        return false;
    }

    /// Every part of the local, as a set.
    fn everyPart(w: *const Walk) u64 {
        const count: u7 = switch (w.shape) {
            .none => return 0,
            .fields => |fields| @intCast(fields.len),
            .elements => |length| length,
        };
        return if (count == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(count)) - 1;
    }

    /// The part a field's name or an element's literal index (`node`) is.
    fn partAt(w: *const Walk, node: Ast.Node.Index, field: bool) Context.Error!?u6 {
        switch (w.shape) {
            .none => return null,
            .fields => |fields| {
                if (!field) return null;
                const name = w.tree.tokenSlice(w.tree.nodeData(node).node_and_token[1]);
                for (fields, 0..) |each, at| if (std.mem.eql(u8, each, name)) return @intCast(at);
                return null;
            },
            .elements => |length| {
                if (field) return null;
                const index = try w.constant(w.tree.nodeData(node).node_and_node[1]) orelse return null;
                return if (index < length) @intCast(index) else null;
            },
        }
    }

    /// What a mention does through `access`, a field or an element of the local: an assignment
    /// to it sets that part, any other use reads it, which reads nothing undefined once that
    /// part is written. A field's address taken, or a method called on it, reaches the local
    /// itself where something converts a pointer to a field of that name back to what holds it.
    fn part(w: *Walk, access: Ast.Node.Index, index: ?u6, field: bool, key: Ast.TokenIndex) Context.Error!?Use {
        const read: Use = .{ .key = key, .effect = .read };
        // `x.a = undefined`, `x.a.b = undefined`: that part undefined again, or all of it where
        // the part is not known.
        if (try w.undefinedThrough(access)) |assign| {
            return .{ .key = w.tree.lastToken(assign), .effect = .{ .unset = if (index) |at| @as(u64, 1) << at else std.math.maxInt(u64) } };
        }
        if (try w.partSet(access, field)) {
            const at = index orelse return null;
            return .{ .key = w.tree.lastToken(w.model.parentOf(access).?), .effect = .{ .set = at } };
        }
        const at = index orelse return read;
        if (field and try w.byReference(access)) {
            if (try parentNamed(w.c, w.owner.?, w.tree.tokenSlice(w.tree.nodeData(access).node_and_token[1]))) return read;
        }
        return .{ .key = key, .effect = .{ .get = at } };
    }

    /// The assignment that gives `undefined` to `access`, or to a part of it (`x.a.b = …`), or
    /// a value holding it (`x.a = .{ .n = 0, .buf = undefined }`); not what a pointer it holds
    /// points at (`x.items[i] = undefined`, a slice's element).
    fn undefinedThrough(w: *Walk, access: Ast.Node.Index) Context.Error!?Ast.Node.Index {
        var at = access;
        while (true) switch (try Facts.accesses.useOf(w.c.facts, w.file, at)) {
            .member, .element => |whole| {
                if (try w.pointerAt(at)) return null;
                at = whole;
            },
            .written => |store| {
                const value = store.value orelse return null;
                return if (try holdsUndefined(w.c.facts, w.file, value)) store.node else null;
            },
            else => return null,
        };
    }

    /// What of the local a value assigned to all of it leaves undefined, as a set of its parts:
    /// none for a value without `undefined` in it; the fields or elements a literal gives a value
    /// holding `undefined`; all of them for `undefined` itself, or for any other value holding it
    /// where the local's parts are not known.
    fn undefinedIn(w: *const Walk, value: Ast.Node.Index) Context.Error!u64 {
        const tree = w.tree;
        const all = std.math.maxInt(u64);
        if (!try holdsUndefined(w.c.facts, w.file, value)) return 0;
        const node = Facts.ungrouped(tree, value);
        var mask: u64 = 0;
        var buffer: [2]Ast.Node.Index = undefined;
        switch (w.shape) {
            .none => return all,
            .fields => |fields| {
                const literal = tree.fullStructInit(&buffer, node) orelse return all;
                for (literal.ast.fields) |field| {
                    if (!try holdsUndefined(w.c.facts, w.file, field)) continue;
                    // `.name = value`: the name two tokens before the value.
                    const name = tree.tokenSlice(tree.firstToken(field) - 2);
                    const at = for (fields, 0..) |each, i| {
                        if (std.mem.eql(u8, each, name)) break i;
                    } else return all;
                    mask |= @as(u64, 1) << @intCast(at);
                }
            },
            .elements => {
                const literal = tree.fullArrayInit(&buffer, node) orelse return all;
                for (literal.ast.elements, 0..) |element, at| {
                    if (!try holdsUndefined(w.c.facts, w.file, element)) continue;
                    if (at >= 64) return all;
                    mask |= @as(u64, 1) << @intCast(at);
                }
            },
        }
        return mask;
    }

    /// The field `@field(local, "name")` spells out, as a part.
    fn fieldSpelled(w: *Walk, node: Ast.Node.Index) Context.Error!?u6 {
        const fields = switch (w.shape) {
            .fields => |list| list,
            else => return null,
        };
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(w.tree, node, &buffer);
        if (args.len != 2) return null;
        // The one name it spells (`Facts.fieldName`): a string, a `const` holding one, an enum
        // literal. One it ranges over or computes is no one part.
        const name = switch (try w.c.facts.fieldName(w.file, args[1])) {
            .name => |name| name,
            .each_of, .names, .computed => return null,
        };
        for (fields, 0..) |each, at| if (std.mem.eql(u8, each, name)) return @intCast(at);
        return null;
    }

    /// Whether a field is used where it stays in place: its address taken, or a method called
    /// on it.
    fn byReference(w: *const Walk, access: Ast.Node.Index) Context.Error!bool {
        const up = switch (try Facts.accesses.useOf(w.c.facts, w.file, access)) {
            .address => return true,
            .member => |member| member,
            else => return false,
        };
        const call = w.model.parentOf(up) orelse return false;
        var buffer: [1]Ast.Node.Index = undefined;
        const full = w.tree.fullCall(&buffer, call) orelse return false;
        return full.ast.fn_expr == up;
    }

    /// The state past `statements`, `block`'s or the rest of them, and past the deferred
    /// statements its end runs.
    fn sequence(w: *Walk, block: Ast.Node.Index, statements: []const Ast.Node.Index, state: State) Context.Error!State {
        var now = state;
        for (statements) |each| {
            if (now.at != .unwritten) break;
            now = try w.statement(each, now);
        }
        return w.ended(block, now);
    }

    /// The state past `block`'s end, reached with `state`: its deferred statements run there,
    /// the last met first, but an `errdefer`, which runs where it is left by an error only. They
    /// are dropped, every exit of the block past.
    fn ended(w: *Walk, block: Ast.Node.Index, state: State) Context.Error!State {
        var now = state;
        while (w.deferred.items.len > 0) {
            const last = w.deferred.items[w.deferred.items.len - 1];
            if (last.block != block) break;
            _ = w.deferred.pop();
            if (now.at != .unwritten or w.tree.nodeTag(last.node) == .@"errdefer") continue;
            now = try w.statement(w.tree.nodeData(last.node).node, now);
        }
        return now;
    }

    /// The state an exit at `node` leaves with, past the deferred statements it runs, reached
    /// with `state`: each one met for a `return` or a failing `try`, an `errdefer`'s too (read,
    /// not taken as written: the exit may be no error's); those of the blocks a `break` or
    /// `continue` leaves. They stay for the walk's other paths.
    fn exiting(w: *Walk, node: Ast.Node.Index, state: State) Context.Error!State {
        const tree = w.tree;
        const goes: ?Ast.Node.Index = switch (tree.nodeTag(node)) {
            .@"break", .@"continue" => jumpTarget(tree, w.model, node),
            else => null,
        };
        var now = state;
        var i = w.deferred.items.len;
        while (i > 0 and now.at == .unwritten) {
            i -= 1;
            const entry = w.deferred.items[i];
            const errors = tree.nodeTag(entry.node) == .@"errdefer";
            if (goes) |target| {
                if (tree.firstToken(entry.block) < tree.firstToken(target) or tree.lastToken(entry.block) > tree.lastToken(target)) break;
                if (errors) continue;
            }
            const past = try w.statement(tree.nodeData(entry.node).node, now);
            if (past.at == .done) return .done;
            if (!errors) now = past;
        }
        return now;
    }

    /// Whether a deferred statement reads the local undefined at an exit inside `node` (a
    /// `return`, a `try`, a jump out; not `node` as a `return` or jump, which `statement` takes),
    /// for a statement the walk does not follow to it: what the exit leaves with is no less than
    /// `state`.
    fn readAtExits(w: *Walk, node: Ast.Node.Index, state: State) Context.Error!bool {
        if (w.deferred.items.len == 0 or state.at != .unwritten) return false;
        const tree = w.tree;
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        var token = first;
        while (token <= last) : (token += 1) switch (tree.tokenTag(token)) {
            .keyword_return, .keyword_try, .keyword_break, .keyword_continue => break,
            else => {},
        } else return false;
        for (tree.nodes.items(.tag), 0..) |tag, i| switch (tag) {
            .@"return", .@"try", .@"break", .@"continue" => {
                const each: Ast.Node.Index = @fromBackingInt(@intCast(i));
                const at = tree.nodeMainToken(each);
                if ((each == node and tag != .@"try") or at < first or at > last) continue;
                if ((try w.exiting(each, state)).at == .done) return true;
            },
            else => {},
        };
        return false;
    }

    /// The state past `node`, reading it in the order Zig evaluates it.
    fn statement(w: *Walk, node: Ast.Node.Index, state: State) Context.Error!State {
        const tree = w.tree;
        // A path that leaves reads what it leaves with first; a parameter's walk sees each
        // `return` that is not an error's with the memory unwritten. A `break` or `continue`
        // takes what it holds to where it goes.
        switch (tree.nodeTag(node)) {
            .@"return", .@"break", .@"continue", .unreachable_literal => {
                const reached = if (w.mentioned(node)) try w.simple(node, state) else state;
                if (reached.at == .done) return .done;
                // The deferred statements it leaves by run before it goes.
                const past = if (tree.nodeTag(node) == .unreachable_literal) reached else try w.exiting(node, reached);
                if (past.at == .done) return .done;
                if (tree.nodeTag(node) == .@"return" and past.at == .unwritten and try w.exitsBy(node)) try w.exited(node);
                w.jump(node, past);
                return .left;
            },
            else => {},
        }
        // An `if` may test a guard's result, or a flag that says more of the local.
        if (!w.mentioned(node) and !try w.returnsIn(node) and !try w.tests(node, state) and (w.flags.items.len == 0 or tree.fullIf(node) == null)) {
            // It leaves the local as it is, for what follows, for where a jump in it goes and
            // for what an exit in it runs; one that never goes on reaches nothing after it.
            if (try w.readAtExits(node, state)) return .done;
            w.jumpsIn(node, state);
            return if (leavesAlways(tree, node)) .left else state;
        }
        switch (tree.nodeTag(node)) {
            .@"defer", .@"errdefer" => {
                // Run where its block is left after it (`ended`, `exiting`), not here.
                try w.deferred.append(w.c.allocator, .{ .block = w.model.parentOf(node).?, .node = node });
                return state;
            },
            // What runs as the program compiles runs in its place all the same.
            .@"comptime" => return w.statement(tree.nodeData(node).node, state),
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                var buffer: [2]Ast.Node.Index = undefined;
                const statements = tree.blockStatements(&buffer, node).?;
                if (blockLabel(tree, node) == null) return w.sequence(node, statements, state);
                try w.enter(node);
                return w.leave(try w.sequence(node, statements, state));
            },
            else => {},
        }
        if (tree.fullIf(node)) |branch| {
            const after = try w.statement(branch.ast.cond_expr, state);
            if (after.at != .unwritten) return after;
            // On an error union, its value is the call's success; otherwise a flag known true
            // or false says what its being true showed, and a test of a guarding call's result
            // writes the local on the side where it checks.
            var holds = if (branch.error_token != null) try w.succeeded(branch.ast.cond_expr, after) else try w.knowing(branch.ast.cond_expr, after, true);
            var fails = if (branch.error_token != null) after else try w.knowing(branch.ast.cond_expr, after, false);
            if (after.guard) |guard| if (try w.checks(branch.ast.cond_expr, guard)) |checked| {
                if (checked) holds = .written else fails = .written;
            };
            const then = try w.arm(branch.ast.then_expr, holds);
            const otherwise = if (branch.ast.else_expr.unwrap()) |e| try w.arm(e, fails) else fails;
            return merge(then, otherwise);
        }
        if (tree.fullSwitch(node)) |choice| return w.branches(node, choice, state);
        if (tree.fullWhile(node)) |loop| {
            const after = try w.statement(loop.ast.cond_expr, state);
            if (after.at != .unwritten) return after;
            // The body runs first with the local unwritten; a loop may run no pass, so what it
            // writes holds on some paths only. Its continue expression runs where a pass ends,
            // and its `else` where the condition fails.
            try w.enter(node);
            const body = w.leave(try w.statement(loop.ast.then_expr, after));
            if (body.at == .done) return .done;
            if (loop.ast.cont_expr.unwrap()) |more| {
                if (body.at == .unwritten and (try w.statement(more, body)).at == .done) return .done;
            }
            if (loop.ast.else_expr.unwrap()) |e| if ((try w.statement(e, after)).at == .done) return .done;
            return after;
        }
        if (tree.fullFor(node)) |loop| {
            if (try w.setsEveryField(loop)) return .written;
            if (try w.stridesWhole(loop)) return .written;
            for (loop.ast.inputs) |input| {
                const past = try w.statement(input, state);
                if (past.at != .unwritten) return past;
            }
            try w.enter(node);
            const body = w.leave(try w.statement(loop.ast.then_expr, state));
            if (body.at == .done) return .done;
            if (loop.ast.else_expr.unwrap()) |e| {
                if ((try w.statement(e, state)).at == .done) return .done;
                return state;
            }
            // A loop over what has passes in it runs the body, and its first pass is as read;
            // what reaches the loop's end is what its passes end with and what jumps there take.
            for (loop.ast.inputs) |input| if (try passes(w.c, w.file, input)) return body;
            return state;
        }
        // A declaration whose value chooses or is a labeled block is walked as that value: each
        // prong from what precedes it, a block's statements in order, a break taking what it
        // holds to the block's end. A `bool` constant keeps what its being true shows: `const ok
        // = n == 64 and if (fill(&buf)) |_| true else |_| false`.
        const past = if (w.choosingValue(node)) |value| try w.statement(value, state) else try w.simple(node, state);
        if (past.at != .unwritten) return past;
        if (tree.fullVarDecl(node)) |variable| if (tree.tokenTag(variable.ast.mut_token) == .keyword_const) {
            const value = variable.ast.init_node.unwrap() orelse return past;
            const decl = w.declaredAt(node) orelse return past;
            try w.flags.append(w.c.allocator, .{ .decl = decl, .state = try w.whenTrue(value, past) });
        };
        return past;
    }

    /// The value the declaration at `node` is given, where it is a `switch`, an `if` or a
    /// labeled block and the only part of the declaration that mentions the local (`const
    /// values = switch (tag) { 0 => blk: { one[0] = v; break :blk &one; }, else => continue };`).
    fn choosingValue(w: *const Walk, node: Ast.Node.Index) ?Ast.Node.Index {
        const tree = w.tree;
        const variable = tree.fullVarDecl(node) orelse return null;
        const value = Facts.ungrouped(tree, variable.ast.init_node.unwrap() orelse return null);
        if (tree.fullSwitch(value) == null and tree.fullIf(value) == null and !(isBlock(tree, value) and blockLabel(tree, value) != null)) return null;
        for (w.mentions) |mention| {
            const token = tree.nodeMainToken(mention);
            if (token < tree.firstToken(node) or token > tree.lastToken(node)) continue;
            if (token < tree.firstToken(value) or token > tree.lastToken(value)) return null;
        }
        return value;
    }

    /// The state past a `switch`: each prong walked from what its condition leaves, the
    /// `.SUCCESS` prong of one on a guarding call's errno or status written.
    fn branches(w: *Walk, node: Ast.Node.Index, choice: Ast.full.Switch, state: State) Context.Error!State {
        const tree = w.tree;
        const after = try w.statement(choice.ast.condition, state);
        if (after.at != .unwritten) return after;
        try w.enter(node);
        // A `continue` to it dispatches again, to any prong, with what the local holds
        // there: no prong is entered only where the condition checked, and each is walked
        // again from what the `continue`s take until that adds nothing (each round unwrites
        // a part more, at most once each).
        const redispatched = w.continuedTo(node);
        var start = after;
        var all: ?State = null;
        while (true) {
            all = null;
            for (choice.ast.cases) |case| {
                const prong = tree.fullSwitchCase(case) orelse {
                    all = .done;
                    break;
                };
                // `switch (errno(rc))` or a status: its `.SUCCESS` prong is where it checks.
                const begin: State = if (start.guard) |guard| (if (!redispatched and try w.successProng(choice.ast.condition, prong, guard)) .written else start) else start;
                const past = try w.arm(prong.ast.target_expr, begin);
                all = if (all) |sofar| merge(sofar, past) else past;
            }
            const target = &w.targets.items[w.targets.items.len - 1];
            const again = target.again orelse break;
            target.again = null;
            const next = merge(start, again);
            if (next.at == .done or (all orelse start).at == .done) {
                all = .done;
                break;
            }
            if (next.at == start.at and next.parts == start.parts) break;
            start = next;
        }
        return w.leave(all orelse start);
    }

    /// Whether a `for` over `0..n`, `n` a number, writes all of the local, an array of `n * k`
    /// elements, a stride at a time: its body is one statement, mentioning the local once, that
    /// writes `local[k * i ..][0..k]` (or `local[k * (n - 1 - i) ..][0..k]`) whole, `i` the
    /// range's capture and `k` a number: `std.mem.writeInt` (whose type is that long),
    /// `@memcpy`, `@memset` or `.* =`. Each pass writes its own stride; together they are all.
    fn stridesWhole(w: *Walk, loop: Ast.full.For) Context.Error!bool {
        const tree = w.tree;
        if (loop.ast.else_expr != .none) return false;
        const length = (try w.arrayLength()) orelse return false;
        const position, const passes_count = for (loop.ast.inputs, 0..) |input, at| {
            if (tree.nodeTag(input) != .for_range) continue;
            const from, const to = tree.nodeData(input).node_and_opt_node;
            if (try w.constant(from) != 0) continue;
            break .{ at, try w.constant(to.unwrap() orelse continue) orelse continue };
        } else return false;
        const index = capture(tree, loop.payload_token, position, false) orelse return false;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, loop.ast.then_expr) orelse (&loop.ast.then_expr)[0..1];
        if (statements.len != 1) return false;
        const only = statements[0];
        if (leavesPass(tree, only) or spellsUndefined(tree, only)) return false;
        var mentions: usize = 0;
        for (w.mentions) |mention| {
            if (tree.firstToken(mention) >= tree.firstToken(only) and tree.lastToken(mention) <= tree.lastToken(only)) mentions += 1;
        }
        if (mentions != 1) return false;
        var call_buffer: [1]Ast.Node.Index = undefined;
        const dest = if (tree.fullCall(&call_buffer, only)) |call| dest: {
            if (call.ast.params.len != 4 or !try w.isStd(only, call, "mem.writeInt")) return false;
            break :dest call.ast.params[1];
        } else (try filled(w.c.facts, w.file, only)) orelse return false;
        // `local[start..][0..k]`.
        const span = tree.fullSlice(dest) orelse return false;
        if (try w.constant(span.ast.start) != 0) return false;
        const stride = try w.constant(span.ast.end.unwrap() orelse return false) orelse return false;
        const rest = tree.fullSlice(span.ast.sliced) orelse return false;
        if (rest.ast.end != .none or !try w.isLocal(rest.ast.sliced)) return false;
        const total = std.math.mul(u64, passes_count, stride) catch return false;
        if (stride == 0 or total != length) return false;
        return strideAt(w, rest.ast.start, stride, index, passes_count);
    }

    /// The value `node` has as the program compiles (`Range.constantValue`): a number, a
    /// constant that holds one, what they compute.
    fn constant(w: *const Walk, node: Ast.Node.Index) Context.Error!?u64 {
        return Range.constantValue(w.c, w.file, node);
    }

    /// Whether `input`, a slice no one assigns, is known at `call` to be twice the local's
    /// length: the local declared `[input.len / 2]T`, or a test every path to the call passes
    /// (`input.len == 64` with the local `[32]u8`, or `input.len == 2 * local.len`), in `and`'s
    /// left side or an `if`'s condition around it, or in a guard before it that leaves
    /// otherwise (`if (input.len != 64) return …;`).
    fn twiceAsLong(w: *const Walk, call: Ast.Node.Index, input: Ast.Node.Index) Context.Error!bool {
        const tree = w.tree;
        const x = (try nameOf(w.c.facts, w.file, input)) orelse return false;
        const record = w.model.declarations[@backingInt(x)];
        switch (record.kind) {
            .parameter => {},
            .variable => if (tree.tokenTag((tree.fullVarDecl(record.node) orelse return false).ast.mut_token) != .keyword_const) return false,
            // A capture by value; one by pointer (`|*x|`) may see its slice change.
            .capture => if (record.token == 0 or tree.tokenTag(record.token - 1) == .asterisk) return false,
            else => return false,
        }
        if (try w.halfOf(x)) return true;
        var child = call;
        while (w.model.parentOf(child)) |up| : (child = up) {
            if (tree.nodeTag(up) == .fn_decl) return false;
            switch (Facts.conditionOf(tree, up)) {
                .both => |sides| if (sides[1] == child and try w.lengthIs(sides[0], x, true)) return true,
                else => {},
            }
            if (tree.fullIf(up)) |branch| {
                if (branch.ast.then_expr == child and branch.error_token == null and try w.lengthIs(branch.ast.cond_expr, x, true)) return true;
            }
            if (!isBlock(tree, up)) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            for (tree.blockStatements(&buffer, up).?) |each| {
                if (each == child) break;
                const guard = tree.fullIf(each) orelse continue;
                if (guard.ast.else_expr != .none or guard.payload_token != null or guard.error_token != null) continue;
                if (leavesAlways(tree, guard.ast.then_expr) and try w.lengthIs(guard.ast.cond_expr, x, false)) return true;
            }
        }
        return false;
    }

    /// Whether the local is declared `[x.len / 2]T`.
    fn halfOf(w: *const Walk, x: Model.Declaration.Id) Context.Error!bool {
        const tree = w.tree;
        const array_type = (try w.localArray()) orelse return false;
        if (array_type.file != w.file) return false;
        const length = array_type.length orelse return false;
        if (tree.nodeTag(length) != .div) return false;
        const lhs, const rhs = tree.nodeData(length).node_and_node;
        return try w.lengthOf(lhs, x) and try w.constant(rhs) == 2;
    }

    /// Whether `condition` coming out `truth` shows `x.len` twice the local's length.
    fn lengthIs(w: *const Walk, condition: Ast.Node.Index, x: Model.Declaration.Id, truth: bool) Context.Error!bool {
        const truths = (try w.c.facts.truthsWhen(w.file, condition, truth)) orelse return false;
        for (truths) |known| switch (Facts.conditionOf(w.tree, known.part)) {
            .compare => |compared| {
                const equal = switch (compared.order) {
                    .equal => known.value,
                    .not_equal => !known.value,
                    .less, .less_or_equal, .greater, .greater_or_equal => false,
                };
                if (!equal) continue;
                if ((try w.lengthOf(compared.left, x) and try w.twiceLocal(compared.right)) or (try w.lengthOf(compared.right, x) and try w.twiceLocal(compared.left))) return true;
            },
            .not, .both, .either, .other => {},
        };
        return false;
    }

    /// Whether `node` is the length of `x`'s memory (`Facts.lengthOf`).
    fn lengthOf(w: *const Walk, node: Ast.Node.Index, x: Model.Declaration.Id) Context.Error!bool {
        const memory = (try w.c.facts.lengthOf(w.file, node)) orelse return false;
        const ref = w.model.reference(Facts.ungrouped(w.tree, memory)) orelse return false;
        return ref.declaration == x;
    }

    /// Whether `node` is twice the local's length: a literal twice its literal length, or `2 *
    /// local.len`.
    fn twiceLocal(w: *const Walk, node: Ast.Node.Index) Context.Error!bool {
        const tree = w.tree;
        if (try w.constant(node)) |value| {
            const length = (try w.localLength()) orelse return false;
            // An array past half of what a u64 counts has no length twice its own here.
            return value == (std.math.mul(u64, 2, length) catch return false);
        }
        if (tree.nodeTag(node) != .mul) return false;
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        return (try w.constant(lhs) == 2 and try w.lengthOf(rhs, w.local)) or (try w.constant(rhs) == 2 and try w.lengthOf(lhs, w.local));
    }

    /// The declaration a `const` statement makes.
    fn declaredAt(w: *const Walk, node: Ast.Node.Index) ?Model.Declaration.Id {
        for (w.model.declarations, 0..) |each, d| {
            if (each.kind == .variable and each.node == node) return @fromBackingInt(@intCast(d));
        }
        return null;
    }

    /// What the local holds on the paths where `value`, a `bool`, is true: past `and`'s left
    /// side, and in an `if` on a call's error union whose value is `true` where it succeeds and
    /// `false` where it fails, past the call's success. Anything else holds no more.
    fn whenTrue(w: *Walk, value: Ast.Node.Index, state: State) Context.Error!State {
        var now = state;
        for ((try w.c.facts.truthsWhen(w.file, value, true)) orelse return state) |known| {
            if (known.value) now = try w.succeededIn(known.part, now);
        }
        return now;
    }

    /// What the local holds where `value`, an `if` on a call's error union that is `true`
    /// where it succeeds and `false` where it fails, is true: past the call's success.
    fn succeededIn(w: *Walk, value: Ast.Node.Index, state: State) Context.Error!State {
        const tree = w.tree;
        const branch = tree.fullIf(value) orelse return state;
        if (branch.error_token == null) return state;
        if (!try w.isBool(branch.ast.then_expr, true) or !try w.isBool(branch.ast.else_expr.unwrap() orelse return state, false)) return state;
        return w.succeeded(branch.ast.cond_expr, state);
    }

    /// Whether `node` names a declaration called `name` (`Facts.definition`): a capture.
    fn isNamed(w: *const Walk, node: Ast.Node.Index, name: []const u8) Context.Error!bool {
        const id = (try nameOf(w.c.facts, w.file, node)) orelse return false;
        return std.mem.eql(u8, w.model.declarations[@backingInt(id)].name, name);
    }

    /// What a field description's name is read on: `f` of `f.name`, `f` a capture of
    /// `@typeInfo(T).@"struct".fields`. Null for any other node.
    fn descriptionName(w: *const Walk, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
        const read = (try Facts.accesses.memberRead(w.c.facts, w.file, node)) orelse return null;
        if (!std.mem.eql(u8, read.name orelse return null, "name")) return null;
        return read.receiver;
    }

    /// Whether `node` is the literal `value` (`Facts.literalOf`).
    fn isBool(w: *const Walk, node: Ast.Node.Index, value: bool) Context.Error!bool {
        const literal = (try w.c.facts.literalOf(w.file, node)) orelse return false;
        return literal == .boolean and literal.boolean == value;
    }

    /// What the local holds past `call` where it succeeds: written, where what it does with
    /// the local is to write it whole once it succeeds; no more anywhere else.
    fn succeeded(w: *Walk, call: Ast.Node.Index, state: State) Context.Error!State {
        if (state.at != .unwritten) return state;
        var buffer: [1]Ast.Node.Index = undefined;
        _ = w.tree.fullCall(&buffer, call) orelse return state;
        w.succeeding = call;
        defer w.succeeding = null;
        const first = w.tree.firstToken(call);
        const last = w.tree.lastToken(call);
        var now = state;
        for (w.mentions) |mention| {
            const token = w.tree.nodeMainToken(mention);
            if (token < first or token > last) continue;
            const use = (try w.classify(mention)) orelse continue;
            if (use.effect != .write) return state;
            now = .written;
        }
        return now;
    }

    /// What the local holds where `condition` came out `truth`: a flag (`const ok = …`) known
    /// true adds what its being true showed, through `!`, `and` known true and `or` known false.
    fn knowing(w: *const Walk, condition: Ast.Node.Index, state: State, truth: bool) Context.Error!State {
        var now = state;
        for ((try w.c.facts.truthsWhen(w.file, condition, truth)) orelse return state) |known| {
            if (known.value) now = w.flagged(known.part, now);
        }
        return now;
    }

    /// What the local holds where `flag_name`, a name a flag holds, is true.
    fn flagged(w: *const Walk, flag_name: Ast.Node.Index, state: State) State {
        if (state.at != .unwritten) return state;
        const decl = (w.model.reference(flag_name) orelse return state).declaration orelse return state;
        var i = w.flags.items.len;
        while (i > 0) {
            i -= 1;
            const flag = w.flags.items[i];
            if (flag.decl != decl) continue;
            if (flag.state.at == .written) return .written;
            if (flag.state.at != .unwritten) return state;
            const parts = state.parts | flag.state.parts;
            if (parts == w.everyPart() and parts != 0) return .written;
            var known = state;
            known.parts = parts;
            return known;
        }
        return state;
    }

    /// Whether an `inline for` writes the local whole: over every field of the local's own type
    /// (`@typeInfo(T).@"struct".fields`, or `.field_names`, with `T` spelled as the local's type
    /// is), each pass sets the field it is on (`@field(out, f.name) = v`) from what does not
    /// read the local, and nothing in it skips a pass or leaves but by an error. A `comptime`
    /// test that the field is one by name, setting that one by its name and any other by the
    /// capture, sets it too.
    fn setsEveryField(w: *Walk, loop: Ast.full.For) Context.Error!bool {
        const tree = w.tree;
        if (loop.inline_token == null or loop.ast.else_expr != .none) return false;
        const own = w.ownType() orelse return false;
        var list: ?struct { position: usize, by_name: bool } = null;
        for (loop.ast.inputs, 0..) |input, position| {
            if (w.mentioned(input)) return false;
            if (list == null) if (try w.fieldList(input, own)) |by_name| {
                list = .{ .position = position, .by_name = by_name };
            };
        }
        const found = list orelse return false;
        const name = capture(tree, loop.payload_token, found.position, false) orelse return false;
        const body = loop.ast.then_expr;
        var token = tree.firstToken(body);
        while (token <= tree.lastToken(body)) : (token += 1) switch (tree.tokenTag(token)) {
            .keyword_break, .keyword_continue => return false,
            else => {},
        };
        if (w.param and try w.returnsIn(body)) return false;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, body) orelse (&loop.ast.then_expr)[0..1];
        var sets = false;
        for (statements) |each| {
            if (!w.mentioned(each)) continue;
            if (sets or !try w.setsCapture(each, name, found.by_name)) return false;
            sets = true;
        }
        return sets;
    }

    /// The type the local is declared with, or a parameter's single-item pointer points at.
    fn ownType(w: *const Walk) ?Ast.Node.Index {
        const tree = w.tree;
        if (!w.param) return (tree.fullVarDecl(w.model.declarations[@backingInt(w.local)].node) orelse return null).ast.type_node.unwrap();
        const kind = w.c.facts.parameterTypeNode(.{ .file = w.file, .index = w.local }) orelse return null;
        const pointer = tree.fullPtrType(kind) orelse return null;
        return if (pointer.size == .one) pointer.ast.child_type else null;
    }

    /// Whether `input` lists the fields of `own` (`@typeInfo(own).@"struct".fields`), directly
    /// or through a constant (`const info = @typeInfo(own).@"struct"; info.field_names`): true
    /// for their names, false for their descriptions.
    fn fieldList(w: *const Walk, input: Ast.Node.Index, own: Ast.Node.Index) Context.Error!?bool {
        const tree = w.tree;
        if (tree.nodeTag(input) != .field_access) return null;
        const info, const member = tree.nodeData(input).node_and_token;
        const by_name = if (std.mem.eql(u8, tree.tokenSlice(member), "field_names")) true else if (std.mem.eql(u8, tree.tokenSlice(member), "fields")) false else return null;
        var of = info;
        if (tree.nodeTag(of) == .identifier) {
            const ref = w.model.reference(of) orelse return null;
            const decl = w.model.declarations[@backingInt(ref.declaration orelse return null)];
            if (decl.kind != .variable) return null;
            const variable = tree.fullVarDecl(decl.node) orelse return null;
            if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
            of = variable.ast.init_node.unwrap() orelse return null;
        }
        if (tree.nodeTag(of) != .field_access) return null;
        const reflected, const kind = tree.nodeData(of).node_and_token;
        if (!std.mem.eql(u8, tree.tokenSlice(kind), "@\"struct\"") or !Facts.isBuiltin(tree, reflected, "@typeInfo")) return null;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, reflected, &buffer);
        if (args.len != 1 or !try sameTypeNamed(w.c.facts, w.file, args[0], own)) return null;
        return by_name;
    }

    /// Whether `node` sets the field a pass is on from what does not read the local: `@field`
    /// of the local by the capture `name`, or a `comptime` test that the field is one by name
    /// (`if (comptime std.mem.eql(u8, name, "x")) local.x = v else …`) whose branches both do.
    fn setsCapture(w: *Walk, node: Ast.Node.Index, name: []const u8, by_name: bool) Context.Error!bool {
        const tree = w.tree;
        if (try storeAt(w.c.facts, w.file, node)) |set| {
            const value = set.value orelse return false;
            return !w.mentioned(value) and !try holdsUndefined(w.c.facts, w.file, value) and try w.fieldOfCapture(set.target orelse return false, name, by_name);
        }
        const branch = tree.fullIf(node) orelse return false;
        if (branch.payload_token != null or branch.error_token != null) return false;
        const otherwise = branch.ast.else_expr.unwrap() orelse return false;
        const spelled = (try w.namedField(branch.ast.cond_expr, name, by_name)) orelse return false;
        const set = (try storeAt(w.c.facts, w.file, branch.ast.then_expr)) orelse return false;
        const target = set.target orelse return false;
        const value = set.value orelse return false;
        if (w.mentioned(value) or try holdsUndefined(w.c.facts, w.file, value)) return false;
        if (!try w.fieldOfCapture(target, name, by_name) and !try w.fieldNamed(target, spelled)) return false;
        return w.setsCapture(otherwise, name, by_name);
    }

    /// Whether `target` is `@field(local, f.name)` (or `@field(local, name)` for a list of
    /// names), `f` or `name` the capture.
    fn fieldOfCapture(w: *const Walk, target: Ast.Node.Index, name: []const u8, by_name: bool) Context.Error!bool {
        const tree = w.tree;
        if (!Facts.isBuiltin(tree, target, "@field")) return false;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, target, &buffer);
        if (args.len != 2 or !try w.isLocal(args[0])) return false;
        var spelled = args[1];
        if (!by_name) spelled = (try w.descriptionName(spelled)) orelse return false;
        return w.isNamed(spelled, name);
    }

    /// Whether `target` is the local's field `field` by name (`local.x`).
    fn fieldNamed(w: *const Walk, target: Ast.Node.Index, field: []const u8) Context.Error!bool {
        const read = (try Facts.accesses.memberRead(w.c.facts, w.file, target)) orelse return false;
        const name = read.name orelse return false;
        return try w.isLocal(read.receiver.?) and std.mem.eql(u8, name, field); // unreachable: a member's step has its holder
    }

    /// The field a `comptime` test names (`comptime std.mem.eql(u8, f.name, "x")`, the capture
    /// against a literal either way round).
    fn namedField(w: *Walk, condition: Ast.Node.Index, name: []const u8, by_name: bool) Context.Error!?[]const u8 {
        const tree = w.tree;
        if (tree.nodeTag(condition) != .@"comptime") return null;
        const test_node = tree.nodeData(condition).node;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, test_node) orelse return null;
        if (call.ast.params.len != 3 or !try w.isStd(test_node, call, "mem.eql")) return null;
        for ([2][2]usize{ .{ 1, 2 }, .{ 2, 1 } }) |order| {
            var spelled = call.ast.params[order[0]];
            if (!by_name) spelled = (try w.descriptionName(spelled)) orelse continue;
            if (!try w.isNamed(spelled, name)) continue;
            // The one name the other side spells (`Facts.fieldName`).
            return switch (try w.c.facts.fieldName(w.file, call.ast.params[order[1]])) {
                .name => |field| field,
                .each_of, .names, .computed => null,
            };
        }
        return null;
    }

    /// Whether `node` names the local itself, or a parameter's or an alias's pointer's memory
    /// (`p.*`).
    fn isLocal(w: *const Walk, node: Ast.Node.Index) Context.Error!bool {
        var at = node;
        if (Facts.accesses.formOf(w.tree.nodeTag(at)) == .deref) {
            const pointer = w.tree.nodeData(at).node;
            if (try nameOf(w.c.facts, w.file, pointer) != null and w.viaPointer(pointer)) at = pointer;
        }
        const decl = (try nameOf(w.c.facts, w.file, at)) orelse return false;
        return decl == w.local or std.mem.findScalar(Model.Declaration.Id, w.aliases, decl) != null;
    }

    /// Whether `node` is an `if` or a `switch` whose condition tests the result of the call
    /// guarding the local, which writes it on one side.
    fn tests(w: *const Walk, node: Ast.Node.Index, state: State) Context.Error!bool {
        const guard = state.guard orelse return false;
        if (w.tree.fullIf(node)) |branch| return (try w.checks(branch.ast.cond_expr, guard)) != null;
        if (w.tree.fullSwitch(node)) |choice| return try w.errnoOf(choice.ast.condition, guard) != null or try w.isResult(choice.ast.condition, guard);
        return false;
    }

    /// A branch walked from `start`: one a guarding call's check starts written reads nothing
    /// unwritten, and its jumps take it written.
    fn arm(w: *Walk, node: Ast.Node.Index, start: State) Context.Error!State {
        if (start.at != .written) return w.statement(node, start);
        w.jumpsIn(node, start);
        return start;
    }

    /// Opens a construct a `break` may leave for its end.
    fn enter(w: *Walk, node: Ast.Node.Index) Context.Error!void {
        try w.targets.append(w.c.allocator, .{ .node = node });
    }

    /// Closes the innermost construct, whose end what reaches it (`end`) and what the jumps to
    /// it take both reach.
    fn leave(w: *Walk, end: State) State {
        const target = w.targets.pop().?;
        return if (target.exit) |exit| merge(end, exit) else end;
    }

    /// Takes `state` to the end of the construct the `break` or `continue` at `node` goes to,
    /// where that is one being walked. A `continue` to a labeled `switch` dispatches again, to
    /// its prongs, with `state`.
    fn jump(w: *Walk, node: Ast.Node.Index, state: State) void {
        const tag = w.tree.nodeTag(node);
        if (tag != .@"break" and tag != .@"continue") return;
        const goes = jumpTarget(w.tree, w.model, node) orelse return;
        const redispatch = tag == .@"continue" and w.tree.fullSwitch(goes) != null;
        var i = w.targets.items.len;
        while (i > 0) {
            i -= 1;
            const target = &w.targets.items[i];
            if (target.node != goes) continue;
            if (redispatch) {
                target.again = if (target.again) |again| merge(again, state) else state;
            } else {
                target.exit = if (target.exit) |exit| merge(exit, state) else state;
            }
            return;
        }
    }

    /// Whether a `continue` in a labeled `switch` dispatches it again.
    fn continuedTo(w: *const Walk, node: Ast.Node.Index) bool {
        const tree = w.tree;
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .@"continue") continue;
            const each: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const at = tree.nodeMainToken(each);
            if (at < first or at > last) continue;
            if (jumpTarget(tree, w.model, each) == node) return true;
        }
        return false;
    }

    /// Takes `state` to where each `break` or `continue` in `node` goes, for a statement the
    /// walk does not follow step by step: what it holds there is no less.
    fn jumpsIn(w: *Walk, node: Ast.Node.Index, state: State) void {
        const tree = w.tree;
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        var token = first;
        while (token <= last) : (token += 1) switch (tree.tokenTag(token)) {
            .keyword_break, .keyword_continue => break,
            else => {},
        } else return;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .@"break" and tag != .@"continue") continue;
            const each: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const at = tree.nodeMainToken(each);
            if (at >= first and at <= last) w.jump(each, state);
        }
    }

    /// A statement without control flow of its own: its mentions in evaluation order, an
    /// assignment's target after its value. A write in a part of it that runs on some paths
    /// only (a branch, past `orelse`, a labeled block) writes nothing for what follows. A
    /// parameter's walk takes a `return` inside it (`x catch return`) as one with the memory
    /// unwritten.
    fn simple(w: *Walk, node: Ast.Node.Index, state: State) Context.Error!State {
        const first = w.tree.firstToken(node);
        const last = w.tree.lastToken(node);
        for (w.returns) |each| {
            if (each == node or !try w.exitsBy(each)) continue;
            const token = w.tree.firstToken(each);
            if (token >= first and token <= last) try w.exited(each);
        }
        // A `try` in it returns its error with the memory as it is here.
        if (w.every_exit) for (w.tries) |each| {
            const token = w.tree.firstToken(each);
            if (token >= first and token <= last) try w.exited(each);
        };
        w.jumpsIn(node, state);
        if (try w.readAtExits(node, state)) return .done;
        const Found = struct {
            use: Use,
            token: Ast.TokenIndex,
            fn before(_: void, a: @This(), b: @This()) bool {
                return a.use.key < b.use.key;
            }
        };
        var uses: std.ArrayList(Found) = .empty;
        defer uses.deinit(w.c.allocator);
        for (w.mentions) |mention| {
            const token = w.tree.nodeMainToken(mention);
            if (token < first or token > last) continue;
            var use = (try w.classify(mention)) orelse continue;
            switch (use.effect) {
                .write, .set, .guarded => if (conditional(w.tree, w.model, mention, node)) continue,
                // Assigned on some paths only, what it leaves undefined is so on those.
                .reset => |left| if (conditional(w.tree, w.model, mention, node)) {
                    use.effect = .{ .unset = left };
                },
                else => {},
            }
            try uses.append(w.c.allocator, .{ .use = use, .token = token });
        }
        for (w.outputs.items) |output| {
            if (output.token < first or output.token > last) continue;
            if (conditional(w.tree, w.model, output.asm_node, node)) continue;
            try uses.append(w.c.allocator, .{ .use = .{ .key = w.tree.lastToken(output.asm_node), .effect = .write }, .token = output.token });
        }
        std.mem.sort(Found, uses.items, {}, Found.before);
        var now = state;
        for (uses.items, 0..) |found, at_use| switch (found.use.effect) {
            .write => return .written,
            // What follows it in the statement reads it only where its result checks.
            .guarded => |guard| {
                for (uses.items[at_use + 1 ..]) |later| switch (later.use.effect) {
                    .write, .set, .guarded, .unset, .reset => {},
                    .read, .handed, .get, .needs => {
                        if (try w.behind(w.mentionAt(later.token) orelse node, guard, node)) continue;
                        w.read = later.token;
                        w.handed = later.use.effect != .read and later.use.effect != .get;
                        return .done;
                    },
                };
                return .{ .at = .unwritten, .parts = now.parts, .guard = guard };
            },
            .set => |at| {
                now.parts |= @as(u64, 1) << at;
                if (now.parts == w.everyPart()) return .written;
            },
            .unset => |left| now.parts &= ~left,
            .reset => |left| {
                now.parts = w.everyPart() & ~left;
                now.guard = null;
            },
            .get => |at| if (now.parts & (@as(u64, 1) << at) == 0) {
                if (w.needing) {
                    w.needed |= @as(u64, 1) << at;
                    continue;
                }
                w.read = found.token;
                return .done;
            },
            // Handed to a function that reads these parts of it.
            .needs => |mask| if (mask & ~now.parts != 0) {
                if (w.needing) {
                    w.needed |= mask & ~now.parts;
                    continue;
                }
                w.read = found.token;
                w.handed = true;
                return .done;
            },
            .read, .handed => {
                w.read = found.token;
                w.handed = found.use.effect == .handed;
                return .done;
            },
        };
        return now;
    }

    /// What a mention does to the local, and where it falls in evaluation order; null where it
    /// neither reads it nor writes all of it: an array's `.len`, known as the program compiles,
    /// a part of it set, or it kept by a call that reads only what it writes there.
    fn classify(w: *Walk, mention: Ast.Node.Index) Context.Error!?Use {
        const tree = w.tree;
        const key = tree.nodeMainToken(mention);
        const read: Use = .{ .key = key, .effect = .read };
        // What `@TypeOf` is given is only typed, never run: the local's type, or a call that
        // would write or read it, as the program compiles.
        if (unevaluated(tree, w.model, mention)) return null;
        const facts = w.c.facts;
        switch (try Facts.accesses.useOf(facts, w.file, mention)) {
            .member => |access| {
                // A method called on it is handed it as its receiver.
                switch (try Facts.accesses.useOf(facts, w.file, access)) {
                    .callee => |made| {
                        var buffer: [1]Ast.Node.Index = undefined;
                        const call = tree.fullCall(&buffer, made) orelse return read; // unreachable: a callee's node is a call's
                        return try w.handedTo(made, call, 0, true, true, key);
                    },
                    else => {},
                }
                // A parameter's slice or array pointer carries its own length.
                if ((try facts.lengthOf(w.file, access)) != null and (w.viaPointer(mention) or try w.array())) return null;
                return w.part(access, try w.partAt(access, true), true, key);
            },
            .element => |access| return w.part(access, try w.partAt(access, false), false, key),
            // A parameter given another address no longer names the caller's memory.
            .written => |site| {
                if (w.viaPointer(mention)) return read;
                return try w.assignedWhole(site.node, site.value orelse return read);
            },
            // Its value given to another place: read.
            .stored, .index => return read,
            .dereferenced => |pointee| {
                if (!w.viaPointer(mention)) return read;
                return switch (try Facts.accesses.useOf(facts, w.file, pointee)) {
                    .written => |site| try w.assignedWhole(site.node, site.value orelse return read),
                    .member => |access| w.part(access, try w.partAt(access, true), true, key),
                    .element => |access| w.part(access, try w.partAt(access, false), false, key),
                    else => read,
                };
            },
            .address => |address| return if (w.viaPointer(mention)) read else try w.given(address, true, key),
            .sliced => |slice| {
                // `buf[0..n]` with n the count a call that wrote that prefix returned.
                if (try w.countedPrefix(slice)) return null;
                return try w.given(slice, try w.allOf(slice), key);
            },
            // `@field(local, name) = v` sets the field it names; a name spelled out is that
            // part, read in place.
            .builtin_argument => |argument| if (argument.position == 0 and Facts.isBuiltin(tree, argument.call, "@field")) {
                const at = try w.fieldSpelled(argument.call);
                switch (try Facts.accesses.useOf(facts, w.file, argument.call)) {
                    .written => |site| {
                        const value = site.value orelse return read;
                        if (try holdsUndefined(w.c.facts, w.file, value)) return .{ .key = tree.lastToken(site.node), .effect = .{ .unset = if (at) |part_at| @as(u64, 1) << part_at else std.math.maxInt(u64) } };
                        return .{ .key = tree.lastToken(site.node), .effect = .{ .set = at orelse return null } };
                    },
                    .address, .member => return read,
                    else => return .{ .key = key, .effect = .{ .get = at orelse return read } },
                }
            },
            else => {},
        }
        // A parameter's pointer, or an alias, handed on hands on the memory it points at.
        return if (w.viaPointer(mention)) try w.given(mention, true, key) else read;
    }

    /// What assigning `value` to all of the local at `assign` does: writes it, or all of it but
    /// what the value leaves undefined.
    fn assignedWhole(w: *const Walk, assign: Ast.Node.Index, value: Ast.Node.Index) Context.Error!Use {
        const key = w.tree.lastToken(assign);
        const left = try w.undefinedIn(value);
        return if (left == 0) .{ .key = key, .effect = .write } else .{ .key = key, .effect = .{ .reset = left } };
    }

    /// Whether `access`, a field or an element of the local (through a parameter's pointer),
    /// is set by an assignment: a part written, the local's own memory, not a pointer it holds.
    fn partSet(w: *Walk, access: Ast.Node.Index, field: bool) Context.Error!bool {
        const site = (try writtenAt(w.c.facts, w.file, access)) orelse return false;
        if (Facts.accesses.formOf(w.tree.nodeTag(site.node)) != .assign) return false;
        if (try w.throughPointer(access)) return true;
        return if (field) w.structure() else try w.array();
    }

    /// What handing `memory` (`&local`, a slice of it, a parameter's pointer) to what holds it
    /// does: a write where all of it is written, nothing where a part is or std keeps it, a
    /// read anywhere else.
    fn given(w: *Walk, memory: Ast.Node.Index, whole: bool, key: Ast.TokenIndex) Context.Error!?Use {
        const tree = w.tree;
        const handed: Use = .{ .key = key, .effect = .handed };
        const parent = w.model.parentOf(memory) orelse return handed;
        // `var w: Writer = .{ .bytes = &buf }`: a cursor writer's memory, which it reads only
        // below the count of what it wrote there, where the writer it makes is kept.
        if (try w.cursorAt(parent, memory) != null and try w.keptWriter(parent)) return null;
        const facts = w.c.facts;
        var buffer: [1]Ast.Node.Index = undefined;
        switch (try Facts.accesses.useOf(facts, w.file, memory)) {
            .builtin_argument => |argument| {
                if (argument.position != 0) return handed;
                const name = Facts.builtinName(tree, argument.call) orelse return handed; // unreachable: a builtin's argument
                if (!std.mem.eql(u8, name, "@memset") and !std.mem.eql(u8, name, "@memcpy")) return handed;
                var params: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, argument.call, &params);
                // `@memset(&x, undefined)`: what it is given undefined again.
                if (std.mem.eql(u8, name, "@memset") and args.len == 2 and try holdsUndefined(w.c.facts, w.file, args[1])) {
                    const all = std.math.maxInt(u64);
                    return .{ .key = tree.lastToken(argument.call), .effect = if (whole) .{ .reset = all } else .{ .unset = all } };
                }
                return if (whole) .{ .key = tree.lastToken(argument.call), .effect = .write } else null;
            },
            .argument => |argument| {
                const call = tree.fullCall(&buffer, argument.call) orelse return handed; // unreachable: a call's argument
                // `std.mem.asBytes(&x)`: all of x's bytes, handed on as the view is.
                if (whole and call.ast.params.len == 1 and try w.isStd(argument.call, call, "mem.asBytes")) return w.given(argument.call, true, key);
                return w.handedTo(argument.call, call, argument.position, false, whole, key);
            },
            .looped => |looped| return try w.forSets(looped.loop, tree.fullFor(looped.loop) orelse return handed, memory, whole, key),
            // `&.{&buf}`: a vector of buffers a call is given, each of which it is given.
            .element_of => |element| {
                var elements: [2]Ast.Node.Index = undefined;
                const literal = tree.fullArrayInit(&elements, element.literal) orelse return handed;
                if (literal.ast.type_expr != .none) return handed;
                const address = switch (try Facts.accesses.useOf(facts, w.file, element.literal)) {
                    .address => |address| address,
                    else => return handed,
                };
                return switch (try Facts.accesses.useOf(facts, w.file, address)) {
                    .argument => |argument| w.handedTo(argument.call, tree.fullCall(&buffer, argument.call) orelse return handed, argument.position, false, false, key),
                    else => handed,
                };
            },
            else => return handed,
        }
    }

    /// What a call does with the memory it is given at argument `position` (or as its
    /// `receiver`): std's named fills and keeps, or the program's own function read for it.
    fn handedTo(w: *Walk, node: Ast.Node.Index, call: Ast.full.Call, position: usize, receiver: bool, whole: bool, key: Ast.TokenIndex) Context.Error!?Use {
        const tree = w.tree;
        const handed: Use = .{ .key = key, .effect = .handed };
        const origin = (try w.callee(node, call)) orelse {
            if (receiver) return handed;
            return switch ((try w.chosen(node, call, position)) orelse return handed) {
                .keep => null,
                .fill => if (whole) .{ .key = tree.lastToken(node), .effect = .write } else null,
                .contract => |entry| if (entry.success == .count or !whole) null else try w.guarded(node, entry),
            };
        };
        const index = if (receiver) 0 else try parameterAt(w.c, w.file, call, position) orelse return handed;
        const written: Use = .{ .key = tree.lastToken(node), .effect = .write };
        const leaves = try w.failureLeaves(node, origin);
        if (try named(w.c, &std_fills, origin, index)) return if (whole and leaves) written else null;
        if (try named(w.c, &std_holders, origin, index)) return if (try holderKept(w.c, w.file, node, w.depth)) null else handed;
        if (try named(w.c, &std_keeps, origin, index)) return null;
        // A count given all of the local writes it all where its result is that length.
        if (try named(w.c, &std_counts, origin, index)) return if (whole and leaves) .{ .key = tree.lastToken(node), .effect = .{ .guarded = .{ .call = node, .entry = &counted_whole, .binding = w.resultConstant(node) } } } else null;
        for (std_halving) |each| {
            if (!try named(w.c, &.{.{ .path = each.path, .param = each.param }}, origin, index)) continue;
            const at = each.input + position - index;
            if (at >= call.ast.params.len) return null;
            return if (whole and leaves and try w.twiceAsLong(node, call.ast.params[at])) written else null;
        }
        // A call outside the program writes what its contract names, on the results it names:
        // a count's prefix, or a part, is kept; all of the local is written where it checks.
        if (try CContract.find(w.c, origin, index)) |entry| {
            if (entry.success == .count or !whole) return null;
            // The call writes what the header says it points at: all of the local only where
            // the local is that type.
            if (!try w.typed(entry, index, false)) return handed;
            return try w.guarded(node, entry);
        }
        // std's own: what it reads of what it is given, where that is known; nothing it writes
        // is taken as written.
        if (!try Program.owns(w.c, origin.file)) return try w.reading(origin, index, whole, key) orelse handed;
        if (try writesWhole(w.c, origin, index, w.depth + 1)) return if (whole and leaves) written else null;
        // What it returns may hold what it keeps: followed here as a holder.
        if (try keepsOnly(w.c, origin, index, w.depth + 1)) {
            if (!holdsResult(try w.c.facts.resolve(w.file, node))) return null;
            return if (try holderKept(w.c, w.file, node, w.depth)) null else handed;
        }
        if (try writesParts(w.c, origin, index, w.depth + 1)) return null;
        return try w.reading(origin, index, whole, key) orelse handed;
    }

    /// A function given all of the local, through a pointer to its type, that reads only some
    /// of its parts: reads those (`needs`). Null where what it reads is not known.
    fn reading(w: *Walk, origin: Facts.Decl, index: usize, whole: bool, key: Ast.TokenIndex) Context.Error!?Use {
        if (!whole) return null;
        const owner = w.owner orelse return null;
        const found = (try needs(w.c, origin, index, w.depth + 1)) orelse return null;
        if (!std.meta.eql(owner, found.owner)) return null;
        return .{ .key = key, .effect = .{ .needs = found.mask } };
    }

    /// What a call to a choice of functions made per build does with what it is given at
    /// `position` (std's `c.fstatat`, a program's `if (x86_64) statfs64 else statfs`, a hasher
    /// a type function picks by a `switch`): every alternative one of std's fills whose failure
    /// leaves where the call is, every one a keep or a count, or every one a function outside
    /// the program whose contract writes it, of the local's type, all alike in when; null where
    /// they differ or one is none of these. Each keeps its own failure: one that can fail where
    /// another cannot is one the build may take.
    fn chosen(w: *Walk, node: Ast.Node.Index, call: Ast.full.Call, position: usize) Context.Error!?Choice {
        const value = try w.c.facts.resolve(w.file, call.ast.fn_expr);
        if (value != .alternatives) return null;
        var found: ?Choice = null;
        for (Facts.valueParts(&value)) |each| {
            if (each != .function) return null;
            const origin = each.function;
            const index = try parameterAt(w.c, w.file, call, position) orelse return null;
            const this: Choice = if (try named(w.c, &std_fills, origin, index)) fill: {
                if (!try w.failureLeaves(node, origin)) return null;
                break :fill .{ .fill = origin };
            } else if (try named(w.c, &std_holders, origin, index)) holder: {
                if (!try holderKept(w.c, w.file, node, w.depth)) return null;
                break :holder .keep;
            } else if (try named(w.c, &std_keeps, origin, index) or try named(w.c, &std_counts, origin, index))
                .keep
            else if (try CContract.find(w.c, origin, index)) |entry| contract: {
                if (!try w.typed(entry, index, entry.success == .count)) return null;
                break :contract .{ .contract = entry };
            } else return null;
            if (found) |sofar| {
                if (std.meta.activeTag(sofar) != std.meta.activeTag(this)) return null;
                if (sofar == .contract and !std.meta.eql(sofar.contract.success, this.contract.success)) return null;
            } else found = this;
        }
        return found;
    }

    /// Whether a call reaches std's declaration at `path`.
    fn isStd(w: *Walk, node: Ast.Node.Index, call: Ast.full.Call, path: []const u8) Context.Error!bool {
        const decl = (try w.callee(node, call)) orelse return false;
        return try stdAt(w.c, decl, path) == .yes;
    }

    /// The function a call reaches: by its name, or a declaration literal (`.fixed(&buf)`) by
    /// the container its result location names.
    fn callee(w: *Walk, node: Ast.Node.Index, call: Ast.full.Call) Context.Error!?Facts.Decl {
        const literal: ?[]const u8 = if (try w.c.facts.literalOf(w.file, call.ast.fn_expr)) |known| switch (known) {
            .enum_literal => |name| name,
            else => null,
        } else null;
        const name = literal orelse return switch (try w.c.facts.resolve(w.file, call.ast.fn_expr)) {
            .function => |decl| decl,
            // A choice of functions is no one callee: `callees` and `chosen` read each.
            .alternatives => null,
            else => null,
        };
        const container = (try w.c.facts.resultContainer(w.file, node)) orelse return null;
        const decl = w.c.facts.member(container, name) orelse return null;
        return switch (try w.c.facts.declaration(decl)) {
            .function => |function| function,
            // A declaration literal's choice of functions: no one callee, as above.
            .alternatives => null,
            else => null,
        };
    }

    /// Whether a call that may fail leaves where it does: its error is `try`'s to return, or a
    /// `catch` that returns or cannot go on (`catch return`, `catch unreachable`).
    fn failureLeaves(w: *Walk, node: Ast.Node.Index, function: Facts.Decl) Context.Error!bool {
        if (w.succeeding == node) return true;
        const tree = &w.c.project.at(function.file).file.tree;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, w.c.project.at(function.file).model.declarations[@backingInt(function.index)].node) orelse return false;
        const result = proto.ast.return_type.unwrap() orelse return false;
        if (!try mayFail(w.c.facts, function.file, result)) return true;
        const parent = w.model.parentOf(node) orelse return false;
        return switch (w.tree.nodeTag(parent)) {
            .@"try" => true,
            .@"catch" => {
                const lhs, const rhs = w.tree.nodeData(parent).node_and_node;
                return lhs == node and switch (w.tree.nodeTag(rhs)) {
                    .@"return", .unreachable_literal => true,
                    else => false,
                };
            },
            else => false,
        };
    }

    /// A `for` over all of `memory` whose body, each pass, sets the element its pointer
    /// capture names before anything else could read it or leave the pass, from what reads
    /// neither it nor the local (`for (&buf, 0..) |*b, i| b.* = f(i)`), and runs every pass
    /// (`passesAll`), writes it whole once it ends: Zig runs a `for` over inputs of one length.
    /// Over a part, that part.
    fn forSets(w: *Walk, node: Ast.Node.Index, loop: Ast.full.For, memory: Ast.Node.Index, whole: bool, key: Ast.TokenIndex) Context.Error!?Use {
        const tree = w.tree;
        const handed: Use = .{ .key = key, .effect = .handed };
        if (loop.ast.else_expr != .none or w.mentioned(loop.ast.then_expr)) return handed;
        const position = std.mem.findScalar(Ast.Node.Index, loop.ast.inputs, memory) orelse return handed;
        const slot = captureAt(tree, w.model, node, loop, position, true) orelse return handed;
        const facts = w.c.facts;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, loop.ast.then_expr) orelse (&loop.ast.then_expr)[0..1];
        for (statements) |each| {
            // Before it, only what neither reads the element nor leaves the pass.
            if (refers(w.model, tree, each, slot) or leavesPass(tree, each)) {
                // The element set through the capture (`b.* = v`), from what reads it not.
                const pointee = for (w.model.references) |reference| {
                    if (reference.declaration != slot or reference.token < tree.firstToken(each) or reference.token > tree.lastToken(each)) continue;
                    switch (try Facts.accesses.useOf(facts, w.file, reference.node)) {
                        .dereferenced => |pointee| break pointee,
                        else => return handed,
                    }
                } else return handed;
                const site = switch (try Facts.accesses.useOf(facts, w.file, pointee)) {
                    .written => |site| site,
                    else => return handed,
                };
                if (site.node != each) return handed;
                const value = site.value orelse return handed;
                if (refers(w.model, tree, value, slot) or leavesPass(tree, value)) return handed;
                if (!try w.passesAll(node, loop.ast.then_expr)) return handed;
                if (try holdsUndefined(w.c.facts, w.file, value)) {
                    const all = std.math.maxInt(u64);
                    return .{ .key = tree.lastToken(node), .effect = if (whole) .{ .reset = all } else .{ .unset = all } };
                }
                return if (whole) .{ .key = tree.lastToken(node), .effect = .write } else null;
            }
        }
        return handed;
    }

    /// Whether nothing in the body of the `for` at `loop` ends its passes before the last: no
    /// `break` out of the body, no `continue` to a loop around it, and in a parameter's walk no
    /// `return` but an error's, which would hand the caller the elements no pass set.
    fn passesAll(w: *const Walk, loop: Ast.Node.Index, body: Ast.Node.Index) Context.Error!bool {
        const tree = w.tree;
        const first = tree.firstToken(body);
        const last = tree.lastToken(body);
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .@"break" and tag != .@"continue") continue;
            const each: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const at = tree.nodeMainToken(each);
            if (at < first or at > last) continue;
            const goes = jumpTarget(tree, w.model, each) orelse return false;
            const inside = tree.firstToken(goes) >= first and tree.lastToken(goes) <= last;
            if (inside) continue;
            if (tag == .@"continue" and goes == loop) continue;
            return false;
        }
        return !w.param or !try w.returnsIn(body);
    }

    /// Whether `slice` is the local from zero to a count one of std's calls returned of what
    /// it wrote there (`const n = try file.readStreaming(io, &.{&buf}); buf[0..n]`): the count
    /// a constant or the call itself, its call given the local itself, alone, at the position
    /// the call writes; a failure that gives a count gives 0.
    fn countedPrefix(w: *Walk, slice: Ast.Node.Index) Context.Error!bool {
        const tree = w.tree;
        const full = tree.fullSlice(slice) orelse return false;
        if (full.ast.sentinel != .none) return false;
        if (try w.constant(full.ast.start) != 0) return false;
        var end = full.ast.end.unwrap() orelse return false;
        // `@intCast(n)`: the same count, or a checked stop.
        if (Facts.isBuiltin(tree, end, "@intCast")) {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, end, &buffer);
            if (args.len != 1) return false;
            end = args[0];
        }
        const facts = w.c.facts;
        // `buf[0..w.pos]`: the count of a cursor writer given all of the local.
        if ((try Facts.accesses.pathOf(facts, w.file, end)).steps[0].kind == .field) return w.cursorCounted(end);
        // `buf[0..std.fmt.printInt(&buf, …)]`: the count the call returns, read where it returns.
        var source = end;
        if (w.model.reference(end)) |reference| {
            const index = reference.declaration orelse return false;
            const count = w.model.declarations[@backingInt(index)];
            if (count.kind != .variable) return false;
            const variable = tree.fullVarDecl(count.node) orelse return false;
            if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return try w.appended(index);
            source = variable.ast.init_node.unwrap() orelse return false;
        }
        // What gives the count (`valuesOf`): the one call, through `try`, and a failure that
        // leaves (`catch return`) or gives 0.
        var buffer: [1]Ast.Node.Index = undefined;
        const leaves = switch (try Facts.accesses.valuesOf(facts, w.file, source)) {
            .leaves => |each| each,
            .unknown => return false,
        };
        var made: ?Ast.Node.Index = null;
        for (leaves) |leaf| {
            if (tree.fullCall(&buffer, leaf) != null) {
                if (made != null) return false;
                made = leaf;
            } else if (try w.constant(leaf) != 0) return false;
        }
        source = made orelse return false;
        const call = tree.fullCall(&buffer, source) orelse return false; // unreachable: `made` is a call
        const origin = (try w.callee(source, call)) orelse return false;
        // A method called on a value takes it first (`Facts.calls`): the arguments start one on.
        const made_call = (try Facts.calls.at(w.c.facts, w.file, source)) orelse return false; // unreachable: `made` is a call
        const offset: usize = switch (made_call.receiver) {
            .bound => 1,
            .none, .unknown => 0,
        };
        for (call.ast.params, 0..) |arg, position| {
            const counts = try named(w.c, &std_counts, origin, position + offset) or
                if (try CContract.find(w.c, origin, position + offset)) |entry| entry.success == .count and try w.typed(entry, position + offset, true) else false;
            if (!counts) continue;
            if (try w.namesAlone(arg)) return true;
        }
        return false;
    }

    /// Whether `count`, a `var` the slice ends at, counts the elements of the local written from
    /// its start: it begins at 0, and every change to it is `count += 1` right after the
    /// statement before it in its block sets `local[count]`, so each step past an element
    /// follows that element's write. Its address is never taken.
    fn appended(w: *const Walk, count: Model.Declaration.Id) Context.Error!bool {
        const tree = w.tree;
        if (!w.within(w.model.declarations[@backingInt(count)].node)) return false;
        const variable = tree.fullVarDecl(w.model.declarations[@backingInt(count)].node) orelse return false;
        if (try w.constant(variable.ast.init_node.unwrap() orelse return false) != 0) return false;
        const facts = w.c.facts;
        for (w.model.references) |reference| {
            if (reference.declaration != count) continue;
            switch (try Facts.accesses.useOf(facts, w.file, reference.node)) {
                .address, .written, .unknown => return false,
                // `count += 1`, checked, right after the element it steps past is set.
                .updated => |site| {
                    const operator = switch (site.operator orelse return false) {
                        .op => |op| op,
                        .unknown => return false,
                    };
                    if (operator.op != .add or operator.overflow != .checked) return false;
                    if (try w.constant(site.value orelse return false) != 1 or !try w.followsSet(site.node, count)) return false;
                },
                else => {},
            }
        }
        return true;
    }

    /// Whether `node`, a declaration, lives no longer than the local: after it in the block
    /// that holds it, so that each time the local is made afresh (a loop's pass) so is it.
    /// Anything in a parameter's function is.
    fn within(w: *const Walk, node: Ast.Node.Index) bool {
        if (w.param) return true;
        const tree = w.tree;
        const own = w.model.declarations[@backingInt(w.local)].node;
        const block = w.model.parentOf(own) orelse return false;
        if (!isBlock(tree, block)) return false;
        return tree.firstToken(node) > tree.lastToken(own) and tree.lastToken(node) <= tree.lastToken(block);
    }

    /// Whether the statement before `step` in its block is `local[count] = …`.
    fn followsSet(w: *const Walk, step: Ast.Node.Index, count: Model.Declaration.Id) Context.Error!bool {
        const tree = w.tree;
        const block = w.model.parentOf(step) orelse return false;
        if (!isBlock(tree, block)) return false;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, block) orelse return false;
        const at = std.mem.findScalar(Ast.Node.Index, statements, step) orelse return false;
        if (at == 0) return false;
        const set = statements[at - 1];
        const facts = w.c.facts;
        for (w.model.references) |reference| {
            if (reference.declaration != count or reference.token < tree.firstToken(set) or reference.token > tree.lastToken(set)) continue;
            const access = switch (try Facts.accesses.useOf(facts, w.file, reference.node)) {
                .index => |access| access,
                else => continue,
            };
            // The element of the local the count indexes (no slice's bound), set by that
            // statement.
            const steps = (try Facts.accesses.pathOf(facts, w.file, access)).steps;
            if (steps.len < 2 or steps[0].kind != .index or steps[0].index != reference.node or !try w.isLocal(steps[1].node)) continue;
            switch (try Facts.accesses.useOf(facts, w.file, access)) {
                .written => |site| if (site.node == set) return true,
                else => {},
            }
        }
        return false;
    }

    /// The cursor writer a struct literal makes where `value` is what it gives the writer's
    /// memory field (`.{ .bytes = &buf }`): its type's fields as `cursorCount` finds them, the
    /// literal giving the count 0 where it names it. Null where it is no such writer.
    fn cursorAt(w: *Walk, literal: Ast.Node.Index, value: Ast.Node.Index) Context.Error!?Cursor {
        const tree = w.tree;
        var buffer: [2]Ast.Node.Index = undefined;
        const made = tree.fullStructInit(&buffer, literal) orelse return null;
        if (std.mem.findScalar(Ast.Node.Index, made.ast.fields, value) == null) return null;
        const container = if (made.ast.type_expr.unwrap()) |type_expr| switch (try w.c.facts.resolve(w.file, type_expr)) {
            .container => |found| found,
            // A choice of types is no one writer's: the literal is read as any other.
            .alternatives => return null,
            else => return null,
        } else (try w.c.facts.resultContainer(w.file, literal)) orelse return null;
        const facts = w.c.facts;
        const memory = facts.member(container, (try fieldNameOf(facts, w.file, value)) orelse return null) orelse return null;
        const source = w.c.project.at(memory.file);
        if (source.model.declarations[@backingInt(memory.index)].kind != .field) return null;
        const count = (try cursorCount(w.c, container, memory)) orelse return null;
        for (made.ast.fields) |field| {
            if (!std.mem.eql(u8, (try fieldNameOf(facts, w.file, field)) orelse return null, count)) continue;
            if (try w.constant(field) != 0) return null;
        }
        return .{ .memory = source.model.declarations[@backingInt(memory.index)].name, .count = count };
    }

    /// Whether `end` (`w.pos`) is the count of a cursor writer declared over all of the local
    /// (`var w: Writer = .{ .bytes = &buf }`) that still holds it: the writer is never
    /// assigned over, and only its fields are named, or its address handed to the program's
    /// functions that do the same with it (`keepsWriter`).
    fn cursorCounted(w: *Walk, end: Ast.Node.Index) Context.Error!bool {
        const tree = w.tree;
        // `w.pos`: a member of a name, the writer.
        const steps = (try Facts.accesses.pathOf(w.c.facts, w.file, end)).steps;
        if (steps.len != 2 or steps[0].kind != .field or steps[1].kind != .root) return false;
        const name = steps[0].name orelse return false;
        const writer = (w.model.reference(steps[1].node) orelse return false).declaration orelse return false;
        const record = w.model.declarations[@backingInt(writer)];
        if (record.kind != .variable) return false;
        const variable = tree.fullVarDecl(record.node) orelse return false;
        const literal = variable.ast.init_node.unwrap() orelse return false;
        var buffer: [2]Ast.Node.Index = undefined;
        const made = tree.fullStructInit(&buffer, literal) orelse return false;
        const counts = for (made.ast.fields) |field| {
            if (!try w.namesAlone(field)) continue;
            const cursor = (try w.cursorAt(literal, field)) orelse return false;
            break std.mem.eql(u8, cursor.count, name);
        } else false;
        if (!counts) return false;
        return w.keptWriter(literal);
    }

    /// Whether the struct literal `literal` makes a writer that is kept over what it is given:
    /// it is a local `var` or `const`'s value, and each mention of that local names one of its
    /// fields, calls a method on it, or hands its address to the program's functions that do
    /// the same (`keepsWriterAt`). A literal made anywhere else (returned, stored, handed on)
    /// is followed no further, so it is not.
    fn keptWriter(w: *Walk, literal: Ast.Node.Index) Context.Error!bool {
        const tree = w.tree;
        const holder = w.model.parentOf(literal) orelse return false;
        const variable = tree.fullVarDecl(holder) orelse return false;
        if (variable.ast.init_node.unwrap() != literal) return false;
        const writer: Model.Declaration.Id = for (w.model.declarations, 0..) |each, d| {
            if (each.kind == .variable and each.node == holder) break @fromBackingInt(@intCast(d));
        } else return false;
        for (w.model.references) |reference| {
            if (reference.declaration != writer) continue;
            if (!try keepsWriterAt(w.c, w.file, reference.node, w.depth + 1)) return false;
        }
        return true;
    }

    /// Whether `arg` is the local's address (`&buf`), all of it sliced, or a vector of it
    /// alone (`&.{&buf}`).
    fn namesAlone(w: *const Walk, arg: Ast.Node.Index) Context.Error!bool {
        const tree = w.tree;
        const formOf = Facts.accesses.formOf;
        var at = arg;
        if (formOf(tree.nodeTag(at)) == .address_of) {
            const inner = tree.nodeData(at).node;
            var elements: [2]Ast.Node.Index = undefined;
            if (tree.fullArrayInit(&elements, inner)) |literal| {
                if (literal.ast.elements.len != 1) return false;
                at = literal.ast.elements[0];
            }
        }
        if (formOf(tree.nodeTag(at)) == .address_of) at = tree.nodeData(at).node else if (tree.fullSlice(at)) |full| {
            if (!try w.allOf(at)) return false;
            at = full.ast.sliced;
        }
        const ref = w.model.reference(at) orelse return false;
        return ref.declaration == w.local;
    }

    /// Whether a slice of the local is all of it: from zero, to its end or its length.
    fn allOf(w: *const Walk, slice: Ast.Node.Index) Context.Error!bool {
        const tree = w.tree;
        const full = tree.fullSlice(slice) orelse return false;
        if (full.ast.sentinel != .none) return false;
        if (try w.constant(full.ast.start) != 0) return false;
        const end = full.ast.end.unwrap() orelse return true;
        return w.lengthOf(end, w.local);
    }

    /// Whether the local is declared an array, whose length its type holds.
    fn array(w: *const Walk) Context.Error!bool {
        return (try w.localArray()) != null;
    }

    /// The array type the local is declared, through the names that spell it (`Facts.arrayType`).
    fn localArray(w: *const Walk) Context.Error!?Facts.ArrayType {
        const variable = w.tree.fullVarDecl(w.model.declarations[@backingInt(w.local)].node) orelse return null;
        return w.c.facts.arrayType(w.file, variable.ast.type_node.unwrap() orelse return null);
    }

    /// The length the local's array type fixes, where it is a constant (`Range.constantValue`).
    fn localLength(w: *const Walk) Context.Error!?u64 {
        const array_type = (try w.localArray()) orelse return null;
        return Range.constantValue(w.c, array_type.file, array_type.length orelse return null);
    }

    /// Whether the local is declared of a struct type by name, whose fields are its own memory.
    fn structure(w: *Walk) bool {
        const variable = w.tree.fullVarDecl(w.model.declarations[@backingInt(w.local)].node) orelse return false;
        const kind = variable.ast.type_node.unwrap() orelse return false;
        const value = w.c.facts.resolve(w.file, kind) catch return false;
        return value == .container;
    }

    /// The innermost `asm` expression whose tokens hold `token`.
    fn enclosingAsm(w: *const Walk, token: Ast.TokenIndex) ?Ast.Node.Index {
        var found: ?Ast.Node.Index = null;
        for (w.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .@"asm") continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (token < w.tree.firstToken(node) or token > w.tree.lastToken(node)) continue;
            if (found == null or w.tree.firstToken(node) > w.tree.firstToken(found.?)) found = node;
        }
        return found;
    }

    /// The length a local declared an array of a constant length has.
    fn arrayLength(w: *const Walk) Context.Error!?u64 {
        return w.localLength();
    }

    /// Whether `node` is the length of the local's memory (`Facts.lengthOf`).
    fn isLength(w: *const Walk, node: Ast.Node.Index) Context.Error!bool {
        const memory = (try w.c.facts.lengthOf(w.file, node)) orelse return false;
        return try w.isLocal(memory);
    }

    /// The mention of the local at `token`.
    fn mentionAt(w: *const Walk, token: Ast.TokenIndex) ?Ast.Node.Index {
        for (w.mentions) |mention| if (w.tree.nodeMainToken(mention) == token) return mention;
        return null;
    }

    /// The constant a call's result is declared as (`const rc = f(&x);`), where it is one.
    fn resultConstant(w: *const Walk, call: Ast.Node.Index) ?Model.Declaration.Id {
        var value = call;
        var parent = w.model.parentOf(call) orelse return null;
        // `const n = try r.readSliceShort(&buf);`: its error leaves, and n is its result.
        if (w.tree.nodeTag(parent) == .@"try") {
            value = parent;
            parent = w.model.parentOf(parent) orelse return null;
        }
        const variable = w.tree.fullVarDecl(parent) orelse return null;
        if (w.tree.tokenTag(variable.ast.mut_token) != .keyword_const or variable.ast.init_node.unwrap() != value) return null;
        for (w.model.declarations, 0..) |each, d| {
            if (each.kind == .variable and each.node == parent) return @fromBackingInt(@intCast(d));
        }
        return null;
    }

    /// Whether `node` is the guarding call's result: the call, or the constant it is held in.
    fn isResult(w: *const Walk, node: Ast.Node.Index, guard: Guard) Context.Error!bool {
        const at = Facts.ungrouped(w.tree, node);
        if (at == guard.call) return true;
        const binding = guard.binding orelse return false;
        return try nameOf(w.c.facts, w.file, at) == binding;
    }

    /// Which of std's errno decoders `node` is, of the guarding call's result alone: as
    /// `noteErrnos` found it by declaration; null for any other call or node.
    fn errnoOf(w: *const Walk, node: Ast.Node.Index, guard: Guard) Context.Error!?CContract.Errno {
        const at = Facts.ungrouped(w.tree, node);
        var buffer: [1]Ast.Node.Index = undefined;
        const call = w.tree.fullCall(&buffer, at) orelse return null;
        if (call.ast.params.len != 1 or !try w.isResult(call.ast.params[0], guard)) return null;
        return w.errnos.get(at);
    }

    /// The guard of a call outside the program given all of the local, with each errno decoder
    /// its result is given to noted.
    fn guarded(w: *Walk, node: Ast.Node.Index, entry: *const CContract.Entry) Context.Error!Use {
        const guard: Guard = .{ .call = node, .entry = entry, .binding = w.resultConstant(node) };
        try w.noteErrnos(guard);
        return .{ .key = w.tree.lastToken(node), .effect = .{ .guarded = guard } };
    }

    /// Notes each call in the file given the guarding call's result alone that reaches std's
    /// `c.errno` or `posix.errno` (the C library's), or `os.linux.errno` (std's raw Linux calls),
    /// by declaration: a function of another name or another meaning decodes nothing.
    fn noteErrnos(w: *Walk, guard: Guard) Context.Error!void {
        for (0..w.tree.nodes.len) |i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            var buffer: [1]Ast.Node.Index = undefined;
            const call = w.tree.fullCall(&buffer, node) orelse continue;
            if (call.ast.params.len != 1 or !try w.isResult(call.ast.params[0], guard)) continue;
            const kind: CContract.Errno = if (try w.isStd(node, call, "c.errno") or try w.isStd(node, call, "posix.errno"))
                .c
            else if (try w.isStd(node, call, "os.linux.errno"))
                .linux
            else
                continue;
            try w.errnos.put(w.c.allocator, node, kind);
        }
    }

    /// Whether the local's type is the one `entry` names for what its parameter `index` points
    /// at, or with `elements`, the local an array of that type's elements: a `size` entry's is
    /// its size, checked where its result is.
    fn typed(w: *Walk, entry: *const CContract.Entry, index: usize, elements: bool) Context.Error!bool {
        const tree = w.tree;
        const at = std.mem.findScalar(usize, entry.writes, index) orelse return false;
        if (entry.types[at].len == 0) return entry.success == .size;
        if (w.param) return false;
        const variable = tree.fullVarDecl(w.model.declarations[@backingInt(w.local)].node) orelse return false;
        var kind = variable.ast.type_node.unwrap() orelse return false;
        if (elements) {
            const array_type = (try w.c.facts.arrayType(w.file, kind)) orelse return false;
            if (array_type.file != w.file) return false;
            kind = array_type.element;
        }
        var spellings = std.mem.splitScalar(u8, entry.types[at], '|');
        while (spellings.next()) |name| if (try w.typeNamed(kind, name)) return true;
        return false;
    }

    /// Whether the type expression `kind` is the type `name` names: a primitive, std's
    /// declaration at that path (through the aliases either is spelled by), or `[n]T` of one.
    fn typeNamed(w: *const Walk, kind: Ast.Node.Index, name: []const u8) Context.Error!bool {
        if (name.len > 0 and name[0] == '[') {
            const close = std.mem.findScalar(u8, name, ']') orelse return false;
            const length = std.fmt.parseInt(u64, name[1..close], 10) catch return false;
            const array_type = (try w.c.facts.arrayType(w.file, kind)) orelse return false;
            if (array_type.file != w.file) return false;
            if ((try Range.constantValue(w.c, array_type.file, array_type.length orelse return false)) != length) return false;
            return w.typeNamed(array_type.element, name[close + 1 ..]);
        }
        const got = try w.c.facts.resolve(w.file, kind);
        if (Model.primitive(name)) return got == .primitive and std.mem.eql(u8, got.primitive, name);
        // Only a type known to be std's is: one std's declarations do not show (the budget) is
        // not, and its contract is not taken.
        const found = switch (try Governed.declarations(w.c, "std", name)) {
            .decls => |each| each,
            .none, .unknown => return false,
        };
        for (found) |decl| {
            if (sameValue(got, try w.c.facts.declaration(decl), 0)) return true;
        }
        return false;
    }

    /// Whether `node`, a size a call is given, is the local's own as a constant: `@sizeOf` of
    /// its type or of `@TypeOf` it, or the length of an array of bytes; through `@intCast` and
    /// `@as`.
    fn sizeOfLocal(w: *const Walk, node: Ast.Node.Index) Context.Error!bool {
        const tree = w.tree;
        var at = Facts.ungrouped(tree, node);
        var buffer: [2]Ast.Node.Index = undefined;
        while (Facts.isBuiltin(tree, at, "@intCast") or Facts.isBuiltin(tree, at, "@as")) {
            const args = Facts.builtinArgs(tree, at, &buffer);
            if (args.len == 0) return false;
            at = Facts.ungrouped(tree, args[args.len - 1]);
        }
        const variable = tree.fullVarDecl(w.model.declarations[@backingInt(w.local)].node) orelse return false;
        const kind = variable.ast.type_node.unwrap() orelse return false;
        if (try w.constant(at)) |bytes| {
            const array_type = (try w.c.facts.arrayType(w.file, kind)) orelse return false;
            if (array_type.file != w.file) return false;
            if ((try Range.constantValue(w.c, array_type.file, array_type.length orelse return false)) != bytes) return false;
            return w.typeNamed(array_type.element, "u8");
        }
        if (!Facts.isBuiltin(tree, at, "@sizeOf")) return false;
        const args = Facts.builtinArgs(tree, at, &buffer);
        if (args.len != 1) return false;
        const of = Facts.ungrouped(tree, args[0]);
        if (Facts.isBuiltin(tree, of, "@TypeOf")) {
            const inner = Facts.builtinArgs(tree, of, &buffer);
            return inner.len == 1 and try w.isLocal(Facts.ungrouped(tree, inner[0]));
        }
        return sameText(w.model, tree, of, kind);
    }

    /// What `cond` says of the guarding call: true where its being true shows the call wrote
    /// (`rc == 0` for a call whose success is 0), false where its being false does (`rc != 0`),
    /// null where it shows neither. Read by the parts its truth shows (`Facts.truthsWhen`):
    /// `a and b` true where either shows it true, `a or b` false where either shows it false.
    fn checks(w: *const Walk, cond: Ast.Node.Index, guard: Guard) Context.Error!?bool {
        for ([_]bool{ true, false }) |value| {
            for ((try w.c.facts.truthsWhen(w.file, cond, value)) orelse continue) |known| {
                if ((try w.shows(known.part, guard)) == known.value) return value;
            }
        }
        return null;
    }

    /// What a comparison of the guarding call's result shows: true where its being true shows
    /// the call wrote, false where its being false does, null for anything else.
    fn shows(w: *const Walk, shown: Ast.Node.Index, guard: Guard) Context.Error!?bool {
        const tree = w.tree;
        const compared = switch (Facts.conditionOf(tree, shown)) {
            .compare => |found| found,
            .not, .both, .either, .other => return null,
        };
        var lhs = compared.left;
        var rhs = compared.right;
        var order = compared.order;
        // The result on the left: `0 != rc` is `rc != 0`.
        if (!try w.isResult(lhs, guard) and try w.errnoOf(lhs, guard) == null) {
            std.mem.swap(Ast.Node.Index, &lhs, &rhs);
            order = switch (order) {
                .greater => .less,
                .less => .greater,
                .greater_or_equal => .less_or_equal,
                .less_or_equal => .greater_or_equal,
                .equal, .not_equal => order,
            };
        }
        const equal: ?bool = switch (order) {
            .equal => true,
            .not_equal => false,
            .less, .less_or_equal, .greater, .greater_or_equal => null,
        };
        if (try w.errnoOf(lhs, guard)) |kind| {
            // errno is SUCCESS exactly where the call did not fail, read by the decoder its
            // results are made for: none for one that answers the error number itself.
            if (guard.entry.errno == .none or kind != guard.entry.errno) return null;
            return if (try isMember(w.c.facts, w.file, rhs, "SUCCESS")) equal else null;
        }
        if (!try w.isResult(lhs, guard)) return null;
        switch (guard.entry.success) {
            .zero => return if (try w.constant(rhs) == 0 or try isMember(w.c.facts, w.file, rhs, "SUCCESS")) equal else null,
            .nonzero => {
                const is = equal orelse return null;
                return if (try w.constant(rhs) == 0 or try isMember(w.c.facts, w.file, rhs, "FALSE")) !is else null;
            },
            .positive => {
                if (try w.constant(rhs) != 0) return null;
                return switch (order) {
                    .greater => true,
                    .less_or_equal => false,
                    .less, .greater_or_equal, .equal, .not_equal => null,
                };
            },
            .size => |param| {
                var buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buffer, guard.call) orelse return null;
                if (param >= call.ast.params.len) return null;
                // The size given, a constant that is the local's own: what the call filled is
                // all of it.
                const size = call.ast.params[param];
                if (!try w.sizeOfLocal(size) or !sameText(w.model, tree, rhs, size)) return null;
                return equal;
            },
            .length => {
                const length = try w.arrayLength();
                const literal = try w.constant(rhs);
                const all = (literal != null and length != null and literal.? == length.?) or try w.isLength(rhs);
                if (!all) return null;
                return switch (order) {
                    .equal, .greater_or_equal => true,
                    .not_equal, .less => false,
                    .less_or_equal, .greater => null,
                };
            },
            .count, .errno => return null,
        }
    }

    /// Whether `prong` of a `switch` on `condition` runs only where the guarding call wrote:
    /// its one item `.SUCCESS`, and the condition the call's errno or its status.
    fn successProng(w: *const Walk, condition: Ast.Node.Index, prong: Ast.full.SwitchCase, guard: Guard) Context.Error!bool {
        if (prong.ast.values.len != 1 or !try isMember(w.c.facts, w.file, prong.ast.values[0], "SUCCESS")) return false;
        if (try w.errnoOf(condition, guard)) |kind| return guard.entry.errno != .none and kind == guard.entry.errno;
        return try w.isResult(condition, guard) and guard.entry.success == .zero;
    }

    /// Whether `mention`, in statement `top`, runs only where the guarding call wrote: in the
    /// branch of an `if` its condition shows the call wrote on, or after `and` or `or` a test
    /// that shows it.
    fn behind(w: *const Walk, mention: Ast.Node.Index, guard: Guard, top: Ast.Node.Index) Context.Error!bool {
        const tree = w.tree;
        var at = mention;
        while (at != top) {
            const up = w.model.parentOf(at) orelse return false;
            switch (Facts.conditionOf(tree, up)) {
                .both => |sides| if (sides[1] == at and (try w.checks(sides[0], guard)) == true) return true,
                .either => |sides| if (sides[1] == at and (try w.checks(sides[0], guard)) == false) return true,
                .not, .compare, .other => if (tree.fullIf(up)) |branch| {
                    if (try w.checks(branch.ast.cond_expr, guard)) |holds| {
                        if (holds and branch.ast.then_expr == at) return true;
                        if (!holds and branch.ast.else_expr.unwrap() == at) return true;
                    }
                },
            }
            at = up;
        }
        return false;
    }

    fn mentioned(w: *const Walk, node: Ast.Node.Index) bool {
        const first = w.tree.firstToken(node);
        const last = w.tree.lastToken(node);
        for (w.outputs.items) |output| if (output.token >= first and output.token <= last) return true;
        for (w.mentions) |mention| {
            const token = w.tree.nodeMainToken(mention);
            if (token >= first and token <= last) return true;
        }
        return false;
    }

    /// Whether a `return` the walk sees the memory leave by (`exitsBy`) sits in `node`, for a
    /// parameter's walk.
    fn returnsIn(w: *const Walk, node: Ast.Node.Index) Context.Error!bool {
        const first = w.tree.firstToken(node);
        const last = w.tree.lastToken(node);
        for (w.returns) |each| {
            const token = w.tree.firstToken(each);
            if (token >= first and token <= last and try w.exitsBy(each)) return true;
        }
        return false;
    }

    /// Whether the `return` at `node` is one a parameter's walk sees its memory leave by: any
    /// but an error's, or any at all where `every_exit` asks.
    fn exitsBy(w: *const Walk, node: Ast.Node.Index) Context.Error!bool {
        return w.every_exit or !try errorReturn(w.c.facts, w.file, node);
    }
};

/// Whether the type `kind` spells a pointer or slice: written so, or as the name of a constant of
/// `scope` that is one, or a choice of them (`if (a) |x| []align(x) T else []T`), where `by_name`.
fn spelledPointer(facts: *Facts, file: Project.FileId, scope: Model.Scope.Id, kind: Ast.Node.Index, by_name: bool) Context.Error!bool {
    const tree = &facts.project.at(file).file.tree;
    const model = &facts.project.at(file).model;
    const node = Facts.ungrouped(tree, kind);
    if (tree.fullPtrType(node) != null) return true;
    if (tree.fullIf(node)) |choice| {
        const otherwise = choice.ast.else_expr.unwrap() orelse return false;
        return try spelledPointer(facts, file, scope, choice.ast.then_expr, by_name) and try spelledPointer(facts, file, scope, otherwise, by_name);
    }
    if (!by_name) return false;
    // The constant of `scope` the name refers to (`Facts.definition`).
    const decl = model.declarations[@backingInt((try nameOf(facts, file, node)) orelse return false)];
    if (decl.kind != .variable or decl.scope != scope) return false;
    const variable = tree.fullVarDecl(decl.node) orelse return false;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return false;
    return spelledPointer(facts, file, scope, variable.ast.init_node.unwrap() orelse return false, false);
}

/// The parameter position the call's argument at `position` takes (`Facts.calls`: its
/// arguments in parameter order, a bound receiver first, `page.write(w, n)`'s `w` second).
/// Null where which parameter an argument takes is not known (a receiver that may bind or not).
fn parameterAt(c: *Context, file: Project.FileId, call: Ast.full.Call, position: usize) Context.Error!?usize {
    const node = c.project.at(file).model.parentOf(call.ast.fn_expr) orelse return null;
    const made = (try Facts.calls.at(c.facts, file, node)) orelse return null;
    const args = switch (made.args) {
        .known => |each| each,
        .unknown => return null,
    };
    return std.mem.findScalar(Ast.Node.Index, args, call.ast.params[position]);
}

/// The place a mention of a local hands on with what holds it: the local, or the field or
/// element of it (`x.list`, `x.lists[0]`) a method is called on or whose address is taken.
fn placeOf(facts: *Facts, file: Project.FileId, mention: Ast.Node.Index) Context.Error!Ast.Node.Index {
    var place = mention;
    while (true) {
        const up = switch (try Facts.accesses.useOf(facts, file, place)) {
            .member => |access| member: {
                // A method's callee (`x.deinit`) is the call's, not a place.
                if (try Facts.accesses.useOf(facts, file, access) == .callee) break;
                break :member access;
            },
            .element => |access| access,
            else => break,
        };
        place = up;
    }
    return place;
}

/// The place (`placeOf`) a mention gives a call, as the call's receiver (`x.deinit(gpa)`) or
/// by address (`f(&x.list)`), or for a parameter's or an alias's pointer, as it is (`f(p)`),
/// `@call`'s tuple included; null where it gives none.
fn handedPlace(facts: *Facts, file: Project.FileId, mention: Ast.Node.Index, pointer: bool) Context.Error!?Ast.Node.Index {
    const place = try placeOf(facts, file, mention);
    switch (try Facts.accesses.useOf(facts, file, place)) {
        .member => |access| return if (try Facts.accesses.useOf(facts, file, access) == .callee) place else null,
        .address => |address| {
            if (try atCall(facts, file, address) != null) return place;
            return if (try Facts.accesses.useOf(facts, file, address) == .argument) place else null;
        },
        .argument => return if (pointer and place == mention) place else null,
        else => {
            if (!pointer or place != mention) return null;
            return if (try atCall(facts, file, place) != null) place else null;
        },
    }
}

/// `@call(modifier, f, .{…, argument, …})`: the call, the function it names, and the argument's
/// place among the tuple's elements, which are f's arguments.
fn atCall(facts: *Facts, file: Project.FileId, argument: Ast.Node.Index) Context.Error!?struct { node: Ast.Node.Index, function: Ast.Node.Index, position: usize } {
    const element = switch (try Facts.accesses.useOf(facts, file, argument)) {
        .element_of => |element| element,
        else => return null,
    };
    const builtin = switch (try Facts.accesses.useOf(facts, file, element.literal)) {
        .builtin_argument => |builtin| builtin,
        else => return null,
    };
    if (!Facts.isBuiltin(&facts.project.at(file).file.tree, builtin.call, "@call")) return null;
    const made = (try Facts.calls.at(facts, file, builtin.call)) orelse return null;
    const args = switch (made.args) {
        .known => |each| each,
        .unknown => return null,
    };
    return .{ .node = builtin.call, .function = made.callee_expr, .position = std.mem.findScalar(Ast.Node.Index, args, argument) orelse return null };
}

/// Adds to `found` each function `value` is: itself, each of a per-build choice, or what a
/// pointer points at. False where any of it is not a function known here.
fn functionsOf(gpa: std.mem.Allocator, value: Facts.Value, found: *std.ArrayList(Facts.Decl)) Context.Error!bool {
    switch (value) {
        .function => |decl| try found.append(gpa, decl),
        .alternatives => |each| for (each) |one| if (!try functionsOf(gpa, one, found)) return false,
        .pointer => |to| return functionsOf(gpa, to.child.*, found),
        else => return false,
    }
    return true;
}

// std_interface_implementations: std 0.17.0's own implementations of Io.Reader's and Io.Writer's
// vtables, each read in std's source (2026-11-01): none gives the interface it is handed
// (`*Reader`, `*Writer`, the one a `stream` writes to) or its buffer `undefined`; what
// `undefined` they spell is their own locals'. The defaults a vtable leaves unnamed are std's
// too. A vtable the program installs is read where it installs it (`installed`).
//
// Io/Writer.zig: the defaults, fixed, failing, discarding, hashed and allocating writers.
//   Io/Writer.zig:392 defaultFlush, Io/Writer.zig:419 defaultRebase,
//   Io/Writer.zig:2426 unimplementedSendFile, Io/Writer.zig:398 noopFlush,
//   Io/Writer.zig:2437 fixedDrain, Io/Writer.zig:2325 failingDrain,
//   Io/Writer.zig:2332 failingSendFile, Io/Writer.zig:2339 failingRebase,
//   Io/Writer.zig:2368 Discarding.drain, Io/Writer.zig:2379 Discarding.sendFile,
//   Io/Writer.zig:2469 unreachableDrain, Io/Writer.zig:2476 unreachableRebase,
//   Io/Writer.zig:2541 Hashed.drain, Io/Writer.zig:2622 Hashing.drain,
//   Io/Writer.zig:2841 Allocating.drain, Io/Writer.zig:2865 Allocating.sendFile,
//   Io/Writer.zig:2884 growingRebase.
// Io/Reader.zig: the defaults, failing, ending, fixed and hashed readers.
//   Io/Reader.zig:196 defaultDiscard, Io/Reader.zig:450 defaultReadVec,
//   Io/Reader.zig:1432 defaultRebase, Io/Reader.zig:1836 endingStream,
//   Io/Reader.zig:1843 endingReadVec, Io/Reader.zig:1849 endingDiscard,
//   Io/Reader.zig:1855 endingRebase, Io/Reader.zig:1861 failingStream,
//   Io/Reader.zig:1868 failingDiscard, Io/Reader.zig:2013 Hashed.stream,
//   Io/Reader.zig:2023 Hashed.readVec, Io/Reader.zig:2048 Hashed.discard,
//   Io/Reader/Limited.zig:28 stream, Io/Reader/Limited.zig:52 discard.
// Files, sockets and the multiplexed reader.
//   Io/File/Reader.zig:199 stream, Io/File/Reader.zig:231 readVec, Io/File/Reader.zig:300 discard,
//   Io/File/Writer.zig:89 drain, Io/File/Writer.zig:134 sendFile,
//   Io/File/MultiReader.zig:149 stream, Io/File/MultiReader.zig:158 discard,
//   Io/File/MultiReader.zig:166 readVec, Io/File/MultiReader.zig:174 rebase,
//   Io/net.zig:1354 Socket.Reader.streamImpl, Io/net.zig:1362 Socket.Reader.readVec,
//   Io/net.zig:1439 Stream.Writer.drain, Io/net.zig:1462 Stream.Writer.sendFile.
// HTTP bodies, TLS, the compressors and decompressors, PDB streams, the AST renderer.
//   http.zig:509 contentLengthStream, http.zig:527 contentLengthDiscard,
//   http.zig:541 chunkedStream, http.zig:610 chunkedDiscard, http.zig:886 contentLengthDrain,
//   http.zig:895 noneDrain, http.zig:903 elidingDrain, http.zig:917 elidingSendFile,
//   http.zig:944 noneSendFile, http.zig:952 contentLengthSendFile, http.zig:961 chunkedSendFile,
//   http.zig:997 chunkedDrain, crypto/tls/Client.zig:965 drain, crypto/tls/Client.zig:997 flush,
//   crypto/tls/Client.zig:1124 stream, crypto/tls/Client.zig:1132 readVec,
//   compress/flate/Compress.zig:345 drain, compress/flate/Compress.zig:356 flush,
//   compress/flate/Compress.zig:371 rebase, compress/flate/Compress.zig:1631 Raw.drain,
//   compress/flate/Compress.zig:1741 Raw.flush, compress/flate/Compress.zig:1752 Raw.rebase,
//   compress/flate/Compress.zig:1877 drain, compress/flate/Compress.zig:1964 flush,
//   compress/flate/Compress.zig:2126 Huffman.drain, compress/flate/Compress.zig:2332 Huffman.flush,
//   compress/flate/Compress.zig:2347 Huffman.rebase,
//   compress/flate/Decompress.zig:105 rebaseFallible,
//   compress/flate/Decompress.zig:121 discardDirect,
//   compress/flate/Decompress.zig:144 discardIndirect, compress/flate/Decompress.zig:164 readVec,
//   compress/flate/Decompress.zig:244 streamDirect,
//   compress/flate/Decompress.zig:249 streamIndirect,
//   compress/zstd/Decompress.zig:110 streamDirect, compress/zstd/Decompress.zig:115 streamIndirect,
//   compress/zstd/Decompress.zig:122 rebaseFallible,
//   compress/zstd/Decompress.zig:159 discardDirect,
//   compress/zstd/Decompress.zig:182 discardIndirect, compress/zstd/Decompress.zig:202 readVec,
//   compress/xz/Decompress.zig:104 readVec, compress/xz/Decompress.zig:109 stream,
//   compress/xz/Decompress.zig:115 discard, compress/lzma.zig:685 readVec,
//   compress/lzma.zig:690 stream, compress/lzma.zig:696 discard, debug/Pdb.zig:1068 stream,
//   zig.zig:648 drain, zig.zig:660 flush, zig/Ast/Render.zig:943 drainNoNewline.

/// A function of std's Io.Reader or Io.Writer vtable a call reaches: `x.vtable.name(…)` with `x`
/// one of those interfaces (or a pointer to one), and the vtable's field by its declaration.
const Slot = struct { interface: enum { reader, writer }, name: []const u8, field: Facts.Decl };

fn vtableSlot(c: *Context, file: Project.FileId, function: Ast.Node.Index) Context.Error!?Slot {
    // `x.vtable.name`: a member of a member, the inner one the interface's vtable field.
    const steps = (try Facts.accesses.pathOf(c.facts, file, function)).steps;
    if (steps.len < 3 or steps[0].kind != .field or steps[1].kind != .field) return null;
    const name = steps[0].name orelse return null;
    var value = steps[1].holder orelse return null;
    if (value == .pointer) value = value.pointer.child.*;
    const container = switch (value) {
        .instance => |container| container,
        // A choice of interfaces: no one slot, so what the call reaches is not known.
        .alternatives => return null,
        else => return null,
    };
    const table = c.facts.member(container, "vtable") orelse return null;
    switch (try c.facts.definition(file, steps[1].node)) {
        .decl => |field| if (!std.meta.eql(field, table)) return null,
        .none, .unknown => return null,
    }
    for ([_][]const u8{ "Io.Reader", "Io.Writer" }, [_]@FieldType(Slot, "interface"){ .reader, .writer }) |path, interface| {
        // An interface std's declarations do not show (the budget), or one an alias not followed
        // names, is no slot known: the call's callee is then not known.
        const found = switch (try Governed.declarations(c, "std", path)) {
            .decls => |each| each,
            .none, .unknown => continue,
        };
        for (found) |decl| {
            const target = switch (try c.facts.origin(decl)) {
                .decl => |d| d,
                .none, .unknown => continue,
            };
            const declared = try c.facts.declaration(target);
            if (declared == .container and std.meta.eql(declared.container, container)) return .{ .interface = interface, .name = name, .field = switch (try c.facts.definition(file, function)) {
                .decl => |d| d,
                .none, .unknown => return null,
            } };
        }
    }
    return null;
}

/// The functions the program, outside std, installs in a vtable's slot: what each store
/// `Facts.fieldStores` reads into the slot's field by meaning may hold (a literal's field, an
/// assignment, a destructure, `@field` by its name). Null where one may install a function not
/// known here (a parameter's, the slot's address taken, a name computed as the program
/// compiles, a file the front end refused). std's own are none of these
/// (`std_interface_implementations`).
fn installed(c: *Context, slot: Slot) Context.Error!?[]const Facts.Decl {
    var files: std.ArrayList(Project.FileId) = .empty;
    for (0..c.project.count()) |i| {
        const file: Project.FileId = @fromBackingInt(@intCast(i));
        if (try inStd(c, file)) continue;
        if (c.project.at(file).file.status != .parsed) return null;
        try files.append(c.allocator, file);
    }
    const stored = (try c.facts.fieldStores(slot.field, files.items)) orelse return null;
    var found: std.ArrayList(Facts.Decl) = .empty;
    for (stored) |value| if (!try functionsOf(c.allocator, value, &found)) return null;
    return found.items;
}

/// What `Walk.collect` and `aliasesOf` read of a file, gathered once for the run: each
/// declaration's identifiers (`nameOf`), each function's own `return`s and `try`s (`ownFunction`),
/// the file's asm outputs, and its variables whose initializer names a declaration of the file or
/// its address, each in order.
const FileIndex = struct {
    named: std.AutoHashMapUnmanaged(Model.Declaration.Id, std.ArrayList(Ast.Node.Index)) = .empty,
    exits: std.AutoHashMapUnmanaged(Ast.Node.Index, Exits) = .empty,
    outputs: std.ArrayList(Ast.Node.Index) = .empty,
    bindings: std.ArrayList(Binding) = .empty,

    const Binding = struct { id: Model.Declaration.Id, of: Model.Declaration.Id, address: bool };
    const Exits = struct { returns: []const Ast.Node.Index, tries: []const Ast.Node.Index };
    const Growing = struct { returns: std.ArrayList(Ast.Node.Index) = .empty, tries: std.ArrayList(Ast.Node.Index) = .empty };
};

/// The function declaration `node` is in, nearest first: `.root` outside any.
fn ownFunction(tree: *const Ast, model: *const Model, node: Ast.Node.Index) Ast.Node.Index {
    var at = node;
    while (model.parentOf(at)) |up| : (at = up) if (tree.nodeTag(up) == .fn_decl) return up;
    return .root;
}

const FileIndexes = struct { files: std.AutoHashMapUnmanaged(Project.FileId, *const FileIndex) = .empty };

fn indexOf(facts: *Facts, file: Project.FileId) Context.Error!*const FileIndex {
    const memo = try facts.memo(FileIndexes);
    if (memo.files.get(file)) |known| return known;
    const gpa = facts.gpa;
    const tree = &facts.project.at(file).file.tree;
    const model = &facts.project.at(file).model;
    const index = try gpa.create(FileIndex);
    index.* = .{};
    var growing: std.AutoHashMapUnmanaged(Ast.Node.Index, FileIndex.Growing) = .empty;
    defer growing.deinit(gpa);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tag) {
            .@"return", .@"try" => {
                const entry = try growing.getOrPut(gpa, ownFunction(tree, model, node));
                if (!entry.found_existing) entry.value_ptr.* = .{};
                try (if (tag == .@"return") &entry.value_ptr.returns else &entry.value_ptr.tries).append(gpa, node);
            },
            .asm_output => try index.outputs.append(gpa, node),
            else => {
                const decl = (try nameOf(facts, file, node)) orelse continue;
                const entry = try index.named.getOrPut(gpa, decl);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(gpa, node);
            },
        }
    }
    for (model.declarations, 0..) |decl, d| {
        if (decl.kind != .variable) continue;
        const variable = tree.fullVarDecl(decl.node) orelse continue;
        const init = Facts.ungrouped(tree, variable.ast.init_node.unwrap() orelse continue);
        const address = Facts.accesses.formOf(tree.nodeTag(init)) == .address_of;
        const spelled = Facts.ungrouped(tree, if (address) tree.nodeData(init).node else init);
        const of = (try nameOf(facts, file, spelled)) orelse continue;
        try index.bindings.append(gpa, .{ .id = @fromBackingInt(@intCast(d)), .of = of, .address = address });
    }
    var each = growing.iterator();
    while (each.next()) |entry| try index.exits.put(gpa, entry.key_ptr.*, .{ .returns = try entry.value_ptr.returns.toOwnedSlice(gpa), .tries = try entry.value_ptr.tries.toOwnedSlice(gpa) });
    try memo.files.put(gpa, file, index);
    return index;
}

/// The locals that hold the address of `local`'s memory as it is, with no step through it:
/// `const p = &x` for a local, `const q = p` for a parameter's pointer (`param`), and one of
/// those again (`const r = q`).
fn aliasesOf(gpa: std.mem.Allocator, facts: *Facts, file: Project.FileId, local: Model.Declaration.Id, param: bool) Context.Error![]const Model.Declaration.Id {
    const index = try indexOf(facts, file);
    var found: std.ArrayList(Model.Declaration.Id) = .empty;
    var grown = true;
    while (grown) {
        grown = false;
        for (index.bindings.items) |binding| {
            const id = binding.id;
            if (id == local or std.mem.findScalar(Model.Declaration.Id, found.items, id) != null) continue;
            const address = binding.address;
            const of = binding.of;
            // The local's address, or a parameter's pointer as it is; an alias's, as it is.
            const alias = if (of == local) address != param else !address and std.mem.findScalar(Model.Declaration.Id, found.items, of) != null;
            if (!alias) continue;
            try found.append(gpa, id);
            grown = true;
        }
    }
    return found.items;
}

/// The name a `for`'s capture at `position` binds (`|x, *slot|`), where it is a pointer's as
/// `pointer` asks.
fn capture(tree: *const Ast, payload: Ast.TokenIndex, position: usize, pointer: bool) ?[]const u8 {
    var token = payload;
    var at: usize = 0;
    while (true) : (at += 1) {
        const star = tree.tokenTag(token) == .asterisk;
        if (star) token += 1;
        if (tree.tokenTag(token) != .identifier) return null;
        if (at == position) return if (star == pointer) tree.tokenSlice(token) else null;
        token += 1;
        if (tree.tokenTag(token) != .comma) return null;
        token += 1;
    }
}

/// The name of the field a struct literal gives `value` (`.{ .bytes = value }`), by its use
/// (`accesses.useOf`): null for anything else.
fn fieldNameOf(facts: *Facts, file: Project.FileId, value: Ast.Node.Index) Context.Error!?[]const u8 {
    return switch (try Facts.accesses.useOf(facts, file, value)) {
        .field_of => |field| facts.project.at(file).file.tree.tokenSlice(field.name),
        else => null,
    };
}

/// The declaration a `for`'s capture at `position` binds (`|x, *slot|`), where it is a
/// pointer's as `pointer` asks.
fn captureAt(tree: *const Ast, model: *const Model, node: Ast.Node.Index, loop: Ast.full.For, position: usize, pointer: bool) ?Model.Declaration.Id {
    for (model.declarations, 0..) |record, d| {
        if (record.kind != .capture or record.node != node) continue;
        if (Model.capturePosition(tree, loop, record.token) != position) continue;
        const star = record.token > 0 and tree.tokenTag(record.token - 1) == .asterisk;
        return if (star == pointer) @fromBackingInt(@intCast(d)) else null;
    }
    return null;
}

/// Whether a name in `node` refers to the declaration `decl`.
fn refers(model: *const Model, tree: *const Ast, node: Ast.Node.Index, decl: Model.Declaration.Id) bool {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    for (model.references) |reference| if (reference.declaration == decl and reference.token >= first and reference.token <= last) return true;
    return false;
}

/// Whether two type expressions in one file name one type: identifiers of one declaration, or
/// the same member of such.
/// Whether two resolved types are one: the same primitive, the same container (not one a type
/// function made, whose arguments are not compared), or pointers, arrays, optionals and per-build
/// choices of such.
fn sameValue(a: Facts.Value, b: Facts.Value, depth: usize) bool {
    if (depth == 16) return false;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .primitive => |name| std.mem.eql(u8, name, b.primitive),
        .container => |one| one.made_by == null and b.container.made_by == null and one.file == b.container.file and one.scope == b.container.scope,
        .pointer => |inner| inner.size == b.pointer.size and sameValue(inner.child.*, b.pointer.child.*, depth + 1),
        .array => |inner| sameValue(inner.*, b.array.*, depth + 1),
        .optional => |inner| sameValue(inner.*, b.optional.*, depth + 1),
        .alternatives => |each| each.len == b.alternatives.len and for (each, b.alternatives) |x, y| {
            if (!sameValue(x, y, depth + 1)) break false;
        } else true,
        else => false,
    };
}

/// Whether `node` holds a way out of a `for` pass that skips what follows in it: `break`,
/// `continue` or `return`. An error `try` returns leaves the function, past every read.
fn leavesPass(tree: *const Ast, node: Ast.Node.Index) bool {
    var token = tree.firstToken(node);
    while (token <= tree.lastToken(node)) : (token += 1) switch (tree.tokenTag(token)) {
        .keyword_break, .keyword_continue, .keyword_return => return true,
        else => {},
    };
    return false;
}

/// Whether what a holder at `node` holds (`Writer.fixed(&buf)`, a field of one, a pointer to
/// one, a literal or a call's result holding one) is never handed back unwritten: it is a
/// number; it is kept in a local each mention of which does the same; its methods are called,
/// or it is handed to a function, std's (but those of `std_room`) or one whose parameter does
/// the same; a field of it is read that does the same (`fw.interface`, `w.end`); it is put in
/// a literal that does the same, or returned, where each caller follows the result as the
/// call's (`handedTo`); something is assigned over it; or it is discarded (`_ = &w`, a
/// statement). Anything else (a
/// field holding the memory, the holder returned, copied into a field or a literal, a cut past
/// the depth) may hand back what nothing wrote.
fn holderKept(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!bool {
    if (depth > depth_limit) return false;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    if (try c.facts.resolve(file, node) == .primitive) return true;
    const parent = model.parentOf(node) orelse return false;
    if (isBlock(tree, parent)) return true;
    var buffer: [1]Ast.Node.Index = undefined;
    var literal: [2]Ast.Node.Index = undefined;
    switch (try Facts.accesses.useOf(c.facts, file, node)) {
        .carried => |carried| switch (carried.how) {
            .grouped, .tried, .payload => return holderKept(c, file, carried.into, depth),
            else => {},
        },
        .address => |address| return holderKept(c, file, address, depth),
        .dereferenced => |deref| return holderKept(c, file, deref, depth),
        .returned => return true,
        .member => |access| {
            switch (try Facts.accesses.useOf(c.facts, file, access)) {
                .callee => |made| return holderKeptThrough(c, file, tree.fullCall(&buffer, made).?, null, depth), // unreachable: a callee's is a call
                else => {},
            }
            return switch (try heldField(c, file, access)) {
                .number => true,
                .holder => holderKept(c, file, access, depth + 1),
                .memory => false,
            };
        },
        // Assigned over, or discarded (`_ = &w;`); what it is stored into keeps it.
        .written, .discarded => return true,
        .stored => return false,
        else => {},
    }
    if (tree.fullVarDecl(parent)) |variable| {
        if (variable.ast.init_node.unwrap() != node) return false;
        const id: Model.Declaration.Id = for (model.declarations, 0..) |each, d| {
            if (each.kind == .variable and each.node == parent) break @fromBackingInt(@intCast(d));
        } else return false;
        return holderKeptBy(c, file, id, depth);
    }
    if (tree.fullCall(&buffer, parent)) |call| {
        const position = std.mem.findScalar(Ast.Node.Index, call.ast.params, node) orelse return false;
        return holderKeptThrough(c, file, call, position, depth);
    }
    if (tree.fullStructInit(&literal, parent) != null or tree.fullArrayInit(&literal, parent) != null) return holderKept(c, file, parent, depth + 1);
    return false;
}

/// What a holder's field `access` is: a number; a holder to follow, a struct or a pointer to
/// one item; or what may be the memory it holds, a slice, a many-item pointer, an array, or
/// what is not known.
fn heldField(c: *Context, file: Project.FileId, access: Ast.Node.Index) Context.Error!enum { number, holder, memory } {
    const tree = &c.project.at(file).file.tree;
    // Each part of what it is (`Facts.valueParts`): a number where every part is one, a holder
    // where every part is a struct; else what its declared type says.
    const value = try c.facts.resolve(file, access);
    var number: Facts.Join = .{};
    var holder: Facts.Join = .{};
    for (Facts.valueParts(&value)) |part| {
        number.add(part, part == .primitive or part == .scalar or part == .error_set);
        holder.add(part, part == .instance);
    }
    if (number.all() == true) return .number;
    if (holder.all() == true) return .holder;
    const object, const member = tree.nodeData(access).node_and_token;
    const container = switch (try c.facts.resolve(file, object)) {
        .instance => |found| found,
        .pointer => |to| switch (to.child.*) {
            .instance => |found| found,
            // A pointer to a choice of holders: no one field, so what may be memory.
            .alternatives => return .memory,
            else => return .memory,
        },
        // A choice of holders: no one field, so what may be memory.
        .alternatives => return .memory,
        else => return .memory,
    };
    const source = c.project.at(container.file);
    const name = tree.tokenSlice(member);
    for (source.model.declarations) |decl| {
        if (decl.kind != .field or decl.scope != container.scope or !std.mem.eql(u8, decl.name, name)) continue;
        const field = source.model.containerField(&source.file.tree, decl.node) orelse return .memory;
        const kind = field.ast.type_expr.unwrap() orelse return .memory;
        // `*T` or `?*T`, by the type it is (`Facts.resolve`).
        const declared = try c.facts.resolve(container.file, kind);
        const held = if (declared == .optional) declared.optional.* else declared;
        return if (held == .pointer and held.pointer.size == .one) .holder else .memory;
    }
    return .memory;
}

/// Whether a call's result may hold what the call keeps: a struct, or what is not known; a
/// number, a slice or a pointer holds none of a holder but what the callee itself handed back,
/// which `holderKept` refuses there.
fn holdsResult(value: Facts.Value) bool {
    return switch (value) {
        .instance, .unknown, .literal, .reified => true,
        .optional, .error_union => |inner| holdsResult(inner.*),
        .alternatives => |each| for (each) |one| {
            if (holdsResult(one)) break true;
        } else false,
        else => false,
    };
}

/// Whether every mention of `id`, a local or a parameter holding a holder or a pointer to one,
/// keeps what it holds as `held` says.
fn holderKeptBy(c: *Context, file: Project.FileId, id: Model.Declaration.Id, depth: u8) Context.Error!bool {
    const model = &c.project.at(file).model;
    for (model.references) |ref| {
        if (try nameOf(c.facts, file, ref.node) != id) continue;
        if (!try holderKept(c, file, ref.node, depth)) return false;
    }
    return true;
}

/// Whether a call handed a holder (a method's receiver, `position` null, or the argument at
/// `position`) keeps what it holds: std's, but those that hand back its room, or the
/// program's, or a dependency's, whose parameter keeps it. A call that may reach several (a
/// per-build choice, a function-pointer field's stored functions) keeps it where each does.
fn holderKeptThrough(c: *Context, file: Project.FileId, call: Ast.full.Call, position: ?usize, depth: u8) Context.Error!bool {
    const value = try c.facts.resolve(file, call.ast.fn_expr);
    // Kept where every function it may reach keeps it (`Facts.Join.all`); a part that is no
    // function, or a choice of none, leaves it not kept.
    var kept: Facts.Join = .{};
    for (Facts.valueParts(&value)) |each| {
        kept.add(each, if (each == .function) try holderKeptIn(c, file, call, each.function, position, depth) else null);
    }
    return kept.all() orelse false;
}

fn holderKeptIn(c: *Context, file: Project.FileId, call: Ast.full.Call, decl: Facts.Decl, position: ?usize, depth: u8) Context.Error!bool {
    // One of std's that leaves room in what it keeps, or one that may be (not known), keeps no
    // holder whole.
    for (std_room) |path| if (try stdAt(c, decl, path) != .no) return false;
    if (try inStd(c, decl.file)) return true;
    const index = if (position) |at| try parameterAt(c, file, call, at) orelse return false else 0;
    return remembered(bool, c, .{ .decl = decl, .index = index, .question = .holds }, depth + 1, holderKeptByParameter, false);
}

fn holderKeptByParameter(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!bool {
    const tree = &c.project.at(decl.file).file.tree;
    const model = &c.project.at(decl.file).model;
    const record = model.declarations[@backingInt(decl.index)];
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, record.node) orelse return false;
    if (tree.nodeTag(model.parentOf(record.node) orelse return false) != .fn_decl) return false;
    var it = proto.iterate(tree);
    var position: usize = 0;
    const param = while (it.next()) |each| : (position += 1) {
        if (position == index) break each;
    } else return false;
    // `_`: nothing in the body names it.
    const name = param.name_token orelse return true;
    const id: Model.Declaration.Id = for (model.declarations, 0..) |each, d| {
        if (each.kind == .parameter and each.token == name) break @fromBackingInt(@intCast(d));
    } else return false;
    return holderKeptBy(c, decl.file, id, depth);
}

/// Whether `file` is one of std's (`Facts.standard`).
fn inStd(c: *Context, file: Project.FileId) Context.Error!bool {
    return c.facts.standard(file);
}

/// Whether the program's function `decl` only keeps what its parameter `index` points at:
/// each mention of the parameter hands all of it to one of std's keeps or to another such
/// function, or reads its length. It writes none of it and reads none of it itself.
fn keepsOnly(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!bool {
    return remembered(bool, c, .{ .decl = decl, .index = index, .question = .keeps }, depth, keepsOnlyRead, false);
}

fn keepsOnlyRead(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!bool {
    const found = (try parameter(c, decl, index, true)) orelse return false;
    var walk: Walk = .init(c, decl.file, found.id, true, depth);
    try walk.collect();
    const tree = walk.tree;
    for (walk.mentions) |mention| {
        const parent = walk.model.parentOf(mention) orelse return false;
        if ((try c.facts.lengthOf(walk.file, parent)) != null) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, parent) orelse return false;
        const position = std.mem.findScalar(Ast.Node.Index, call.ast.params, mention) orelse return false;
        if (try walk.handedTo(parent, call, position, false, true, tree.nodeMainToken(mention)) != null) return false;
    }
    return true;
}

/// Whether the program's function `decl` writes parts of what its parameter `index` points at
/// and reads, returns or hands on only what it wrote (`buf[0..4].* = v; return buf[0..4];`):
/// each mention of the parameter reads its length; writes a part, or all of it (`p[i] = v`,
/// `p[a..b].* = v`, `p.* = v`, `@memcpy(p[a..b], …)`, a `for` setting each element of `p[a..b]`,
/// one of std's fills given it); hands it to one of std's keeps or such a function; or is
/// that part, or any part once all of it is, written by a statement before it in a block that
/// holds it, with nothing between assigning a name the part's bounds spell. It writes none of
/// it for its caller, and reads none of what it has not written.
fn writesParts(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!bool {
    return remembered(bool, c, .{ .decl = decl, .index = index, .question = .parts }, depth, writesPartsRead, false);
}

fn writesPartsRead(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!bool {
    const found = (try parameter(c, decl, index, true)) orelse return false;
    var walk: Walk = .init(c, decl.file, found.id, true, depth);
    try walk.collect();
    const tree = walk.tree;
    const model = walk.model;
    // What a statement wrote: the part (null: all of it), and the statement.
    var written: std.ArrayList(struct { part: ?Ast.Node.Index, statement: Ast.Node.Index }) = .empty;
    for (walk.mentions) |mention| {
        const key = tree.nodeMainToken(mention);
        const facts = c.facts;
        var memory = mention;
        switch (try Facts.accesses.useOf(facts, walk.file, mention)) {
            .member => |access| {
                if ((try facts.lengthOf(walk.file, access)) != null) continue;
                return false;
            },
            .element => |access| {
                if (try writtenAt(facts, walk.file, access) != null) continue;
                if (try coveredBefore(c, decl.file, written.items, null, access)) continue;
                return false;
            },
            .index => return false,
            .dereferenced => |pointee| {
                // `p.* = undefined` writes nothing, and leaves undefined what was.
                const site = (try writtenAt(facts, walk.file, pointee)) orelse return false;
                if (try holdsUndefined(c.facts, decl.file, site.value orelse return false)) return false;
                try written.append(c.allocator, .{ .part = null, .statement = statementOf(model, tree, pointee) orelse return false });
                continue;
            },
            .sliced => |parent| {
                memory = parent;
                // `p[0..w.pos]`: what a cursor writer, or a counting call, wrote there.
                if (try walk.countedPrefix(parent)) continue;
                // `p[a..b].* = v`.
                const above = model.parentOf(parent) orelse return false;
                switch (try Facts.accesses.useOf(facts, walk.file, parent)) {
                    .dereferenced => |pointee| if (try writtenAt(facts, walk.file, pointee)) |site| {
                        if (try holdsUndefined(c.facts, decl.file, site.value orelse return false)) return false;
                        try written.append(c.allocator, .{ .part = parent, .statement = statementOf(model, tree, pointee) orelse return false });
                        continue;
                    },
                    else => {},
                }
                // `const part = p[a..b];`: the part under another name, each mention of which
                // is the part's.
                if (tree.fullVarDecl(above)) |variable| if (variable.ast.init_node.unwrap() == parent and tree.tokenTag(variable.ast.mut_token) == .keyword_const) {
                    const alias = for (model.declarations, 0..) |each, d| {
                        if (each.kind == .variable and each.node == above) break @as(Model.Declaration.Id, @fromBackingInt(@intCast(d)));
                    } else return false;
                    var aliased: Walk = .init(c, decl.file, alias, true, depth);
                    try aliased.collect();
                    for (aliased.mentions) |each| {
                        const up = model.parentOf(each) orelse return false;
                        if ((try c.facts.lengthOf(aliased.file, up)) != null) continue;
                        const use = (try aliased.given(each, true, tree.nodeMainToken(each))) orelse continue;
                        if (use.effect == .write) {
                            try written.append(c.allocator, .{ .part = parent, .statement = statementOf(model, tree, each) orelse return false });
                            continue;
                        }
                        if (!try coveredBefore(c, decl.file, written.items, parent, each)) return false;
                    }
                    continue;
                };
            },
            .address => return false,
            else => {},
        }
        const use = (try walk.given(memory, true, key)) orelse continue;
        if (use.effect == .write) {
            try written.append(c.allocator, .{ .part = if (memory == mention) null else memory, .statement = statementOf(model, tree, memory) orelse return false });
            continue;
        }
        if (try coveredBefore(c, decl.file, written.items, if (memory == mention) null else memory, memory)) continue;
        return false;
    }
    return true;
}

/// A cursor writer's fields: the memory it is given and its count of what it wrote there.
const Cursor = struct { memory: []const u8, count: []const u8 };

/// What the program's types were found to be as cursor writers, kept once per memory field
/// (the count field's name, null where the type is none), and what its functions do with a
/// writer they are given, once per function and parameter.
const Cursors = struct {
    counts: std.AutoHashMapUnmanaged(Facts.Decl, ?[]const u8) = .empty,
    kept: std.AutoHashMapUnmanaged(Calls.Key, bool) = .empty,
    active: std.AutoHashMapUnmanaged(Calls.Key, void) = .empty,
    cuts: usize = 0,
};

/// The count field of a cursor writer whose memory is the struct `container`'s field `memory`
/// (cloak's `Writer`: `bytes: []u8, pos: usize = 0`): its one integer field that starts at 0,
/// which the program, wherever it holds one of these or may, only reads, sets to 0, or steps by
/// `k` in the statement right after one that writes `x.bytes[x.pos..][0..k]` whole; and
/// `memory`, which it only writes, measures, or reads below the count (`x.bytes[0..x.pos]`),
/// and never sets. What such a writer holds below its count was written, through it. Null
/// where the type is no such writer.
fn cursorCount(c: *Context, container: Facts.Container, memory: Facts.Decl) Context.Error!?[]const u8 {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Cursors);
    if (memo.counts.get(memory)) |known| return known;
    const found = try cursorCountRead(c, container, memory);
    try memo.counts.put(c.allocator, memory, found);
    return found;
}

fn cursorCountRead(c: *Context, container: Facts.Container, memory: Facts.Decl) Context.Error!?[]const u8 {
    const source = c.project.at(container.file);
    const tree = &source.file.tree;
    const model = &source.model;
    var count: ?[]const u8 = null;
    for (model.declarations) |decl| {
        if (decl.kind != .field or decl.scope != container.scope) continue;
        const field = model.containerField(tree, decl.node) orelse continue;
        if (try Range.constantValue(c, container.file, field.ast.value_expr.unwrap() orelse continue) != 0) continue;
        const kind = field.ast.type_expr.unwrap() orelse continue;
        // An unsigned integer (`Facts.integerType`), at any pointer width.
        const declared = try c.facts.resolve(container.file, kind);
        if (declared != .primitive) continue;
        switch (Facts.integerType(declared, 64)) {
            .int => |int| if (int.signed or int.either) continue,
            .literal, .unknown => continue,
        }
        // Two that start at 0: neither is known to be the count.
        if (count != null) return null;
        count = decl.name;
    }
    const counted = count orelse return null;
    const held = model.declarations[@backingInt(memory.index)].name;
    // The selected files' uses are all that touch a writer this clears: one reaches only
    // functions of the selected files (`keepsWriter`), never one outside them.
    for (try c.facts.memberUses(counted)) |use| {
        const holder = try holderOf(c, use, container);
        if (holder == .other) continue;
        if (!try stepsCount(c, use, held)) return null;
    }
    for (try c.facts.memberUses(held)) |use| {
        const holder = try holderOf(c, use, container);
        if (holder == .other) continue;
        if (!try keepsBelow(c, use, counted)) return null;
    }
    return counted;
}

/// Whether the object a member access (`x.pos`) is made on is one of `container`'s, through
/// pointers and optionals; `unknown` where what it is is not known.
fn holderOf(c: *Context, use: Facts.Key, container: Facts.Container) Context.Error!enum { ours, other, unknown } {
    const tree = &c.project.at(use.file).file.tree;
    var value = try c.facts.resolve(use.file, tree.nodeData(use.node).node_and_token[0]);
    while (true) switch (value) {
        .pointer => |inner| value = inner.child.*,
        .optional => |inner| value = inner.*,
        // A choice is not known, below.
        .alternatives => break,
        else => break,
    };
    return switch (value) {
        .instance => |found| if (found.file == container.file and found.scope == container.scope) .ours else .other,
        .unknown, .alternatives, .reflected, .reified, .literal => .unknown,
        else => .other,
    };
}

/// Whether a mention of a cursor writer's count (`x.pos`) reads it, sets it to 0, or steps it
/// by `k` right after the statement before it in its block writes `x.bytes[x.pos..][0..k]` whole.
fn stepsCount(c: *Context, use: Facts.Key, memory: []const u8) Context.Error!bool {
    const tree = &c.project.at(use.file).file.tree;
    const model = &c.project.at(use.file).model;
    const facts = c.facts;
    switch (try Facts.accesses.useOf(facts, use.file, use.node)) {
        .address => return false,
        // Set to 0.
        .written => |site| return try Range.constantValue(c, use.file, site.value orelse return false) == 0,
        // `x.pos += k`, checked, right after `k` elements past it are written.
        .updated => |site| {
            const operator = switch (site.operator orelse return false) {
                .op => |op| op,
                .unknown => return false,
            };
            if (operator.op != .add or operator.overflow != .checked) return false;
            const step = site.value orelse return false;
            const parent = site.node;
            const block = model.parentOf(parent) orelse return false;
            if (!isBlock(tree, block)) return false;
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, block) orelse return false;
            const at = std.mem.findScalar(Ast.Node.Index, statements, parent) orelse return false;
            if (at == 0) return false;
            const span = (try filled(c.facts, use.file, statements[at - 1])) orelse return false;
            // `x.bytes[x.pos..][0..k]`, the same `x`, `pos` and `k` as the step's.
            const part = tree.fullSlice(span) orelse return false;
            if (try Range.constantValue(c, use.file, part.ast.start) != 0) return false;
            if (!try plain(c.facts, use.file, step) or !sameText(model, tree, part.ast.end.unwrap() orelse return false, step)) return false;
            const rest = tree.fullSlice(part.ast.sliced) orelse return false;
            if (rest.ast.end != .none or !sameText(model, tree, rest.ast.start, use.node)) return false;
            const held = (try Facts.accesses.pathOf(facts, use.file, rest.ast.sliced)).steps;
            const counted = (try Facts.accesses.pathOf(facts, use.file, use.node)).steps;
            if (held.len < 2 or counted.len < 2 or held[0].kind != .field or counted[0].kind != .field) return false;
            if (!std.mem.eql(u8, held[0].name orelse return false, memory)) return false;
            return try Facts.accesses.samePlace(facts, use.file, held[1].node, counted[1].node) == .yes;
        },
        else => return true,
    }
}

/// Whether `node` spells only names, numbers, a name's `.len` and arithmetic: no field, no
/// dereference and no call, so that spelled alike in two statements with nothing between them,
/// it is the same value in both.
fn plain(facts: *Facts, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &facts.project.at(file).file.tree;
    const at = Facts.ungrouped(tree, node);
    switch (tree.nodeTag(at)) {
        .add, .sub, .mul => {
            const lhs, const rhs = tree.nodeData(at).node_and_node;
            return try plain(facts, file, lhs) and try plain(facts, file, rhs);
        },
        else => {},
    }
    if (try facts.literalOf(file, at)) |literal| return literal == .number;
    if (try nameOf(facts, file, at) != null) return true;
    // A name's memory's length (`Facts.languageField`): no field so named.
    if (try facts.languageField(file, at) != .len) return false;
    const read = (try Facts.accesses.memberRead(facts, file, at)).?; // unreachable: a language field is a member read
    return try nameOf(facts, file, read.receiver.?) != null; // unreachable: a member's step has its holder
}

/// The memory a statement writes whole: `@memcpy(m, …)`, `@memset(m, …)` or `m.* = …`, with
/// no `undefined` in what it writes.
fn filled(facts: *Facts, file: Project.FileId, statement: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const tree = &facts.project.at(file).file.tree;
    if (Facts.isBuiltin(tree, statement, "@memcpy") or Facts.isBuiltin(tree, statement, "@memset")) {
        var buffer: [2]Ast.Node.Index = undefined;
        const params = tree.builtinCallParams(&buffer, statement) orelse return null;
        if (params.len != 2 or try holdsUndefined(facts, file, params[1])) return null;
        return params[0];
    }
    // `m.* = …`: the store (`accesses.storeInto`) through the pointer `m`.
    const set = (try storeAt(facts, file, statement)) orelse return null;
    if (try holdsUndefined(facts, file, set.value orelse return null)) return null;
    const target = set.target orelse return null;
    return if (Facts.accesses.formOf(tree.nodeTag(target)) == .deref) tree.nodeData(target).node else null;
}

/// Whether a mention of a cursor writer's memory (`x.bytes`) measures it, reads it below the
/// count (`x.bytes[0..x.pos]`), or is written: an element set, or a part of it written whole.
fn keepsBelow(c: *Context, use: Facts.Key, count: []const u8) Context.Error!bool {
    const tree = &c.project.at(use.file).file.tree;
    const model = &c.project.at(use.file).model;
    const facts = c.facts;
    switch (try Facts.accesses.useOf(facts, use.file, use.node)) {
        .member => |access| return (try facts.lengthOf(use.file, access)) != null,
        .element => |access| {
            const site = (try writtenAt(facts, use.file, access)) orelse return false;
            return !try holdsUndefined(facts, use.file, site.value orelse return false);
        },
        .sliced => |parent| {
            const slice = tree.fullSlice(parent) orelse return false; // unreachable: a slice's
            // `x.bytes[0..x.pos]`: the count of the same writer.
            if (try Range.constantValue(c, use.file, slice.ast.start) == 0) if (slice.ast.end.unwrap()) |end| {
                const counted = (try Facts.accesses.pathOf(facts, use.file, end)).steps;
                const memory = (try Facts.accesses.pathOf(facts, use.file, use.node)).steps;
                if (counted.len >= 2 and memory.len >= 2 and counted[0].kind == .field and memory[0].kind == .field and
                    std.mem.eql(u8, counted[0].name orelse "", count) and
                    try Facts.accesses.samePlace(facts, use.file, counted[1].node, memory[1].node) == .yes) return true;
            };
            // A part, or a part of it, written whole.
            var part = parent;
            while (model.parentOf(part)) |up| {
                const inner = tree.fullSlice(up) orelse break;
                if (inner.ast.sliced != part) break;
                part = up;
            }
            const above = model.parentOf(part) orelse return false;
            if (try filled(facts, use.file, above) == part) return true;
            return try Facts.accesses.useOf(facts, use.file, part) == .dereferenced and try filled(facts, use.file, model.parentOf(above) orelse return false) == part;
        },
        else => return false,
    }
}

/// Whether a mention of a local cursor writer (`node`) keeps it over what it was given: it
/// names one of its fields or calls a method on it, or hands its address to one of the
/// program's functions, each of which does the same with the pointer. Nothing assigns over it
/// or keeps its address elsewhere.
fn keepsWriterAt(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!bool {
    const facts = c.facts;
    switch (try Facts.accesses.useOf(facts, file, node)) {
        .member => |access| {
            // A method called on it is given it, or its address; a field is only read.
            if (try Facts.accesses.useOf(facts, file, access) != .callee) return true;
            // Kept where every method it may reach keeps it (`Facts.Join.all`).
            const methods = try facts.resolve(file, access);
            var keeps: Facts.Join = .{};
            for (Facts.valueParts(&methods)) |part| {
                keeps.add(part, if (part == .function) try keepsWriter(c, part.function, 0, depth) else null);
            }
            return keeps.all() orelse false;
        },
        .address => |address| {
            const argument = switch (try Facts.accesses.useOf(facts, file, address)) {
                .argument => |argument| argument,
                else => return false,
            };
            const made = (try Facts.calls.at(facts, file, argument.call)) orelse return false;
            const decl = switch (made.callee) {
                .function => |function| function,
                else => return false,
            };
            const args = switch (made.args) {
                .known => |each| each,
                .unknown => return false,
            };
            return keepsWriter(c, decl, std.mem.findScalar(Ast.Node.Index, args, address) orelse return false, depth);
        },
        else => return false,
    }
}

/// Whether the program's function `decl` keeps the cursor writer its parameter `index` gives
/// it as `keepsWriterAt` says: a copy, where the parameter is no pointer, holds nothing back.
fn keepsWriter(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!bool {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    if (!try Program.owns(c, decl.file)) return false;
    const memo = try c.facts.memo(Cursors);
    const key: Calls.Key = .{ .decl = decl, .index = index, .question = .keeps };
    if (memo.kept.get(key)) |known| return known;
    // A cycle back to a function being read, or one past the depth, shows nothing; what was
    // read while one was is not kept, as it depends on where the reading began.
    if (depth > depth_limit or memo.active.contains(key)) {
        memo.cuts += 1;
        return false;
    }
    try memo.active.put(c.allocator, key, {});
    defer _ = memo.active.remove(key);
    const cuts = memo.cuts;
    const found = try keepsWriterRead(c, decl, index, depth);
    if (memo.cuts == cuts) try memo.kept.put(c.allocator, key, found);
    return found;
}

fn keepsWriterRead(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!bool {
    const tree = &c.project.at(decl.file).file.tree;
    const model = &c.project.at(decl.file).model;
    const record = model.declarations[@backingInt(decl.index)];
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, record.node) orelse return false;
    var it = proto.iterate(tree);
    var position: usize = 0;
    const param = while (it.next()) |each| : (position += 1) {
        if (position == index) break each;
    } else return false;
    const name = param.name_token orelse return true;
    const kind = param.type_expr orelse return false;
    // A struct by value is a copy; a type named otherwise may be a pointer.
    if (tree.fullPtrType(kind) == null) return try c.facts.resolve(decl.file, kind) == .container;
    const id: Model.Declaration.Id = for (model.declarations, 0..) |each, d| {
        if (each.kind == .parameter and each.token == name) break @fromBackingInt(@intCast(d));
    } else return false;
    for (model.references) |ref| {
        if (try nameOf(c.facts, decl.file, ref.node) != id) continue;
        if (!try keepsPointerAt(c, decl.file, ref.node, depth + 1)) return false;
    }
    return true;
}

/// As `keepsWriterAt`, for a pointer to the writer: its fields named through it, or the
/// pointer itself handed on.
fn keepsPointerAt(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const parent = model.parentOf(node) orelse return false;
    var buffer: [1]Ast.Node.Index = undefined;
    switch (try Facts.accesses.useOf(c.facts, file, node)) {
        .member => return keepsWriterAt(c, file, node, depth),
        else => {
            const call = tree.fullCall(&buffer, parent) orelse return false;
            const position = std.mem.findScalar(Ast.Node.Index, call.ast.params, node) orelse return false;
            const callees = try c.facts.resolve(file, call.ast.fn_expr);
            if (callees != .function and callees != .alternatives) return false;
            const index = try parameterAt(c, file, call, position) orelse return false;
            // Kept where every function it may reach keeps it (`Facts.Join.all`).
            var keeps: Facts.Join = .{};
            for (Facts.valueParts(&callees)) |part| {
                keeps.add(part, if (part == .function) try keepsWriter(c, part.function, index, depth) else null);
            }
            return keeps.all() orelse false;
        },
    }
}

/// The store whose target `node` is (`x = v`, a destructure's), by its use
/// (`accesses.useOf`): null where it is no store's target.
fn writtenAt(facts: *Facts, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Facts.accesses.Site {
    return switch (try Facts.accesses.useOf(facts, file, node)) {
        .written => |site| site,
        else => null,
    };
}

/// Whether the type nodes `a` and `b` name one type: two names of one declaration (a generic's
/// `comptime T: type`, one value on each reading of its function), or two values that resolve
/// to one. Not known is not one.
fn sameTypeNamed(facts: *Facts, file: Project.FileId, a: Ast.Node.Index, b: Ast.Node.Index) Context.Error!bool {
    if (try nameOf(facts, file, a)) |x| if (try nameOf(facts, file, b)) |y| if (x == y) return true;
    return sameValue(try facts.resolve(file, a), try facts.resolve(file, b), 0);
}

/// The plain store `node` is (`x = v`, `accesses.formOf`), as `accesses.storeInto` reads its
/// target: null for any other node, and for `_ = v`, which stores nothing.
fn storeAt(facts: *Facts, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Facts.accesses.Site {
    const tree = &facts.project.at(file).file.tree;
    if (Facts.accesses.formOf(tree.nodeTag(node)) != .assign) return null;
    return Facts.accesses.storeInto(facts, file, tree.nodeData(node).node_and_node[0]);
}

/// The statement of a block that `node` is in and runs whenever the statement does: nothing
/// between them chooses (`if`, `switch`, `orelse`, `catch`, `and`, `or`, a loop's body) or
/// defers it, so a write there holds past the statement.
fn statementOf(model: *const Model, tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) switch (Model.runsWith(tree, parent, at)) {
        .sequenced, .labeled => return at,
        // A `for` that writes the memory it is given sets each element, so the memory is all
        // written once it ends: its inputs run every time.
        .always => {},
        // A deferred write runs where the scope ends, after what follows it.
        .branch, .loop, .deferred, .unevaluated, .compile_time, .function => return null,
    };
    return null;
}

/// Whether `use`, all of a parameter's memory (`part` null) or the part `part` of it, was
/// written by one of `written`'s statements before it in a block that holds it: the same part,
/// spelled alike, or all of it; with nothing between assigning a name the part's bounds spell.
fn coveredBefore(c: *Context, file: Project.FileId, written: anytype, part: ?Ast.Node.Index, use: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    for (written) |each| {
        if (each.part) |done| {
            const wanted = part orelse continue;
            if (!sameText(model, tree, done, wanted)) continue;
        }
        const block = model.parentOf(each.statement) orelse continue;
        var at = use;
        const statement = while (model.parentOf(at)) |parent| : (at = parent) {
            if (parent == block) break at;
        } else continue;
        if (statement == each.statement or tree.firstToken(statement) <= tree.lastToken(each.statement)) continue;
        // Through the end of the use's statement: what runs in it before the use, in any order.
        if (each.part) |done| if (try boundsChanged(c, file, done, tree.lastToken(each.statement), tree.lastToken(statement))) continue;
        return true;
    }
    return false;
}

/// Whether two nodes are spelled with the same tokens, each name naming the same declaration.
fn sameText(model: *const Model, tree: *const Ast, a: Ast.Node.Index, b: Ast.Node.Index) bool {
    const a_first = tree.firstToken(a);
    const b_first = tree.firstToken(b);
    const len = tree.lastToken(a) - a_first;
    if (tree.lastToken(b) - b_first != len) return false;
    for (0..len + 1) |i| {
        const at: Ast.TokenIndex = @intCast(i);
        const x = a_first + at;
        const y = b_first + at;
        if (!std.mem.eql(u8, tree.tokenSlice(x), tree.tokenSlice(y))) return false;
        if (tree.tokenTag(x) != .identifier or (x > 0 and tree.tokenTag(x - 1) == .period)) continue;
        const name = tree.tokenSlice(x);
        if (model.lookup(model.scopeOf(x), name, x) != model.lookup(model.scopeOf(y), name, y)) return false;
    }
    return true;
}

/// Whether the bounds of `slice` may differ between tokens `from` and `to`, by what each name
/// in them declares. Numbers, arithmetic, and names that cannot change there keep their value:
/// a constant, a parameter, a capture, a local `var` nothing assigns between and whose address
/// nothing takes; a container's constant (of each type a choice may give); the length of an
/// array, or of a slice such a name holds. Anything else (a field of a value, a dereference, a
/// call) may change.
fn boundsChanged(c: *Context, file: Project.FileId, slice: Ast.Node.Index, from: Ast.TokenIndex, to: Ast.TokenIndex) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const full = tree.fullSlice(slice) orelse return true;
    switch (Facts.accesses.formOf(tree.nodeTag(full.ast.sliced))) {
        .slice => if (try boundsChanged(c, file, full.ast.sliced, from, to)) return true,
        // A name (`Facts.definition`); any other memory may change.
        else => if (try nameOf(c.facts, file, full.ast.sliced) == null) return true,
    }
    if (!try fixedBetween(c, file, full.ast.start, from, to, 0)) return true;
    if (full.ast.end.unwrap()) |end| if (!try fixedBetween(c, file, end, from, to, 0)) return true;
    if (full.ast.sentinel.unwrap()) |sentinel| if (!try fixedBetween(c, file, sentinel, from, to, 0)) return true;
    return false;
}

fn fixedBetween(c: *Context, file: Project.FileId, node: Ast.Node.Index, from: Ast.TokenIndex, to: Ast.TokenIndex, depth: u8) Context.Error!bool {
    if (depth == 16) return false;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const at = Facts.ungrouped(tree, node);
    // A number written so (`Facts.literalOf`); no other literal is a bound.
    if (try c.facts.literalOf(file, at)) |literal| return literal == .number;
    switch (tree.nodeTag(at)) {
        .add, .sub, .mul, .div, .mod, .shl, .shr, .add_wrap, .sub_wrap, .mul_wrap, .add_sat, .sub_sat, .mul_sat => {
            const lhs, const rhs = tree.nodeData(at).node_and_node;
            return try fixedBetween(c, file, lhs, from, to, depth + 1) and try fixedBetween(c, file, rhs, from, to, depth + 1);
        },
        else => {},
    }
    if (try nameOf(c.facts, file, at)) |decl| {
        const record = model.declarations[@backingInt(decl)];
        switch (record.kind) {
            .parameter, .capture => return true,
            .function, .field => return false,
            .variable => {},
        }
        const variable = tree.fullVarDecl(record.node) orelse return false;
        if (tree.tokenTag(variable.ast.mut_token) == .keyword_const) return true;
        // A container's `var` is anyone's to change; a local's changes only where named.
        switch (model.scopes[@backingInt(record.scope)].kind) {
            .file, .container => return false,
            else => {},
        }
        for (model.references) |ref| {
            if (try nameOf(c.facts, file, ref.node) != decl) continue;
            const use = try Facts.accesses.useOf(c.facts, file, ref.node);
            switch (use) {
                // Its address taken, or a part of a destructure: it may change anywhere.
                .address, .destructured => return false,
                .written => |site| if (Facts.accesses.formOf(tree.nodeTag(site.node)) == .destructure) return false,
                else => {},
            }
            if (ref.token < from or ref.token > to) continue;
            // Stored to between them.
            if (use == .written or use == .updated) return false;
        }
        return true;
    }
    // A member (`Facts.accesses.memberRead`): an array's length, or a container's constant.
    const read = (try Facts.accesses.memberRead(c.facts, file, at)) orelse return false;
    const held = read.receiver.?; // unreachable: a member's step has its holder
    const value = read.holder.?; // unreachable: a member's step has its holder's value
    if ((try c.facts.lengthOf(file, at)) != null) switch (lengthBy(value)) {
        .fixed => return true,
        .not_fixed => return false,
        .holder => return fixedBetween(c, file, held, from, to, depth + 1),
        .other => {},
    };
    const member = read.name orelse return false;
    // A constant of every type it may be (`Facts.Join.all`); a choice of none is not known.
    var constant: Facts.Join = .{};
    for (Facts.valueParts(&value)) |part| constant.add(part, part == .container and constantMember(c, part.container, member));
    return constant.all() orelse false;
}

/// What fixes a length read through a holder of `value`, each part of it read
/// (`Facts.valueParts`): an array's own (`fixed`), as one a pointer to an array reads; what
/// holds a pointer to anything else, a slice's (`holder`). A pointer to a container, an
/// instance (its `len` field written through the pointer) or what is not known is not fixed,
/// nor a choice whose parts differ in kind; `other` where no part is an array or a pointer.
fn lengthBy(value: Facts.Value) enum { fixed, not_fixed, holder, other } {
    const parts = Facts.valueParts(&value);
    var shaped: usize = 0;
    var through_holder = false;
    for (parts) |part| {
        if (part == .array) {
            shaped += 1;
            continue;
        }
        if (part != .pointer) continue;
        shaped += 1;
        const children = Facts.valueParts(part.pointer.child);
        if (children.len == 0) return .not_fixed;
        for (children) |child| {
            if (child == .container or child == .instance or child == .unknown) return .not_fixed;
            if (child != .array) through_holder = true;
        }
    }
    if (shaped == 0) return .other;
    if (shaped != parts.len) return .not_fixed;
    return if (through_holder) .holder else .fixed;
}

/// Whether `container` declares `name` a constant.
fn constantMember(c: *Context, container: Facts.Container, name: []const u8) bool {
    const decl = c.facts.member(container, name) orelse return false;
    const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    if (record.kind != .variable) return false;
    const tree = &c.project.at(decl.file).file.tree;
    const variable = tree.fullVarDecl(record.node) orelse return false;
    return tree.tokenTag(variable.ast.mut_token) == .keyword_const;
}

/// A function's parameter at `index`: its declaration, where its type is a pointer (one the
/// function may write through, where `mutable`), and the function's body.
fn parameter(c: *Context, decl: Facts.Decl, index: usize, mutable: bool) Context.Error!?struct { id: Model.Declaration.Id, body: Ast.Node.Index } {
    const tree = &c.project.at(decl.file).file.tree;
    const model = &c.project.at(decl.file).model;
    const record = model.declarations[@backingInt(decl.index)];
    const function = model.parentOf(record.node) orelse return null;
    if (tree.nodeTag(function) != .fn_decl) return null;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, record.node) orelse return null;
    var it = proto.iterate(tree);
    var position: usize = 0;
    const param = while (it.next()) |each| : (position += 1) {
        if (position == index) break each;
    } else return null;
    const name = param.name_token orelse return null;
    const kind = param.type_expr orelse return null;
    const pointer = tree.fullPtrType(kind) orelse return null;
    if (mutable and pointer.const_token != null) return null;
    const id: Model.Declaration.Id = for (model.declarations, 0..) |each, d| {
        if (each.kind == .parameter and each.token == name) break @fromBackingInt(@intCast(d));
    } else return null;
    return .{ .id = id, .body = tree.nodeData(function).node_and_node[1] };
}

/// Whether the program's function `decl` writes the whole of what its parameter `index` points
/// at before any read of it, on every path that returns, read once per function and parameter.
/// A parameter that is not a mutable pointer, or a function without a body, writes nothing.
fn writesWhole(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!bool {
    return remembered(bool, c, .{ .decl = decl, .index = index, .question = .writes }, depth, writesWholeRead, false);
}

fn writesWholeRead(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!bool {
    const found = (try parameter(c, decl, index, true)) orelse return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = c.project.at(decl.file).file.tree.blockStatements(&buffer, found.body) orelse return false;
    var walk: Walk = .init(c, decl.file, found.id, true, depth);
    try walk.collect();
    const end = try walk.sequence(found.body, statements, .unwritten);
    if (walk.read != null or walk.exit_unwritten or (end.at != .written and end.at != .left)) return false;
    // Given `undefined` again, it must be written whole again before every return.
    for (try walk.undefinings()) |again| {
        var from: Walk = .init(c, decl.file, found.id, true, depth);
        try from.collect();
        const past = try from.onFrom(again.mention, again.left, found.body);
        if (from.read != null or from.exit_unwritten or (past.at != .written and past.at != .left)) return false;
    }
    return true;
}

/// What the program's functions were found to do with a parameter, kept once per function,
/// parameter and question. A reading cut short (a cycle back to a function being read, or one
/// past the depth) shows nothing, and what was read while one was is kept only for the pass of
/// the outermost reading: it depends on where the reading began, and another may show more.
const Calls = struct {
    const Key = struct { decl: Facts.Decl, index: usize, question: enum { writes, keeps, parts, needs, holds, undefines } };
    found: std.AutoHashMapUnmanaged(Key, bool) = .empty,
    needed: std.AutoHashMapUnmanaged(Key, ?Needs) = .empty,
    left: std.AutoHashMapUnmanaged(Key, Left) = .empty,
    /// The `undefines` readings under way, outermost first, each with what it has shown so far;
    /// and the outermost of them a reading under way leaned on.
    reading: std.ArrayList(struct { key: Key, sofar: Left }) = .empty,
    lowest: usize = std.math.maxInt(usize),
    /// What a reading that leaned on one above it showed, kept for that one's pass (`head`, its
    /// place in `reading`): read again only when that one is.
    /// One that leaned on what a function past the depth is assumed to leave is `assumed`: kept
    /// while a pass of `readDeferred` holds its assumptions (`holding`), past the reading from
    /// the top (`top`) that showed it, and never kept past the pass.
    provisional: std.AutoHashMapUnmanaged(Key, struct { left: Left, head: usize, assumed: bool, top: usize }) = .empty,
    holding: bool = false,
    top: usize = 0,
    /// How many functions' parameters `undefines` has read, for the test that keeps it linear.
    reads: usize = 0,
    /// What readings cut short (a cycle back to a function being read, or one past the depth)
    /// showed, kept for the outermost reading's pass so each is read once a pass, not once a
    /// path; and how many readings `remembered` made, for the test that keeps it linear.
    found_this_pass: std.AutoHashMapUnmanaged(Key, bool) = .empty,
    needed_this_pass: std.AutoHashMapUnmanaged(Key, ?Needs) = .empty,
    remembered_reads: usize = 0,
    active: std.AutoHashMapUnmanaged(Key, void) = .empty,
    cuts: usize = 0,
    /// The `undefines` readings cut at the depth, unread, deepest last (`readDeferred`), and
    /// what each is taken to leave meanwhile: from nothing, then what its reading from the top
    /// showed, which only grows.
    deferred: std.ArrayList(Key) = .empty,
    assumed: std.AutoHashMapUnmanaged(Key, Left) = .empty,
    /// The readings from the top made since the assumptions last grew: each holds for them.
    fresh: std.AutoHashMapUnmanaged(Key, void) = .empty,
};

/// Reads each function a reading cut at the depth took at what it is assumed to leave, from the
/// top: what a function leaves undefined does not depend on who asks. Each read grows its
/// assumption to what it showed; those its reading took are read after it, deeper first, and
/// what the readings showed under the assumptions is kept for the pass. An assumption that
/// grows drops that, and each function read is read again; one read since the last growth is
/// not. True where an assumption grew, so what leaned on it is to be asked again; false where
/// every one held, the least answer, as a recursion's is; null where `budget` readings did not
/// end the pass.
fn readDeferred(c: *Context) Context.Error!?bool {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Calls);
    memo.holding = true;
    defer {
        memo.holding = false;
        dropAssumed(c.allocator, memo);
    }
    var queued: std.AutoHashMapUnmanaged(Calls.Key, void) = .empty;
    defer queued.deinit(c.allocator);
    var work: std.ArrayList(Calls.Key) = .empty;
    defer work.deinit(c.allocator);
    var done: std.ArrayList(Calls.Key) = .empty;
    defer done.deinit(c.allocator);
    var budget: usize = 4096;
    var grew = false;
    while (true) {
        while (memo.deferred.pop()) |key| if (!memo.fresh.contains(key) and !queued.contains(key)) {
            try queued.put(c.allocator, key, {});
            try work.append(c.allocator, key);
        };
        const key = work.pop() orelse return grew;
        _ = queued.remove(key);
        if (budget == 0) return null;
        budget -= 1;
        memo.top += 1;
        const shown = try undefines(c, key.decl, key.index, 0);
        try memo.fresh.put(c.allocator, key, {});
        try done.append(c.allocator, key);
        const before = memo.assumed.get(key) orelse Left{ .mask = 0, .owner = null };
        const after: Left = .{ .mask = before.mask | shown.mask, .owner = shown.owner, .failing = before.failing | shown.failing, .known = before.known and shown.known };
        if (after.mask == before.mask and after.failing == before.failing and after.known == before.known) continue;
        try memo.assumed.put(c.allocator, key, after);
        grew = true;
        // What was read under the smaller assumption is read again.
        dropAssumed(c.allocator, memo);
        memo.fresh.clearRetainingCapacity();
        try memo.deferred.appendSlice(c.allocator, done.items);
        done.clearRetainingCapacity();
    }
}

/// Drops what readings that leaned on an assumption showed.
fn dropAssumed(gpa: std.mem.Allocator, memo: *Calls) void {
    var each = memo.provisional.iterator();
    var stale: std.ArrayList(Calls.Key) = .empty;
    defer stale.deinit(gpa);
    while (each.next()) |entry| if (entry.value_ptr.assumed) stale.append(gpa, entry.key_ptr.*) catch {
        // Out of memory: drop every one, assumed or not, which only reads them again.
        memo.provisional.clearRetainingCapacity();
        return;
    };
    for (stale.items) |key| _ = memo.provisional.remove(key);
}

/// What of a parameter's memory a function may read before writing it: the parts in `mask`, of
/// the struct `owner` (or the array of that many elements) the parameter points at.
const Needs = struct { mask: u64, owner: Owner };
const Owner = union(enum) { container: struct { file: Project.FileId, scope: Model.Scope.Id }, elements: u7 };

fn remembered(comptime T: type, c: *Context, key: Calls.Key, depth: u8, comptime read: fn (*Context, Facts.Decl, usize, u8) Context.Error!T, comptime cut: T) Context.Error!T {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Calls);
    const map = if (T == bool) &memo.found else &memo.needed;
    const pass = if (T == bool) &memo.found_this_pass else &memo.needed_this_pass;
    if (map.get(key)) |known| return known;
    // Shown by a reading cut short in this pass: as cut for the one asking.
    if (pass.get(key)) |kept| {
        memo.cuts += 1;
        return kept;
    }
    if (depth > depth_limit or memo.active.contains(key)) {
        memo.cuts += 1;
        return cut;
    }
    try memo.active.put(c.allocator, key, {});
    defer _ = memo.active.remove(key);
    memo.remembered_reads += 1;
    const cuts = memo.cuts;
    const shown = try read(c, key.decl, key.index, depth);
    try (if (memo.cuts == cuts) map else pass).put(c.allocator, key, shown);
    // The outermost reading ends its pass: what a cut shaped is read again in the next.
    if (memo.active.count() == 1) {
        memo.found_this_pass.clearRetainingCapacity();
        memo.needed_this_pass.clearRetainingCapacity();
    }
    return shown;
}

/// What of the memory its pointer parameter `index` points at a function `decl`, the program's
/// or std's, gives `undefined` and leaves so on some path that returns: given it there
/// (`self.* = undefined`, a field, `@memset(…, undefined)`), or handing it, or a field of it,
/// to such a function (`self.list.deinit(gpa)`), with nothing after writing it again on that
/// path. An error's `return` is such a path: a caller's `catch` goes on from it. The parts are
/// of what the parameter points at (`owner`).
/// A function reached again while it is being read (recursion) is taken at what its reading
/// has shown so far, from nothing, and read again until that holds still: what some path of it
/// gives `undefined`, whatever the recursion. Only what such a reading showed of itself is
/// kept; a function past the depth is taken at what it is assumed to leave (`readDeferred`).
fn undefines(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!Left {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Calls);
    const key: Calls.Key = .{ .decl = decl, .index = index, .question = .undefines };
    if (memo.left.get(key)) |known| return known;
    if (memo.provisional.get(key)) |kept| {
        memo.lowest = @min(memo.lowest, kept.head);
        // Shown under an assumption: so is what leans on it.
        if (kept.assumed) memo.cuts += 1;
        return kept.left;
    }
    for (memo.reading.items, 0..) |each, at| if (std.meta.eql(each.key, key)) {
        memo.lowest = @min(memo.lowest, at);
        return each.sofar;
    };
    // Past the depth: what it is assumed to leave, which `readDeferred` reads it for.
    if (depth > undefines_depth_limit) {
        memo.cuts += 1;
        try memo.deferred.append(c.allocator, key);
        return memo.assumed.get(key) orelse .{ .mask = 0, .owner = null };
    }
    const at = memo.reading.items.len;
    const lowest = memo.lowest;
    try memo.reading.append(c.allocator, .{ .key = key, .sofar = .{ .mask = 0, .owner = null } });
    defer _ = memo.reading.pop();
    const cuts = memo.cuts;
    while (true) {
        memo.lowest = std.math.maxInt(usize);
        const shown = try undefinesRead(c, decl, index, depth);
        const sofar = &memo.reading.items[at].sofar;
        const settled: Left = .{ .mask = shown.mask | sofar.mask, .owner = shown.owner, .failing = shown.failing | sofar.failing, .known = shown.known and sofar.known };
        if (memo.lowest > at or (settled.mask == sofar.mask and settled.failing == sofar.failing)) {
            const above = memo.lowest < at;
            // Leaning on a reading above it, it is kept for that one's pass; cut short, for the
            // outermost reading's: read once a pass either way, and never kept past it.
            const head: ?usize = if (above) memo.lowest else if (memo.cuts != cuts and (at > 0 or memo.holding)) 0 else null;
            if (head) |outer| {
                var each = memo.provisional.iterator();
                while (each.next()) |entry| if (entry.value_ptr.head >= at) {
                    entry.value_ptr.head = outer;
                };
                try memo.provisional.put(c.allocator, key, .{ .left = settled, .head = outer, .assumed = memo.cuts != cuts, .top = memo.top });
            } else {
                try settle(c.allocator, memo, at, memo.cuts == cuts);
                if (memo.cuts == cuts) try memo.left.put(c.allocator, key, settled);
            }
            memo.lowest = @min(lowest, if (above) memo.lowest else std.math.maxInt(usize));
            return settled;
        }
        // Read again from what it has shown: what leaned on the last pass leans on nothing now.
        try settle(c.allocator, memo, at, false);
        sofar.* = settled;
    }
}

/// Ends the pass of the reading at `head` in `reading`: what leaned on it is kept where `keep`
/// and it leaned on no assumption, and dropped either way from what is provisional. What an
/// earlier reading from the top showed under the assumptions a pass holds stays.
fn settle(gpa: std.mem.Allocator, memo: *Calls, head: usize, keep: bool) Context.Error!void {
    var done: std.ArrayList(Calls.Key) = .empty;
    defer done.deinit(gpa);
    var each = memo.provisional.iterator();
    while (each.next()) |entry| if (entry.value_ptr.head >= head) {
        if (memo.holding and entry.value_ptr.assumed and entry.value_ptr.top != memo.top) continue;
        try done.append(gpa, entry.key_ptr.*);
        if (keep and !entry.value_ptr.assumed) try memo.left.put(gpa, entry.key_ptr.*, entry.value_ptr.left);
    };
    for (done.items) |key| _ = memo.provisional.remove(key);
}

fn undefinesRead(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!Left {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    (try c.facts.memo(Calls)).reads += 1;
    const found = (try parameter(c, decl, index, true)) orelse return .{ .mask = 0, .owner = null };
    var walk: Walk = .init(c, decl.file, found.id, true, depth);
    try walk.collect();
    var mask: u64 = 0;
    var failing: u64 = 0;
    for (try walk.undefinings()) |again| {
        const exits = try walk.leftExits(again.mention, again.left, found.body);
        if (exits.success) mask |= again.left;
        if (exits.failure) failing |= again.left;
    }
    var known = true;
    for (walk.mentions) |mention| {
        walk.unknown = false;
        walk.failing = 0;
        walk.leaving = 0;
        const left = try walk.undoneBy(mention);
        const unknown = walk.unknown;
        // What the call's failure leaves with: returned at once, by an error or by a `return`.
        failing |= walk.failing | walk.leaving;
        mask |= walk.leaving;
        if (unknown and (walk.failing | walk.leaving) != 0) known = false;
        if (left == 0) continue;
        const exits = try walk.leftExits(mention, left, found.body);
        if (exits.success) mask |= left;
        if (exits.failure) failing |= left;
        if (unknown and (exits.success or exits.failure)) known = false;
    }
    return .{ .mask = mask, .owner = walk.owner, .failing = failing, .known = known };
}

/// The parts of what a parameter points at a function leaves `undefined` (`undefines`), of
/// `owner`'s struct or array; every bit set, all of it.
const Left = struct {
    /// What it leaves on an exit that does not return an error.
    mask: u64,
    owner: ?Owner,
    /// What it leaves on an exit that returns an error, which a caller's `try` passes on and a
    /// `catch` that goes on goes on with.
    failing: u64 = 0,
    /// False where a call it was handed to reaches a function not known here, which may give
    /// it `undefined` (`Walk.unknown`): the mask holds that as all it was handed.
    known: bool = true,
};

/// What of the memory its pointer parameter `index` points at the program's function `decl`
/// may read before writing it, on any path, as parts of that memory: null where it may read
/// any of it, hands it where nothing shows what is read there, keeps the pointer, or the
/// parameter's memory has no parts known.
fn needs(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!?Needs {
    return remembered(?Needs, c, .{ .decl = decl, .index = index, .question = .needs }, depth, needsRead, null);
}

fn needsRead(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!?Needs {
    const found = (try parameter(c, decl, index, false)) orelse return null;
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = c.project.at(decl.file).file.tree.blockStatements(&buffer, found.body) orelse return null;
    var walk: Walk = .init(c, decl.file, found.id, true, depth);
    walk.needing = true;
    try walk.collect();
    const owner = walk.owner orelse return null;
    _ = try walk.sequence(found.body, statements, .unwritten);
    if (walk.read != null) return null;
    return .{ .mask = walk.needed, .owner = owner };
}

/// Whether `decl` is known to be one of std's calls `list` names, at its parameter `index`.
/// One not known to be is not: std's own is then read for what it reads of what it is given,
/// and nothing it writes is taken as written.
fn named(c: *Context, list: []const Named, decl: Facts.Decl, index: usize) Context.Error!bool {
    for (list) |each| {
        if (each.param != index) continue;
        if (try stdAt(c, decl, each.path) == .yes) return true;
    }
    return false;
}

const Match = enum { yes, no, unknown };

/// Whether the function `decl` is std's declaration at `path`, through the aliases that one is
/// spelled by: not known where std's declarations are not read (the budget) or an alias of
/// one is not followed. Each caller takes `unknown` the way that clears nothing.
fn stdAt(c: *Context, decl: Facts.Decl, path: []const u8) Context.Error!Match {
    const found = switch (try Governed.declarations(c, "std", path)) {
        .decls => |each| each,
        .none => return .no,
        .unknown => return .unknown,
    };
    var answer: Match = .no;
    for (found) |each| switch (try c.facts.origin(each)) {
        .decl => |target| if (std.meta.eql(target, decl)) return .yes,
        .none => if (std.meta.eql(each, decl)) return .yes,
        .unknown => answer = .unknown,
    };
    return answer;
}

/// Whether a `return` returns an error by name (`return error.Short`) from a function whose
/// result is an error union: a path the caller's `try` leaves by. One whose result is an error
/// set returns the error as its value, a path like any other.
fn errorReturn(facts: *Facts, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &facts.project.at(file).file.tree;
    const model = &facts.project.at(file).model;
    const operand = tree.nodeData(node).opt_node.unwrap() orelse return false;
    const literal = (try facts.literalOf(file, operand)) orelse return false;
    if (literal != .error_value) return false;
    var at = node;
    const function = while (model.parentOf(at)) |up| : (at = up) {
        if (tree.nodeTag(up) == .fn_decl) break up;
    } else return false;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(function).node_and_node[0]) orelse return false;
    const result = proto.ast.return_type.unwrap() orelse return false;
    return mayFail(facts, file, result);
}

/// Whether a function whose result is `result` may fail: its result is an error union, written
/// or named (`Facts.resolve`), or `!T`, whose errors it infers.
fn mayFail(facts: *Facts, file: Project.FileId, result: Ast.Node.Index) Context.Error!bool {
    if (Model.inferredErrors(&facts.project.at(file).file.tree, result)) return true;
    return try facts.resolve(file, result) == .error_union;
}

fn merge(a: State, b: State) State {
    if (a.at == .done or b.at == .done) return .done;
    // A path that left reaches nothing after the branch.
    if (a.at == .left) return b;
    if (b.at == .left) return a;
    if (a.at == .written and b.at == .written) return .written;
    // Written on some paths only: a read that follows may read it undefined, past the parts
    // every path wrote.
    return .{ .at = .unwritten, .parts = a.have() & b.have(), .guard = if (a.guard != null and b.guard != null and a.guard.?.call == b.guard.?.call) a.guard else null };
}

/// The fields of a struct (`container`), by name: none for a union, an enum, a tuple, one of
/// no fields or of more than 64. A `comptime` field holds its value already.
const ShapeKey = struct { file: Project.FileId, scope: Model.Scope.Id };
const Shapes = struct { of: std.AutoHashMapUnmanaged(ShapeKey, Shape) = .empty };

/// The parts of a container, of its syntax: read once for the run.
fn fieldsOf(c: *Context, container: Facts.Container) Context.Error!Shape {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const key: ShapeKey = .{ .file = container.file, .scope = container.scope };
    if ((try c.facts.memo(Shapes)).of.get(key)) |known| return known;
    const shape = try fieldsRead(c, container);
    try (try c.facts.memo(Shapes)).of.put(c.allocator, key, shape);
    return shape;
}

fn fieldsRead(c: *Context, container: Facts.Container) Context.Error!Shape {
    const source = c.project.at(container.file);
    const tree = &source.file.tree;
    const scope = source.model.scopes[@backingInt(container.scope)];
    switch (scope.kind) {
        .file => {},
        .container => {
            var buffer: [2]Ast.Node.Index = undefined;
            const decl = tree.fullContainerDecl(&buffer, scope.node) orelse return .none;
            if (tree.tokenTag(decl.ast.main_token) != .keyword_struct) return .none;
        },
        else => return .none,
    }
    var found: std.ArrayList([]const u8) = .empty;
    for (source.model.declarations) |decl| {
        if (decl.kind != .field or decl.scope != container.scope) continue;
        const field = source.model.containerField(tree, decl.node) orelse return .none;
        if (field.ast.tuple_like) return .none;
        if (field.comptime_token != null) continue;
        try found.append(c.allocator, decl.name);
    }
    if (found.items.len == 0 or found.items.len > 64) return .none;
    return .{ .fields = found.items };
}

/// The conversions the project's `@fieldParentPtr`s make, read once: each the struct it gives,
/// where its result location names one, and the field it names, where that is spelled out. A
/// pointer to such a field of such a struct may be turned back into one to what holds it. A
/// name a function is given (`comptime member: []const u8`) is each name its calls spell, and
/// any where one does not spell it or the function is named other than to be called.
const ParentNames = struct {
    read: bool = false,
    conversions: std.ArrayList(Conversion) = .empty,

    /// A null `owner` may be any struct, a null `name` any field.
    const Conversion = struct { owner: ?Facts.Container, name: ?[]const u8 };
};

/// Whether something in the project may convert a pointer to `owner`'s field `name` back to
/// one to `owner`.
fn parentNamed(c: *Context, owner: Owner, name: []const u8) Context.Error!bool {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(ParentNames);
    if (!memo.read) {
        memo.read = true;
        var given: std.ArrayList(Given) = .empty;
        defer given.deinit(c.allocator);
        for (c.project.sources) |*source| {
            const tree = &source.file.tree;
            for (0..tree.nodes.len) |i| {
                const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (!Facts.isBuiltin(tree, node, "@fieldParentPtr")) continue;
                const converted = try ParentPointer.converts(c, source.id, node);
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, node, &buffer);
                const any: ParentNames.Conversion = .{ .owner = converted, .name = null };
                if (args.len == 0) {
                    try memo.conversions.append(c.allocator, any);
                    continue;
                }
                // The name it spells (`Facts.fieldName`), each a list it ranges over holds, or
                // a parameter's, which each call gives.
                switch (try c.facts.fieldName(source.id, args[0])) {
                    .name => |field| try memo.conversions.append(c.allocator, .{ .owner = converted, .name = field }),
                    .names => |fields| for (fields) |field| try memo.conversions.append(c.allocator, .{ .owner = converted, .name = field }),
                    .each_of, .computed => if (try nameGiven(c.facts, source, node, args[0])) |found| {
                        var each = found;
                        each.owner = converted;
                        try given.append(c.allocator, each);
                    } else try memo.conversions.append(c.allocator, any),
                }
            }
        }
        for (given.items) |each| try spellCalls(c, memo, each);
    }
    const held = switch (owner) {
        .container => |container| container,
        .elements => return false,
    };
    for (memo.conversions.items) |each| {
        if (each.owner) |to| if (to.file != held.file or to.scope != held.scope) continue;
        if (each.name) |spelled| if (!std.mem.eql(u8, spelled, name)) continue;
        return true;
    }
    return false;
}

/// A function's parameter a `@fieldParentPtr` takes its field's name from: the function's name
/// and the parameter's place, with the struct the conversion gives.
const Given = struct { function: Facts.Decl, index: usize, owner: ?Facts.Container = null };

fn nameGiven(facts: *Facts, source: *const Project.Source, node: Ast.Node.Index, spelled: Ast.Node.Index) Context.Error!?Given {
    const tree = &source.file.tree;
    const model = &source.model;
    const decl = model.declarations[@backingInt((try nameOf(facts, source.id, spelled)) orelse return null)];
    if (decl.kind != .parameter) return null;
    var at = node;
    const function = while (model.parentOf(at)) |up| : (at = up) {
        if (tree.nodeTag(up) == .fn_decl) break up;
    } else return null;
    // A function is declared at its prototype.
    const prototype = tree.nodeData(function).node_and_node[0];
    const declared = for (model.declarations, 0..) |record, i| {
        if (record.kind == .function and record.node == prototype) break i;
    } else return null;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, prototype) orelse return null;
    var it = proto.iterate(tree);
    var index: usize = 0;
    while (it.next()) |param| : (index += 1) {
        if (param.name_token == decl.token) return .{ .function = .{ .file = source.id, .index = @fromBackingInt(@intCast(declared)) }, .index = index };
    }
    return null;
}

/// Adds the names each call of `given.function` gives its parameter (`Facts.programCallSites`,
/// `Facts.fieldName`): any field where a call gives one no name spells or the function is used
/// other than to be called.
fn spellCalls(c: *Context, memo: *ParentNames, given: Given) Context.Error!void {
    const any: ParentNames.Conversion = .{ .owner = given.owner, .name = null };
    const sites = (try c.facts.programCallSites(given.function)) orelse return memo.conversions.append(c.allocator, any);
    for (sites) |site| {
        // A method's parameters count the receiver its call passes first.
        if (given.index < site.receiver or given.index - site.receiver >= site.params.len) return memo.conversions.append(c.allocator, any);
        switch (try c.facts.fieldName(site.file, site.params[given.index - site.receiver])) {
            .name => |name| try memo.conversions.append(c.allocator, .{ .owner = given.owner, .name = name }),
            .names => |names| for (names) |name| try memo.conversions.append(c.allocator, .{ .owner = given.owner, .name = name }),
            .each_of, .computed => return memo.conversions.append(c.allocator, any),
        }
    }
}

/// Whether `node` never goes on to what follows it: a `return`, `break`, `continue` or
/// `unreachable`, or an unlabeled block whose last statement is one.
fn leavesAlways(tree: *const Ast, node: Ast.Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .@"return", .@"break", .@"continue", .unreachable_literal => return true,
        else => {},
    }
    if (!isBlock(tree, node) or blockLabel(tree, node) != null) return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, node).?;
    return statements.len > 0 and leavesAlways(tree, statements[statements.len - 1]);
}

/// Whether a value is `undefined` or holds it: a literal giving it a field or an element, at
/// any depth (`.{ .n = 0, .buf = undefined }`), one joined to another (`a ++ .{undefined}`), or
/// `undefined` as a type (`@as(T, undefined)`).
fn holdsUndefined(facts: *Facts, file: Project.FileId, value: Ast.Node.Index) Context.Error!bool {
    const tree = &facts.project.at(file).file.tree;
    const node = Facts.ungrouped(tree, value);
    if (try facts.literalOf(file, node)) |literal| return literal == .undefined;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, node)) |literal| {
        for (literal.ast.fields) |field| if (try holdsUndefined(facts, file, field)) return true;
        return false;
    }
    if (tree.fullArrayInit(&buffer, node)) |literal| {
        for (literal.ast.elements) |element| if (try holdsUndefined(facts, file, element)) return true;
        return false;
    }
    if (tree.nodeTag(node) == .array_cat) {
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        return try holdsUndefined(facts, file, lhs) or try holdsUndefined(facts, file, rhs);
    }
    if (Facts.isBuiltin(tree, node, "@as")) {
        const args = Facts.builtinArgs(tree, node, &buffer);
        return args.len == 2 and try holdsUndefined(facts, file, args[1]);
    }
    return false;
}

/// Whether `undefined` is spelled anywhere in `node`.
fn spellsUndefined(tree: *const Ast, node: Ast.Node.Index) bool {
    var token = tree.firstToken(node);
    while (token <= tree.lastToken(node)) : (token += 1) {
        if (tree.tokenTag(token) == .identifier and std.mem.eql(u8, tree.tokenSlice(token), "undefined")) return true;
    }
    return false;
}

/// Whether `node` sits in an operand of `@TypeOf`, which Zig types and never runs, within its
/// function.
fn unevaluated(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    var at = node;
    while (model.parentOf(at)) |up| : (at = up) {
        if (tree.nodeTag(up) == .fn_decl) return false;
        if (Facts.isBuiltin(tree, up, "@TypeOf")) return true;
    }
    return false;
}

/// The label a block carries (`blk: { … }`), by its token.
fn blockLabel(tree: *const Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    const brace = tree.nodeMainToken(node);
    if (brace < 2 or tree.tokenTag(brace - 1) != .colon or tree.tokenTag(brace - 2) != .identifier) return null;
    return brace - 2;
}

/// Whether a `break` or `continue` may go to `node`: a loop, a `switch`, a labeled block.
fn jumpable(tree: *const Ast, node: Ast.Node.Index) bool {
    if (tree.fullWhile(node) != null or tree.fullFor(node) != null or tree.fullSwitch(node) != null) return true;
    return isBlock(tree, node) and blockLabel(tree, node) != null;
}

/// The declaration of `file` that `node` names (`Facts.definition`), as a name: never as a
/// member read (`a.b`, `@field(a, "b")`), which names a member of its holder and no local or
/// parameter. Null for a primitive, another file's declaration and a name that does not resolve.
fn nameOf(facts: *Facts, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Model.Declaration.Id {
    if (Facts.accesses.formOf(facts.project.at(file).file.tree.nodeTag(node)) == .member) return null;
    return switch (try facts.definition(file, node)) {
        .decl => |decl| if (decl.file == file) decl.index else null,
        .none, .unknown => null,
    };
}

fn isBlock(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => true,
        else => false,
    };
}

/// Where a `break` or `continue` goes: the construct its label names, or the innermost loop
/// whose body holds it; null past the function.
fn jumpTarget(tree: *const Ast, model: *const Model, node: Ast.Node.Index) ?Ast.Node.Index {
    const label_token, _ = tree.nodeData(node).opt_token_and_opt_node;
    const label: ?[]const u8 = if (label_token.unwrap()) |token| tree.tokenSlice(token) else null;
    var at = node;
    while (model.parentOf(at)) |up| : (at = up) {
        if (tree.nodeTag(up) == .fn_decl) return null;
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buffer, up) != null) return null;
        var name: ?Ast.TokenIndex = null;
        // A jump in a loop's condition, inputs or `else` goes past that loop.
        var body = false;
        if (tree.fullWhile(up)) |loop| {
            name = loop.label_token;
            body = at == loop.ast.then_expr or at.toOptional() == loop.ast.cont_expr;
        } else if (tree.fullFor(up)) |loop| {
            name = loop.label_token;
            body = at == loop.ast.then_expr;
        } else if (tree.fullSwitch(up)) |choice| {
            name = choice.label_token;
        } else if (isBlock(tree, up)) {
            name = blockLabel(tree, up);
        } else continue;
        if (label) |wanted| {
            if (name) |token| if (std.mem.eql(u8, tree.tokenSlice(token), wanted)) return up;
        } else if (body) return up;
    }
    return null;
}

/// Whether what `inner` does runs on some paths through `top` only: in a branch of an `if` or a
/// `switch`, past `orelse` or `catch`, `and` or `or`, in a loop, or in a labeled block past a
/// statement a `break` in it may leave early by.
fn conditional(tree: *const Ast, model: *const Model, inner: Ast.Node.Index, top: Ast.Node.Index) bool {
    var at = inner;
    while (at != top) : (at = model.parentOf(at).?) {
        const up = model.parentOf(at) orelse return true;
        switch (Model.runsWith(tree, up, at)) {
            .always, .sequenced, .compile_time, .deferred => {},
            // A labeled block's statement runs wherever the block does unless one before it may
            // break: a `continue`, `return` or `try` before it leaves what holds the block too
            // (`one[0] = v; break :blk &one;` writes `one` before the break hands it on).
            .labeled => if (breaksBefore(tree, up, at)) return true,
            // Never run here: `@TypeOf`'s operand, another function's body.
            .branch, .loop, .unevaluated, .function => return true,
        }
    }
    return false;
}

/// Whether a statement of `block` before `statement` holds a `break`.
fn breaksBefore(tree: *const Ast, block: Ast.Node.Index, statement: Ast.Node.Index) bool {
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, block) orelse return true;
    for (statements) |each| {
        if (each == statement) return false;
        var token = tree.firstToken(each);
        while (token <= tree.lastToken(each)) : (token += 1) if (tree.tokenTag(token) == .keyword_break) return true;
    }
    return true;
}

/// Whether a `for` input is a range of literals with a pass in it (`0..2`).
/// Whether `start` is the stride `k` times the pass `i` of `n`: `k * i`, `i * k`, or counting
/// down, `k * (n - 1 - i)`.
fn strideAt(w: *const Walk, start: Ast.Node.Index, stride: u64, index: []const u8, count: u64) Context.Error!bool {
    const tree = w.tree;
    if (tree.nodeTag(start) != .mul) return false;
    const a, const b = tree.nodeData(start).node_and_node;
    const pass = Facts.ungrouped(tree, if (try w.constant(a) == stride) b else if (try w.constant(b) == stride) a else return false);
    if (try w.isNamed(pass, index)) return true;
    if (tree.nodeTag(pass) != .sub) return false;
    const left, const right = tree.nodeData(pass).node_and_node;
    if (!try w.isNamed(right, index) or tree.nodeTag(left) != .sub) return false;
    const n, const one = tree.nodeData(left).node_and_node;
    return try w.constant(n) == count and try w.constant(one) == 1;
}

/// Whether a loop over `input` runs a pass: a range whose end is past its start, each a constant
/// (`0..n`), or memory of a known length above zero, a literal's elements (`.{ a, b }`) or an
/// array's (`Range.memoryLength`). Every input of one loop has the same length.
fn passes(c: *Context, file: Project.FileId, input: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const at = Facts.ungrouped(tree, input);
    if (tree.nodeTag(at) == .for_range) {
        const start, const end = tree.nodeData(at).node_and_opt_node;
        const from = try Range.constantValue(c, file, start) orelse return false;
        const to = try Range.constantValue(c, file, end.unwrap() orelse return false) orelse return false;
        return to > from;
    }
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullArrayInit(&buffer, at)) |literal| return literal.ast.elements.len > 0;
    const length = try Range.memoryLength(c, file, at) orelse return false;
    return length > 0;
}

/// Whether `node` names a member `name`: `.SUCCESS`, or `E.SUCCESS` of some enum.
fn isMember(facts: *Facts, file: Project.FileId, node: Ast.Node.Index, name: []const u8) Context.Error!bool {
    const at = Facts.ungrouped(&facts.project.at(file).file.tree, node);
    if (try facts.literalOf(file, at)) |literal| return literal == .enum_literal and std.mem.eql(u8, literal.enum_literal, name);
    const read = (try Facts.accesses.memberRead(facts, file, at)) orelse return false;
    return std.mem.eql(u8, read.name orelse return false, name);
}

/// A ring of diamonds deeper than the depths the summaries follow: each level reaches the next
/// by two paths, and the last goes back to the first. Read once per function a pass, a count
/// stays near the functions'; read again on each path, it doubles per level. `main` hands the
/// ring `local`, declared `S` as `declared` spells. Returns how many functions it holds.
fn diamonds(gpa: std.mem.Allocator, source: *std.ArrayList(u8), declared: []const u8) !usize {
    const n = 12;
    try source.print(gpa, "const S = struct {{ a: u32 }};\n", .{});
    for (0..n) |i| try source.print(gpa,
        \\fn g{d}(p: *S, k: u32) void {{ if (k == 0) return; l{d}(p, k - 1); r{d}(p, k - 1); }}
        \\fn l{d}(p: *S, k: u32) void {{ g{d}(p, k); }}
        \\fn r{d}(p: *S, k: u32) void {{ g{d}(p, k); }}
        \\
    , .{ i, i, i, i, i + 1, i, i + 1 });
    try source.print(gpa, "fn g{d}(p: *S, k: u32) void {{ g0(p, k); }}\n", .{n});
    try source.print(gpa, "pub fn main() u32 {{ var local: {s}; g0(&local, 3); return local.a; }}\n", .{declared});
    return 3 * n + 1;
}

/// Runs A019's reads over `source`, the program alone, and gives its summaries' memo.
fn readSummaries(gpa: std.mem.Allocator, source: []const u8) !Calls {
    const Report = @import("Report.zig");
    const Probe = struct {
        const id: Rule = @fromBackingInt(1000); // safe: an extension identity the test owns.
        const config: @import("Rule.zig").Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = id, .level = .report }} };
        fn never(_: *Context, _: Model.Declaration) Context.Error!bool {
            return false;
        }
        fn diagnostic(_: *Context.Sink, _: Rule, _: u32, _: u32, _: []const u8, _: []const Report.Span, _: []const Report.Edit) Context.Error!void {}
        fn coverage(_: *Context.Sink, _: Report.Coverage) Context.Error!void {}
        fn configOf(_: *Context.Sink, _: Project.FileId) @import("Rule.zig").Config {
            return config;
        }
    };
    var project = try Project.init(gpa, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    // A program std's AstGen refuses is never read: it would pass with no summary read.
    try std.testing.expectEqual(.parsed, project.sources[0].file.status);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    var sink: Context.Sink = .{ .diagnostic = Probe.diagnostic, .coverage = Probe.coverage, .config = Probe.configOf };
    const definitions = [_]@import("Rule.zig").Definition{.{ .id = Probe.id, .name = "SUMMARIES", .group = .family_policy, .purpose = "counts summaries", .version = 1 }};
    var c: Context = .{ .allocator = arena.allocator(), .project = &project, .file = project.sources[0].id, .config = Probe.config, .facts = &facts, .definitions = &definitions, .sink = &sink };
    try reads(&c, Probe.id, Probe.never);
    const memo = try facts.memo(Calls);
    return .{ .reads = memo.reads, .remembered_reads = memo.remembered_reads };
}

test "summaries are read a bounded number of times per function, through nested recursion and past the depth" {
    const gpa = std.testing.allocator;
    // What a call leaves undefined (`undefines`), for a local the ring is given.
    var deinit_ring: std.ArrayList(u8) = .empty;
    defer deinit_ring.deinit(gpa);
    const deinit_functions = try diamonds(gpa, &deinit_ring, "S = .{ .a = 1 }");
    const deinit_read = try readSummaries(gpa, deinit_ring.items);
    try std.testing.expect(deinit_read.reads >= deinit_functions);
    try std.testing.expect(deinit_read.reads <= 3 * deinit_functions);
    // What a call writes, keeps, reads or needs (`remembered`), for a local declared undefined:
    // each of its questions about each function, once for each the walk asks first (a pass of
    // its own), some twenty a function; read again on each path, thousands.
    var write_ring: std.ArrayList(u8) = .empty;
    defer write_ring.deinit(gpa);
    const write_functions = try diamonds(gpa, &write_ring, "S = undefined");
    const write_read = try readSummaries(gpa, write_ring.items);
    try std.testing.expect(write_read.remembered_reads >= write_functions);
    try std.testing.expect(write_read.remembered_reads <= 40 * write_functions);
}

test "a length read through a holder is fixed by each part of it: an array's own, a slice's holder, never through a pointer to a choice holding an instance or a choice of none" {
    const bytes: Facts.Value = .{ .primitive = "u8" };
    const array: Facts.Value = .{ .array = &bytes };
    const instance: Facts.Value = .{ .instance = .{ .file = @fromBackingInt(0), .scope = @fromBackingInt(0) } };
    const slice: Facts.Value = .{ .pointer = .{ .child = &bytes, .size = .slice } };
    const to_array: Facts.Value = .{ .pointer = .{ .child = &array, .size = .one } };
    const array_or_instance: Facts.Value = .{ .alternatives = &.{ array, instance } };
    const none: Facts.Value = .{ .alternatives = &.{} };
    const to_choice: Facts.Value = .{ .pointer = .{ .child = &array_or_instance, .size = .one } };
    const to_none: Facts.Value = .{ .pointer = .{ .child = &none, .size = .one } };
    const LengthBy = @typeInfo(@TypeOf(lengthBy)).@"fn".return_type.?;
    for ([_]struct { Facts.Value, LengthBy }{
        .{ array, .fixed },
        .{ to_array, .fixed },
        .{ slice, .holder },
        .{ .{ .alternatives = &.{ array, to_array } }, .fixed },
        .{ .{ .alternatives = &.{ array, slice } }, .holder },
        // A pointer to a choice one of whose parts is an instance: its `len` may be written
        // through the pointer, whatever holds it.
        .{ to_choice, .not_fixed },
        .{ to_none, .not_fixed },
        .{ .{ .alternatives = &.{ array, instance } }, .not_fixed },
        .{ instance, .other },
        .{ none, .other },
    }) |row| {
        const value, const expected = row;
        try std.testing.expectEqual(expected, lengthBy(value));
    }
}
