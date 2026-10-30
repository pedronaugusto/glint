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
    .{ .path = "mem.writeInt", .param = 1 },
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
    // A writer's or a reader's buffer, its end and seek at 0.
    .{ .path = "debug.lockStderr", .param = 0 },
    .{ .path = "compress.flate.Decompress.init", .param = 2 },
    // The file's bytes into a prefix, returned as the slice they fill.
    .{ .path = "Io.Dir.readFile", .param = 3 },
    // The streams' length set, their contexts and storage for MultiReader.init to write.
    .{ .path = "Io.File.MultiReader.Buffer.toStreams", .param = 0 },
};

const Named = struct { path: []const u8, param: usize };

/// std's calls that, succeeding, write the memory at `param` from the front for half the length
/// of their input at `input`, and read none of it: all of it where that input is twice its
/// length.
const std_halving = [_]struct { path: []const u8, param: usize, input: usize }{
    // Two hex digits a byte; odd input fails, and out.len * 2 < input.len does too.
    .{ .path = "fmt.hexToBytes", .param = 0, .input = 1 },
};

/// How deep the program's callees are read, each handing the memory to the next.
const depth_limit = 8;

pub fn reads(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (model.declarations, 0..) |decl, d| {
        if (decl.kind != .variable or c.inTest(decl.token)) continue;
        const variable = tree.fullVarDecl(decl.node) orelse continue;
        if (tree.tokenTag(variable.ast.mut_token) != .keyword_var) continue;
        const init = variable.ast.init_node.unwrap() orelse continue;
        if (tree.nodeTag(init) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init)), "undefined")) continue;
        if (!Danger.atRuntime(c, decl.node)) continue;
        const block = model.parentOf(decl.node) orelse continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, block) orelse continue;
        var walk: Walk = .init(c, c.file, @fromBackingInt(@intCast(d)), false, 0);
        try walk.collect();
        const start = std.mem.findScalar(Ast.Node.Index, statements, decl.node) orelse continue;
        _ = try walk.sequence(statements[start + 1 ..], .unwritten);
        const token = walk.read orelse continue;
        try c.at(rule, token, if (walk.handed)
            try c.allocator.print("'{s}' is handed on here while still undefined on a path from its declaration, where nothing shows it written whole before it is read: a read of undefined memory, which no build checks; write it whole first, or keep a filled prefix in aegis bounded.Array", .{decl.name})
        else
            try c.allocator.print("'{s}' is read here while still undefined on a path from its declaration: a read of undefined memory, which no build checks", .{decl.name}));
    }
}

/// Where the walk stands: the local unwritten, written, a read found (`done`), or the path left
/// before what follows (`left`). While it is unwritten, `parts` holds what of it every path here
/// has written: its fields, by their place in its struct, or its elements, by index.
const State = struct {
    at: enum { unwritten, written, done, left },
    parts: u64 = 0,

    const unwritten: State = .{ .at = .unwritten };
    const written: State = .{ .at = .written };
    const done: State = .{ .at = .done };
    const left: State = .{ .at = .left };

    /// The parts it holds written: all of them, once it is written whole.
    fn have(state: State) u64 {
        return if (state.at == .written) std.math.maxInt(u64) else state.parts;
    }
};

/// What a mention does: reads the local, hands it on, writes it whole, or sets or reads one of
/// its parts, by index.
const Effect = union(enum) { read, handed, write, set: u6, get: u6, needs: u64 };
const Use = struct { key: Ast.TokenIndex, effect: Effect };

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
    /// The constructs being walked that a `break` or `continue` in them may leave for their end
    /// (a loop, a labeled block or `switch`), innermost last, each with what the jumps to it
    /// so far take there.
    targets: std.ArrayList(struct { node: Ast.Node.Index, exit: ?State = null }) = .empty,
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
                if (tree.nodeTag(node) == .@"return" and past.at == .unwritten and !errorReturn(tree, node)) w.exit_unwritten = true;
                w.jump(node, past);
                return .left;
            },
            else => {},
        }
        // An `if` may test a flag that says more of the local.
        if (!w.mentioned(node) and !w.returnsIn(node) and (w.flags.items.len == 0 or tree.fullIf(node) == null)) {
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
            // or false says what its being true showed.
            const holds = if (branch.error_token != null) try w.succeeded(branch.ast.cond_expr, after) else w.knowing(branch.ast.cond_expr, after, true);
            const fails = if (branch.error_token != null) after else w.knowing(branch.ast.cond_expr, after, false);
            const then = try w.statement(branch.ast.then_expr, holds);
            const otherwise = if (branch.ast.else_expr.unwrap()) |e| try w.statement(e, fails) else fails;
            return merge(then, otherwise);
        }
        if (tree.fullSwitch(node)) |choice| {
            const after = try w.statement(choice.ast.condition, state);
            if (after.at != .unwritten) return after;
            try w.enter(node);
            var all: ?State = null;
            for (choice.ast.cases) |case| {
                const prong = tree.fullSwitchCase(case) orelse {
                    all = .done;
                    break;
                };
                const past = try w.statement(prong.ast.target_expr, after);
                all = if (all) |sofar| merge(sofar, past) else past;
            }
            return w.leave(all orelse after);
        }
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
            return value == 2 * length;
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
                    return if (parts == w.everyPart() and parts != 0) .written else .{ .at = .unwritten, .parts = parts };
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
            return !w.mentioned(value) and w.fieldOfCapture(target, name, by_name);
        }
        const branch = tree.fullIf(node) orelse return false;
        if (branch.payload_token != null or branch.error_token != null) return false;
        const otherwise = branch.ast.else_expr.unwrap() orelse return false;
        const spelled = (try w.namedField(branch.ast.cond_expr, name, by_name)) orelse return false;
        if (tree.nodeTag(branch.ast.then_expr) != .assign) return false;
        const target, const value = tree.nodeData(branch.ast.then_expr).node_and_node;
        if (w.mentioned(value)) return false;
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
    /// prongs walked from what the `switch` began with, which holds no more.
    fn jump(w: *Walk, node: Ast.Node.Index, state: State) void {
        const tag = w.tree.nodeTag(node);
        if (tag != .@"break" and tag != .@"continue") return;
        const goes = jumpTarget(w.tree, w.model, node) orelse return;
        if (tag == .@"continue" and w.tree.fullSwitch(goes) != null) return;
        var i = w.targets.items.len;
        while (i > 0) {
            i -= 1;
            const target = &w.targets.items[i];
            if (target.node != goes) continue;
            target.exit = if (target.exit) |exit| merge(exit, state) else state;
            return;
        }
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
            if (each == node or errorReturn(w.tree, each)) continue;
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
            const use = (try w.classify(mention)) orelse continue;
            switch (use.effect) {
                .write, .set => if (conditional(w.tree, w.model, mention, node)) continue,
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
        for (uses.items) |found| switch (found.use.effect) {
            .write => return .written,
            .set => |at| {
                now.parts |= @as(u64, 1) << at;
                if (now.parts == w.everyPart()) return .written;
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
                if (tree.nodeData(parent).node_and_node[0] != mention or w.param) return read;
                return .{ .key = tree.lastToken(parent), .effect = .write };
            },
            .deref => {
                if (!w.param) return read;
                const grand = w.model.parentOf(parent) orelse return read;
                if (tree.nodeTag(grand) == .assign and tree.nodeData(grand).node_and_node[0] == parent) return .{ .key = tree.lastToken(grand), .effect = .write };
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
                return if (whole) .{ .key = tree.lastToken(parent), .effect = .write } else null;
            },
            else => {},
        }
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
        const decl = (try w.callee(node, call)) orelse return handed;
        const origin = (try w.c.facts.origin(decl)) orelse decl;
        var index = position;
        if (receiver) {
            index = 0;
        } else if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
            // A method call hands its receiver first.
            switch (try w.c.facts.resolve(w.file, tree.nodeData(call.ast.fn_expr).node_and_token[0])) {
                .instance, .pointer, .optional => index += 1,
                else => {},
            }
        }
        const written: Use = .{ .key = tree.lastToken(node), .effect = .write };
        const leaves = w.failureLeaves(node, origin);
        if (try named(w.c, &std_fills, origin, index)) return if (whole and leaves) written else null;
        if (try named(w.c, &std_keeps, origin, index) or try named(w.c, &std_counts, origin, index)) return null;
        for (std_halving) |each| {
            if (!try named(w.c, &.{.{ .path = each.path, .param = each.param }}, origin, index)) continue;
            const at = each.input + position - index;
            if (at >= call.ast.params.len) return null;
            return if (whole and leaves and w.twiceAsLong(node, call.ast.params[at])) written else null;
        }
        if (!w.c.project.at(origin.file).input.selected) return handed;
        if (try writesWhole(w.c, origin, index, w.depth + 1)) return if (whole and leaves) written else null;
        if (try keepsOnly(w.c, origin, index, w.depth + 1)) return null;
        // One that reads only some parts of what it is given, through a pointer to the same
        // type, reads those.
        if (!whole) return handed;
        const owner = w.owner orelse return handed;
        const found = (try needs(w.c, origin, index, w.depth + 1)) orelse return handed;
        if (!std.meta.eql(owner, found.owner)) return handed;
        return .{ .key = key, .effect = .{ .needs = found.mask } };
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
    /// neither it nor the local (`for (&buf, 0..) |*b, i| b.* = f(i)`), writes it whole once it
    /// ends: Zig runs a `for` over inputs of one length. Over a part, that part.
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
                return if (whole) .{ .key = tree.lastToken(node), .effect = .write } else null;
            }
        }
        return handed;
    }

    /// Whether `slice` is the local from zero to a count one of std's calls returned of what
    /// it wrote there (`const n = try file.readStreaming(io, &.{&buf}); buf[0..n]`): the count
    /// a constant, its call given the local itself, alone, at the position the call writes; a
    /// failure that gives a count gives 0.
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
        if (tree.nodeTag(end) != .identifier) return false;
        const index = (w.model.reference(end) orelse return false).declaration orelse return false;
        const count = w.model.declarations[@backingInt(index)];
        if (count.kind != .variable) return false;
        const variable = tree.fullVarDecl(count.node) orelse return false;
        if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return false;
        var source = variable.ast.init_node.unwrap() orelse return false;
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
            if (!try named(w.c, &std_counts, origin, position + offset)) continue;
            if (w.namesAlone(arg)) return true;
        }
        return false;
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

    /// Whether a `return` that is not an error's sits in `node`, for a parameter's walk.
    fn returnsIn(w: *const Walk, node: Ast.Node.Index) bool {
        const first = w.tree.firstToken(node);
        const last = w.tree.lastToken(node);
        for (w.returns.items) |each| {
            const token = w.tree.firstToken(each);
            if (token >= first and token <= last and !errorReturn(w.tree, each)) return true;
        }
        return false;
    }
};

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
    return walk.read == null and !walk.exit_unwritten and (end.at == .written or end.at == .left);
}

/// What the program's functions were found to do with a parameter, kept once per function,
/// parameter and question. A reading cut short (a cycle back to a function being read, or one
/// past the depth) shows nothing, and what was read while one was is not kept: it depends on
/// where the reading began, and another reading may show more.
const Calls = struct {
    const Key = struct { decl: Facts.Decl, index: usize, question: enum { writes, keeps, needs } };
    found: std.AutoHashMapUnmanaged(Key, bool) = .empty,
    needed: std.AutoHashMapUnmanaged(Key, ?Needs) = .empty,
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

/// Whether a `return` returns an error by name (`return error.Short`): a path the caller's
/// `try` leaves by.
fn errorReturn(tree: *const Ast, node: Ast.Node.Index) bool {
    const operand = tree.nodeData(node).opt_node.unwrap() orelse return false;
    return tree.nodeTag(operand) == .error_value;
}

fn merge(a: State, b: State) State {
    if (a.at == .done or b.at == .done) return .done;
    // A path that left reaches nothing after the branch.
    if (a.at == .left) return b;
    if (b.at == .left) return a;
    if (a.at == .written and b.at == .written) return .written;
    // Written on some paths only: a read that follows may read it undefined, past the parts
    // every path wrote.
    return .{ .at = .unwritten, .parts = a.have() & b.have() };
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
fn passes(tree: *const Ast, input: Ast.Node.Index) bool {
    if (tree.nodeTag(input) != .for_range) return false;
    const start, const end = tree.nodeData(input).node_and_opt_node;
    const from = literalValue(tree, start) orelse return false;
    const to = literalValue(tree, end.unwrap() orelse return false) orelse return false;
    return to > from;
}

fn literalValue(tree: *const Ast, node: Ast.Node.Index) ?u64 {
    if (tree.nodeTag(node) != .number_literal) return null;
    return switch (std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(node)))) {
        .int => |value| value,
        else => null,
    };
}
