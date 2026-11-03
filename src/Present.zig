//! Where a `.?` reads a value known not to be null, so that `x orelse unreachable` never runs
//! its `unreachable`: a place under a check that it is not null (`x != null and`, the then of
//! `if (x != null)` or `if (x) |_|`, the rest of a block after `if (x == null) return;`), and
//! std's reading of a node (`tree.fullIf(node).?`) whose tag the code checked (a prong of
//! `switch (tree.nodeTag(node))`, `nodeTag(node) == .tag`, the rest of a block after
//! `!= .tag) return;`), or an element of a switch's cases. What std's reading returns on each
//! tag is read from std's own body (`return switch (tree.nodeTag(node)) { .tag => value,
//! else => null }`), not from a table. A check holds only where nothing between it and the
//! read may write the place: a place that is a constant by value cannot be written, a local
//! variable whose address is never taken is written only by an assignment to it, and any
//! other place by any call or assignment. Anything else is not known here: A013 judges it.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Governed = @import("Governed.zig");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Ast = std.zig.Ast;

const Present = @This();
const Tags = std.EnumSet(Ast.Node.Tag);

c: *Context,
/// The file's calls and assignments with their tokens: what may write between a check and
/// the read it guards.
effects: []const Effect,

/// A statement or expression that may write memory: a call (a builtin that may write, `asm`),
/// or a store with its site (`accesses.storesIn`; none for a destructure, which writes several,
/// or a store `accesses` does not read).
const Effect = struct { node: Ast.Node.Index, first: Ast.TokenIndex, last: Ast.TokenIndex, kind: enum { call, assign }, store: ?Facts.accesses.Site = null };

/// What a `.?` needs to be known: its place not null, or a node's tag one of a set.
const Goal = union(enum) {
    some: Ast.Node.Index,
    tag: Tagged,
};
const Tagged = struct {
    /// The tree and the node std reads (`tree`, `node` of `tree.fullIf(node)`), as places.
    tree: Ast.Node.Index,
    node: Ast.Node.Index,
    /// The tags on which std's reading returns a value.
    tags: Tags,
    /// std's `nodeTag`, the read a check of the tag calls.
    read: Facts.Decl,
};
/// What std's reading of a node is, from its body: which parameters are the tree and the
/// node, which tags it returns a value on, and the `nodeTag` it switches on.
const Reading = struct { tree: usize, node: usize, tags: Tags, read: Facts.Decl };

pub fn init(c: *Context) Context.Error!Present {
    const tree = &c.project.at(c.file).file.tree;
    var stores: std.AutoHashMapUnmanaged(Ast.Node.Index, Facts.accesses.Site) = .empty;
    for (try Facts.accesses.storesIn(c.facts, c.file)) |site| try stores.put(c.allocator, site.node, site);
    var effects: std.ArrayList(Effect) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const kind: @FieldType(Effect, "kind") = switch (Facts.accesses.formOf(tag)) {
            .assign, .compound_assign, .destructure => .assign,
            .call, .@"asm" => .call,
            .builtin => if (writingBuiltin(tree, node)) .call else continue,
            else => continue,
        };
        const store = if (Facts.accesses.formOf(tag) == .destructure) null else stores.get(node);
        try effects.append(c.allocator, .{ .node = node, .first = tree.firstToken(node), .last = tree.lastToken(node), .kind = kind, .store = store });
    }
    return .{ .c = c, .effects = effects.items };
}

/// Whether the `.?` at `node` reads a value known not to be null.
pub fn unwrapped(self: *Present, node: Ast.Node.Index) Context.Error!bool {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const operand = Facts.ungrouped(tree, tree.nodeData(node).node_and_token[0]);
    if (try self.place(operand)) return self.holds(node, .{ .some = operand });
    const tagged = try self.reading(operand) orelse return false;
    if (try self.caseOf(tagged)) return true;
    return self.holds(node, .{ .tag = tagged });
}

/// The goal `operand`, a call of std's reading of a node, needs: null for any other call.
fn reading(self: *Present, operand: Ast.Node.Index) Context.Error!?Tagged {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const call = try Facts.calls.at(self.c.facts, self.c.file, operand) orelse return null;
    const function = switch (call.callee) {
        .function => |function| function,
        .choice, .any => return null,
    };
    const args = switch (call.args) {
        .known => |known| known,
        .unknown => return null,
    };
    const shape = try self.shapeOf(function) orelse return null;
    if (shape.tree >= args.len or shape.node >= args.len) return null;
    const on = Facts.ungrouped(tree, args[shape.tree]);
    const node = Facts.ungrouped(tree, args[shape.node]);
    if (!try self.place(on) or !try self.place(node)) return null;
    return .{ .tree = on, .node = node, .tags = shape.tags, .read = shape.read };
}

/// std's reading's shape: a function whose body is `return switch (tree.nodeTag(node))` over
/// its parameters, its prongs enum literals each returning null or a value of a type that is
/// not optional (`tree.ifSimple(node)`), and its `else` null. A prong whose value may be null
/// (`.fn_decl => tree.fullFnProto(...)`) is not one of its tags; any other body is no shape.
fn shapeOf(self: *Present, function: Facts.Decl) Context.Error!?Reading {
    const source = self.c.project.at(function.file);
    const tree = &source.file.tree;
    const record = source.model.declarations[@backingInt(function.index)];
    if (record.kind != .function) return null;
    // A function's declaration is its prototype; its body is the `fn_decl` above it.
    const declared = if (tree.nodeTag(record.node) == .fn_decl) record.node else source.model.parentOf(record.node) orelse return null;
    if (tree.nodeTag(declared) != .fn_decl) return null;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buffer, declared) orelse return null;
    var statements_buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&statements_buffer, tree.nodeData(declared).node_and_node[1]) orelse return null;
    if (statements.len != 1 or tree.nodeTag(statements[0]) != .@"return") return null;
    const returned = tree.nodeData(statements[0]).opt_node.unwrap() orelse return null;
    const whole = tree.fullSwitch(returned) orelse return null;
    const read = try Facts.calls.at(self.c.facts, function.file, Facts.ungrouped(tree, whole.ast.condition)) orelse return null;
    const read_function = switch (read.callee) {
        .function => |each| each,
        .choice, .any => return null,
    };
    // Only std's own tag read is pure: the program's of that name may move what it reads.
    if (try Governed.isStd(self.c, read_function, "zig.Ast.nodeTag") != .yes) return null;
    const read_args = switch (read.args) {
        .known => |known| known,
        .unknown => return null,
    };
    if (read_args.len != 2) return null;
    const on = try self.parameterAt(function.file, proto, read_args[0]) orelse return null;
    const node = try self.parameterAt(function.file, proto, read_args[1]) orelse return null;
    var tags: Tags = .empty;
    for (whole.ast.cases) |case_node| {
        const case = tree.fullSwitchCase(case_node) orelse return null;
        const empty = Facts.isNull(tree, case.ast.target_expr);
        if (case.ast.values.len == 0) {
            if (!empty) return null;
            continue;
        }
        if (empty or !try self.valued(function.file, case.ast.target_expr)) continue;
        for (case.ast.values) |value| tags.insert(try self.tagOf(function.file, value) orelse return null);
    }
    return .{ .tree = on, .node = node, .tags = tags, .read = read_function };
}

/// Whether `value` is a call of a function whose return type is not optional: a container
/// type it names, or a pointer or slice type.
fn valued(self: *Present, file: Project.FileId, value: Ast.Node.Index) Context.Error!bool {
    const call = try Facts.calls.at(self.c.facts, file, value) orelse return false;
    const function = switch (call.callee) {
        .function => |function| function,
        .choice, .any => return false,
    };
    const source = self.c.project.at(function.file);
    const tree = &source.file.tree;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buffer, source.model.declarations[@backingInt(function.index)].node) orelse return false;
    const returned = proto.ast.return_type.unwrap() orelse return false;
    // What the written result resolves to: a container type or a pointer, no optional.
    return switch (try self.c.facts.resolve(function.file, returned)) {
        .container, .pointer => true,
        else => false,
    };
}

/// An element of a switch's cases (`for (whole.ast.cases) |case| tree.fullSwitchCase(case).?`)
/// is a case: std's parser makes only cases of them, as std's own AstGen reads them. `whole`
/// is the reading of std's `fullSwitch` on the same tree, and the case a capture by value.
fn caseOf(self: *Present, tagged: Tagged) Context.Error!bool {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const model = &self.c.project.at(self.c.file).model;
    const declared = switch (try self.c.facts.definition(self.c.file, tagged.node)) {
        .decl => |decl| if (decl.file == self.c.file) decl.index else return false,
        .none, .unknown => return false,
    };
    const record = model.declarations[@backingInt(declared)];
    if (record.kind != .capture or tree.tokenTag(record.token - 1) == .asterisk) return false;
    const loop = tree.fullFor(record.node) orelse return false;
    var position: usize = 0;
    var token = loop.payload_token;
    while (token < record.token) : (token += 1) {
        if (tree.tokenTag(token) == .comma) position += 1;
    }
    if (position >= loop.ast.inputs.len) return false;
    // `<whole>.ast.cases`: std's `full.Switch` fields by their declarations (`Facts.definition`,
    // `Governed.isStd`), along the input's path (`accesses.pathOf`).
    const input = loop.ast.inputs[position];
    const path = try Facts.accesses.pathOf(self.c.facts, self.c.file, input);
    if (path.steps.len < 3 or path.steps[0].kind != .field or path.steps[1].kind != .field) return false;
    if (!try self.stdField(path.steps[0].node, "zig.Ast.full.Switch.Components.cases") or !try self.stdField(path.steps[1].node, "zig.Ast.full.Switch.ast")) return false;
    if (!try self.switchRead(path.steps[2].node, tagged)) return false;
    const cases: Tags = .initMany(&.{ .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline });
    return cases.subsetOf(tagged.tags);
}

/// Whether the member read at `node` is std's field at `path`, by its declaration.
fn stdField(self: *Present, node: Ast.Node.Index, path: []const u8) Context.Error!bool {
    const field = switch (try self.c.facts.definition(self.c.file, node)) {
        .decl => |decl| decl,
        .none, .unknown => return false,
    };
    return try Governed.isStd(self.c, field, path) == .yes;
}

/// Whether `holder` is std's `fullSwitch` read on `tagged`'s tree: `tree.fullSwitch(n).?`, or
/// a constant holding one.
fn switchRead(self: *Present, holder: Ast.Node.Index, tagged: Tagged) Context.Error!bool {
    const tree = &self.c.project.at(self.c.file).file.tree;
    var value = try self.heldValue(holder) orelse return false;
    // `.?`'s operand, or `orelse`'s payload side (`accesses.carriedFrom`).
    value = Facts.ungrouped(tree, Facts.accesses.carriedFrom(tree, value) orelse return false);
    const call = try Facts.calls.at(self.c.facts, self.c.file, value) orelse return false;
    const function = switch (call.callee) {
        .function => |function| function,
        .choice, .any => return false,
    };
    const args = switch (call.args) {
        .known => |known| known,
        .unknown => return false,
    };
    if (args.len == 0 or !try self.samePlace(args[0], tagged.tree)) return false;
    // Not known to be std's: no case's tags are known here, and the use stays reported.
    return try Governed.isStd(self.c, function, "zig.Ast.fullSwitch") == .yes;
}

/// The value `expression` gives, through parentheses: itself, or where it names a variable of
/// this file, the one value it is ever given (`Facts.givenTo`). Null for a variable given more
/// than one, or any other declaration it names.
fn heldValue(self: *Present, expression: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const model = &self.c.project.at(self.c.file).model;
    const value = Facts.ungrouped(tree, expression);
    const declared = switch (try self.c.facts.definition(self.c.file, value)) {
        .decl => |decl| decl,
        .none => return value,
        .unknown => return null,
    };
    if (declared.file != self.c.file or model.declarations[@backingInt(declared.index)].kind != .variable) return null;
    const given = try self.c.facts.givenTo(declared, false) orelse return null;
    if (given.len != 1 or given[0].file != self.c.file) return null;
    return Facts.ungrouped(tree, given[0].node);
}

/// Whether a check dominating `use` gives `goal`, with nothing between that may write it.
fn holds(self: *Present, use: Ast.Node.Index, goal: Goal) Context.Error!bool {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const model = &self.c.project.at(self.c.file).model;
    var at = use;
    while (model.parentOf(at)) |parent| : (at = parent) {
        const tag = tree.nodeTag(parent);
        if (tag == .fn_decl) break;
        // `a and b`'s or `a or b`'s right side is read only where the left is true or false.
        const condition = Model.conditionOf(tree, parent);
        switch (condition) {
            .both, .either => |sides| if (sides[0] == at or sides[1] == at) {
                if (sides[1] == at) if (try self.implied(sides[0], condition == .both, goal)) |from| {
                    if (try self.unwritten(goal, from, use, parent)) return true;
                };
                continue;
            },
            else => {},
        }
        if (tree.fullIf(parent)) |branch| {
            if (at == branch.ast.then_expr) {
                if (try self.captured(branch.ast.cond_expr, branch.payload_token, goal)) |from| if (try self.unwritten(goal, from, use, parent)) return true;
                if (try self.implied(branch.ast.cond_expr, true, goal)) |from| if (try self.unwritten(goal, from, use, parent)) return true;
            } else if (branch.ast.else_expr.unwrap() == at) {
                if (try self.implied(branch.ast.cond_expr, false, goal)) |from| if (try self.unwritten(goal, from, use, parent)) return true;
            }
            continue;
        }
        if (tree.fullWhile(parent)) |loop| {
            if (at == loop.ast.then_expr) {
                if (try self.captured(loop.ast.cond_expr, loop.payload_token, goal)) |from| if (try self.unwritten(goal, from, use, parent)) return true;
                if (try self.implied(loop.ast.cond_expr, true, goal)) |from| if (try self.unwritten(goal, from, use, parent)) return true;
            }
            continue;
        }
        if (tree.fullSwitchCase(parent)) |case| {
            if (at != case.ast.target_expr or goal != .tag or case.ast.values.len == 0) continue;
            const choice = model.parentOf(parent) orelse continue;
            const whole = tree.fullSwitch(choice) orelse continue;
            const from = try self.subject(whole.ast.condition, goal.tag) orelse continue;
            var tags: Tags = .empty;
            for (case.ast.values) |value| tags.insert(try self.tagOf(self.c.file, value) orelse break) else {
                if (tags.subsetOf(goal.tag.tags) and try self.unwritten(goal, from, use, choice)) return true;
            }
            continue;
        }
        var statements_buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&statements_buffer, parent) orelse continue;
        for (statements) |statement| {
            if (statement == at) break;
            const guard = tree.fullIf(statement) orelse continue;
            if (guard.payload_token != null or !exits(tree, guard.ast.then_expr)) continue;
            if (try self.implied(guard.ast.cond_expr, false, goal)) |from| if (try self.unwritten(goal, from, use, parent)) return true;
        }
    }
    return false;
}

/// Whether `condition` being `truth` gives `goal`; the first token from which the place must
/// stay unwritten (the earliest check it rests on), or null for no.
fn implied(self: *Present, condition: Ast.Node.Index, truth: bool, goal: Goal) Context.Error!?Ast.TokenIndex {
    return switch (goal) {
        .some => |at| self.nonNull(condition, truth, at),
        .tag => |tagged| {
            const found = try self.tagsUnder(condition, truth, tagged) orelse return null;
            return if (found.tags.subsetOf(tagged.tags)) found.from else null;
        },
    };
}

/// `if (x) |_|` or `while (x) |_|` on the place itself: its body has it not null.
fn captured(self: *Present, condition: Ast.Node.Index, payload: ?Ast.TokenIndex, goal: Goal) Context.Error!?Ast.TokenIndex {
    const tree = &self.c.project.at(self.c.file).file.tree;
    if (payload == null or goal != .some) return null;
    if (!try self.samePlace(condition, goal.some)) return null;
    return tree.lastToken(condition);
}

fn nonNull(self: *Present, condition: Ast.Node.Index, truth: bool, at: Ast.Node.Index) Context.Error!?Ast.TokenIndex {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const read = Model.conditionOf(tree, condition);
    const compared = switch (read) {
        .not => |negated| return self.nonNull(negated, !truth, at),
        .both, .either => |sides| {
            const lhs, const rhs = sides;
            // `a and b` true, or `a or b` false: either side's own reading is enough.
            if ((read == .both) == truth) {
                if (try self.nonNull(lhs, truth, at)) |from| return from;
                return self.nonNull(rhs, truth, at);
            }
            // `a and b` false, or `a or b` true: only both sides together.
            const left = try self.nonNull(lhs, truth, at) orelse return null;
            const right = try self.nonNull(rhs, truth, at) orelse return null;
            return @min(left, right);
        },
        .compare => |compared| compared,
        .other => return null,
    };
    const equal = equalOrder(compared.order) orelse return null;
    const lhs, const rhs = .{ compared.left, compared.right };
    const other = if (Facts.isNull(tree, lhs)) rhs else if (Facts.isNull(tree, rhs)) lhs else return null;
    if (!try self.samePlace(other, at)) return null;
    // `x != null` true, or `x == null` false.
    return if (!equal == truth) tree.lastToken(compared.node) else null;
}

const Found = struct { tags: Tags, from: Ast.TokenIndex };

/// The tags `tagged`'s node can have where `condition` is `truth`, and the earliest check
/// that rests on; null for any tag.
fn tagsUnder(self: *Present, condition: Ast.Node.Index, truth: bool, tagged: Tagged) Context.Error!?Found {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const read = Model.conditionOf(tree, condition);
    const compared = switch (read) {
        .not => |negated| return self.tagsUnder(negated, !truth, tagged),
        .both, .either => |sides| {
            const lhs, const rhs = sides;
            const left = try self.tagsUnder(lhs, truth, tagged);
            const right = try self.tagsUnder(rhs, truth, tagged);
            if ((read == .both) == truth) {
                // Both hold: either side's tags, or the tags both allow.
                const one = left orelse return right;
                const other = right orelse return left;
                return .{ .tags = one.tags.intersectWith(other.tags), .from = @min(one.from, other.from) };
            }
            // One of them holds: the tags either allows.
            const one = left orelse return null;
            const other = right orelse return null;
            return .{ .tags = one.tags.unionWith(other.tags), .from = @min(one.from, other.from) };
        },
        .compare => |compared| compared,
        .other => return null,
    };
    const equal = equalOrder(compared.order) orelse return null;
    const lhs, const rhs = .{ compared.left, compared.right };
    // The side that reads the node's tag (`subject`); the other names the tag it is compared
    // with.
    const from, const literal = if (try self.subject(lhs, tagged)) |from| .{ from, rhs } else .{ try self.subject(rhs, tagged) orelse return null, lhs };
    const tag = try self.tagOf(self.c.file, literal) orelse return null;
    // `== .tag` true, or `!= .tag` false.
    if (equal != truth) return null;
    return .{ .tags = .initOne(tag), .from = @min(from, tree.lastToken(compared.node)) };
}

/// Whether `expression` reads `tagged`'s node's tag (`tree.nodeTag(node)`, or a constant
/// holding it), and the first token from which tree and node must stay unwritten.
fn subject(self: *Present, expression: Ast.Node.Index, tagged: Tagged) Context.Error!?Ast.TokenIndex {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const value = try self.heldValue(expression) orelse return null;
    const from = tree.lastToken(value);
    const call = try Facts.calls.at(self.c.facts, self.c.file, value) orelse return null;
    const function = switch (call.callee) {
        .function => |function| function,
        .choice, .any => return null,
    };
    if (!std.meta.eql(function, tagged.read)) return null;
    const args = switch (call.args) {
        .known => |known| known,
        .unknown => return null,
    };
    if (args.len != 2) return null;
    if (!try self.samePlace(args[0], tagged.tree) or !try self.samePlace(args[1], tagged.node)) return null;
    return from;
}

/// Whether nothing from `from` to `use` may write what `goal` rests on; a loop between
/// `top` (where the check is) and `use` counts whole, its next turn coming after the use.
fn unwritten(self: *Present, goal: Goal, from: Ast.TokenIndex, use: Ast.Node.Index, top: Ast.Node.Index) Context.Error!bool {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const model = &self.c.project.at(self.c.file).model;
    var spans: std.ArrayList([2]Ast.TokenIndex) = .empty;
    try spans.append(self.c.allocator, .{ from + 1, tree.firstToken(use) });
    var at = use;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (parent == top) break;
        if (tree.fullWhile(parent) != null or tree.fullFor(parent) != null) try spans.append(self.c.allocator, .{ tree.firstToken(parent), tree.lastToken(parent) + 1 });
        // A deferred use runs as its block ends: after every statement written below it.
        if (tree.nodeTag(parent) == .@"defer" or tree.nodeTag(parent) == .@"errdefer") {
            const block = model.parentOf(parent) orelse parent;
            try spans.append(self.c.allocator, .{ tree.firstToken(parent), tree.lastToken(block) + 1 });
        }
    }
    return switch (goal) {
        .some => |place_node| self.kept(place_node, spans.items, null, true),
        .tag => |tagged| try self.kept(tagged.tree, spans.items, tagged.read, false) and try self.kept(tagged.node, spans.items, tagged.read, false),
    };
}

/// Whether no effect within `spans` may write `place_node`: none for a constant by value; for
/// a local variable whose address is never taken, no assignment to it; else no call (but a
/// call of `read`, which writes nothing) and no assignment.
fn kept(self: *Present, place_node: Ast.Node.Index, spans: []const [2]Ast.TokenIndex, read: ?Facts.Decl, some: bool) Context.Error!bool {
    const tree = &self.c.project.at(self.c.file).file.tree;
    if (try self.constant(place_node)) return true;
    const local = try self.lone(place_node);
    for (self.effects) |effect| {
        const within = for (spans) |span| {
            if (effect.first >= span[0] and effect.last < span[1]) break true;
        } else false;
        if (!within) continue;
        switch (effect.kind) {
            .call => {
                if (local != null) continue;
                if (read) |known| if (try Facts.calls.at(self.c.facts, self.c.file, effect.node)) |call| switch (call.callee) {
                    .function => |function| if (std.meta.eql(function, known)) continue,
                    .choice, .any => {},
                };
                return false;
            },
            .assign => {
                const store = effect.store orelse return false;
                const target = Facts.ungrouped(tree, store.target orelse return false);
                const root = try self.rootOf(target);
                const declared: ?Model.Declaration.Id = switch (try self.c.facts.definition(self.c.file, root)) {
                    .decl => |decl| if (decl.file == self.c.file) decl.index else null,
                    .none, .unknown => null,
                };
                if (local) |own| {
                    if (declared) |other| if (other != own) continue;
                    // A presence written whole with a value that is never null stays present
                    // (`found = 0`); a tag changes with any write.
                    if (some and target == root and store.kind == .set and !store.part) if (store.value) |value| if (try self.present(value)) continue;
                    return false;
                }
                // Another local variable written whole leaves any other place as it was.
                if (target == root) if (declared) |other| if (self.isLocalVariable(other) and try Facts.accesses.samePlace(self.c.facts, self.c.file, try self.rootOf(place_node), root) == .no) continue;
                return false;
            },
        }
    }
    return true;
}

/// Whether `value` is never null: of a type that is no optional (a number, a struct), by what
/// it resolves to. `null`, an optional and what does not resolve may be.
fn present(self: *Present, value: Ast.Node.Index) Context.Error!bool {
    const tree = &self.c.project.at(self.c.file).file.tree;
    if (Facts.isNull(tree, value)) return false;
    return switch (try self.c.facts.resolve(self.c.file, value)) {
        .optional, .unknown, .alternatives => false,
        else => true,
    };
}

/// Whether `place_node` cannot be written at all: a parameter, a capture or a constant, and
/// each member it reads of a value held by value, never through a pointer, by its path
/// (`accesses.pathOf`).
fn constant(self: *Present, place_node: Ast.Node.Index) Context.Error!bool {
    const path = try Facts.accesses.pathOf(self.c.facts, self.c.file, place_node);
    for (path.steps[0 .. path.steps.len - 1]) |step| {
        if (step.kind != .field or step.crosses) return false;
        switch (step.holder orelse return false) {
            .pointer, .unknown, .alternatives => return false,
            else => {},
        }
    }
    const declared = switch (path.root) {
        .decl => |decl| if (decl.file == self.c.file) decl else return false,
        .none, .unknown => return false,
    };
    const record = self.c.project.at(declared.file).model.declarations[@backingInt(declared.index)];
    return switch (record.kind) {
        .parameter, .capture => true,
        .variable => blk: {
            const tree = &self.c.project.at(self.c.file).file.tree;
            const variable = tree.fullVarDecl(record.node) orelse break :blk false;
            break :blk tree.tokenTag(variable.ast.mut_token) == .keyword_const;
        },
        .function, .field => false,
    };
}

/// The declaration of `place_node` when it is a local variable named alone whose address
/// the function never takes and no method is called on: only an assignment writes it.
fn lone(self: *Present, place_node: Ast.Node.Index) Context.Error!?Model.Declaration.Id {
    const model = &self.c.project.at(self.c.file).model;
    const declared = switch (try self.c.facts.definition(self.c.file, place_node)) {
        .decl => |decl| if (decl.file == self.c.file) decl.index else return null,
        .none, .unknown => return null,
    };
    if (!self.isLocalVariable(declared)) return null;
    for (model.references) |each| {
        const other = each.declaration orelse continue;
        if (other != declared) continue;
        // Its address taken (`&x`, `&(x)`), by `accesses.useOf`; `x.f(…)` may take it too.
        var use = try Facts.accesses.useOf(self.c.facts, self.c.file, each.node);
        while (use == .carried and use.carried.how == .grouped) use = try Facts.accesses.useOf(self.c.facts, self.c.file, use.carried.into);
        switch (use) {
            .address => return null,
            .member => |member| if (try Facts.accesses.useOf(self.c.facts, self.c.file, member) == .callee) return null,
            else => {},
        }
    }
    return declared;
}

fn isLocalVariable(self: *Present, declared: Model.Declaration.Id) bool {
    const model = &self.c.project.at(self.c.file).model;
    const record = model.declarations[@backingInt(declared)];
    if (record.kind != .variable) return false;
    return switch (model.scopes[@backingInt(record.scope)].kind) {
        .function, .block, .branch, .loop, .@"test", .@"comptime" => true,
        .file, .container => false,
    };
}

/// The expression a place starts from (`x` of `x.f.g`, by `accesses.pathOf`); the expression
/// itself for any other.
fn rootOf(self: *Present, node: Ast.Node.Index) Context.Error!Ast.Node.Index {
    const path = try Facts.accesses.pathOf(self.c.facts, self.c.file, node);
    return path.steps[path.steps.len - 1].node;
}

/// A builtin that may write memory or call: any but the ones that only compute a value.
fn writingBuiltin(tree: *const Ast, node: Ast.Node.Index) bool {
    const name = Facts.builtinName(tree, node) orelse return false;
    const pure = [_][]const u8{ "@as", "@intCast", "@truncate", "@min", "@max", "@TypeOf", "@sizeOf", "@bitSizeOf", "@alignOf", "@backingInt", "@fromBackingInt", "@enumFromInt", "@intFromEnum", "@intFromBool", "@tagName", "@errorName", "@floatCast", "@floatFromInt", "@intFromFloat", "@This", "@import", "@hasDecl", "@hasField", "@typeInfo", "@FieldType", "@field", "@bitCast", "@abs", "@clz", "@ctz", "@popCount", "@divTrunc", "@divFloor", "@divExact", "@mod", "@rem", "@shlExact", "@shrExact", "@splat", "@errorFromInt", "@intFromError", "@constCast", "@ptrCast", "@alignCast", "@intFromPtr", "@ptrFromInt", "@src", "@inComptime", "@offsetOf", "@byteSwap", "@bitReverse", "@sqrt" };
    for (pure) |each| if (std.mem.eql(u8, name, each)) return false;
    return true;
}

/// Whether `node` ends the path it is on: `return`, `continue`, `break`, `unreachable`, or a
/// block whose last statement does.
fn exits(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .@"return", .@"continue", .@"break", .unreachable_literal => true,
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, node) orelse return false;
            if (statements.len == 0) return false;
            return exits(tree, statements[statements.len - 1]) and !landsWithin(tree, node);
        },
        else => false,
    };
}

/// Whether a `break` or `continue` in `node` lands inside it: one naming a label `node` or
/// what it holds declares (`blk: { if (c) break :blk; return; }` goes on past the block), or
/// one of no label in a loop `node` holds.
fn landsWithin(tree: *const Ast, node: Ast.Node.Index) bool {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    // A labeled block's label stands before its first token.
    const from = if (first >= 2 and tree.tokenTag(first - 1) == .colon and tree.tokenTag(first - 2) == .identifier) first - 2 else first;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"break" and tag != .@"continue") continue;
        const jump: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(jump);
        if (token < first or token > last) continue;
        if (tree.nodeData(jump).opt_token_and_opt_node[0].unwrap()) |label| {
            const name = tree.tokenSlice(label);
            var at = from;
            while (at + 1 <= last) : (at += 1) {
                if (tree.tokenTag(at) == .identifier and tree.tokenTag(at + 1) == .colon and at != label and std.mem.eql(u8, tree.tokenSlice(at), name)) return true;
            }
        } else for (tree.nodes.items(.tag), 0..) |loop_tag, j| switch (loop_tag) {
            .@"while", .while_simple, .while_cont, .@"for", .for_simple => {
                const loop: Ast.Node.Index = @fromBackingInt(@intCast(j));
                if (tree.firstToken(loop) >= first and tree.lastToken(loop) <= last and tree.firstToken(loop) < token and token <= tree.lastToken(loop)) return true;
            },
            else => {},
        };
    }
    return false;
}

/// A name, or a member of one (`x`, `x.f.g`), by `accesses.pathOf`: what a check and a read
/// can share.
fn place(self: *Present, node: Ast.Node.Index) Context.Error!bool {
    const path = try Facts.accesses.pathOf(self.c.facts, self.c.file, node);
    for (path.steps[0 .. path.steps.len - 1]) |step| if (step.kind != .field or step.name == null) return false;
    return path.root == .decl;
}

/// The same place (`accesses.samePlace`): one declaration named, and the same members of it.
fn samePlace(self: *Present, a: Ast.Node.Index, b: Ast.Node.Index) Context.Error!bool {
    return try Facts.accesses.samePlace(self.c.facts, self.c.file, a, b) == .yes;
}

/// The position in `proto` of the parameter `node` names, by `Facts.definition`; null where it
/// names none of them.
fn parameterAt(self: *Present, file: Project.FileId, proto: Ast.full.FnProto, node: Ast.Node.Index) Context.Error!?usize {
    const declared = switch (try self.c.facts.definition(file, node)) {
        .decl => |decl| decl,
        .none, .unknown => return null,
    };
    if (declared.file != file) return null;
    const source = self.c.project.at(file);
    const tree = &source.file.tree;
    const record = source.model.declarations[@backingInt(declared.index)];
    if (record.kind != .parameter) return null;
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        if (param.name_token == record.token) return position;
    }
    return null;
}

/// The node tag `node` names, in the tags this glint was built with. Each caller compares it
/// with std's `nodeTag` read (`shapeOf`'s and `subject`'s check that the read is std's), whose
/// result type is std's `Ast.Node.Tag`; the name is the one `Facts.fieldName` reads (an enum
/// literal, a constant holding one).
fn tagOf(self: *Present, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Ast.Node.Tag {
    return switch (try self.c.facts.fieldName(file, node)) {
        .name => |name| std.meta.stringToEnum(Ast.Node.Tag, name),
        .each_of, .names, .computed => null,
    };
}

/// Whether a comparison's order is `==` (true) or `!=` (false); null for any other.
fn equalOrder(order: Model.Order) ?bool {
    return switch (order) {
        .equal => true,
        .not_equal => false,
        else => null,
    };
}
