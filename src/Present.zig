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

const Effect = struct { node: Ast.Node.Index, first: Ast.TokenIndex, last: Ast.TokenIndex, kind: enum { call, assign } };

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
    var effects: std.ArrayList(Effect) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var call_buffer: [1]Ast.Node.Index = undefined;
        const kind: @FieldType(Effect, "kind") = if (std.mem.startsWith(u8, @tagName(tag), "assign"))
            .assign
        else if (tree.fullCall(&call_buffer, node) != null or tree.fullAsm(node) != null or writingBuiltin(tree, node))
            .call
        else
            continue;
        try effects.append(c.allocator, .{ .node = node, .first = tree.firstToken(node), .last = tree.lastToken(node), .kind = kind });
    }
    return .{ .c = c, .effects = effects.items };
}

/// Whether the `.?` at `node` reads a value known not to be null.
pub fn unwrapped(self: *Present, node: Ast.Node.Index) Context.Error!bool {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const operand = ungrouped(tree, tree.nodeData(node).node_and_token[0]);
    if (place(tree, operand)) return self.holds(node, .{ .some = operand });
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
    const on = ungrouped(tree, args[shape.tree]);
    const node = ungrouped(tree, args[shape.node]);
    if (!place(tree, on) or !place(tree, node)) return null;
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
    const read = try Facts.calls.at(self.c.facts, function.file, ungrouped(tree, whole.ast.condition)) orelse return null;
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
    const on = parameterAt(tree, &source.model, proto, read_args[0]) orelse return null;
    const node = parameterAt(tree, &source.model, proto, read_args[1]) orelse return null;
    var tags: Tags = .empty;
    for (whole.ast.cases) |case_node| {
        const case = tree.fullSwitchCase(case_node) orelse return null;
        const empty = isNull(tree, case.ast.target_expr);
        if (case.ast.values.len == 0) {
            if (!empty) return null;
            continue;
        }
        if (empty or !try self.valued(function.file, case.ast.target_expr)) continue;
        for (case.ast.values) |value| tags.insert(tagOf(tree, value) orelse return null);
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
    if (tree.fullPtrType(returned) != null) return true;
    if (tree.nodeTag(returned) != .identifier and tree.nodeTag(returned) != .field_access) return false;
    return switch (try self.c.facts.resolve(function.file, returned)) {
        .container => true,
        else => false,
    };
}

/// An element of a switch's cases (`for (whole.ast.cases) |case| tree.fullSwitchCase(case).?`)
/// is a case: std's parser makes only cases of them, as std's own AstGen reads them. `whole`
/// is the reading of std's `fullSwitch` on the same tree, and the case a capture by value.
fn caseOf(self: *Present, tagged: Tagged) Context.Error!bool {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const model = &self.c.project.at(self.c.file).model;
    if (tree.nodeTag(tagged.node) != .identifier) return false;
    const reference = model.reference(tagged.node) orelse return false;
    const declared = reference.declaration orelse return false;
    const record = model.declarations[@backingInt(declared)];
    if (record.kind != .capture or tree.tokenTag(record.token - 1) == .asterisk) return false;
    const loop = tree.fullFor(record.node) orelse return false;
    var position: usize = 0;
    var token = loop.payload_token;
    while (token < record.token) : (token += 1) {
        if (tree.tokenTag(token) == .comma) position += 1;
    }
    if (position >= loop.ast.inputs.len) return false;
    // `<whole>.ast.cases`.
    const input = loop.ast.inputs[position];
    if (tree.nodeTag(input) != .field_access or !std.mem.eql(u8, tree.tokenSlice(tree.nodeData(input).node_and_token[1]), "cases")) return false;
    const ast = tree.nodeData(input).node_and_token[0];
    if (tree.nodeTag(ast) != .field_access or !std.mem.eql(u8, tree.tokenSlice(tree.nodeData(ast).node_and_token[1]), "ast")) return false;
    if (!try self.switchRead(tree.nodeData(ast).node_and_token[0], tagged)) return false;
    const cases: Tags = .initMany(&.{ .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline });
    return cases.subsetOf(tagged.tags);
}

/// Whether `holder` is std's `fullSwitch` read on `tagged`'s tree: `tree.fullSwitch(n).?`, or
/// a constant holding one.
fn switchRead(self: *Present, holder: Ast.Node.Index, tagged: Tagged) Context.Error!bool {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const model = &self.c.project.at(self.c.file).model;
    var value = ungrouped(tree, holder);
    if (tree.nodeTag(value) == .identifier) {
        const reference = model.reference(value) orelse return false;
        const declared = reference.declaration orelse return false;
        const record = model.declarations[@backingInt(declared)];
        if (record.kind != .variable) return false;
        const variable = tree.fullVarDecl(record.node) orelse return false;
        if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return false;
        value = ungrouped(tree, variable.ast.init_node.unwrap() orelse return false);
    }
    value = switch (tree.nodeTag(value)) {
        .unwrap_optional => ungrouped(tree, tree.nodeData(value).node_and_token[0]),
        .@"orelse" => ungrouped(tree, tree.nodeData(value).node_and_node[0]),
        else => return false,
    };
    const call = try Facts.calls.at(self.c.facts, self.c.file, value) orelse return false;
    const function = switch (call.callee) {
        .function => |function| function,
        .choice, .any => return false,
    };
    const args = switch (call.args) {
        .known => |known| known,
        .unknown => return false,
    };
    if (args.len == 0 or !samePlace(tree, model, ungrouped(tree, args[0]), tagged.tree)) return false;
    // Not known to be std's: no case's tags are known here, and the use stays reported.
    return try Governed.isStd(self.c, function, "zig.Ast.fullSwitch") == .yes;
}

/// Whether a check dominating `use` gives `goal`, with nothing between that may write it.
fn holds(self: *Present, use: Ast.Node.Index, goal: Goal) Context.Error!bool {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const model = &self.c.project.at(self.c.file).model;
    var at = use;
    while (model.parentOf(at)) |parent| : (at = parent) {
        const tag = tree.nodeTag(parent);
        if (tag == .fn_decl) break;
        if (tag == .bool_and or tag == .bool_or) {
            const lhs, const rhs = tree.nodeData(parent).node_and_node;
            if (rhs == at) if (try self.implied(lhs, tag == .bool_and, goal)) |from| {
                if (try self.unwritten(goal, from, use, parent)) return true;
            };
            continue;
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
            for (case.ast.values) |value| tags.insert(tagOf(tree, value) orelse break) else {
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
    const model = &self.c.project.at(self.c.file).model;
    if (payload == null or goal != .some) return null;
    if (!samePlace(tree, model, ungrouped(tree, condition), goal.some)) return null;
    return tree.lastToken(condition);
}

fn nonNull(self: *Present, condition: Ast.Node.Index, truth: bool, at: Ast.Node.Index) Context.Error!?Ast.TokenIndex {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const model = &self.c.project.at(self.c.file).model;
    const node = ungrouped(tree, condition);
    switch (tree.nodeTag(node)) {
        .bool_not => return self.nonNull(tree.nodeData(node).node, !truth, at),
        .bool_and, .bool_or => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            // `a and b` true, or `a or b` false: either side's own reading is enough.
            if ((tree.nodeTag(node) == .bool_and) == truth) {
                if (try self.nonNull(lhs, truth, at)) |from| return from;
                return self.nonNull(rhs, truth, at);
            }
            // `a and b` false, or `a or b` true: only both sides together.
            const left = try self.nonNull(lhs, truth, at) orelse return null;
            const right = try self.nonNull(rhs, truth, at) orelse return null;
            return @min(left, right);
        },
        .equal_equal, .bang_equal => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const other = if (isNull(tree, lhs)) rhs else if (isNull(tree, rhs)) lhs else return null;
            if (!samePlace(tree, model, ungrouped(tree, other), at)) return null;
            // `x != null` true, or `x == null` false.
            return if ((tree.nodeTag(node) == .bang_equal) == truth) tree.lastToken(node) else null;
        },
        else => return null,
    }
}

const Found = struct { tags: Tags, from: Ast.TokenIndex };

/// The tags `tagged`'s node can have where `condition` is `truth`, and the earliest check
/// that rests on; null for any tag.
fn tagsUnder(self: *Present, condition: Ast.Node.Index, truth: bool, tagged: Tagged) Context.Error!?Found {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const node = ungrouped(tree, condition);
    switch (tree.nodeTag(node)) {
        .bool_not => return self.tagsUnder(tree.nodeData(node).node, !truth, tagged),
        .bool_and, .bool_or => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const left = try self.tagsUnder(lhs, truth, tagged);
            const right = try self.tagsUnder(rhs, truth, tagged);
            if ((tree.nodeTag(node) == .bool_and) == truth) {
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
        .equal_equal, .bang_equal => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const literal, const read = if (tree.nodeTag(rhs) == .enum_literal) .{ rhs, lhs } else if (tree.nodeTag(lhs) == .enum_literal) .{ lhs, rhs } else return null;
            const from = try self.subject(read, tagged) orelse return null;
            const tag = tagOf(tree, literal) orelse return null;
            // `== .tag` true, or `!= .tag` false.
            if ((tree.nodeTag(node) == .equal_equal) != truth) return null;
            return .{ .tags = .initOne(tag), .from = @min(from, tree.lastToken(node)) };
        },
        else => return null,
    }
}

/// Whether `expression` reads `tagged`'s node's tag (`tree.nodeTag(node)`, or a constant
/// holding it), and the first token from which tree and node must stay unwritten.
fn subject(self: *Present, expression: Ast.Node.Index, tagged: Tagged) Context.Error!?Ast.TokenIndex {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const model = &self.c.project.at(self.c.file).model;
    var value = ungrouped(tree, expression);
    var from = tree.lastToken(value);
    if (tree.nodeTag(value) == .identifier) {
        const reference = model.reference(value) orelse return null;
        const declared = reference.declaration orelse return null;
        const record = model.declarations[@backingInt(declared)];
        if (record.kind != .variable) return null;
        const variable = tree.fullVarDecl(record.node) orelse return null;
        if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
        value = ungrouped(tree, variable.ast.init_node.unwrap() orelse return null);
        from = tree.lastToken(value);
    }
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
    if (!samePlace(tree, model, ungrouped(tree, args[0]), tagged.tree) or !samePlace(tree, model, ungrouped(tree, args[1]), tagged.node)) return null;
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
    const model = &self.c.project.at(self.c.file).model;
    if (try self.constant(place_node)) return true;
    const local = self.lone(place_node);
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
                const target = ungrouped(tree, assigned(tree, effect.node) orelse return false);
                const root = rootOf(tree, target);
                const declared = if (tree.nodeTag(root) == .identifier) if (model.reference(root)) |reference| reference.declaration else null else null;
                if (local) |own| {
                    if (declared) |other| if (other != own) continue;
                    // A presence written whole with a value that is never null stays present
                    // (`found = 0`); a tag changes with any write.
                    if (some and target == root and tree.nodeTag(effect.node) == .assign and try self.present(tree.nodeData(effect.node).node_and_node[1])) continue;
                    return false;
                }
                // Another local variable written whole leaves any other place as it was.
                if (target == root) if (declared) |other| if (self.isLocalVariable(other) and !samePlace(tree, model, rootOf(tree, place_node), root)) continue;
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
    if (isNull(tree, value)) return false;
    return switch (try self.c.facts.resolve(self.c.file, value)) {
        .optional, .unknown, .alternatives => false,
        else => true,
    };
}

/// Whether `place_node` cannot be written at all: a parameter, a capture or a constant, and
/// each member it reads of a value held by value, never through a pointer.
fn constant(self: *Present, place_node: Ast.Node.Index) Context.Error!bool {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const model = &self.c.project.at(self.c.file).model;
    switch (tree.nodeTag(place_node)) {
        .identifier => {
            const reference = model.reference(place_node) orelse return false;
            const declared = reference.declaration orelse return false;
            const record = model.declarations[@backingInt(declared)];
            return switch (record.kind) {
                .parameter, .capture => true,
                .variable => blk: {
                    const variable = tree.fullVarDecl(record.node) orelse break :blk false;
                    break :blk tree.tokenTag(variable.ast.mut_token) == .keyword_const;
                },
                .function, .field => false,
            };
        },
        .field_access => {
            const holder = tree.nodeData(place_node).node_and_token[0];
            return switch (try self.c.facts.resolve(self.c.file, holder)) {
                .pointer, .unknown => false,
                else => self.constant(holder),
            };
        },
        else => return false,
    }
}

/// The declaration of `place_node` when it is a local variable named alone whose address
/// the function never takes and no method is called on: only an assignment writes it.
fn lone(self: *Present, place_node: Ast.Node.Index) ?Model.Declaration.Id {
    const tree = &self.c.project.at(self.c.file).file.tree;
    const model = &self.c.project.at(self.c.file).model;
    if (tree.nodeTag(place_node) != .identifier) return null;
    const reference = model.reference(place_node) orelse return null;
    const declared = reference.declaration orelse return null;
    if (!self.isLocalVariable(declared)) return null;
    for (model.references) |each| {
        const other = each.declaration orelse continue;
        if (other != declared) continue;
        const parent = model.parentOf(each.node) orelse continue;
        switch (tree.nodeTag(parent)) {
            .address_of => return null,
            // `x.f(…)` may take `&x`.
            .field_access => if (model.parentOf(parent)) |above| {
                var call_buffer: [1]Ast.Node.Index = undefined;
                if (tree.fullCall(&call_buffer, above)) |call| if (call.ast.fn_expr == parent) return null;
            },
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

/// The place an assignment writes: its left side, or null for a destructure (it writes
/// several).
fn assigned(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    if (tree.nodeTag(node) == .assign_destructure) return null;
    return tree.nodeData(node).node_and_node[0];
}

/// The name a place starts from (`x` of `x.f.g`); the expression itself for any other.
fn rootOf(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var at = ungrouped(tree, node);
    while (true) switch (tree.nodeTag(at)) {
        .field_access => at = ungrouped(tree, tree.nodeData(at).node_and_token[0]),
        .deref => at = ungrouped(tree, tree.nodeData(at).node),
        .array_access => at = ungrouped(tree, tree.nodeData(at).node_and_node[0]),
        else => return at,
    };
}

/// A builtin that may write memory or call: any but the ones that only compute a value.
fn writingBuiltin(tree: *const Ast, node: Ast.Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {},
        else => return false,
    }
    const name = tree.tokenSlice(tree.nodeMainToken(node));
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

/// A name, or a member of one (`x`, `x.f.g`): what a check and a read can share.
fn place(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .identifier => true,
        .field_access => place(tree, ungrouped(tree, tree.nodeData(node).node_and_token[0])),
        else => false,
    };
}

/// The same place: one declaration named, and the same members of it.
fn samePlace(tree: *const Ast, model: *const Model, a: Ast.Node.Index, b: Ast.Node.Index) bool {
    if (tree.nodeTag(a) != tree.nodeTag(b)) return false;
    switch (tree.nodeTag(a)) {
        .identifier => {
            const left = model.reference(a) orelse return false;
            const right = model.reference(b) orelse return false;
            const one = left.declaration orelse return false;
            const other = right.declaration orelse return false;
            return one == other;
        },
        .field_access => {
            const left = tree.nodeData(a).node_and_token;
            const right = tree.nodeData(b).node_and_token;
            if (!std.mem.eql(u8, tree.tokenSlice(left[1]), tree.tokenSlice(right[1]))) return false;
            return samePlace(tree, model, ungrouped(tree, left[0]), ungrouped(tree, right[0]));
        },
        else => return false,
    }
}

fn parameterAt(tree: *const Ast, model: *const Model, proto: Ast.full.FnProto, node: Ast.Node.Index) ?usize {
    if (tree.nodeTag(node) != .identifier) return null;
    const reference = model.reference(node) orelse return null;
    const declared = reference.declaration orelse return null;
    const record = model.declarations[@backingInt(declared)];
    if (record.kind != .parameter) return null;
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        if (param.name_token == record.token) return position;
    }
    return null;
}

/// The node tag an enum literal names, in the tags this glint was built with.
fn tagOf(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Tag {
    if (tree.nodeTag(node) != .enum_literal) return null;
    const raw = tree.tokenSlice(tree.nodeMainToken(node));
    const name = if (std.mem.startsWith(u8, raw, "@\"") and raw.len >= 3) raw[2 .. raw.len - 1] else raw;
    return std.meta.stringToEnum(Ast.Node.Tag, name);
}

fn isNull(tree: *const Ast, node: Ast.Node.Index) bool {
    const value = ungrouped(tree, node);
    return tree.nodeTag(value) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "null");
}

fn ungrouped(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var at = node;
    while (tree.nodeTag(at) == .grouped_expression) at = tree.nodeData(at).node_and_token[0];
    return at;
}
