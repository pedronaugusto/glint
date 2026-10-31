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
//! `continue` reaches the end of where it goes with what it holds, and a `for` over a range of
//! literals runs at least once. A deferred statement reads it as at its place: it runs at the
//! scope's exits, where the local may be as unwritten as it is there.
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
/// How deep `undefines` follows what a function hands its parameter to: std's writers reach
/// past `depth_limit` (`Writer.print`'s formatting), where a cut would leave all of it undefined.
const undefines_depth_limit = 16;

/// `follows`: whether another rule follows a local from its acquisition through its cleanup
/// (A003), and reads a use of it after a call that gives it `undefined` in this one's place.
pub fn reads(c: *Context, rule: Rule, follows: *const fn (*Context, Model.Declaration) Context.Error!bool) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    // The mentions that give a call a local, or a part of it, as its receiver or by address:
    // where a call may give it `undefined` (a `deinit`), read as each local is.
    var handed: std.AutoHashMapUnmanaged(Model.Declaration.Id, std.ArrayList(Ast.Node.Index)) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const id = (model.reference(node) orelse continue).declaration orelse continue;
        if (model.declarations[@backingInt(id)].kind != .variable) continue;
        if (handedPlace(tree, model, node, false) == null) continue;
        const entry = try handed.getOrPutValue(c.allocator, id, .empty);
        try entry.value_ptr.append(c.allocator, node);
    }
    for (model.declarations, 0..) |decl, d| {
        if (decl.kind != .variable or c.inTest(decl.token)) continue;
        const variable = tree.fullVarDecl(decl.node) orelse continue;
        if (tree.tokenTag(variable.ast.mut_token) != .keyword_var) continue;
        const init = variable.ast.init_node.unwrap() orelse continue;
        if (!Danger.atRuntime(c, decl.node)) continue;
        // An array of no elements has no memory to leave undefined.
        if (variable.ast.type_node.unwrap()) |kind| if (tree.nodeTag(kind) == .array_type and literalValue(tree, tree.nodeData(kind).node_and_node[0]) == 0) continue;
        const block = model.parentOf(decl.node) orelse continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, block) orelse continue;
        const start = std.mem.findScalar(Ast.Node.Index, statements, decl.node) orelse continue;
        // Undefined where it is declared so, in whole or in part, or where it is given
        // `undefined` again.
        const declared = holdsUndefined(tree, init);
        const local: Model.Declaration.Id = @fromBackingInt(@intCast(d));
        const calls = if (handed.get(local)) |list| list.items else &.{};
        if (!declared and !spellsUndefined(tree, block) and calls.len == 0) continue;
        var walk: Walk = .init(c, c.file, local, false, 0);
        try walk.collect();
        var found: ?Ast.TokenIndex = null;
        if (declared) {
            _ = try walk.sequence(statements[start + 1 ..], .{ .at = .unwritten, .parts = walk.everyPart() & ~walk.undefinedIn(init) });
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
            const left = try walk.undoneBy(call);
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
    /// The identifiers that name the local, in source order.
    mentions: std.ArrayList(Ast.Node.Index) = .empty,
    /// The `asm` outputs bound to the local, by the token naming it, with the `asm` they are in.
    outputs: std.ArrayList(struct { token: Ast.TokenIndex, asm_node: Ast.Node.Index }) = .empty,
    /// The function's `return`s, for a parameter's walk.
    returns: std.ArrayList(Ast.Node.Index) = .empty,
    read: ?Ast.TokenIndex = null,
    /// Whether the read is the local handed on rather than read in place.
    handed: bool = false,
    /// Whether a path returns with a parameter's memory not yet written whole.
    exit_unwritten: bool = false,
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
        for (w.tree.nodes.items(.tag), 0..) |tag, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (tag == .@"return") {
                if (w.param) try w.returns.append(w.c.allocator, node);
                continue;
            }
            if (tag == .asm_output) {
                // `[a] "b" (c)` names its variable by the token before `)`; `(-> T)` returns one.
                const lhs, const rparen = w.tree.nodeData(node).opt_node_and_token;
                if (lhs != .none or !std.mem.eql(u8, w.tree.tokenSlice(rparen - 1), name)) continue;
                const asm_node = w.enclosingAsm(rparen) orelse continue;
                try w.outputs.append(w.c.allocator, .{ .token = rparen - 1, .asm_node = asm_node });
                continue;
            }
            if (tag != .identifier) continue;
            const ref = w.model.reference(node) orelse continue;
            if (ref.declaration == w.local) try w.mentions.append(w.c.allocator, node);
        }
        w.shape = try w.partsOf();
    }

    /// The parts of what the local is, or a parameter's single-item pointer points at: an
    /// array's elements by its literal length, or a struct's fields.
    fn partsOf(w: *Walk) Context.Error!Shape {
        const tree = w.tree;
        var kind = if (w.param)
            w.c.facts.parameterTypeNode(.{ .file = w.file, .index = w.local }) orelse return .none
        else
            (tree.fullVarDecl(w.model.declarations[@backingInt(w.local)].node) orelse return .none).ast.type_node.unwrap() orelse return .none;
        if (w.param) {
            const pointer = tree.fullPtrType(kind) orelse return .none;
            if (pointer.size != .one) return .none;
            kind = pointer.ast.child_type;
        }
        if (tree.nodeTag(kind) == .array_type) {
            const length = literalValue(tree, tree.nodeData(kind).node_and_node[0]) orelse return .none;
            if (length == 0 or length > 64) return .none;
            w.owner = .{ .elements = @intCast(length) };
            return .{ .elements = @intCast(length) };
        }
        const container = switch (try w.c.facts.resolve(w.file, kind)) {
            .container => |container| container,
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
        for (w.mentions.items) |mention| {
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
                // A deferred one runs at the block's end, after what follows it.
                switch (tree.nodeTag(child)) {
                    .@"defer", .@"errdefer" => {},
                    else => state = try w.sequence(statements[position + 1 ..], state),
                }
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
        const place = handedPlace(tree, w.model, mention, w.param) orelse return 0;
        if (!try w.inMemory(mention, place)) return 0;
        // A field or element handed: the part its first step names.
        const part_handed: ?u64 = if (place == mention) null else part: {
            const first = w.model.parentOf(mention).?;
            const index = w.partAt(first, tree.nodeTag(first) == .field_access) orelse break :part all;
            break :part @as(u64, 1) << index;
        };
        const holder = w.model.parentOf(place).?;
        var buffer: [1]Ast.Node.Index = undefined;
        const receiver = tree.nodeTag(holder) == .field_access;
        const node = if (receiver) w.model.parentOf(holder).? else w.model.parentOf(if (tree.nodeTag(holder) == .address_of) holder else place).?;
        const call = tree.fullCall(&buffer, node).?;
        // A local that is a pointer gives a method, or a field's address, what it points at.
        if (!w.param and (receiver or place != mention)) {
            if (try w.c.facts.resolve(w.file, mention) == .pointer) return 0;
        }
        if (receiver and place != mention and try w.c.facts.resolve(w.file, place) != .instance) return 0;
        const decl = (try w.callee(node, call)) orelse return 0;
        const origin = (try w.c.facts.origin(decl)) orelse decl;
        const index = if (receiver) 0 else parameterAt(w.c, w.file, call, origin, std.mem.findScalar(Ast.Node.Index, call.ast.params, if (tree.nodeTag(holder) == .address_of) holder else place).?);
        const found = try undefines(w.c, origin, index, w.depth + 1);
        if (found.mask == 0) return 0;
        if (part_handed) |handed| return handed;
        if (found.mask == all) return all;
        const owner = w.owner orelse return all;
        const theirs = found.owner orelse return all;
        return if (std.meta.eql(owner, theirs)) found.mask else all;
    }

    /// Whether `place`, reached from `mention` by fields and elements, lies in the local's own
    /// memory (or a parameter's pointee): no step passes through a pointer it holds (`w.c.facts`
    /// with `c: *Context`, a slice's element).
    fn inMemory(w: *Walk, mention: Ast.Node.Index, place: Ast.Node.Index) Context.Error!bool {
        const tree = w.tree;
        var at = place;
        while (at != mention) {
            const inner = switch (tree.nodeTag(at)) {
                .field_access => tree.nodeData(at).node_and_token[0],
                .array_access => tree.nodeData(at).node_and_node[0],
                else => return false,
            };
            // A parameter's pointer is how its memory is reached.
            if (!(w.param and inner == mention) and try w.pointerAt(inner)) return false;
            at = inner;
        }
        return true;
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
        if (w.tree.nodeTag(node) != .field_access) return false;
        const of, const member = w.tree.nodeData(node).node_and_token;
        if (std.mem.findScalar(Ast.Node.Index, w.mentions.items, of) == null) return false;
        const owner = w.owner orelse return false;
        if (owner != .container) return false;
        const source = w.c.project.at(owner.container.file);
        const tree = &source.file.tree;
        const name = w.tree.tokenSlice(member);
        for (source.model.declarations) |decl| {
            if (decl.kind != .field or decl.scope != owner.container.scope or !std.mem.eql(u8, decl.name, name)) continue;
            const field = tree.fullContainerField(decl.node) orelse return false;
            const kind = field.ast.type_expr.unwrap() orelse return false;
            return spelledPointer(tree, &source.model, owner.container.scope, kind, true);
        }
        return false;
    }

    /// Whether a parameter's memory is left `undefined`, the parts in `left`, on some path that
    /// returns, walking on from `mention`, which leaves them so, to the end of `body`. One that
    /// reads it there (its own fault) is taken as leaving it.
    fn leftUndefined(w: *Walk, mention: Ast.Node.Index, left: u64, body: Ast.Node.Index) Context.Error!bool {
        var from: Walk = .init(w.c, w.file, w.local, true, w.depth);
        from.every_exit = true;
        try from.collect();
        const past = try from.onFrom(mention, left, body);
        return from.read != null or from.exit_unwritten or past.at == .unwritten or past.at == .done;
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
        for (w.mentions.items) |mention| {
            if (tree.nodeMainToken(mention) >= at) continue;
            const place = placeOf(tree, w.model, mention);
            if (!try w.inMemory(mention, place)) continue;
            const holder = w.model.parentOf(place) orelse continue;
            const value = switch (tree.nodeTag(holder)) {
                .address_of => holder,
                .field_access => value: {
                    const node = w.model.parentOf(holder) orelse continue;
                    const call = tree.fullCall(&buffer, node) orelse continue;
                    if (call.ast.fn_expr != holder) continue;
                    if (!holdsResult(try w.c.facts.resolve(w.file, node))) continue;
                    // Given by value, the method holds a copy.
                    const decl = (try w.callee(node, call)) orelse break :value node;
                    const function = (try w.c.facts.origin(decl)) orelse decl;
                    if (try parameter(w.c, function, 0, false) == null) continue;
                    break :value node;
                },
                else => continue,
            };
            // Through `try`, `catch` and grouping to where the value goes.
            var result = value;
            while (w.model.parentOf(result)) |up| : (result = up) switch (tree.nodeTag(up)) {
                .@"try", .grouped_expression => {},
                .@"catch", .@"orelse" => if (tree.nodeData(up).node_and_node[0] != result) break,
                else => break,
            };
            const goes = w.model.parentOf(result) orelse continue;
            if (tree.fullCall(&buffer, goes) != null or isBlock(tree, goes)) continue;
            const binding = w.declaredAt(goes) orelse return tree.nodeMainToken(value);
            if (tree.fullVarDecl(goes).?.ast.init_node.unwrap() != result) return tree.nodeMainToken(value);
            if (w.mentionedAfter(binding, origin, scope)) return tree.nodeMainToken(value);
        }
        return null;
    }

    /// Whether the declaration `binding` is mentioned after `origin`, or anywhere in a loop
    /// that holds `origin` within `scope`, the local's block.
    fn mentionedAfter(w: *const Walk, binding: Model.Declaration.Id, origin: Ast.Node.Index, scope: Ast.Node.Index) bool {
        const tree = w.tree;
        const at = tree.nodeMainToken(origin);
        var first = at;
        var up = origin;
        while (w.model.parentOf(up)) |next| : (up = next) {
            if (next == scope) break;
            if (tree.fullWhile(next) != null or tree.fullFor(next) != null) first = @min(first, tree.firstToken(next));
        }
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const ref = w.model.reference(node) orelse continue;
            if (ref.declaration != binding) continue;
            const token = tree.nodeMainToken(node);
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
    fn partAt(w: *const Walk, node: Ast.Node.Index, field: bool) ?u6 {
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
                const index = literalValue(w.tree, w.tree.nodeData(node).node_and_node[1]) orelse return null;
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
        if (w.partSet(access, field)) {
            const at = index orelse return null;
            return .{ .key = w.tree.lastToken(w.model.parentOf(access).?), .effect = .{ .set = at } };
        }
        const at = index orelse return read;
        if (field and w.byReference(access)) {
            if (try parentNamed(w.c, w.owner.?, w.tree.tokenSlice(w.tree.nodeData(access).node_and_token[1]))) return read;
        }
        return .{ .key = key, .effect = .{ .get = at } };
    }

    /// The assignment that gives `undefined` to `access`, or to a part of it (`x.a.b = …`), or
    /// a value holding it (`x.a = .{ .n = 0, .buf = undefined }`); not what a pointer it holds
    /// points at (`x.items[i] = undefined`, a slice's element).
    fn undefinedThrough(w: *Walk, access: Ast.Node.Index) Context.Error!?Ast.Node.Index {
        const tree = w.tree;
        var at = access;
        while (w.model.parentOf(at)) |up| : (at = up) switch (tree.nodeTag(up)) {
            .field_access, .array_access => {
                const inner = if (tree.nodeTag(up) == .field_access) tree.nodeData(up).node_and_token[0] else tree.nodeData(up).node_and_node[0];
                if (inner != at) return null;
                if (try w.pointerAt(at)) return null;
            },
            .assign => {
                const target, const value = tree.nodeData(up).node_and_node;
                return if (target == at and holdsUndefined(tree, value)) up else null;
            },
            else => return null,
        };
        return null;
    }

    /// What of the local a value assigned to all of it leaves undefined, as a set of its parts:
    /// none for a value without `undefined` in it; the fields or elements a literal gives a value
    /// holding `undefined`; all of them for `undefined` itself, or for any other value holding it
    /// where the local's parts are not known.
    fn undefinedIn(w: *const Walk, value: Ast.Node.Index) u64 {
        const tree = w.tree;
        const all = std.math.maxInt(u64);
        if (!holdsUndefined(tree, value)) return 0;
        const node = ungrouped(tree, value);
        var mask: u64 = 0;
        var buffer: [2]Ast.Node.Index = undefined;
        switch (w.shape) {
            .none => return all,
            .fields => |fields| {
                const literal = tree.fullStructInit(&buffer, node) orelse return all;
                for (literal.ast.fields) |field| {
                    if (!holdsUndefined(tree, field)) continue;
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
                    if (!holdsUndefined(tree, element)) continue;
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
        if (args.len != 2 or w.tree.nodeTag(args[1]) != .string_literal) return null;
        const name = std.zig.string_literal.parseAlloc(w.c.allocator, w.tree.tokenSlice(w.tree.nodeMainToken(args[1]))) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        for (fields, 0..) |each, at| if (std.mem.eql(u8, each, name)) return @intCast(at);
        return null;
    }

    /// Whether a field is used where it stays in place: its address taken, or a method called
    /// on it.
    fn byReference(w: *const Walk, access: Ast.Node.Index) bool {
        const up = w.model.parentOf(access) orelse return false;
        if (w.tree.nodeTag(up) == .address_of) return true;
        if (w.tree.nodeTag(up) != .field_access) return false;
        const call = w.model.parentOf(up) orelse return false;
        var buffer: [1]Ast.Node.Index = undefined;
        const full = w.tree.fullCall(&buffer, call) orelse return false;
        return full.ast.fn_expr == up;
    }

    fn sequence(w: *Walk, statements: []const Ast.Node.Index, state: State) Context.Error!State {
        var now = state;
        for (statements) |each| {
            if (now.at != .unwritten) return now;
            now = try w.statement(each, now);
        }
        return now;
    }

    /// The state past `node`, reading it in the order Zig evaluates it.
    fn statement(w: *Walk, node: Ast.Node.Index, state: State) Context.Error!State {
        const tree = w.tree;
        // A path that leaves reads what it leaves with first; a parameter's walk sees each
        // `return` that is not an error's with the memory unwritten. A `break` or `continue`
        // takes what it holds to where it goes.
        switch (tree.nodeTag(node)) {
            .@"return", .@"break", .@"continue", .unreachable_literal => {
                const past = if (w.mentioned(node)) try w.simple(node, state) else state;
                if (past.at == .done) return .done;
                if (tree.nodeTag(node) == .@"return" and past.at == .unwritten and w.exitsBy(node)) w.exit_unwritten = true;
                w.jump(node, past);
                return .left;
            },
            else => {},
        }
        // An `if` may test a guard's result, or a flag that says more of the local.
        if (!w.mentioned(node) and !w.returnsIn(node) and !w.tests(node, state) and (w.flags.items.len == 0 or tree.fullIf(node) == null)) {
            // It leaves the local as it is, for what follows and for where a jump in it goes;
            // one that never goes on reaches nothing after it.
            w.jumpsIn(node, state);
            return if (leavesAlways(tree, node)) .left else state;
        }
        switch (tree.nodeTag(node)) {
            .@"defer", .@"errdefer" => {
                // Run at the scope's exits, where the local may be as unwritten as here; what it
                // writes holds before none of them.
                const past = try w.statement(tree.nodeData(node).node, state);
                return if (past.at == .done) .done else state;
            },
            // What runs as the program compiles runs in its place all the same.
            .@"comptime" => return w.statement(tree.nodeData(node).node, state),
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                var buffer: [2]Ast.Node.Index = undefined;
                const statements = tree.blockStatements(&buffer, node).?;
                if (blockLabel(tree, node) == null) return w.sequence(statements, state);
                try w.enter(node);
                return w.leave(try w.sequence(statements, state));
            },
            else => {},
        }
        if (tree.fullIf(node)) |branch| {
            const after = try w.statement(branch.ast.cond_expr, state);
            if (after.at != .unwritten) return after;
            // On an error union, its value is the call's success; otherwise a flag known true
            // or false says what its being true showed, and a test of a guarding call's result
            // writes the local on the side where it checks.
            var holds = if (branch.error_token != null) try w.succeeded(branch.ast.cond_expr, after) else w.knowing(branch.ast.cond_expr, after, true);
            var fails = if (branch.error_token != null) after else w.knowing(branch.ast.cond_expr, after, false);
            if (after.guard) |guard| if (w.checks(branch.ast.cond_expr, guard)) |checked| {
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
            // A range of literals with passes in it runs the body, and its first pass is as read;
            // what reaches the loop's end is what its passes end with and what jumps there take.
            return if (passes(tree, loop.ast.inputs[0])) body else state;
        }
        // A `bool` constant keeps what its being true shows: `const ok = n == 64 and if
        // (fill(&buf)) |_| true else |_| false`.
        const past = try w.simple(node, state);
        if (past.at != .unwritten) return past;
        if (tree.fullVarDecl(node)) |variable| if (tree.tokenTag(variable.ast.mut_token) == .keyword_const) {
            const value = variable.ast.init_node.unwrap() orelse return past;
            const decl = w.declaredAt(node) orelse return past;
            try w.flags.append(w.c.allocator, .{ .decl = decl, .state = try w.whenTrue(value, past) });
        };
        return past;
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
                const begin: State = if (start.guard) |guard| (if (!redispatched and w.successProng(choice.ast.condition, prong, guard)) .written else start) else start;
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
        const length = w.arrayLength() orelse return false;
        const position, const passes_count = for (loop.ast.inputs, 0..) |input, at| {
            if (tree.nodeTag(input) != .for_range) continue;
            const from, const to = tree.nodeData(input).node_and_opt_node;
            if (literalValue(tree, from) != 0) continue;
            break .{ at, literalValue(tree, to.unwrap() orelse continue) orelse continue };
        } else return false;
        const index = capture(tree, loop.payload_token, position, false) orelse return false;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, loop.ast.then_expr) orelse (&loop.ast.then_expr)[0..1];
        if (statements.len != 1) return false;
        const only = statements[0];
        if (leavesPass(tree, only) or spellsUndefined(tree, only)) return false;
        var mentions: usize = 0;
        for (w.mentions.items) |mention| {
            if (tree.firstToken(mention) >= tree.firstToken(only) and tree.lastToken(mention) <= tree.lastToken(only)) mentions += 1;
        }
        if (mentions != 1) return false;
        var call_buffer: [1]Ast.Node.Index = undefined;
        const dest = if (tree.fullCall(&call_buffer, only)) |call| dest: {
            if (call.ast.params.len != 4 or !try w.isStd(only, call, "mem.writeInt")) return false;
            break :dest call.ast.params[1];
        } else filled(tree, only) orelse return false;
        // `local[start..][0..k]`.
        const span = tree.fullSlice(dest) orelse return false;
        if (literalValue(tree, span.ast.start) != 0) return false;
        const stride = literalValue(tree, span.ast.end.unwrap() orelse return false) orelse return false;
        const rest = tree.fullSlice(span.ast.sliced) orelse return false;
        if (rest.ast.end != .none or !w.isLocal(rest.ast.sliced)) return false;
        const total = std.math.mul(u64, passes_count, stride) catch return false;
        if (stride == 0 or total != length) return false;
        return strideAt(tree, rest.ast.start, stride, index, passes_count);
    }

    /// Whether `input`, a slice no one assigns, is known at `call` to be twice the local's
    /// length: the local declared `[input.len / 2]T`, or a test every path to the call passes
    /// (`input.len == 64` with the local `[32]u8`, or `input.len == 2 * local.len`), in `and`'s
    /// left side or an `if`'s condition around it, or in a guard before it that leaves
    /// otherwise (`if (input.len != 64) return …;`).
    fn twiceAsLong(w: *const Walk, call: Ast.Node.Index, input: Ast.Node.Index) bool {
        const tree = w.tree;
        if (tree.nodeTag(input) != .identifier) return false;
        const x = (w.model.reference(input) orelse return false).declaration orelse return false;
        const record = w.model.declarations[@backingInt(x)];
        switch (record.kind) {
            .parameter => {},
            .variable => if (tree.tokenTag((tree.fullVarDecl(record.node) orelse return false).ast.mut_token) != .keyword_const) return false,
            // A capture by value; one by pointer (`|*x|`) may see its slice change.
            .capture => if (record.token == 0 or tree.tokenTag(record.token - 1) == .asterisk) return false,
            else => return false,
        }
        if (w.halfOf(x)) return true;
        var child = call;
        while (w.model.parentOf(child)) |up| : (child = up) {
            if (tree.nodeTag(up) == .fn_decl) return false;
            if (tree.nodeTag(up) == .bool_and) {
                const lhs, const rhs = tree.nodeData(up).node_and_node;
                if (rhs == child and w.lengthIs(lhs, x, true)) return true;
            }
            if (tree.fullIf(up)) |branch| {
                if (branch.ast.then_expr == child and branch.error_token == null and w.lengthIs(branch.ast.cond_expr, x, true)) return true;
            }
            if (!isBlock(tree, up)) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            for (tree.blockStatements(&buffer, up).?) |each| {
                if (each == child) break;
                const guard = tree.fullIf(each) orelse continue;
                if (guard.ast.else_expr != .none or guard.payload_token != null or guard.error_token != null) continue;
                if (leavesAlways(tree, guard.ast.then_expr) and w.lengthIs(guard.ast.cond_expr, x, false)) return true;
            }
        }
        return false;
    }

    /// Whether the local is declared `[x.len / 2]T`.
    fn halfOf(w: *const Walk, x: Model.Declaration.Id) bool {
        const tree = w.tree;
        const variable = tree.fullVarDecl(w.model.declarations[@backingInt(w.local)].node) orelse return false;
        const kind = variable.ast.type_node.unwrap() orelse return false;
        if (tree.nodeTag(kind) != .array_type) return false;
        const length = tree.nodeData(kind).node_and_node[0];
        if (tree.nodeTag(length) != .div) return false;
        const lhs, const rhs = tree.nodeData(length).node_and_node;
        return w.lengthOf(lhs, x) and literalValue(tree, rhs) == 2;
    }

    /// Whether `condition` coming out `truth` shows `x.len` twice the local's length.
    fn lengthIs(w: *const Walk, condition: Ast.Node.Index, x: Model.Declaration.Id, truth: bool) bool {
        const tree = w.tree;
        switch (tree.nodeTag(condition)) {
            .grouped_expression => return w.lengthIs(tree.nodeData(condition).node_and_token[0], x, truth),
            .bool_not => return w.lengthIs(tree.nodeData(condition).node, x, !truth),
            .bool_and, .bool_or => {
                if (truth != (tree.nodeTag(condition) == .bool_and)) return false;
                const lhs, const rhs = tree.nodeData(condition).node_and_node;
                return w.lengthIs(lhs, x, truth) or w.lengthIs(rhs, x, truth);
            },
            .equal_equal, .bang_equal => {
                if (truth != (tree.nodeTag(condition) == .equal_equal)) return false;
                const lhs, const rhs = tree.nodeData(condition).node_and_node;
                return (w.lengthOf(lhs, x) and w.twiceLocal(rhs)) or (w.lengthOf(rhs, x) and w.twiceLocal(lhs));
            },
            else => return false,
        }
    }

    /// Whether `node` is `x.len`.
    fn lengthOf(w: *const Walk, node: Ast.Node.Index, x: Model.Declaration.Id) bool {
        const tree = w.tree;
        if (tree.nodeTag(node) != .field_access) return false;
        const of, const member = tree.nodeData(node).node_and_token;
        if (!std.mem.eql(u8, tree.tokenSlice(member), "len") or tree.nodeTag(of) != .identifier) return false;
        const ref = w.model.reference(of) orelse return false;
        return ref.declaration == x;
    }

    /// Whether `node` is twice the local's length: a literal twice its literal length, or `2 *
    /// local.len`.
    fn twiceLocal(w: *const Walk, node: Ast.Node.Index) bool {
        const tree = w.tree;
        if (literalValue(tree, node)) |value| {
            const variable = tree.fullVarDecl(w.model.declarations[@backingInt(w.local)].node) orelse return false;
            const kind = variable.ast.type_node.unwrap() orelse return false;
            if (tree.nodeTag(kind) != .array_type) return false;
            const length = literalValue(tree, tree.nodeData(kind).node_and_node[0]) orelse return false;
            // An array past half of what a u64 counts has no length twice its own here.
            return value == (std.math.mul(u64, 2, length) catch return false);
        }
        if (tree.nodeTag(node) != .mul) return false;
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        return (literalValue(tree, lhs) == 2 and w.lengthOf(rhs, w.local)) or (literalValue(tree, rhs) == 2 and w.lengthOf(lhs, w.local));
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
        const tree = w.tree;
        switch (tree.nodeTag(value)) {
            .grouped_expression => return w.whenTrue(tree.nodeData(value).node_and_token[0], state),
            .bool_and => {
                const lhs, const rhs = tree.nodeData(value).node_and_node;
                return w.whenTrue(rhs, try w.whenTrue(lhs, state));
            },
            else => {},
        }
        const branch = tree.fullIf(value) orelse return state;
        if (branch.error_token == null) return state;
        if (!isWord(tree, branch.ast.then_expr, "true") or !isWord(tree, branch.ast.else_expr.unwrap() orelse return state, "false")) return state;
        return w.succeeded(branch.ast.cond_expr, state);
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
        for (w.mentions.items) |mention| {
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
    fn knowing(w: *const Walk, condition: Ast.Node.Index, state: State, truth: bool) State {
        const tree = w.tree;
        if (state.at != .unwritten) return state;
        switch (tree.nodeTag(condition)) {
            .grouped_expression => return w.knowing(tree.nodeData(condition).node_and_token[0], state, truth),
            .bool_not => return w.knowing(tree.nodeData(condition).node, state, !truth),
            .bool_and, .bool_or => {
                // Both sides are known only where `and` is true or `or` false.
                if (truth != (tree.nodeTag(condition) == .bool_and)) return state;
                const lhs, const rhs = tree.nodeData(condition).node_and_node;
                return w.knowing(rhs, w.knowing(lhs, state, truth), truth);
            },
            .identifier => {
                if (!truth) return state;
                const decl = (w.model.reference(condition) orelse return state).declaration orelse return state;
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
            },
            else => return state,
        }
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
            if (list == null) if (w.fieldList(input, own)) |by_name| {
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
        if (w.param and w.returnsIn(body)) return false;
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
    fn fieldList(w: *const Walk, input: Ast.Node.Index, own: Ast.Node.Index) ?bool {
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
        if (!std.mem.eql(u8, tree.tokenSlice(kind), "@\"struct\"") or !isBuiltin(tree, reflected, "@typeInfo")) return null;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, reflected, &buffer);
        if (args.len != 1 or !sameType(tree, w.model, args[0], own)) return null;
        return by_name;
    }

    /// Whether `node` sets the field a pass is on from what does not read the local: `@field`
    /// of the local by the capture `name`, or a `comptime` test that the field is one by name
    /// (`if (comptime std.mem.eql(u8, name, "x")) local.x = v else …`) whose branches both do.
    fn setsCapture(w: *Walk, node: Ast.Node.Index, name: []const u8, by_name: bool) Context.Error!bool {
        const tree = w.tree;
        if (tree.nodeTag(node) == .assign) {
            const target, const value = tree.nodeData(node).node_and_node;
            return !w.mentioned(value) and !holdsUndefined(tree, value) and w.fieldOfCapture(target, name, by_name);
        }
        const branch = tree.fullIf(node) orelse return false;
        if (branch.payload_token != null or branch.error_token != null) return false;
        const otherwise = branch.ast.else_expr.unwrap() orelse return false;
        const spelled = (try w.namedField(branch.ast.cond_expr, name, by_name)) orelse return false;
        if (tree.nodeTag(branch.ast.then_expr) != .assign) return false;
        const target, const value = tree.nodeData(branch.ast.then_expr).node_and_node;
        if (w.mentioned(value) or holdsUndefined(tree, value)) return false;
        if (!w.fieldOfCapture(target, name, by_name) and !w.fieldNamed(target, spelled)) return false;
        return w.setsCapture(otherwise, name, by_name);
    }

    /// Whether `target` is `@field(local, f.name)` (or `@field(local, name)` for a list of
    /// names), `f` or `name` the capture.
    fn fieldOfCapture(w: *const Walk, target: Ast.Node.Index, name: []const u8, by_name: bool) bool {
        const tree = w.tree;
        if (!isBuiltin(tree, target, "@field")) return false;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, target, &buffer);
        if (args.len != 2 or !w.isLocal(args[0])) return false;
        var spelled = args[1];
        if (!by_name) {
            if (tree.nodeTag(spelled) != .field_access) return false;
            const of, const member = tree.nodeData(spelled).node_and_token;
            if (!std.mem.eql(u8, tree.tokenSlice(member), "name")) return false;
            spelled = of;
        }
        return tree.nodeTag(spelled) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(spelled)), name);
    }

    /// Whether `target` is the local's field `field` by name (`local.x`).
    fn fieldNamed(w: *const Walk, target: Ast.Node.Index, field: []const u8) bool {
        const tree = w.tree;
        if (tree.nodeTag(target) != .field_access) return false;
        const of, const member = tree.nodeData(target).node_and_token;
        return w.isLocal(of) and std.mem.eql(u8, tree.tokenSlice(member), field);
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
            if (!by_name) {
                if (tree.nodeTag(spelled) != .field_access) continue;
                const of, const member = tree.nodeData(spelled).node_and_token;
                if (!std.mem.eql(u8, tree.tokenSlice(member), "name")) continue;
                spelled = of;
            }
            if (tree.nodeTag(spelled) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(spelled)), name)) continue;
            const literal = call.ast.params[order[1]];
            if (tree.nodeTag(literal) != .string_literal) return null;
            return std.zig.string_literal.parseAlloc(w.c.allocator, tree.tokenSlice(tree.nodeMainToken(literal))) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
        }
        return null;
    }

    /// Whether `node` names the local itself, or a parameter's pointer's memory (`p.*`).
    fn isLocal(w: *const Walk, node: Ast.Node.Index) bool {
        var at = node;
        if (w.param and w.tree.nodeTag(at) == .deref) at = w.tree.nodeData(at).node;
        if (w.tree.nodeTag(at) != .identifier) return false;
        const ref = w.model.reference(at) orelse return false;
        return ref.declaration == w.local;
    }

    /// Whether `node` is an `if` or a `switch` whose condition tests the result of the call
    /// guarding the local, which writes it on one side.
    fn tests(w: *const Walk, node: Ast.Node.Index, state: State) bool {
        const guard = state.guard orelse return false;
        if (w.tree.fullIf(node)) |branch| return w.checks(branch.ast.cond_expr, guard) != null;
        if (w.tree.fullSwitch(node)) |choice| return w.errnoOf(choice.ast.condition, guard) != null or w.isResult(choice.ast.condition, guard);
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
        for (w.returns.items) |each| {
            if (each == node or !w.exitsBy(each)) continue;
            const token = w.tree.firstToken(each);
            if (token >= first and token <= last) w.exit_unwritten = true;
        }
        w.jumpsIn(node, state);
        const Found = struct {
            use: Use,
            token: Ast.TokenIndex,
            fn before(_: void, a: @This(), b: @This()) bool {
                return a.use.key < b.use.key;
            }
        };
        var uses: std.ArrayList(Found) = .empty;
        defer uses.deinit(w.c.allocator);
        for (w.mentions.items) |mention| {
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
                        if (w.behind(w.mentionAt(later.token) orelse node, guard, node)) continue;
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
        const parent = w.model.parentOf(mention) orelse return read;
        // What `@TypeOf` is given is only typed, never run: the local's type, or a call that
        // would write or read it, as the program compiles.
        if (unevaluated(tree, w.model, mention)) return null;
        switch (tree.nodeTag(parent)) {
            .field_access => {
                // A parameter's slice or array pointer carries its own length.
                if (std.mem.eql(u8, tree.tokenSlice(tree.nodeData(parent).node_and_token[1]), "len") and (w.param or w.array())) return null;
                const grand = w.model.parentOf(parent) orelse return read;
                var buffer: [1]Ast.Node.Index = undefined;
                // A method called on it is handed it as its receiver.
                if (tree.fullCall(&buffer, grand)) |call| if (call.ast.fn_expr == parent) return try w.handedTo(grand, call, 0, true, true, key);
                return w.part(parent, w.partAt(parent, true), true, key);
            },
            .array_access => {
                if (tree.nodeData(parent).node_and_node[0] != mention) return read;
                return w.part(parent, w.partAt(parent, false), false, key);
            },
            .assign => {
                // A parameter given another address no longer names the caller's memory.
                const target, const value = tree.nodeData(parent).node_and_node;
                if (target != mention or w.param) return read;
                return w.assignedWhole(parent, value);
            },
            .deref => {
                if (!w.param) return read;
                const grand = w.model.parentOf(parent) orelse return read;
                if (tree.nodeTag(grand) == .assign and tree.nodeData(grand).node_and_node[0] == parent) return w.assignedWhole(grand, tree.nodeData(grand).node_and_node[1]);
                return switch (tree.nodeTag(grand)) {
                    .field_access => w.part(grand, w.partAt(grand, true), true, key),
                    .array_access => w.part(grand, w.partAt(grand, false), false, key),
                    else => read,
                };
            },
            .address_of => return if (w.param) read else try w.given(parent, true, key),
            .slice_open, .slice, .slice_sentinel => {
                if ((tree.fullSlice(parent) orelse return read).ast.sliced != mention) return read;
                // `buf[0..n]` with n the count a call that wrote that prefix returned.
                if (try w.countedPrefix(parent)) return null;
                return try w.given(parent, w.allOf(parent), key);
            },
            else => {
                // `@field(local, name) = v` sets the field it names; a name spelled out is that
                // part, read in place.
                if (builtinField(tree, parent, mention)) {
                    const grand = w.model.parentOf(parent) orelse return read;
                    const at = try w.fieldSpelled(parent);
                    if (tree.nodeTag(grand) == .assign and tree.nodeData(grand).node_and_node[0] == parent) {
                        if (holdsUndefined(tree, tree.nodeData(grand).node_and_node[1])) {
                            return .{ .key = tree.lastToken(grand), .effect = .{ .unset = if (at) |part_at| @as(u64, 1) << part_at else std.math.maxInt(u64) } };
                        }
                        return .{ .key = tree.lastToken(grand), .effect = .{ .set = at orelse return null } };
                    }
                    if (tree.nodeTag(grand) == .address_of or tree.nodeTag(grand) == .field_access) return read;
                    return .{ .key = key, .effect = .{ .get = at orelse return read } };
                }
                // A parameter's pointer handed on hands on the memory it points at.
                return if (w.param) try w.given(mention, true, key) else read;
            },
        }
    }

    /// What assigning `value` to all of the local at `assign` does: writes it, or all of it but
    /// what the value leaves undefined.
    fn assignedWhole(w: *const Walk, assign: Ast.Node.Index, value: Ast.Node.Index) Use {
        const key = w.tree.lastToken(assign);
        const left = w.undefinedIn(value);
        return if (left == 0) .{ .key = key, .effect = .write } else .{ .key = key, .effect = .{ .reset = left } };
    }

    /// Whether `access`, a field or an element of the local (through a parameter's pointer),
    /// is set by an assignment: a part written, the local's own memory, not a pointer it holds.
    fn partSet(w: *Walk, access: Ast.Node.Index, field: bool) bool {
        const grand = w.model.parentOf(access) orelse return false;
        if (w.tree.nodeTag(grand) != .assign or w.tree.nodeData(grand).node_and_node[0] != access) return false;
        if (w.param) return true;
        return if (field) w.structure() else w.array();
    }

    /// What handing `memory` (`&local`, a slice of it, a parameter's pointer) to what holds it
    /// does: a write where all of it is written, nothing where a part is or std keeps it, a
    /// read anywhere else.
    fn given(w: *Walk, memory: Ast.Node.Index, whole: bool, key: Ast.TokenIndex) Context.Error!?Use {
        const tree = w.tree;
        const handed: Use = .{ .key = key, .effect = .handed };
        const parent = w.model.parentOf(memory) orelse return handed;
        switch (tree.nodeTag(parent)) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const name = tree.tokenSlice(tree.nodeMainToken(parent));
                var buffer: [2]Ast.Node.Index = undefined;
                const params = tree.builtinCallParams(&buffer, parent) orelse return handed;
                if (params.len == 0 or params[0] != memory) return handed;
                if (!std.mem.eql(u8, name, "@memset") and !std.mem.eql(u8, name, "@memcpy")) return handed;
                // `@memset(&x, undefined)`: what it is given undefined again.
                if (std.mem.eql(u8, name, "@memset") and params.len == 2 and holdsUndefined(tree, params[1])) {
                    const all = std.math.maxInt(u64);
                    return .{ .key = tree.lastToken(parent), .effect = if (whole) .{ .reset = all } else .{ .unset = all } };
                }
                return if (whole) .{ .key = tree.lastToken(parent), .effect = .write } else null;
            },
            else => {},
        }
        // `var w: Writer = .{ .bytes = &buf }`: a cursor writer's memory, which it reads only
        // below the count of what it wrote there, where the writer it makes is kept.
        if (try w.cursorAt(parent, memory) != null and try w.keptWriter(parent)) return null;
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buffer, parent)) |call| {
            // `std.mem.asBytes(&x)`: all of x's bytes, handed on as the view is.
            if (whole and call.ast.params.len == 1 and try w.isStd(parent, call, "mem.asBytes")) return w.given(parent, true, key);
            for (call.ast.params, 0..) |arg, position| if (arg == memory) return w.handedTo(parent, call, position, false, whole, key);
            return handed;
        }
        if (tree.fullFor(parent)) |loop| return w.forSets(parent, loop, memory, whole, key);
        // `&.{&buf}`: a vector of buffers a call is given, each of which it is given.
        var elements: [2]Ast.Node.Index = undefined;
        if (tree.fullArrayInit(&elements, parent)) |literal| if (literal.ast.type_expr == .none) {
            const address = w.model.parentOf(parent) orelse return handed;
            if (tree.nodeTag(address) != .address_of) return handed;
            const outer = w.model.parentOf(address) orelse return handed;
            const call = tree.fullCall(&buffer, outer) orelse return handed;
            for (call.ast.params, 0..) |arg, position| if (arg == address) return w.handedTo(outer, call, position, false, false, key);
        };
        return handed;
    }

    /// What a call does with the memory it is given at argument `position` (or as its
    /// `receiver`): std's named fills and keeps, or the program's own function read for it.
    fn handedTo(w: *Walk, node: Ast.Node.Index, call: Ast.full.Call, position: usize, receiver: bool, whole: bool, key: Ast.TokenIndex) Context.Error!?Use {
        const tree = w.tree;
        const handed: Use = .{ .key = key, .effect = .handed };
        const decl = (try w.callee(node, call)) orelse {
            if (receiver) return handed;
            return switch ((try w.chosen(node, call, position)) orelse return handed) {
                .keep => null,
                .fill => if (whole) .{ .key = tree.lastToken(node), .effect = .write } else null,
                .contract => |entry| if (entry.success == .count or !whole) null else try w.guarded(node, entry),
            };
        };
        const origin = (try w.c.facts.origin(decl)) orelse decl;
        const index = if (receiver) 0 else parameterAt(w.c, w.file, call, origin, position);
        const written: Use = .{ .key = tree.lastToken(node), .effect = .write };
        const leaves = w.failureLeaves(node, origin);
        if (try named(w.c, &std_fills, origin, index)) return if (whole and leaves) written else null;
        if (try named(w.c, &std_holders, origin, index)) return if (try holderKept(w.c, w.file, node, w.depth)) null else handed;
        if (try named(w.c, &std_keeps, origin, index)) return null;
        // A count given all of the local writes it all where its result is that length.
        if (try named(w.c, &std_counts, origin, index)) return if (whole and leaves) .{ .key = tree.lastToken(node), .effect = .{ .guarded = .{ .call = node, .entry = &counted_whole, .binding = w.resultConstant(node) } } } else null;
        for (std_halving) |each| {
            if (!try named(w.c, &.{.{ .path = each.path, .param = each.param }}, origin, index)) continue;
            const at = each.input + position - index;
            if (at >= call.ast.params.len) return null;
            return if (whole and leaves and w.twiceAsLong(node, call.ast.params[at])) written else null;
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
        if (!try Program.owns(w.c, origin.file)) return handed;
        if (try writesWhole(w.c, origin, index, w.depth + 1)) return if (whole and leaves) written else null;
        // What it returns may hold what it keeps: followed here as a holder.
        if (try keepsOnly(w.c, origin, index, w.depth + 1)) {
            if (!holdsResult(try w.c.facts.resolve(w.file, node))) return null;
            return if (try holderKept(w.c, w.file, node, w.depth)) null else handed;
        }
        if (try writesParts(w.c, origin, index, w.depth + 1)) return null;
        // One that reads only some parts of what it is given, through a pointer to the same
        // type, reads those.
        if (!whole) return handed;
        const owner = w.owner orelse return handed;
        const found = (try needs(w.c, origin, index, w.depth + 1)) orelse return handed;
        if (!std.meta.eql(owner, found.owner)) return handed;
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
        for (value.alternatives) |each| {
            const decl = switch (each) {
                .function => |function| function,
                else => return null,
            };
            const origin = (try w.c.facts.origin(decl)) orelse decl;
            const index = parameterAt(w.c, w.file, call, origin, position);
            const this: Choice = if (try named(w.c, &std_fills, origin, index)) fill: {
                if (!w.failureLeaves(node, origin)) return null;
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
        const origin = (try w.c.facts.origin(decl)) orelse decl;
        for ((try Governed.declarations(w.c, "std", path)) orelse &.{}) |found| {
            const target = (try w.c.facts.origin(found)) orelse found;
            if (std.meta.eql(target, origin)) return true;
        }
        return false;
    }

    /// The function a call reaches: by its name, or a declaration literal (`.fixed(&buf)`) by
    /// the container its result location names.
    fn callee(w: *Walk, node: Ast.Node.Index, call: Ast.full.Call) Context.Error!?Facts.Decl {
        const tree = w.tree;
        if (tree.nodeTag(call.ast.fn_expr) != .enum_literal) return switch (try w.c.facts.resolve(w.file, call.ast.fn_expr)) {
            .function => |decl| decl,
            else => null,
        };
        const container = (try w.c.facts.resultContainer(w.file, node)) orelse return null;
        const decl = w.c.facts.member(container, tree.tokenSlice(tree.nodeMainToken(call.ast.fn_expr))) orelse return null;
        return switch (try w.c.facts.declaration(decl)) {
            .function => |function| function,
            else => null,
        };
    }

    /// Whether a call that may fail leaves where it does: its error is `try`'s to return, or a
    /// `catch` that returns or cannot go on (`catch return`, `catch unreachable`).
    fn failureLeaves(w: *Walk, node: Ast.Node.Index, function: Facts.Decl) bool {
        if (w.succeeding == node) return true;
        const tree = &w.c.project.at(function.file).file.tree;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, w.c.project.at(function.file).model.declarations[@backingInt(function.index)].node) orelse return false;
        const result = proto.ast.return_type.unwrap() orelse return false;
        if (tree.nodeTag(result) != .error_union and !Model.inferredErrors(tree, result)) return true;
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
    fn forSets(w: *Walk, node: Ast.Node.Index, loop: Ast.full.For, memory: Ast.Node.Index, whole: bool, key: Ast.TokenIndex) ?Use {
        const tree = w.tree;
        const handed: Use = .{ .key = key, .effect = .handed };
        if (loop.ast.else_expr != .none or w.mentioned(loop.ast.then_expr)) return handed;
        const position = std.mem.findScalar(Ast.Node.Index, loop.ast.inputs, memory) orelse return handed;
        const name = capture(tree, loop.payload_token, position, true) orelse return handed;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, loop.ast.then_expr) orelse (&loop.ast.then_expr)[0..1];
        for (statements) |each| {
            // Before it, only what neither reads the element nor leaves the pass.
            if (names(tree, each, name) or leavesPass(tree, each)) {
                if (tree.nodeTag(each) != .assign) return handed;
                const target, const value = tree.nodeData(each).node_and_node;
                if (names(tree, value, name) or leavesPass(tree, value)) return handed;
                if (tree.nodeTag(target) != .deref) return handed;
                const pointer = tree.nodeData(target).node;
                if (tree.nodeTag(pointer) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(pointer)), name)) return handed;
                if (!w.passesAll(node, loop.ast.then_expr)) return handed;
                if (holdsUndefined(tree, value)) {
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
    fn passesAll(w: *const Walk, loop: Ast.Node.Index, body: Ast.Node.Index) bool {
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
        return !w.param or !w.returnsIn(body);
    }

    /// Whether `slice` is the local from zero to a count one of std's calls returned of what
    /// it wrote there (`const n = try file.readStreaming(io, &.{&buf}); buf[0..n]`): the count
    /// a constant or the call itself, its call given the local itself, alone, at the position
    /// the call writes; a failure that gives a count gives 0.
    fn countedPrefix(w: *Walk, slice: Ast.Node.Index) Context.Error!bool {
        const tree = w.tree;
        if (tree.nodeTag(slice) == .slice_sentinel) return false;
        const full = tree.fullSlice(slice) orelse return false;
        if (literalValue(tree, full.ast.start) != 0) return false;
        var end = full.ast.end.unwrap() orelse return false;
        // `@intCast(n)`: the same count, or a checked stop.
        if (isBuiltin(tree, end, "@intCast")) {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, end, &buffer);
            if (args.len != 1) return false;
            end = args[0];
        }
        // `buf[0..w.pos]`: the count of a cursor writer given all of the local.
        if (tree.nodeTag(end) == .field_access) return w.cursorCounted(end);
        // `buf[0..std.fmt.printInt(&buf, …)]`: the count the call returns, read where it returns.
        var source = end;
        if (tree.nodeTag(end) == .identifier) {
            const index = (w.model.reference(end) orelse return false).declaration orelse return false;
            const count = w.model.declarations[@backingInt(index)];
            if (count.kind != .variable) return false;
            const variable = tree.fullVarDecl(count.node) orelse return false;
            if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return w.appended(index);
            source = variable.ast.init_node.unwrap() orelse return false;
        }
        switch (tree.nodeTag(source)) {
            .@"try" => source = tree.nodeData(source).node,
            .@"catch" => {
                const lhs, const rhs = tree.nodeData(source).node_and_node;
                switch (tree.nodeTag(rhs)) {
                    .@"return", .unreachable_literal => {},
                    else => if (literalValue(tree, rhs) != 0) return false,
                }
                source = lhs;
            },
            else => {},
        }
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, source) orelse return false;
        const decl = (try w.callee(source, call)) orelse return false;
        const origin = (try w.c.facts.origin(decl)) orelse decl;
        var offset: usize = 0;
        if (tree.nodeTag(call.ast.fn_expr) == .field_access) switch (try w.c.facts.resolve(w.file, tree.nodeData(call.ast.fn_expr).node_and_token[0])) {
            .instance, .pointer, .optional => offset = 1,
            else => {},
        };
        for (call.ast.params, 0..) |arg, position| {
            const counts = try named(w.c, &std_counts, origin, position + offset) or
                if (try CContract.find(w.c, origin, position + offset)) |entry| entry.success == .count and try w.typed(entry, position + offset, true) else false;
            if (!counts) continue;
            if (w.namesAlone(arg)) return true;
        }
        return false;
    }

    /// Whether `count`, a `var` the slice ends at, counts the elements of the local written from
    /// its start: it begins at 0, and every change to it is `count += 1` right after the
    /// statement before it in its block sets `local[count]`, so each step past an element
    /// follows that element's write. Its address is never taken.
    fn appended(w: *const Walk, count: Model.Declaration.Id) bool {
        const tree = w.tree;
        if (!w.within(w.model.declarations[@backingInt(count)].node)) return false;
        const variable = tree.fullVarDecl(w.model.declarations[@backingInt(count)].node) orelse return false;
        if (literalValue(tree, variable.ast.init_node.unwrap() orelse return false) != 0) return false;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const ref = w.model.reference(node) orelse continue;
            if (ref.declaration != count) continue;
            const parent = w.model.parentOf(node) orelse return false;
            switch (tree.nodeTag(parent)) {
                .address_of => return false,
                .assign, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat => if (tree.nodeData(parent).node_and_node[0] == node) return false,
                .assign_add => {
                    const target, const step = tree.nodeData(parent).node_and_node;
                    if (target != node) continue;
                    if (literalValue(tree, step) != 1 or !w.followsSet(parent, count)) return false;
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
    fn followsSet(w: *const Walk, step: Ast.Node.Index, count: Model.Declaration.Id) bool {
        const tree = w.tree;
        const block = w.model.parentOf(step) orelse return false;
        if (!isBlock(tree, block)) return false;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, block) orelse return false;
        const at = std.mem.findScalar(Ast.Node.Index, statements, step) orelse return false;
        if (at == 0) return false;
        const set = statements[at - 1];
        if (tree.nodeTag(set) != .assign) return false;
        const target = tree.nodeData(set).node_and_node[0];
        if (tree.nodeTag(target) != .array_access) return false;
        const memory, const index = tree.nodeData(target).node_and_node;
        if (!w.isLocal(memory) or tree.nodeTag(index) != .identifier) return false;
        const ref = w.model.reference(index) orelse return false;
        return ref.declaration == count;
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
            else => return null,
        } else (try w.c.facts.resultContainer(w.file, literal)) orelse return null;
        const memory = w.c.facts.member(container, tree.tokenSlice(tree.firstToken(value) - 2)) orelse return null;
        const source = w.c.project.at(memory.file);
        if (source.model.declarations[@backingInt(memory.index)].kind != .field) return null;
        const count = (try cursorCount(w.c, container, memory)) orelse return null;
        for (made.ast.fields) |field| {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.firstToken(field) - 2), count)) continue;
            if (literalValue(tree, field) != 0) return null;
        }
        return .{ .memory = source.model.declarations[@backingInt(memory.index)].name, .count = count };
    }

    /// Whether `end` (`w.pos`) is the count of a cursor writer declared over all of the local
    /// (`var w: Writer = .{ .bytes = &buf }`) that still holds it: the writer is never
    /// assigned over, and only its fields are named, or its address handed to the program's
    /// functions that do the same with it (`keepsWriter`).
    fn cursorCounted(w: *Walk, end: Ast.Node.Index) Context.Error!bool {
        const tree = w.tree;
        const object, const name = tree.nodeData(end).node_and_token;
        if (tree.nodeTag(object) != .identifier) return false;
        const writer = (w.model.reference(object) orelse return false).declaration orelse return false;
        const record = w.model.declarations[@backingInt(writer)];
        if (record.kind != .variable) return false;
        const variable = tree.fullVarDecl(record.node) orelse return false;
        const literal = variable.ast.init_node.unwrap() orelse return false;
        var buffer: [2]Ast.Node.Index = undefined;
        const made = tree.fullStructInit(&buffer, literal) orelse return false;
        const counts = for (made.ast.fields) |field| {
            if (!w.namesAlone(field)) continue;
            const cursor = (try w.cursorAt(literal, field)) orelse return false;
            break std.mem.eql(u8, cursor.count, tree.tokenSlice(name));
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
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .identifier) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const ref = w.model.reference(node) orelse continue;
            if (ref.declaration != writer) continue;
            if (!try keepsWriterAt(w.c, w.file, node, w.depth + 1)) return false;
        }
        return true;
    }

    /// Whether `arg` is the local's address (`&buf`), all of it sliced, or a vector of it
    /// alone (`&.{&buf}`).
    fn namesAlone(w: *const Walk, arg: Ast.Node.Index) bool {
        const tree = w.tree;
        var at = arg;
        if (tree.nodeTag(at) == .address_of) {
            const inner = tree.nodeData(at).node;
            var elements: [2]Ast.Node.Index = undefined;
            if (tree.fullArrayInit(&elements, inner)) |literal| {
                if (literal.ast.elements.len != 1) return false;
                at = literal.ast.elements[0];
            }
        }
        if (tree.nodeTag(at) == .address_of) at = tree.nodeData(at).node else if (tree.fullSlice(at) != null) {
            if (!w.allOf(at)) return false;
            at = tree.fullSlice(at).?.ast.sliced;
        }
        if (tree.nodeTag(at) != .identifier) return false;
        const ref = w.model.reference(at) orelse return false;
        return ref.declaration == w.local;
    }

    /// Whether a slice of the local is all of it: from zero, to its end or its length.
    fn allOf(w: *const Walk, slice: Ast.Node.Index) bool {
        const tree = w.tree;
        if (tree.nodeTag(slice) == .slice_sentinel) return false;
        const full = tree.fullSlice(slice) orelse return false;
        if (literalValue(tree, full.ast.start) != 0) return false;
        const end = full.ast.end.unwrap() orelse return true;
        if (tree.nodeTag(end) != .field_access or !std.mem.eql(u8, tree.tokenSlice(tree.nodeData(end).node_and_token[1]), "len")) return false;
        const of = tree.nodeData(end).node_and_token[0];
        if (tree.nodeTag(of) != .identifier) return false;
        const ref = w.model.reference(of) orelse return false;
        return ref.declaration == w.local;
    }

    /// Whether the local is declared an array, whose length its type holds.
    fn array(w: *const Walk) bool {
        const variable = w.tree.fullVarDecl(w.model.declarations[@backingInt(w.local)].node) orelse return false;
        const kind = variable.ast.type_node.unwrap() orelse return false;
        return switch (w.tree.nodeTag(kind)) {
            .array_type, .array_type_sentinel => true,
            else => false,
        };
    }

    /// Whether the local is declared of a struct type by name, whose fields are its own memory.
    fn structure(w: *Walk) bool {
        const variable = w.tree.fullVarDecl(w.model.declarations[@backingInt(w.local)].node) orelse return false;
        const kind = variable.ast.type_node.unwrap() orelse return false;
        const value = w.c.facts.resolve(w.file, kind) catch return false;
        return value == .container;
    }

    fn builtinField(tree: *const Ast, node: Ast.Node.Index, operand: Ast.Node.Index) bool {
        switch (tree.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma => {},
            else => return false,
        }
        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@field")) return false;
        const first = tree.nodeData(node).opt_node_and_opt_node[0].unwrap() orelse return false;
        return first == operand;
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

    /// The length a local declared an array of a literal length has.
    fn arrayLength(w: *const Walk) ?u64 {
        const tree = w.tree;
        const variable = tree.fullVarDecl(w.model.declarations[@backingInt(w.local)].node) orelse return null;
        const kind = variable.ast.type_node.unwrap() orelse return null;
        if (tree.nodeTag(kind) != .array_type) return null;
        return literalValue(tree, tree.nodeData(kind).node_and_node[0]);
    }

    /// Whether `node` is the local's `.len`.
    fn isLength(w: *const Walk, node: Ast.Node.Index) bool {
        const tree = w.tree;
        const at = ungrouped(tree, node);
        if (tree.nodeTag(at) != .field_access) return false;
        const of, const member = tree.nodeData(at).node_and_token;
        return std.mem.eql(u8, tree.tokenSlice(member), "len") and w.isLocal(of);
    }

    /// The mention of the local at `token`.
    fn mentionAt(w: *const Walk, token: Ast.TokenIndex) ?Ast.Node.Index {
        for (w.mentions.items) |mention| if (w.tree.nodeMainToken(mention) == token) return mention;
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
    fn isResult(w: *const Walk, node: Ast.Node.Index, guard: Guard) bool {
        const at = ungrouped(w.tree, node);
        if (at == guard.call) return true;
        if (w.tree.nodeTag(at) != .identifier) return false;
        const binding = guard.binding orelse return false;
        const ref = w.model.reference(at) orelse return false;
        return ref.declaration == binding;
    }

    /// Which of std's errno decoders `node` is, of the guarding call's result alone: as
    /// `noteErrnos` found it by declaration; null for any other call or node.
    fn errnoOf(w: *const Walk, node: Ast.Node.Index, guard: Guard) ?CContract.Errno {
        const at = ungrouped(w.tree, node);
        var buffer: [1]Ast.Node.Index = undefined;
        const call = w.tree.fullCall(&buffer, at) orelse return null;
        if (call.ast.params.len != 1 or !w.isResult(call.ast.params[0], guard)) return null;
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
        for (w.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .call_one and tag != .call_one_comma) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            var buffer: [1]Ast.Node.Index = undefined;
            const call = w.tree.fullCall(&buffer, node) orelse continue;
            if (call.ast.params.len != 1 or !w.isResult(call.ast.params[0], guard)) continue;
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
            if (tree.nodeTag(kind) != .array_type) return false;
            kind = tree.nodeData(kind).node_and_node[1];
        }
        var spellings = std.mem.splitScalar(u8, entry.types[at], '|');
        while (spellings.next()) |name| if (try w.typeNamed(kind, name)) return true;
        return false;
    }

    /// Whether the type expression `kind` is the type `name` names: a primitive, std's
    /// declaration at that path (through the aliases either is spelled by), or `[n]T` of one.
    fn typeNamed(w: *Walk, kind: Ast.Node.Index, name: []const u8) Context.Error!bool {
        const tree = w.tree;
        if (name.len > 0 and name[0] == '[') {
            const close = std.mem.findScalar(u8, name, ']') orelse return false;
            const length = std.fmt.parseInt(u64, name[1..close], 10) catch return false;
            if (tree.nodeTag(kind) != .array_type) return false;
            const count, const element = tree.nodeData(kind).node_and_node;
            if (literalValue(tree, count) != length) return false;
            return w.typeNamed(element, name[close + 1 ..]);
        }
        const got = try w.c.facts.resolve(w.file, kind);
        if (Model.primitive(name)) return got == .primitive and std.mem.eql(u8, got.primitive, name);
        for ((try Governed.declarations(w.c, "std", name)) orelse &.{}) |decl| {
            if (sameValue(got, try w.c.facts.declaration(decl), 0)) return true;
        }
        return false;
    }

    /// Whether `node`, a size a call is given, is the local's own as a constant: `@sizeOf` of
    /// its type or of `@TypeOf` it, or the length of an array of bytes; through `@intCast` and
    /// `@as`.
    fn sizeOfLocal(w: *const Walk, node: Ast.Node.Index) bool {
        const tree = w.tree;
        var at = ungrouped(tree, node);
        var buffer: [2]Ast.Node.Index = undefined;
        while (isBuiltin(tree, at, "@intCast") or isBuiltin(tree, at, "@as")) {
            const args = Facts.builtinArgs(tree, at, &buffer);
            if (args.len == 0) return false;
            at = ungrouped(tree, args[args.len - 1]);
        }
        const variable = tree.fullVarDecl(w.model.declarations[@backingInt(w.local)].node) orelse return false;
        const kind = variable.ast.type_node.unwrap() orelse return false;
        if (literalValue(tree, at)) |bytes| {
            if (tree.nodeTag(kind) != .array_type) return false;
            const count, const element = tree.nodeData(kind).node_and_node;
            return literalValue(tree, count) == bytes and isWord(tree, element, "u8");
        }
        if (!isBuiltin(tree, at, "@sizeOf")) return false;
        const args = Facts.builtinArgs(tree, at, &buffer);
        if (args.len != 1) return false;
        const of = ungrouped(tree, args[0]);
        if (isBuiltin(tree, of, "@TypeOf")) {
            const inner = Facts.builtinArgs(tree, of, &buffer);
            return inner.len == 1 and w.isLocal(ungrouped(tree, inner[0]));
        }
        return sameText(w.model, tree, of, kind);
    }

    /// What `cond` being true says of the guarding call: true where it shows the call wrote
    /// (`rc == 0` for a call whose success is 0), false where its being false does (`rc != 0`),
    /// null where it shows neither. `a and b` is true when either shows it true; `a or b` false
    /// when either shows it false.
    fn checks(w: *const Walk, cond: Ast.Node.Index, guard: Guard) ?bool {
        const tree = w.tree;
        const node = ungrouped(tree, cond);
        switch (tree.nodeTag(node)) {
            .bool_and => {
                const a, const b = tree.nodeData(node).node_and_node;
                return if (w.checks(a, guard) == true or w.checks(b, guard) == true) true else null;
            },
            .bool_or => {
                const a, const b = tree.nodeData(node).node_and_node;
                return if (w.checks(a, guard) == false or w.checks(b, guard) == false) false else null;
            },
            .equal_equal, .bang_equal, .greater_than, .greater_or_equal, .less_than, .less_or_equal => {},
            else => return null,
        }
        var lhs, var rhs = tree.nodeData(node).node_and_node;
        var op = tree.nodeTag(node);
        // The result on the left: `0 != rc` is `rc != 0`.
        if (!w.isResult(lhs, guard) and w.errnoOf(lhs, guard) == null) {
            std.mem.swap(Ast.Node.Index, &lhs, &rhs);
            op = switch (op) {
                .greater_than => .less_than,
                .less_than => .greater_than,
                .greater_or_equal => .less_or_equal,
                .less_or_equal => .greater_or_equal,
                else => op,
            };
        }
        const equal: ?bool = switch (op) {
            .equal_equal => true,
            .bang_equal => false,
            else => null,
        };
        if (w.errnoOf(lhs, guard)) |kind| {
            // errno is SUCCESS exactly where the call did not fail, read by the decoder its
            // results are made for: none for one that answers the error number itself.
            if (guard.entry.errno == .none or kind != guard.entry.errno) return null;
            return if (isMember(tree, rhs, "SUCCESS")) equal else null;
        }
        if (!w.isResult(lhs, guard)) return null;
        switch (guard.entry.success) {
            .zero => return if (literalValue(tree, rhs) == 0 or isMember(tree, rhs, "SUCCESS")) equal else null,
            .nonzero => {
                const is = equal orelse return null;
                return if (literalValue(tree, rhs) == 0 or isMember(tree, rhs, "FALSE")) !is else null;
            },
            .positive => {
                if (literalValue(tree, rhs) != 0) return null;
                return switch (op) {
                    .greater_than => true,
                    .less_or_equal => false,
                    else => null,
                };
            },
            .size => |param| {
                var buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buffer, guard.call) orelse return null;
                if (param >= call.ast.params.len) return null;
                // The size given, a constant that is the local's own: what the call filled is
                // all of it.
                const size = call.ast.params[param];
                if (!w.sizeOfLocal(size) or !sameText(w.model, tree, rhs, size)) return null;
                return equal;
            },
            .length => {
                const length = w.arrayLength();
                const literal = literalValue(tree, rhs);
                const all = (literal != null and length != null and literal.? == length.?) or w.isLength(rhs);
                if (!all) return null;
                return switch (op) {
                    .equal_equal, .greater_or_equal => true,
                    .bang_equal, .less_than => false,
                    else => null,
                };
            },
            .count, .errno => return null,
        }
    }

    /// Whether `prong` of a `switch` on `condition` runs only where the guarding call wrote:
    /// its one item `.SUCCESS`, and the condition the call's errno or its status.
    fn successProng(w: *const Walk, condition: Ast.Node.Index, prong: Ast.full.SwitchCase, guard: Guard) bool {
        if (prong.ast.values.len != 1 or !isMember(w.tree, prong.ast.values[0], "SUCCESS")) return false;
        if (w.errnoOf(condition, guard)) |kind| return guard.entry.errno != .none and kind == guard.entry.errno;
        return w.isResult(condition, guard) and guard.entry.success == .zero;
    }

    /// Whether `mention`, in statement `top`, runs only where the guarding call wrote: in the
    /// branch of an `if` its condition shows the call wrote on, or after `and` or `or` a test
    /// that shows it.
    fn behind(w: *const Walk, mention: Ast.Node.Index, guard: Guard, top: Ast.Node.Index) bool {
        const tree = w.tree;
        var at = mention;
        while (at != top) {
            const up = w.model.parentOf(at) orelse return false;
            switch (tree.nodeTag(up)) {
                .bool_and => {
                    const a, const b = tree.nodeData(up).node_and_node;
                    if (b == at and w.checks(a, guard) == true) return true;
                },
                .bool_or => {
                    const a, const b = tree.nodeData(up).node_and_node;
                    if (b == at and w.checks(a, guard) == false) return true;
                },
                else => if (tree.fullIf(up)) |branch| {
                    if (w.checks(branch.ast.cond_expr, guard)) |holds| {
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
        for (w.mentions.items) |mention| {
            const token = w.tree.nodeMainToken(mention);
            if (token >= first and token <= last) return true;
        }
        return false;
    }

    /// Whether a `return` the walk sees the memory leave by (`exitsBy`) sits in `node`, for a
    /// parameter's walk.
    fn returnsIn(w: *const Walk, node: Ast.Node.Index) bool {
        const first = w.tree.firstToken(node);
        const last = w.tree.lastToken(node);
        for (w.returns.items) |each| {
            const token = w.tree.firstToken(each);
            if (token >= first and token <= last and w.exitsBy(each)) return true;
        }
        return false;
    }

    /// Whether the `return` at `node` is one a parameter's walk sees its memory leave by: any
    /// but an error's, or any at all where `every_exit` asks.
    fn exitsBy(w: *const Walk, node: Ast.Node.Index) bool {
        return w.every_exit or !errorReturn(w.tree, w.model, node);
    }
};

/// Whether the type `kind` spells a pointer or slice: written so, or as the name of a constant of
/// `scope` that is one, or a choice of them (`if (a) |x| []align(x) T else []T`), where `by_name`.
fn spelledPointer(tree: *const Ast, model: *const Model, scope: Model.Scope.Id, kind: Ast.Node.Index, by_name: bool) bool {
    const node = ungrouped(tree, kind);
    if (tree.fullPtrType(node) != null) return true;
    if (tree.fullIf(node)) |choice| {
        const otherwise = choice.ast.else_expr.unwrap() orelse return false;
        return spelledPointer(tree, model, scope, choice.ast.then_expr, by_name) and spelledPointer(tree, model, scope, otherwise, by_name);
    }
    if (!by_name or tree.nodeTag(node) != .identifier) return false;
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    for (model.declarations) |decl| {
        if (decl.kind != .variable or decl.scope != scope or !std.mem.eql(u8, decl.name, name)) continue;
        const variable = tree.fullVarDecl(decl.node) orelse return false;
        if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return false;
        return spelledPointer(tree, model, scope, variable.ast.init_node.unwrap() orelse return false, false);
    }
    return false;
}

/// The parameter of `decl`, the function a call reaches, that the call's argument at `position`
/// is: one further for a method's call, whose receiver comes first (`page.write(w, n)`). Read
/// by how many parameters the function has, so a receiver whose type does not resolve counts
/// the same; a namespace's function (`S.f(x)`) has none.
fn parameterAt(c: *Context, file: Project.FileId, call: Ast.full.Call, decl: Facts.Decl, position: usize) usize {
    if (c.project.at(file).file.tree.nodeTag(call.ast.fn_expr) != .field_access) return position;
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return position;
    var count: usize = 0;
    var it = proto.iterate(tree);
    while (it.next()) |_| count += 1;
    return if (count == call.ast.params.len + 1) position + 1 else position;
}

/// The place a mention of a local hands on with what holds it: the local, or the field or
/// element of it (`x.list`, `x.lists[0]`) a method is called on or whose address is taken.
fn placeOf(tree: *const Ast, model: *const Model, mention: Ast.Node.Index) Ast.Node.Index {
    var buffer: [1]Ast.Node.Index = undefined;
    var place = mention;
    while (model.parentOf(place)) |up| {
        const inner = switch (tree.nodeTag(up)) {
            .field_access => tree.nodeData(up).node_and_token[0],
            .array_access => tree.nodeData(up).node_and_node[0],
            else => break,
        };
        if (inner != place) break;
        if (tree.nodeTag(up) == .field_access) if (model.parentOf(up)) |grand| if (tree.fullCall(&buffer, grand)) |call| if (call.ast.fn_expr == up) break;
        place = up;
    }
    return place;
}

/// The place (`placeOf`) a mention gives a call, as the call's receiver (`x.deinit(gpa)`) or
/// by address (`f(&x.list)`), or for a parameter's pointer, as it is (`f(p)`); null where it
/// gives none.
fn handedPlace(tree: *const Ast, model: *const Model, mention: Ast.Node.Index, param: bool) ?Ast.Node.Index {
    var buffer: [1]Ast.Node.Index = undefined;
    const place = placeOf(tree, model, mention);
    const holder = model.parentOf(place) orelse return null;
    switch (tree.nodeTag(holder)) {
        .field_access => {
            const call = tree.fullCall(&buffer, model.parentOf(holder) orelse return null) orelse return null;
            return if (call.ast.fn_expr == holder) place else null;
        },
        .address_of => {
            const call = tree.fullCall(&buffer, model.parentOf(holder) orelse return null) orelse return null;
            return if (std.mem.findScalar(Ast.Node.Index, call.ast.params, holder) != null) place else null;
        },
        else => {
            if (!param or place != mention) return null;
            const call = tree.fullCall(&buffer, holder) orelse return null;
            return if (std.mem.findScalar(Ast.Node.Index, call.ast.params, place) != null) place else null;
        },
    }
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
        .pointer => |inner| sameValue(inner.*, b.pointer.*, depth + 1),
        .array => |inner| sameValue(inner.*, b.array.*, depth + 1),
        .optional => |inner| sameValue(inner.*, b.optional.*, depth + 1),
        .alternatives => |each| each.len == b.alternatives.len and for (each, b.alternatives) |x, y| {
            if (!sameValue(x, y, depth + 1)) break false;
        } else true,
        else => false,
    };
}

fn sameType(tree: *const Ast, model: *const Model, a: Ast.Node.Index, b: Ast.Node.Index) bool {
    if (tree.nodeTag(a) != tree.nodeTag(b)) return false;
    switch (tree.nodeTag(a)) {
        .identifier => {
            const x = (model.reference(a) orelse return false).declaration orelse return false;
            const y = (model.reference(b) orelse return false).declaration orelse return false;
            return x == y;
        },
        .field_access => {
            const x, const member_x = tree.nodeData(a).node_and_token;
            const y, const member_y = tree.nodeData(b).node_and_token;
            return std.mem.eql(u8, tree.tokenSlice(member_x), tree.tokenSlice(member_y)) and sameType(tree, model, x, y);
        },
        else => return false,
    }
}

/// Whether `node` calls the builtin `name`.
fn isBuiltin(tree: *const Ast, node: Ast.Node.Index, name: []const u8) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name),
        else => false,
    };
}

/// Whether an identifier spelled `name` appears in `node`.
fn names(tree: *const Ast, node: Ast.Node.Index, name: []const u8) bool {
    var token = tree.firstToken(node);
    while (token <= tree.lastToken(node)) : (token += 1) {
        // A member's name (`rule.definition`, `.definition = …`) names no local.
        if (token > 0 and tree.tokenTag(token - 1) == .period) continue;
        if (tree.tokenTag(token) == .identifier and std.mem.eql(u8, tree.tokenSlice(token), name)) return true;
    }
    return false;
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
    switch (tree.nodeTag(parent)) {
        .grouped_expression, .address_of, .deref, .@"try" => return holderKept(c, file, parent, depth),
        .@"catch", .@"orelse" => return tree.nodeData(parent).node_and_node[0] == node and try holderKept(c, file, parent, depth),
        .@"return" => return true,
        .field_access => {
            if (model.parentOf(parent)) |grand| if (tree.fullCall(&buffer, grand)) |call| if (call.ast.fn_expr == parent) {
                return holderKeptThrough(c, file, call, null, depth);
            };
            return switch (try heldField(c, file, parent)) {
                .number => true,
                .holder => holderKept(c, file, parent, depth + 1),
                .memory => false,
            };
        },
        .assign => {
            // Assigned over, or discarded (`_ = &w;`).
            const target = tree.nodeData(parent).node_and_node[0];
            return target == node or isWord(tree, target, "_");
        },
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
    switch (try c.facts.resolve(file, access)) {
        .primitive, .scalar, .error_set => return .number,
        .instance => return .holder,
        else => {},
    }
    const object, const member = tree.nodeData(access).node_and_token;
    const container = switch (try c.facts.resolve(file, object)) {
        .instance => |found| found,
        .pointer => |to| switch (to.*) {
            .instance => |found| found,
            else => return .memory,
        },
        else => return .memory,
    };
    const source = c.project.at(container.file);
    const name = tree.tokenSlice(member);
    for (source.model.declarations) |decl| {
        if (decl.kind != .field or decl.scope != container.scope or !std.mem.eql(u8, decl.name, name)) continue;
        const field = source.file.tree.fullContainerField(decl.node) orelse return .memory;
        var kind = field.ast.type_expr.unwrap() orelse return .memory;
        if (source.file.tree.nodeTag(kind) == .optional_type) kind = source.file.tree.nodeData(kind).node;
        const pointer = source.file.tree.fullPtrType(kind) orelse return .memory;
        return if (pointer.size == .one) .holder else .memory;
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
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const each: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const ref = model.reference(each) orelse continue;
        if (ref.declaration != id) continue;
        if (!try holderKept(c, file, each, depth)) return false;
    }
    return true;
}

/// Whether a call handed a holder (a method's receiver, `position` null, or the argument at
/// `position`) keeps what it holds: std's, but those that hand back its room, or the
/// program's, or a dependency's, whose parameter keeps it.
fn holderKeptThrough(c: *Context, file: Project.FileId, call: Ast.full.Call, position: ?usize, depth: u8) Context.Error!bool {
    const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
        .function => |function| function,
        else => return false,
    };
    const origin = (try c.facts.origin(decl)) orelse decl;
    for (std_room) |path| for ((try Governed.declarations(c, "std", path)) orelse &.{}) |found| {
        if (std.meta.eql((try c.facts.origin(found)) orelse found, origin)) return false;
    };
    if (try inStd(c, origin.file)) return true;
    const index = if (position) |at| parameterAt(c, file, call, origin, at) else 0;
    return remembered(bool, c, .{ .decl = origin, .index = index, .question = .holds }, depth + 1, holderKeptByParameter, false);
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

/// The files std's own import reaches, found once.
const StdFiles = struct { set: std.AutoHashMapUnmanaged(u32, void) = .empty, found: bool = false };

fn inStd(c: *Context, file: Project.FileId) Context.Error!bool {
    const memo = try c.facts.memo(StdFiles);
    if (!memo.found) {
        memo.found = true;
        for (c.project.imports) |mapping| {
            if (!std.mem.eql(u8, mapping.spelling, "std")) continue;
            if ((try memo.set.getOrPut(c.allocator, @backingInt(mapping.target))).found_existing) continue;
            var stack: std.ArrayList(Project.FileId) = .empty;
            try stack.append(c.allocator, mapping.target);
            while (stack.pop()) |each| for (c.project.imports) |edge| {
                if (edge.from != each) continue;
                if ((try memo.set.getOrPut(c.allocator, @backingInt(edge.target))).found_existing) continue;
                try stack.append(c.allocator, edge.target);
            };
        }
    }
    return memo.set.contains(@backingInt(file));
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
    for (walk.mentions.items) |mention| {
        const parent = walk.model.parentOf(mention) orelse return false;
        if (tree.nodeTag(parent) == .field_access and std.mem.eql(u8, tree.tokenSlice(tree.nodeData(parent).node_and_token[1]), "len")) continue;
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
    for (walk.mentions.items) |mention| {
        const key = tree.nodeMainToken(mention);
        const parent = model.parentOf(mention) orelse return false;
        var memory = mention;
        switch (tree.nodeTag(parent)) {
            .field_access => {
                if (std.mem.eql(u8, tree.tokenSlice(tree.nodeData(parent).node_and_token[1]), "len")) continue;
                return false;
            },
            .array_access => {
                if (tree.nodeData(parent).node_and_node[0] != mention) return false;
                if (assigned(model, tree, parent)) continue;
                if (try coveredBefore(c, decl.file, written.items, null, parent)) continue;
                return false;
            },
            .deref => {
                // `p.* = undefined` writes nothing, and leaves undefined what was.
                if (assigned(model, tree, parent) and !holdsUndefined(tree, tree.nodeData(model.parentOf(parent).?).node_and_node[1])) {
                    try written.append(c.allocator, .{ .part = null, .statement = statementOf(model, tree, parent) orelse return false });
                    continue;
                }
                return false;
            },
            .slice_open, .slice, .slice_sentinel => {
                if ((tree.fullSlice(parent) orelse return false).ast.sliced != mention) return false;
                memory = parent;
                // `p[0..w.pos]`: what a cursor writer, or a counting call, wrote there.
                if (try walk.countedPrefix(parent)) continue;
                // `p[a..b].* = v`.
                const above = model.parentOf(parent) orelse return false;
                if (tree.nodeTag(above) == .deref and assigned(model, tree, above)) {
                    if (holdsUndefined(tree, tree.nodeData(model.parentOf(above).?).node_and_node[1])) return false;
                    try written.append(c.allocator, .{ .part = parent, .statement = statementOf(model, tree, above) orelse return false });
                    continue;
                }
                // `const part = p[a..b];`: the part under another name, each mention of which
                // is the part's.
                if (tree.fullVarDecl(above)) |variable| if (variable.ast.init_node.unwrap() == parent and tree.tokenTag(variable.ast.mut_token) == .keyword_const) {
                    const alias = for (model.declarations, 0..) |each, d| {
                        if (each.kind == .variable and each.node == above) break @as(Model.Declaration.Id, @fromBackingInt(@intCast(d)));
                    } else return false;
                    var aliased: Walk = .init(c, decl.file, alias, true, depth);
                    try aliased.collect();
                    for (aliased.mentions.items) |each| {
                        const up = model.parentOf(each) orelse return false;
                        if (tree.nodeTag(up) == .field_access and std.mem.eql(u8, tree.tokenSlice(tree.nodeData(up).node_and_token[1]), "len")) continue;
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
            .address_of => return false,
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
        const field = tree.fullContainerField(decl.node) orelse continue;
        if (literalValue(tree, field.ast.value_expr.unwrap() orelse continue) != 0) continue;
        const kind = field.ast.type_expr.unwrap() orelse continue;
        if (tree.nodeTag(kind) != .identifier or !isUnsigned(tree.tokenSlice(tree.nodeMainToken(kind)))) continue;
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
        if (!stepsCount(c, use, held)) return null;
    }
    for (try c.facts.memberUses(held)) |use| {
        const holder = try holderOf(c, use, container);
        if (holder == .other) continue;
        if (!keepsBelow(c, use, counted)) return null;
    }
    return counted;
}

/// Whether the object a member access (`x.pos`) is made on is one of `container`'s, through
/// pointers and optionals; `unknown` where what it is is not known.
fn holderOf(c: *Context, use: Facts.Key, container: Facts.Container) Context.Error!enum { ours, other, unknown } {
    const tree = &c.project.at(use.file).file.tree;
    var value = try c.facts.resolve(use.file, tree.nodeData(use.node).node_and_token[0]);
    while (true) switch (value) {
        .pointer, .optional => |inner| value = inner.*,
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
fn stepsCount(c: *Context, use: Facts.Key, memory: []const u8) bool {
    const tree = &c.project.at(use.file).file.tree;
    const model = &c.project.at(use.file).model;
    const parent = model.parentOf(use.node) orelse return true;
    switch (tree.nodeTag(parent)) {
        .address_of => return false,
        .assign => {
            const target, const value = tree.nodeData(parent).node_and_node;
            return target != use.node or literalValue(tree, value) == 0;
        },
        .assign_add => {
            const target, const step = tree.nodeData(parent).node_and_node;
            if (target != use.node) return true;
            const block = model.parentOf(parent) orelse return false;
            if (!isBlock(tree, block)) return false;
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, block) orelse return false;
            const at = std.mem.findScalar(Ast.Node.Index, statements, parent) orelse return false;
            if (at == 0) return false;
            const span = filled(tree, statements[at - 1]) orelse return false;
            // `x.bytes[x.pos..][0..k]`, the same `x`, `pos` and `k` as the step's.
            const part = tree.fullSlice(span) orelse return false;
            if (literalValue(tree, part.ast.start) != 0) return false;
            if (!plain(tree, step) or !sameText(model, tree, part.ast.end.unwrap() orelse return false, step)) return false;
            const rest = tree.fullSlice(part.ast.sliced) orelse return false;
            if (rest.ast.end != .none or !sameText(model, tree, rest.ast.start, use.node)) return false;
            const held = rest.ast.sliced;
            if (tree.nodeTag(held) != .field_access or !std.mem.eql(u8, tree.tokenSlice(tree.nodeData(held).node_and_token[1]), memory)) return false;
            if (!sameText(model, tree, tree.nodeData(held).node_and_token[0], tree.nodeData(use.node).node_and_token[0])) return false;
            return true;
        },
        .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat => return tree.nodeData(parent).node_and_node[0] != use.node,
        else => return true,
    }
}

/// Whether `node` spells only names, numbers, a name's `.len` and arithmetic: no field, no
/// dereference and no call, so that spelled alike in two statements with nothing between them,
/// it is the same value in both.
fn plain(tree: *const Ast, node: Ast.Node.Index) bool {
    var token = tree.firstToken(node);
    while (token <= tree.lastToken(node)) : (token += 1) switch (tree.tokenTag(token)) {
        .identifier => if (token < tree.lastToken(node) and tree.tokenTag(token + 1) == .l_paren) return false,
        .period => {
            if (token == tree.firstToken(node) or tree.tokenTag(token - 1) != .identifier) return false;
            if (!std.mem.eql(u8, tree.tokenSlice(token + 1), "len")) return false;
            token += 1;
        },
        .number_literal, .plus, .minus, .asterisk, .l_paren, .r_paren => {},
        else => return false,
    };
    return true;
}

/// The memory a statement writes whole: `@memcpy(m, …)`, `@memset(m, …)` or `m.* = …`, with
/// no `undefined` in what it writes.
fn filled(tree: *const Ast, statement: Ast.Node.Index) ?Ast.Node.Index {
    if (isBuiltin(tree, statement, "@memcpy") or isBuiltin(tree, statement, "@memset")) {
        var buffer: [2]Ast.Node.Index = undefined;
        const params = tree.builtinCallParams(&buffer, statement) orelse return null;
        if (params.len != 2 or holdsUndefined(tree, params[1])) return null;
        return params[0];
    }
    if (tree.nodeTag(statement) != .assign) return null;
    const target, const value = tree.nodeData(statement).node_and_node;
    if (holdsUndefined(tree, value)) return null;
    return if (tree.nodeTag(target) == .deref) tree.nodeData(target).node else null;
}

/// Whether a mention of a cursor writer's memory (`x.bytes`) measures it, reads it below the
/// count (`x.bytes[0..x.pos]`), or is written: an element set, or a part of it written whole.
fn keepsBelow(c: *Context, use: Facts.Key, count: []const u8) bool {
    const tree = &c.project.at(use.file).file.tree;
    const model = &c.project.at(use.file).model;
    const parent = model.parentOf(use.node) orelse return false;
    switch (tree.nodeTag(parent)) {
        .field_access => return std.mem.eql(u8, tree.tokenSlice(tree.nodeData(parent).node_and_token[1]), "len"),
        .array_access => return tree.nodeData(parent).node_and_node[0] == use.node and assigned(model, tree, parent) and
            !holdsUndefined(tree, tree.nodeData(model.parentOf(parent).?).node_and_node[1]),
        .slice_open, .slice, .slice_sentinel => {
            const slice = tree.fullSlice(parent) orelse return false;
            if (slice.ast.sliced != use.node) return false;
            if (literalValue(tree, slice.ast.start) == 0) if (slice.ast.end.unwrap()) |end| {
                if (tree.nodeTag(end) == .field_access and
                    std.mem.eql(u8, tree.tokenSlice(tree.nodeData(end).node_and_token[1]), count) and
                    sameText(model, tree, tree.nodeData(end).node_and_token[0], tree.nodeData(use.node).node_and_token[0])) return true;
            };
            // A part, or a part of it, written whole.
            var part = parent;
            while (model.parentOf(part)) |up| {
                const inner = tree.fullSlice(up) orelse break;
                if (inner.ast.sliced != part) break;
                part = up;
            }
            const above = model.parentOf(part) orelse return false;
            if (filled(tree, above) == part) return true;
            return tree.nodeTag(above) == .deref and filled(tree, model.parentOf(above) orelse return false) == part;
        },
        else => return false,
    }
}

/// Whether a mention of a local cursor writer (`node`) keeps it over what it was given: it
/// names one of its fields or calls a method on it, or hands its address to one of the
/// program's functions, each of which does the same with the pointer. Nothing assigns over it
/// or keeps its address elsewhere.
fn keepsWriterAt(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const parent = model.parentOf(node) orelse return false;
    var buffer: [1]Ast.Node.Index = undefined;
    switch (tree.nodeTag(parent)) {
        .field_access => {
            // A method called on it is given it, or its address.
            const grand = model.parentOf(parent) orelse return true;
            const call = tree.fullCall(&buffer, grand) orelse return true;
            if (call.ast.fn_expr != parent) return true;
            const decl = switch (try c.facts.resolve(file, parent)) {
                .function => |function| function,
                else => return false,
            };
            return keepsWriter(c, (try c.facts.origin(decl)) orelse decl, 0, depth);
        },
        .address_of => {
            const grand = model.parentOf(parent) orelse return false;
            const call = tree.fullCall(&buffer, grand) orelse return false;
            const position = std.mem.findScalar(Ast.Node.Index, call.ast.params, parent) orelse return false;
            const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
                .function => |function| function,
                else => return false,
            };
            const index = parameterAt(c, file, call, (try c.facts.origin(decl)) orelse decl, position);
            return keepsWriter(c, (try c.facts.origin(decl)) orelse decl, index, depth);
        },
        else => return false,
    }
}

/// Whether the program's function `decl` keeps the cursor writer its parameter `index` gives
/// it as `keepsWriterAt` says: a copy, where the parameter is no pointer, holds nothing back.
fn keepsWriter(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!bool {
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
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const ref = model.reference(node) orelse continue;
        if (ref.declaration != id) continue;
        if (!try keepsPointerAt(c, decl.file, node, depth + 1)) return false;
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
    switch (tree.nodeTag(parent)) {
        .field_access => return keepsWriterAt(c, file, node, depth),
        else => {
            const call = tree.fullCall(&buffer, parent) orelse return false;
            const position = std.mem.findScalar(Ast.Node.Index, call.ast.params, node) orelse return false;
            const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
                .function => |function| function,
                else => return false,
            };
            const index = parameterAt(c, file, call, (try c.facts.origin(decl)) orelse decl, position);
            return keepsWriter(c, (try c.facts.origin(decl)) orelse decl, index, depth);
        },
    }
}

/// Whether a type's name is an unsigned integer's (`usize`, `u16`).
fn isUnsigned(name: []const u8) bool {
    if (std.mem.eql(u8, name, "usize")) return true;
    if (name.len < 2 or name[0] != 'u') return false;
    for (name[1..]) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// Whether `node` is the target of an assignment.
fn assigned(model: *const Model, tree: *const Ast, node: Ast.Node.Index) bool {
    const parent = model.parentOf(node) orelse return false;
    return tree.nodeTag(parent) == .assign and tree.nodeData(parent).node_and_node[0] == node;
}

/// The statement of a block that `node` is in and runs whenever the statement does: nothing
/// between them chooses (`if`, `switch`, `orelse`, `catch`, `and`, `or`, a loop's body) or
/// defers it, so a write there holds past the statement.
fn statementOf(model: *const Model, tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) switch (tree.nodeTag(parent)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => return at,
        // A deferred write runs where the scope ends, after what follows it.
        .@"orelse", .@"catch", .bool_and, .bool_or, .@"defer", .@"errdefer" => return null,
        else => {
            if (tree.fullIf(parent) != null or tree.fullSwitch(parent) != null or tree.fullWhile(parent) != null) return null;
            // A `for` that writes the memory it is given sets each element, so the memory is
            // all written once it ends; a `for` around the write runs it on some paths only.
            if (tree.fullFor(parent)) |loop| if (std.mem.findScalar(Ast.Node.Index, loop.ast.inputs, at) == null) return null;
        },
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
    switch (tree.nodeTag(full.ast.sliced)) {
        .identifier => {},
        .slice_open, .slice, .slice_sentinel => if (try boundsChanged(c, file, full.ast.sliced, from, to)) return true,
        else => return true,
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
    switch (tree.nodeTag(node)) {
        .number_literal => return true,
        .grouped_expression => return fixedBetween(c, file, tree.nodeData(node).node_and_token[0], from, to, depth + 1),
        .add, .sub, .mul, .div, .mod, .shl, .shr, .add_wrap, .sub_wrap, .mul_wrap, .add_sat, .sub_sat, .mul_sat => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return try fixedBetween(c, file, lhs, from, to, depth + 1) and try fixedBetween(c, file, rhs, from, to, depth + 1);
        },
        .identifier => {
            const decl = (model.reference(node) orelse return false).declaration orelse return false;
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
                if (ref.declaration != decl) continue;
                const parent = model.parentOf(ref.node) orelse continue;
                switch (tree.nodeTag(parent)) {
                    .address_of, .assign_destructure => return false,
                    else => {},
                }
                if (ref.token < from or ref.token > to) continue;
                if (std.mem.startsWith(u8, @tagName(tree.nodeTag(parent)), "assign") and tree.nodeData(parent).node_and_node[0] == ref.node) return false;
            }
            return true;
        },
        .field_access => {
            const held, const name = tree.nodeData(node).node_and_token;
            const value = try c.facts.resolve(file, held);
            if (std.mem.eql(u8, tree.tokenSlice(name), "len")) switch (value) {
                .array => return true,
                .pointer => |inner| switch (inner.*) {
                    .array => return true,
                    .container, .instance, .unknown => return false,
                    else => return fixedBetween(c, file, held, from, to, depth + 1),
                },
                else => {},
            };
            const member = try Model.identifier(c.allocator, tree.tokenSlice(name));
            return switch (value) {
                .container => |container| constantMember(c, container, member),
                .alternatives => |each| for (each) |one| {
                    if (one != .container or !constantMember(c, one.container, member)) break false;
                } else true,
                else => false,
            };
        },
        else => return false,
    }
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
    const end = try walk.sequence(statements, .unwritten);
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
/// past the depth) shows nothing, and what was read while one was is not kept: it depends on
/// where the reading began, and another reading may show more.
const Calls = struct {
    const Key = struct { decl: Facts.Decl, index: usize, question: enum { writes, keeps, parts, needs, holds, undefines } };
    found: std.AutoHashMapUnmanaged(Key, bool) = .empty,
    needed: std.AutoHashMapUnmanaged(Key, ?Needs) = .empty,
    left: std.AutoHashMapUnmanaged(Key, Left) = .empty,
    /// The `undefines` readings under way, outermost first, each with what it has shown so far;
    /// and the outermost of them a reading under way leaned on.
    reading: std.ArrayList(struct { key: Key, sofar: Left }) = .empty,
    lowest: usize = std.math.maxInt(usize),
    active: std.AutoHashMapUnmanaged(Key, void) = .empty,
    cuts: usize = 0,
};

/// What of a parameter's memory a function may read before writing it: the parts in `mask`, of
/// the struct `owner` (or the array of that many elements) the parameter points at.
const Needs = struct { mask: u64, owner: Owner };
const Owner = union(enum) { container: struct { file: Project.FileId, scope: Model.Scope.Id }, elements: u7 };

fn remembered(comptime T: type, c: *Context, key: Calls.Key, depth: u8, comptime read: fn (*Context, Facts.Decl, usize, u8) Context.Error!T, comptime cut: T) Context.Error!T {
    const memo = try c.facts.memo(Calls);
    const map = if (T == bool) &memo.found else &memo.needed;
    if (map.get(key)) |known| return known;
    if (depth > depth_limit or memo.active.contains(key)) {
        memo.cuts += 1;
        return cut;
    }
    try memo.active.put(c.allocator, key, {});
    defer _ = memo.active.remove(key);
    const cuts = memo.cuts;
    const shown = try read(c, key.decl, key.index, depth);
    if (memo.cuts == cuts) try map.put(c.allocator, key, shown);
    return shown;
}

/// What of the memory its pointer parameter `index` points at a function `decl`, the program's
/// or std's, gives `undefined` and leaves so on some path that returns: given it there
/// (`self.* = undefined`, a field, `@memset(…, undefined)`), or handing it, or a field of it,
/// to such a function (`self.list.deinit(gpa)`), with nothing after writing it again on that
/// path. An error's `return` is such a path: a caller's `catch` goes on from it. The parts are
/// of what the parameter points at (`owner`); a reading cut short leaves all of it.
/// A function reached again while it is being read (recursion) is taken at what its reading
/// has shown so far, from nothing, and read again until that holds still: what some path of it
/// gives `undefined`, whatever the recursion. Only what such a reading showed of itself is
/// kept; a reading past the depth leaves all of it.
fn undefines(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!Left {
    const memo = try c.facts.memo(Calls);
    const key: Calls.Key = .{ .decl = decl, .index = index, .question = .undefines };
    if (memo.left.get(key)) |known| return known;
    for (memo.reading.items, 0..) |each, at| if (std.meta.eql(each.key, key)) {
        memo.lowest = @min(memo.lowest, at);
        return each.sofar;
    };
    if (depth > undefines_depth_limit) {
        memo.cuts += 1;
        return .{ .mask = std.math.maxInt(u64), .owner = null };
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
        const recursed = memo.lowest <= at;
        if (!recursed or (shown.mask | sofar.mask) == sofar.mask) {
            // Settled: kept where it leaned on no reading above it and nothing was cut.
            const settled: Left = .{ .mask = shown.mask | sofar.mask, .owner = shown.owner };
            const above = memo.lowest < at;
            if (!above and memo.cuts == cuts) try memo.left.put(c.allocator, key, settled);
            memo.lowest = @min(lowest, if (above) memo.lowest else std.math.maxInt(usize));
            return settled;
        }
        sofar.* = .{ .mask = shown.mask | sofar.mask, .owner = shown.owner };
    }
}

fn undefinesRead(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!Left {
    const found = (try parameter(c, decl, index, true)) orelse return .{ .mask = 0, .owner = null };
    var walk: Walk = .init(c, decl.file, found.id, true, depth);
    try walk.collect();
    var mask: u64 = 0;
    for (try walk.undefinings()) |again| {
        if (try walk.leftUndefined(again.mention, again.left, found.body)) mask |= again.left;
    }
    for (walk.mentions.items) |mention| {
        const left = try walk.undoneBy(mention);
        if (left != 0 and try walk.leftUndefined(mention, left, found.body)) mask |= left;
    }
    return .{ .mask = mask, .owner = walk.owner };
}

/// The parts of what a parameter points at a function leaves `undefined` (`undefines`), of
/// `owner`'s struct or array; every bit set, all of it.
const Left = struct { mask: u64, owner: ?Owner };

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
    _ = try walk.sequence(statements, .unwritten);
    if (walk.read != null) return null;
    return .{ .mask = walk.needed, .owner = owner };
}

/// Whether `decl` is one of std's calls `list` names, at its parameter `index`.
fn named(c: *Context, list: []const Named, decl: Facts.Decl, index: usize) Context.Error!bool {
    for (list) |each| {
        if (each.param != index) continue;
        for ((try Governed.declarations(c, "std", each.path)) orelse &.{}) |found| {
            const origin = (try c.facts.origin(found)) orelse found;
            if (std.meta.eql(origin, decl)) return true;
        }
    }
    return false;
}

/// Whether a `return` returns an error by name (`return error.Short`) from a function whose
/// result is an error union: a path the caller's `try` leaves by. One whose result is an error
/// set returns the error as its value, a path like any other.
fn errorReturn(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    const operand = tree.nodeData(node).opt_node.unwrap() orelse return false;
    if (tree.nodeTag(operand) != .error_value) return false;
    var at = node;
    const function = while (model.parentOf(at)) |up| : (at = up) {
        if (tree.nodeTag(up) == .fn_decl) break up;
    } else return false;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(function).node_and_node[0]) orelse return false;
    const result = proto.ast.return_type.unwrap() orelse return false;
    return tree.nodeTag(result) == .error_union or Model.inferredErrors(tree, result);
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
fn fieldsOf(c: *Context, container: Facts.Container) Context.Error!Shape {
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
        const field = tree.fullContainerField(decl.node) orelse return .none;
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
    const memo = try c.facts.memo(ParentNames);
    if (!memo.read) {
        memo.read = true;
        var given: std.ArrayList(Given) = .empty;
        defer given.deinit(c.allocator);
        for (c.project.sources) |*source| {
            const tree = &source.file.tree;
            for (0..tree.nodes.len) |i| {
                const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (!isBuiltin(tree, node, "@fieldParentPtr")) continue;
                const converted = try ParentPointer.converts(c, source.id, node);
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, node, &buffer);
                if (args.len > 0 and tree.nodeTag(args[0]) == .string_literal) {
                    try spell(c, memo, converted, tree, args[0]);
                } else if (args.len > 0 and nameGiven(source, node, args[0]) != null) {
                    var each = nameGiven(source, node, args[0]).?;
                    each.owner = converted;
                    try given.append(c.allocator, each);
                } else try memo.conversions.append(c.allocator, .{ .owner = converted, .name = null });
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
const Given = struct { function: []const u8, index: usize, owner: ?Facts.Container = null };

fn nameGiven(source: *const Project.Source, node: Ast.Node.Index, spelled: Ast.Node.Index) ?Given {
    const tree = &source.file.tree;
    const model = &source.model;
    if (tree.nodeTag(spelled) != .identifier) return null;
    const decl = model.declarations[@backingInt((model.reference(spelled) orelse return null).declaration orelse return null)];
    if (decl.kind != .parameter) return null;
    var at = node;
    const function = while (model.parentOf(at)) |up| : (at = up) {
        if (tree.nodeTag(up) == .fn_decl) break up;
    } else return null;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(function).node_and_node[0]) orelse return null;
    var it = proto.iterate(tree);
    var index: usize = 0;
    while (it.next()) |param| : (index += 1) {
        if (param.name_token == decl.token) return .{ .function = tree.tokenSlice(proto.name_token orelse return null), .index = index };
    }
    return null;
}

/// Adds the names each call of `given.function` spells at its parameter, by every name in the
/// project spelled as that function.
fn spellCalls(c: *Context, memo: *ParentNames, given: Given) Context.Error!void {
    const any: ParentNames.Conversion = .{ .owner = given.owner, .name = null };
    for (c.project.sources) |*source| {
        if (std.mem.find(u8, source.file.source, given.function) == null) continue;
        const tree = &source.file.tree;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const token = switch (tag) {
                .identifier => tree.nodeMainToken(node),
                .field_access => tree.nodeData(node).node_and_token[1],
                else => continue,
            };
            if (!std.mem.eql(u8, tree.tokenSlice(token), given.function)) continue;
            var buffer: [1]Ast.Node.Index = undefined;
            const up = source.model.parentOf(node) orelse return memo.conversions.append(c.allocator, any);
            const call = tree.fullCall(&buffer, up) orelse return memo.conversions.append(c.allocator, any);
            if (call.ast.fn_expr != node or given.index >= call.ast.params.len or tree.nodeTag(call.ast.params[given.index]) != .string_literal) {
                return memo.conversions.append(c.allocator, any);
            }
            try spell(c, memo, given.owner, tree, call.ast.params[given.index]);
        }
    }
}

fn spell(c: *Context, memo: *ParentNames, owner: ?Facts.Container, tree: *const Ast, literal: Ast.Node.Index) Context.Error!void {
    const spelled = std.zig.string_literal.parseAlloc(c.allocator, tree.tokenSlice(tree.nodeMainToken(literal))) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return memo.conversions.append(c.allocator, .{ .owner = owner, .name = null }),
    };
    try memo.conversions.append(c.allocator, .{ .owner = owner, .name = spelled });
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
fn holdsUndefined(tree: *const Ast, value: Ast.Node.Index) bool {
    const node = ungrouped(tree, value);
    if (isWord(tree, node, "undefined")) return true;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, node)) |literal| {
        for (literal.ast.fields) |field| if (holdsUndefined(tree, field)) return true;
        return false;
    }
    if (tree.fullArrayInit(&buffer, node)) |literal| {
        for (literal.ast.elements) |element| if (holdsUndefined(tree, element)) return true;
        return false;
    }
    if (tree.nodeTag(node) == .array_cat) {
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        return holdsUndefined(tree, lhs) or holdsUndefined(tree, rhs);
    }
    if (isBuiltin(tree, node, "@as")) {
        const args = Facts.builtinArgs(tree, node, &buffer);
        return args.len == 2 and holdsUndefined(tree, args[1]);
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
        if (isBuiltin(tree, up, "@TypeOf")) return true;
    }
    return false;
}

/// Whether `node` is the identifier `text` (`true`, `false`).
fn isWord(tree: *const Ast, node: Ast.Node.Index, text: []const u8) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), text);
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
/// `switch`, past `orelse` or `catch`, `and` or `or`, in a loop, or in a labeled block a `break`
/// may leave early.
fn conditional(tree: *const Ast, model: *const Model, inner: Ast.Node.Index, top: Ast.Node.Index) bool {
    var at = inner;
    while (at != top) : (at = model.parentOf(at).?) {
        const up = model.parentOf(at) orelse return true;
        switch (tree.nodeTag(up)) {
            .@"orelse", .@"catch", .bool_and, .bool_or => if (tree.nodeData(up).node_and_node[1] == at) return true,
            else => {
                if (tree.fullIf(up)) |branch| {
                    if (branch.ast.cond_expr != at) return true;
                } else if (tree.fullSwitch(up)) |choice| {
                    if (choice.ast.condition != at) return true;
                } else if (tree.fullWhile(up) != null or tree.fullFor(up) != null) {
                    return true;
                } else if (isBlock(tree, up) and blockLabel(tree, up) != null) return true;
            },
        }
    }
    return false;
}

/// Whether a `for` input is a range of literals with a pass in it (`0..2`).
/// Whether `start` is the stride `k` times the pass `i` of `n`: `k * i`, `i * k`, or counting
/// down, `k * (n - 1 - i)`.
fn strideAt(tree: *const Ast, start: Ast.Node.Index, stride: u64, index: []const u8, count: u64) bool {
    if (tree.nodeTag(start) != .mul) return false;
    const a, const b = tree.nodeData(start).node_and_node;
    const pass = ungrouped(tree, if (literalValue(tree, a) == stride) b else if (literalValue(tree, b) == stride) a else return false);
    if (isWord(tree, pass, index)) return true;
    if (tree.nodeTag(pass) != .sub) return false;
    const left, const right = tree.nodeData(pass).node_and_node;
    if (!isWord(tree, right, index) or tree.nodeTag(left) != .sub) return false;
    const n, const one = tree.nodeData(left).node_and_node;
    return literalValue(tree, n) == count and literalValue(tree, one) == 1;
}

fn passes(tree: *const Ast, input: Ast.Node.Index) bool {
    if (tree.nodeTag(input) != .for_range) return false;
    const start, const end = tree.nodeData(input).node_and_opt_node;
    const from = literalValue(tree, start) orelse return false;
    const to = literalValue(tree, end.unwrap() orelse return false) orelse return false;
    return to > from;
}

/// `node` without the parentheses around it.
fn ungrouped(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var at = node;
    while (tree.nodeTag(at) == .grouped_expression) at = tree.nodeData(at).node_and_token[0];
    return at;
}

/// Whether `node` names a member `name`: `.SUCCESS`, or `E.SUCCESS` of some enum.
fn isMember(tree: *const Ast, node: Ast.Node.Index, name: []const u8) bool {
    const at = ungrouped(tree, node);
    return switch (tree.nodeTag(at)) {
        .enum_literal => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(at)), name),
        .field_access => std.mem.eql(u8, tree.tokenSlice(tree.nodeData(at).node_and_token[1]), name),
        else => false,
    };
}

fn literalValue(tree: *const Ast, node: Ast.Node.Index) ?u64 {
    if (tree.nodeTag(node) != .number_literal) return null;
    return switch (std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(node)))) {
        .int => |value| value,
        else => null,
    };
}
