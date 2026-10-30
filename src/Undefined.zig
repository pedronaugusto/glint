//! A019's `undefined` reads (designs/aegis.md §7): a `var` declared `undefined` in a function's
//! body, read, or handed on, before every path to that point writes the whole of it.
//!
//! What writes it whole: an assignment to it; an `asm` output bound to it, written once the
//! `asm` has read its inputs; all of it given to `@memset` or `@memcpy`, to a `for` whose first
//! act each pass is to set the element it points at, to one of std's calls named in `std_fills`
//! (`Io.Reader.readSliceAll`), or to the program's own function whose body writes the whole of
//! that parameter before any read on every path that returns. A call that may fail writes only
//! where its failure leaves (`try`). What a part of it takes (a field or an element set, a
//! slice of it filled) writes that part only, and what std's calls named in `std_keeps` are
//! given (a writer's buffer) they keep without reading what they have not written: neither
//! writes it whole, and neither reads it. Handed anywhere else (a call nothing shows writing it
//! whole, a pointer kept in a local) it is read there.
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

const Effect = enum { read, handed, write };
const Use = struct { key: Ast.TokenIndex, effect: Effect };

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
        if (!w.mentioned(node) and !w.returnsIn(node)) {
            // It leaves the local as it is, for what follows and for where a jump in it goes.
            w.jumpsIn(node, state);
            return state;
        }
        switch (tree.nodeTag(node)) {
            .@"defer", .@"errdefer" => {
                // Run at the scope's exits, where the local may be as unwritten as here; what it
                // writes holds before none of them.
                const past = try w.statement(tree.nodeData(node).node, state);
                return if (past.at == .done) .done else state;
            },
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
            const then = try w.statement(branch.ast.then_expr, after);
            const otherwise = if (branch.ast.else_expr.unwrap()) |e| try w.statement(e, after) else after;
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
        return w.simple(node, state);
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
        var earliest: ?struct { use: Use, token: Ast.TokenIndex } = null;
        for (w.mentions.items) |mention| {
            const token = w.tree.nodeMainToken(mention);
            if (token < first or token > last) continue;
            const use = (try w.classify(mention)) orelse continue;
            if (use.effect == .write and conditional(w.tree, w.model, mention, node)) continue;
            if (earliest == null or use.key < earliest.?.use.key) earliest = .{ .use = use, .token = token };
        }
        for (w.outputs.items) |output| {
            if (output.token < first or output.token > last) continue;
            if (conditional(w.tree, w.model, output.asm_node, node)) continue;
            const key = w.tree.lastToken(output.asm_node);
            if (earliest == null or key < earliest.?.use.key) earliest = .{ .use = .{ .key = key, .effect = .write }, .token = output.token };
        }
        const found = earliest orelse return state;
        if (found.use.effect == .write) return .written;
        w.read = found.token;
        w.handed = found.use.effect == .handed;
        return .done;
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
                return if (w.partSet(parent, true)) null else read;
            },
            .array_access => return if (tree.nodeData(parent).node_and_node[0] == mention and w.partSet(parent, false)) null else read,
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
                    .field_access, .array_access => if (w.partSet(grand, tree.nodeTag(grand) == .field_access)) null else read,
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
                // `@field(local, name) = v` sets the field it names.
                if (builtinField(tree, parent, mention)) {
                    const grand = w.model.parentOf(parent) orelse return read;
                    return if (tree.nodeTag(grand) == .assign and tree.nodeData(grand).node_and_node[0] == parent) null else read;
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
        if (!w.c.project.at(origin.file).input.selected) return handed;
        if (try writesWhole(w.c, origin, index, w.depth + 1)) return if (whole and leaves) written else null;
        if (try keepsOnly(w.c, origin, index, w.depth + 1)) return null;
        return handed;
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
        const name = capture(tree, loop.payload_token, position) orelse return handed;
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

/// The name a `for`'s pointer capture at `position` binds (`|x, *slot|`), or null where that
/// capture is not a pointer's.
fn capture(tree: *const Ast, payload: Ast.TokenIndex, position: usize) ?[]const u8 {
    var token = payload;
    var at: usize = 0;
    while (true) : (at += 1) {
        const pointer = tree.tokenTag(token) == .asterisk;
        if (pointer) token += 1;
        if (tree.tokenTag(token) != .identifier) return null;
        if (at == position) return if (pointer) tree.tokenSlice(token) else null;
        token += 1;
        if (tree.tokenTag(token) != .comma) return null;
        token += 1;
    }
}

/// Whether an identifier spelled `name` appears in `node`.
fn isBuiltin(tree: *const Ast, node: Ast.Node.Index, name: []const u8) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name),
        else => false,
    };
}

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
    return remembered(c, .{ .decl = decl, .index = index, .question = .keeps }, depth, keepsOnlyRead);
}

fn keepsOnlyRead(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!bool {
    const found = (try parameter(c, decl, index)) orelse return false;
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

/// A function's parameter at `index`: its declaration, where its type is a pointer the
/// function may write through, and the function's body.
fn parameter(c: *Context, decl: Facts.Decl, index: usize) Context.Error!?struct { id: Model.Declaration.Id, body: Ast.Node.Index } {
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
    if (pointer.const_token != null) return null;
    const id: Model.Declaration.Id = for (model.declarations, 0..) |each, d| {
        if (each.kind == .parameter and each.token == name) break @fromBackingInt(@intCast(d));
    } else return null;
    return .{ .id = id, .body = tree.nodeData(function).node_and_node[1] };
}

/// Whether the program's function `decl` writes the whole of what its parameter `index` points
/// at before any read of it, on every path that returns, read once per function and parameter.
/// A parameter that is not a mutable pointer, or a function without a body, writes nothing.
fn writesWhole(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!bool {
    return remembered(c, .{ .decl = decl, .index = index, .question = .writes }, depth, writesWholeRead);
}

fn writesWholeRead(c: *Context, decl: Facts.Decl, index: usize, depth: u8) Context.Error!bool {
    const found = (try parameter(c, decl, index)) orelse return false;
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
    const Key = struct { decl: Facts.Decl, index: usize, question: enum { writes, keeps } };
    found: std.AutoHashMapUnmanaged(Key, bool) = .empty,
    active: std.AutoHashMapUnmanaged(Key, void) = .empty,
    cuts: usize = 0,
};

fn remembered(c: *Context, key: Calls.Key, depth: u8, comptime read: fn (*Context, Facts.Decl, usize, u8) Context.Error!bool) Context.Error!bool {
    const memo = try c.facts.memo(Calls);
    if (memo.found.get(key)) |known| return known;
    if (depth > depth_limit or memo.active.contains(key)) {
        memo.cuts += 1;
        return false;
    }
    try memo.active.put(c.allocator, key, {});
    defer _ = memo.active.remove(key);
    const cuts = memo.cuts;
    const shown = try read(c, key.decl, key.index, depth);
    if (memo.cuts == cuts) try memo.found.put(c.allocator, key, shown);
    return shown;
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
