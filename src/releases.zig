//! What a function does with an owner its parameter holds: whether it releases that owner, this
//! instance, on every exit (`released`). A must-summary, read by every rule that releases (A003's
//! owners a record holds by value; A021's and A020's guards): unknown is the default, and nothing
//! it cannot show is read as released.
//!
//! The owner is a place: a parameter and the fields from its value to the owner (`Owner`). A
//! release is a call the rule's own notion of release accepts (`Base`), given that place, or a
//! call of the program's function that releases the place (or what holds it) itself, read here
//! the same way. A release counts for an exit only where it runs on every way there: before it
//! in a block the exit is in, at no condition, loop or branch on the way, but the owner's own
//! optional (`if (p.opt) |*o| o.deinit()`: null holds nothing), or in a `defer` (an `errdefer`
//! for error exits) the exit leaves. Any other use of the place before its release (a store over
//! it, a copy, its address, a call that may write it) leaves the answer unknown.
const std = @import("std");
const Ast = std.zig.Ast;
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Project = @import("Project.zig");

pub const Error = Facts.ResolveError;

/// A rule's notion of what releases an owner by its type alone: one per kind of owner, shared
/// by the rules that release it.
pub const Notion = enum { aegis_owner, std_handle, guard };

pub const Owner = struct {
    /// The parameter holding the owner, in Facts.calls' order (a bound receiver first).
    parameter: usize,
    /// The fields from the parameter's value to the owner, each a field's declaration, through
    /// pointers and optionals' payloads: `lock: *LockFile` and `.pending` is `{0, &.{pending}}`.
    /// Empty: the parameter's value is the owner.
    path: []const Facts.Decl,
};

pub const Released = union(enum) {
    /// On every exit (a return, an error's; a trap owes nothing) the owner was released by a
    /// release of this place, or was never held there (the null arm of its own optional).
    every_exit,
    /// It neither releases the owner nor uses its place in any way that may move, copy or
    /// overwrite it, here or in a call it hands the place to: a call of it leaves the owner held
    /// as it was.
    untouched,
    /// Anything else: why, and the site that decides it where there is one.
    unknown: struct { why: Facts.Unknown, site: ?Facts.Key = null },
};

/// What releases an owner directly: the rule's release of the owner's type, judged by the callee
/// (each of a choice must be one) and the owner's value there. Comptime, so the memo's notion
/// can pair with no other predicate.
pub const Base = struct {
    notion: Notion,
    isRelease: fn (*Facts, Facts.Decl, Facts.Value) Error!bool,
};

/// How many calls deep a release is followed; past it, unknown.
const depth_limit = 8;

const State = struct {
    answers: std.StringHashMapUnmanaged(Released) = .empty,
    active: std.StringHashMapUnmanaged(void) = .empty,
};

/// Whether `function` releases `owner`, this instance, on every exit.
pub fn released(facts: *Facts, function: Facts.Decl, owner: Owner, comptime base: Base) Error!Released {
    return releasedAt(facts, function, owner, base, 0);
}

fn releasedAt(facts: *Facts, function: Facts.Decl, owner: Owner, comptime base: Base, depth: u8) Error!Released {
    if (depth >= depth_limit) return unknown(.budget, null);
    const state = try facts.memo(State);
    const key = try keyOf(facts.gpa, function, owner, base.notion);
    if (state.answers.get(key)) |kept| return kept;
    // A call back into a summary being read: no fixed point is sought.
    if (state.active.contains(key)) return unknown(.cycle, null);
    try state.active.put(facts.gpa, key, {});
    const answer = try judge(facts, function, owner, base, depth);
    _ = state.active.remove(key);
    try state.answers.put(facts.gpa, key, answer);
    return answer;
}

fn keyOf(gpa: std.mem.Allocator, function: Facts.Decl, owner: Owner, notion: Notion) Error![]const u8 {
    const head = [_]u32{ @backingInt(function.file), @backingInt(function.index), @intCast(owner.parameter), @backingInt(notion) };
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(gpa, std.mem.sliceAsBytes(&head));
    for (owner.path) |field| try bytes.appendSlice(gpa, std.mem.sliceAsBytes(&[_]u32{ @backingInt(field.file), @backingInt(field.index) }));
    return bytes.items;
}

fn unknown(why: Facts.Unknown, site: ?Facts.Key) Released {
    return .{ .unknown = .{ .why = why, .site = site } };
}

/// A name standing for the owner's place or what holds it: the parameter, or a pointer capture
/// of an optional on the owner's path (`|*lock|` of `tx.packed_lock`), and how many of the
/// path's fields it is past.
const Root = struct { decl: Model.Declaration.Id, past: usize };

/// Where a release runs for good: in `block`, after its statement `index` (`normal`), or as a
/// `defer`/`errdefer` there at its scope's exits.
const Anchor = struct { block: Ast.Node.Index, index: usize, kind: enum { normal, deferred, error_deferred } };

/// What a place expression names, measured against the owner's path.
const Match = union(enum) {
    /// The owner itself.
    exact,
    /// What holds it: so many of the path's fields in.
    prefix: usize,
    /// A part of the owner (`lock.pending.handle`).
    inside,
    /// Another field beside the path: not the owner.
    apart,
    unknown: Facts.Unknown,
};

const Walk = struct {
    facts: *Facts,
    file: Project.FileId,
    tree: *const Ast,
    model: *const Model,
    owner: Owner,
    function_node: Ast.Node.Index,
    body: Ast.Node.Index,
    roots: std.ArrayList(Root) = .empty,
    /// Each release's anchors, every one a release that runs for good there.
    anchors: std.ArrayList(Anchor) = .empty,
    /// Uses of the place that must come after a release: their nodes.
    after: std.ArrayList(Ast.Node.Index) = .empty,
    /// Whether it may release the place: a release met, anchored or not (one on a branch is no
    /// anchor), or a call it hands the place to whose own reading is no `untouched`.
    touched: bool = false,
    failed: ?Released = null,

    fn fail(w: *Walk, why: Facts.Unknown, node: ?Ast.Node.Index) void {
        if (w.failed == null) w.failed = unknown(why, if (node) |n| .{ .file = w.file, .node = n } else null);
    }

    fn rootOf(w: *const Walk, decl: Model.Declaration.Id) ?Root {
        for (w.roots.items) |root| if (root.decl == decl) return root;
        return null;
    }

    /// Whether `node` is in this function's own body, not a function or container declared in it.
    fn own(w: *const Walk, node: Ast.Node.Index) bool {
        var at = node;
        while (w.model.parentOf(at)) |parent| : (at = parent) {
            switch (w.tree.nodeTag(parent)) {
                .fn_decl => return parent == w.function_node,
                .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing, .container_decl_arg, .container_decl_arg_trailing, .tagged_union, .tagged_union_trailing, .tagged_union_two, .tagged_union_two_trailing, .tagged_union_enum_tag, .tagged_union_enum_tag_trailing => return false,
                else => {},
            }
        }
        return false;
    }

    fn inside(w: *const Walk, ancestor: Ast.Node.Index, node: Ast.Node.Index) bool {
        var at = node;
        while (true) {
            if (at == ancestor) return true;
            at = w.model.parentOf(at) orelse return false;
        }
    }

    /// The position in `block` of the statement holding `node`, which is inside it.
    fn statementIndex(w: *const Walk, block: Ast.Node.Index, node: Ast.Node.Index) ?usize {
        var at = node;
        while (w.model.parentOf(at)) |parent| : (at = parent) {
            if (parent != block) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = w.tree.blockStatements(&buffer, block) orelse return null;
            for (statements, 0..) |statement, i| if (statement == at) return i;
            return null;
        }
        return null;
    }

    /// The place `node` names, measured against the owner's path: its root one of `roots`, each
    /// member step's field found through its holder's type, `.*` and `.?` passed through.
    fn match(w: *const Walk, node: Ast.Node.Index) Error!Match {
        const path = try Facts.accesses.pathOf(w.facts, w.file, Facts.ungrouped(w.tree, node));
        const root_step = path.steps[path.steps.len - 1];
        if (w.tree.nodeTag(root_step.node) != .identifier) return .{ .unknown = .unsupported };
        const reference = w.model.reference(root_step.node) orelse return .{ .unknown = .unresolved };
        const decl = reference.declaration orelse return .{ .unknown = .unresolved };
        const root = w.rootOf(decl) orelse return .apart;
        var k = root.past;
        var i = path.steps.len - 1;
        while (i > 0) {
            i -= 1;
            const step = path.steps[i];
            switch (step.kind) {
                .unwrap, .deref, .root => {},
                .index, .slice => return if (k >= w.owner.path.len) .inside else .{ .unknown = .unsupported },
                .field => {
                    if (k >= w.owner.path.len) return .inside;
                    const name = step.name orelse return .{ .unknown = .unsupported };
                    const holder = holderContainer(step.holder orelse return .{ .unknown = .unresolved }) orelse return .{ .unknown = .unresolved };
                    const field = w.facts.member(holder, name) orelse return .{ .unknown = .unresolved };
                    if (std.meta.eql(field, w.owner.path[k])) {
                        k += 1;
                        continue;
                    }
                    // A union's fields share its memory.
                    if (w.facts.kindOf(holder) != .keyword_struct) return .{ .unknown = .unsupported };
                    return .apart;
                },
            }
        }
        if (k == w.owner.path.len) return .exact;
        return .{ .prefix = k };
    }

    /// Where the release at `node` runs for good, climbing from it to the function's body: each
    /// block statement it is on the way to, through what runs it whatever happens (its operand,
    /// a call's arguments, a declaration's value, the left of `catch`/`orelse`, a condition),
    /// the owner's own optional's arm, and a `defer` or `errdefer` holding it.
    fn anchor(w: *Walk, node: Ast.Node.Index) Error!void {
        w.touched = true;
        var at = node;
        while (w.model.parentOf(at)) |parent| : (at = parent) {
            const tag = w.tree.nodeTag(parent);
            switch (tag) {
                .block, .block_semicolon, .block_two, .block_two_semicolon => {
                    const lbrace = w.tree.nodeMainToken(parent);
                    if (lbrace >= 2 and w.tree.tokenTag(lbrace - 1) == .colon) return; // a labeled block: its value and breaks are not read
                    const index = w.statementIndex(parent, at) orelse return;
                    try w.anchors.append(w.facts.gpa, .{ .block = parent, .index = index, .kind = .normal });
                    if (parent == w.body) return;
                },
                .@"defer" => {
                    const block = w.model.parentOf(parent) orelse return;
                    const index = w.statementIndex(block, parent) orelse return;
                    try w.anchors.append(w.facts.gpa, .{ .block = block, .index = index, .kind = .deferred });
                    // Its scope's end is a release for what follows the block.
                    if (block != w.body) try w.anchorAfter(block);
                    return;
                },
                .@"errdefer" => {
                    const block = w.model.parentOf(parent) orelse return;
                    const index = w.statementIndex(block, parent) orelse return;
                    try w.anchors.append(w.facts.gpa, .{ .block = block, .index = index, .kind = .error_deferred });
                    return;
                },
                .grouped_expression, .@"try", .field_access, .simple_var_decl, .local_var_decl, .aligned_var_decl, .@"return" => {},
                .assign => if (w.tree.nodeData(parent).node_and_node[1] != at) return,
                .@"catch", .@"orelse" => if (w.tree.nodeData(parent).node_and_node[0] != at) return,
                else => {
                    var buffer: [1]Ast.Node.Index = undefined;
                    if (w.tree.fullCall(&buffer, parent) != null) continue;
                    if (w.tree.fullIf(parent)) |branch| {
                        if (branch.ast.cond_expr == at) continue;
                        if (branch.ast.then_expr == at and try w.ownOptional(branch)) continue;
                        return;
                    }
                    var builtin_buffer: [2]Ast.Node.Index = undefined;
                    if (std.mem.findScalar(Ast.Node.Index, Facts.builtinArgs(w.tree, parent, &builtin_buffer), at) != null) continue;
                    return;
                },
            }
        }
    }

    /// The block `block` ending (its defers run) as a release for what follows it.
    fn anchorAfter(w: *Walk, block: Ast.Node.Index) Error!void {
        const parent = w.model.parentOf(block) orelse return;
        switch (w.tree.nodeTag(parent)) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => try w.anchor(block),
            else => {},
        }
    }

    /// Whether `branch` is `if (p) |*o|` over an optional on the owner's path: where it is null,
    /// nothing there is held.
    fn ownOptional(w: *const Walk, branch: Ast.full.If) Error!bool {
        const payload = branch.payload_token orelse return false;
        if (w.tree.tokenTag(payload) != .asterisk) return false;
        return switch (try w.match(branch.ast.cond_expr)) {
            .exact, .prefix => true,
            else => false,
        };
    }

    /// Whether a release anchored so runs before `node` on every way there.
    fn before(w: *const Walk, a: Anchor, node: Ast.Node.Index) bool {
        if (a.kind != .normal) return false;
        if (!w.inside(a.block, node)) return false;
        const index = w.statementIndex(a.block, node) orelse return false;
        return index > a.index;
    }

    /// Whether a release runs on every way out through the exit `node` (an error's where `error`).
    fn covers(w: *const Walk, a: Anchor, node: Ast.Node.Index, error_exit: bool) bool {
        if (!w.inside(a.block, node)) return false;
        const index = w.statementIndex(a.block, node) orelse return false;
        if (a.kind == .error_deferred and !error_exit) return false;
        // A deferred release runs as an exit after it leaves its scope.
        return index > a.index;
    }

    /// Whether a release runs before the body's end is reached by falling off it.
    fn coversEnd(w: *const Walk, a: Anchor) bool {
        return a.block == w.body and a.kind != .error_deferred;
    }
};

fn holderContainer(value: Facts.Value) ?Facts.Container {
    return switch (value) {
        .container, .instance => |container| container,
        .pointer => |inner| holderContainer(inner.child.*),
        .optional => |inner| holderContainer(inner.*),
        else => null,
    };
}

fn judge(facts: *Facts, function: Facts.Decl, owner: Owner, comptime base: Base, depth: u8) Error!Released {
    const model = &facts.project.at(function.file).model;
    const tree = &facts.project.at(function.file).file.tree;
    const record = model.declarations[@backingInt(function.index)];
    if (record.kind != .function) return unknown(.unsupported, null);
    const function_node = model.parentOf(record.node) orelse return unknown(.unsupported, null);
    // No body to read: extern, a prototype.
    if (tree.nodeTag(function_node) != .fn_decl) return unknown(.unsupported, null);
    // A generic is read at its binding, which this summary does not take: unknown.
    if (try facts.hasGenericParameter(function)) return unknown(.generic, null);
    const body = tree.nodeData(function_node).node_and_node[1];
    const param = parameterAt(tree, model, record.node, owner.parameter) orelse return unknown(.unresolved, null);
    // The owner reached through what the parameter points at: a parameter by value is a copy,
    // whose release is the copy's.
    switch (try facts.declaration(.{ .file = function.file, .index = param })) {
        .pointer => {},
        else => return unknown(.unsupported, null),
    }
    var w: Walk = .{ .facts = facts, .file = function.file, .tree = tree, .model = model, .owner = owner, .function_node = function_node, .body = body };
    try w.roots.append(facts.gpa, .{ .decl = param, .past = 0 });
    // Each reference of a root, once: a capture of the owner's optional is a root from the
    // pass that meets it, and its references are read in the next.
    const read = try facts.gpa.alloc(bool, model.references.len);
    defer facts.gpa.free(read);
    @memset(read, false);
    while (true) {
        const roots = w.roots.items.len;
        for (model.references, read) |reference, *done| {
            if (done.*) continue;
            const decl = reference.declaration orelse continue;
            if (w.rootOf(decl) == null) continue;
            done.* = true;
            if (!w.own(reference.node)) continue;
            try use(&w, reference.node, base, depth);
            if (w.failed) |answer| return answer;
        }
        if (w.roots.items.len == roots) break;
    }
    if (w.anchors.items.len == 0 and w.after.items.len == 0 and !w.touched) return .untouched;
    // Every exit: each `return` and `try` of the body, and its end where it falls off.
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const error_exit = switch (tag) {
            .@"try" => true,
            .@"return" => if (tree.nodeData(node).opt_node.unwrap()) |value| tree.nodeTag(value) == .error_value else false,
            else => continue,
        };
        if (!w.inside(body, node) or !w.own(node)) continue;
        for (w.anchors.items) |a| {
            if (w.covers(a, node, error_exit)) break;
        } else return unknown(.unsupported, .{ .file = function.file, .node = node });
    }
    if (fallsOff(tree, body)) {
        for (w.anchors.items) |a| {
            if (w.coversEnd(a)) break;
        } else return unknown(.unsupported, .{ .file = function.file, .node = body });
    }
    // Each use that may move, copy or overwrite the owner comes after a release.
    for (w.after.items) |node| {
        for (w.anchors.items) |a| {
            if (w.before(a, node)) break;
        } else return unknown(.unsupported, .{ .file = function.file, .node = node });
    }
    return .every_exit;
}

/// Whether the body's end may be reached: its last statement is no `return` or `unreachable`.
fn fallsOff(tree: *const Ast, body: Ast.Node.Index) bool {
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, body) orelse return true;
    if (statements.len == 0) return true;
    return switch (tree.nodeTag(statements[statements.len - 1])) {
        .@"return", .unreachable_literal => false,
        else => true,
    };
}

/// The declaration of the parameter at `position` of the function `proto_node` declares.
fn parameterAt(tree: *const Ast, model: *const Model, proto_node: Ast.Node.Index, position: usize) ?Model.Declaration.Id {
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, proto_node) orelse return null;
    var params = proto.iterate(tree);
    var count: usize = 0;
    const token = while (params.next()) |p| : (count += 1) {
        if (count == position) break p.name_token orelse return null;
    } else return null;
    for (model.declarations, 0..) |d, i| if (d.kind == .parameter and d.token == token) return @fromBackingInt(@intCast(i));
    return null;
}

/// The place expression a reference starts: out through member reads, `.?`, `.*` and
/// parentheses, but not to a method's name.
fn placeOf(w: *const Walk, reference: Ast.Node.Index) Ast.Node.Index {
    var at = reference;
    while (w.model.parentOf(at)) |parent| {
        switch (w.tree.nodeTag(parent)) {
            .grouped_expression, .unwrap_optional, .deref => {},
            .field_access => {
                if (w.tree.nodeData(parent).node_and_token[0] != at) break;
                // `x.f()`: `x` is the receiver, `f` no field.
                if (w.model.parentOf(parent)) |above| {
                    var buffer: [1]Ast.Node.Index = undefined;
                    if (w.tree.fullCall(&buffer, above)) |call| if (call.ast.fn_expr == parent) break;
                }
            },
            .array_access => if (w.tree.nodeData(parent).node_and_node[0] != at) break,
            else => break,
        }
        at = parent;
    }
    return at;
}

/// Reads one reference of a root: a release, a use that is no harm, one that must come after a
/// release, a capture of the owner's optional (a new root), or one that leaves the answer unknown.
fn use(w: *Walk, reference: Ast.Node.Index, comptime base: Base, depth: u8) Error!void {
    const place = placeOf(w, reference);
    const found = try w.match(place);
    switch (found) {
        .apart => return,
        .unknown => |why| return w.fail(why, place),
        .exact, .prefix, .inside => {},
    }
    var at = place;
    var address = false;
    var parent = w.model.parentOf(at) orelse return w.fail(.unsupported, place);
    if (w.tree.nodeTag(parent) == .address_of) {
        address = true;
        at = parent;
        parent = w.model.parentOf(at) orelse return w.fail(.unsupported, place);
    }
    // A call given it: its receiver or an argument.
    if (try Facts.calls.at(w.facts, w.file, parent)) |call| {
        if (call.callee_expr != at) return given(w, call, at, found, base, depth);
    }
    if (w.tree.nodeTag(parent) == .field_access) if (w.model.parentOf(parent)) |above| {
        if (try Facts.calls.at(w.facts, w.file, above)) |call| if (call.receiver == .bound and call.receiver.bound == at) return given(w, call, at, found, base, depth);
    };
    if (address) return w.after.append(w.facts.gpa, place);
    // `if (p.opt) |*o|`: `o` stands for the owner's optional's payload.
    if (w.tree.fullIf(parent)) |branch| if (branch.ast.cond_expr == at) {
        const payload = branch.payload_token orelse return; // a test reads it
        if (w.tree.tokenTag(payload) != .asterisk) return w.after.append(w.facts.gpa, place); // a copy
        const past = switch (found) {
            .exact => w.owner.path.len,
            .prefix => |k| k,
            else => return,
        };
        const name = payload + 1;
        for (w.model.declarations, 0..) |d, i| if (d.kind == .capture and d.token == name) {
            try w.roots.append(w.facts.gpa, .{ .decl = @fromBackingInt(@intCast(i)), .past = past });
            return;
        };
        return w.fail(.unresolved, place);
    };
    // A store over it, or over what holds it.
    switch (w.tree.nodeTag(parent)) {
        .assign, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_shl, .assign_shr => if (w.tree.nodeData(parent).node_and_node[0] == at) return w.after.append(w.facts.gpa, place),
        else => {},
    }
    // A part of the owner read, or the owner compared (`p.opt != null`): no harm. The owner, or
    // what holds it, read whole: a copy.
    if (found == .inside) return;
    switch (w.tree.nodeTag(parent)) {
        .equal_equal, .bang_equal => return,
        else => {},
    }
    return w.after.append(w.facts.gpa, place);
}

/// A call given the place (`node`, an argument or the receiver): a release of it, of what it
/// holds through a callee that releases it, a call that cannot write it, or one that may.
fn given(w: *Walk, call: Facts.calls.Call, node: Ast.Node.Index, found: Match, comptime base: Base, depth: u8) Error!void {
    const args = switch (call.args) {
        .known => |args| args,
        .unknown => return w.after.append(w.facts.gpa, node),
    };
    const position = for (args, 0..) |arg, i| {
        if (Facts.ungrouped(w.tree, arg) == node) break i;
    } else return w.after.append(w.facts.gpa, node);
    const each: []const Facts.Decl = switch (call.callee) {
        .function => |*one| one[0..1],
        .choice => |all| all,
        .any => return w.after.append(w.facts.gpa, node),
    };
    if (found == .exact) {
        const value = try w.facts.resolve(w.file, node);
        for (each) |callee| {
            if (!try base.isRelease(w.facts, callee, value)) break;
        } else return w.anchor(call.node);
    }
    const past = switch (found) {
        .exact => w.owner.path.len,
        .prefix => |k| k,
        else => null,
    };
    if (past) |k| {
        for (each) |callee| {
            const target = switch (try w.facts.origin(callee)) {
                .decl => |d| d,
                .none, .unknown => break,
            };
            if (!try w.facts.program(target.file)) break;
            if (try releasedAt(w.facts, target, .{ .parameter = position, .path = w.owner.path[k..] }, base, depth + 1) != .every_exit) break;
        } else return w.anchor(call.node);
        // Each callee leaves it as it was: the call is no use of it.
        for (each) |callee| {
            const target = switch (try w.facts.origin(callee)) {
                .decl => |d| d,
                .none, .unknown => break,
            };
            if (!try w.facts.program(target.file)) break;
            if (try releasedAt(w.facts, target, .{ .parameter = position, .path = w.owner.path[k..] }, base, depth + 1) != .untouched) break;
        } else return;
        w.touched = true;
    }
    // No release: a call that may write what it is given may move or overwrite the owner.
    for (each) |callee| {
        const target = switch (try w.facts.origin(callee)) {
            .decl => |d| d,
            .none, .unknown => return w.after.append(w.facts.gpa, node),
        };
        const tree = &w.facts.project.at(target.file).file.tree;
        const model = &w.facts.project.at(target.file).model;
        const param = parameterAt(tree, model, model.declarations[@backingInt(target.index)].node, position) orelse return w.after.append(w.facts.gpa, node);
        if (try w.facts.declaration(.{ .file = target.file, .index = param }) != .pointer) {
            // A copy of the owner, or of what holds it.
            if (found != .inside) return w.after.append(w.facts.gpa, node);
            continue;
        }
        if (try Facts.accesses.writtenThrough(w.facts, .{ .file = target.file, .index = param })) return w.after.append(w.facts.gpa, node);
    }
}
