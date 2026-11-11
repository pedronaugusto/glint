//! Built-in code rules use the public rule context, like project-owned rules.
const std = @import("std");
const Facts = @import("Facts.zig");
const rules = @import("Rule.zig");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const names = @import("names.zig");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Report = @import("Report.zig");
const DeadDeclarations = @import("DeadDeclarations.zig");
const Disallowed = @import("Disallowed.zig");
const Governed = @import("Governed.zig");
const Discards = @import("Discards.zig");
const RunError = Context.Error;

pub fn check(context: *Context) RunError!void {
    try parser(context);
    try lineLength(context);
    if ((try context.project.status(try context.source())) != .parsed) return;
    try unusedImports(context);
    try priorityRules(context);
    try amendedPolicies(context);
    try syntaxRules(context);
    try precedence(context);
    try contextRules(context);
    try sourcePolicies(context);
    try functionLengths(context);
    try Disallowed.check(context);
    try DeadDeclarations.check(context);
    try unknownCoverage(context);
}

fn parser(self: *Context) RunError!void {
    if (!self.config.has(.Z003)) return;
    const file = self.project.at(self.file).file;
    for (file.tree.errors) |err| {
        if (err.is_note) continue;
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        file.tree.renderError(err, &writer.writer) catch return error.OutOfMemory;
        const offset = file.tree.tokenStart(err.token) + file.tree.errorOffset(err);
        try self.emit(.Z003, offset, offset, try writer.toOwnedSlice());
    }
}

/// The groups Zig 0.18's parser orders binary operators by.
const Operators = enum { product, mod, sum, shift, bit_and, bit_xor, bit_or, comparison, bool_and, bool_or, @"orelse", @"catch" };

fn operators(tag: Ast.Node.Tag) ?Operators {
    return switch (tag) {
        .mul, .div, .mul_wrap, .mul_sat, .merge_error_sets => .product,
        .mod => .mod,
        .add, .sub, .array_cat, .add_wrap, .sub_wrap, .add_sat, .sub_sat => .sum,
        .shl, .shl_sat, .shr => .shift,
        .bit_and => .bit_and,
        .bit_xor => .bit_xor,
        .bit_or => .bit_or,
        .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal => .comparison,
        .bool_and => .bool_and,
        .bool_or => .bool_or,
        .@"orelse" => .@"orelse",
        .@"catch" => .@"catch",
        else => null,
    };
}

/// Whether Zig 0.18 orders an operator of `outer` over an operand of `inner` without
/// parentheses. Arithmetic and bitwise operators bind tighter than comparisons, which bind
/// tighter than `and` and `or`; a product or a remainder tighter than a sum. Every other pair
/// meets unordered: a product and a remainder, two bitwise operators, arithmetic and bitwise,
/// `and` and `or`, and `orelse` or `catch` with any other. A remainder and a shift do not chain,
/// as a comparison does not (Zig 0.17 already refuses the comparison).
fn ordered(outer: Operators, inner: Operators) bool {
    const Major = enum { arithmetic, bitwise, comparison, boolean, recovery };
    const major = struct {
        fn of(group: Operators) Major {
            return switch (group) {
                .product, .mod, .sum => .arithmetic,
                .shift, .bit_and, .bit_xor, .bit_or => .bitwise,
                .comparison => .comparison,
                .bool_and, .bool_or => .boolean,
                .@"orelse", .@"catch" => .recovery,
            };
        }
    }.of;
    if (outer == inner) return outer != .mod and outer != .shift;
    const a = major(outer);
    const b = major(inner);
    if (a == .recovery or b == .recovery) return false;
    if (a == b) return a == .arithmetic and (outer == .sum or inner == .sum);
    const rank = struct {
        fn of(m: Major) u2 {
            return switch (m) {
                .arithmetic, .bitwise => 2,
                .comparison => 1,
                .boolean, .recovery => 0,
            };
        }
    }.of;
    return rank(a) != rank(b);
}

/// Z034: two operators the next Zig's parser refuses to order without parentheses (Zig
/// master's "ambiguous operator precedence"), read as Zig 0.17 orders them. The fix
/// parenthesizes the operand as 0.17 groups it, which keeps what the expression means.
fn precedence(self: *Context) RunError!void {
    if (!self.config.has(.Z034)) return;
    const source = self.project.at(self.file);
    const tree = &source.file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, n| {
        const inner = operators(tag) orelse continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
        const parent = source.model.node_parents[n] orelse continue;
        const outer = operators(tree.nodeTag(parent)) orelse continue;
        if (ordered(outer, inner)) continue;
        const operand_start = tree.tokenStart(tree.firstToken(node));
        const last = tree.lastToken(node);
        const operand_end = tree.tokenToSpan(last).end;
        const outer_token = tree.nodeMainToken(parent);
        const inner_token = tree.nodeMainToken(node);
        const at = tree.tokenToSpan(inner_token);
        const message = try self.allocator.print("'{s}' and '{s}' meet without parentheses, which Zig 0.18 refuses as ambiguous; parenthesize the operand", .{ tree.tokenSlice(outer_token), tree.tokenSlice(inner_token) });
        const edits = try self.allocator.dupe(Report.Edit, &.{ .{ .start = operand_start, .end = operand_start, .text = "(", .nests = true }, .{ .start = operand_end, .end = operand_end, .text = ")", .nests = true } });
        try self.emitFixed(.Z034, at.start, at.end, message, &.{}, edits);
    }
}

/// Z013: a private `const X = @import("...")` at file or container level whose name its file
/// spells nowhere else. Zig refuses another file a private declaration, so only its own file
/// could use it. Any spelling is a use: an identifier (`@"..."` decoded), a member or a
/// declaration literal `.X` from any holder, and `@field`'s literal name; `@hasDecl` sees no
/// private declaration, so its string is none. A miss is allowed; a report is never wrong. A
/// `@field` whose name is not a string literal may reach any of them, so such a file's reports
/// are withheld.
fn unusedImports(self: *Context) RunError!void {
    if (!self.config.has(.Z013)) return;
    const source = self.project.at(self.file);
    const tree = &source.file.tree;
    const model = &source.model;
    // Each candidate's name, and how often the file spells it, its own name token included.
    var spelled: std.StringHashMapUnmanaged(u32) = .empty;
    var candidates: std.ArrayList(Model.Declaration.Id) = .empty;
    for (model.declarations, 0..) |decl, index| {
        if (decl.kind != .variable or decl.public or decl.exported) continue;
        switch (model.scopes[@backingInt(decl.scope)].kind) {
            .file, .container => {},
            else => continue,
        }
        const full = tree.fullVarDecl(decl.node) orelse continue;
        if (tree.tokenTag(full.ast.mut_token) != .keyword_const) continue;
        const value = Facts.ungrouped(tree, full.ast.init_node.unwrap() orelse continue);
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, value, &buffer);
        if (!Facts.isBuiltin(tree, value, "@import") or args.len != 1 or tree.nodeTag(args[0]) != .string_literal) continue;
        try candidates.append(self.allocator, @fromBackingInt(@intCast(index)));
        try spelled.put(self.allocator, decl.name, 0);
    }
    if (candidates.items.len == 0) return;
    // An identifier is every spelling but `@field`'s: a name, a member, a literal `.X`.
    for (tree.tokens.items(.tag), 0..) |tag, t| {
        if (tag != .identifier) continue;
        const name = try Model.identifier(self.allocator, tree.tokenSlice(@intCast(t)));
        if (spelled.getPtr(name)) |count| count.* += 1;
    }
    for (0..tree.nodes.len) |n| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
        if (!Facts.isBuiltin(tree, node, "@field")) continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        if (args.len != 2) continue;
        const name_node = Facts.ungrouped(tree, args[1]);
        // A computed name may be any candidate's: the file's reports are withheld.
        if (tree.nodeTag(name_node) != .string_literal) return;
        const name = std.zig.string_literal.parseAlloc(self.allocator, tree.tokenSlice(tree.nodeMainToken(name_node))) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // No name is read from it: it may be any.
            error.InvalidLiteral => return,
        };
        if (spelled.getPtr(name)) |count| count.* += 1;
    }
    for (candidates.items) |index| {
        const decl = model.declarations[@backingInt(index)];
        if (spelled.get(decl.name).? <= 1) try self.at(.Z013, decl.token, try self.allocator.print("unused private import '{s}'", .{decl.name}));
    }
}

fn selected(self: *const Context, selection: []const rules.Rule) bool {
    return self.selected(selection);
}
fn unknown(self: *Context, rule: rules.Rule, node: Ast.Node.Index, reason: Facts.Unknown) RunError!void {
    return self.unknown(rule, node, reason);
}

/// Z011: each call by meaning (`Facts.calls`: a direct call, a method's, `@call`, a callee
/// through `@field` or a function pointer) of a deprecated declaration, or through an alias
/// that is one; one whose callee may be any function is undecided.
fn priorityRules(self: *Context) RunError!void {
    if (!self.config.has(.Z011)) return;
    const tree = &self.project.at(self.file).file.tree;
    for (try Facts.calls.in(self.facts, self.file)) |call| {
        const token = if (tree.nodeTag(call.callee_expr) == .field_access) tree.nodeData(call.callee_expr).node_and_token[1] else tree.nodeMainToken(call.callee_expr);
        // An alias that is itself deprecated; one not followed leaves the callee to decide.
        switch (try self.facts.definition(self.file, call.callee_expr)) {
            .decl => |alias| if (deprecated(self, alias)) {
                try self.atDefinition(.Z011, token, "call uses a deprecated declaration", alias);
                continue;
            },
            .none, .unknown => {},
        }
        switch (call.callee) {
            .function => |function| if (deprecated(self, function)) try self.atDefinition(.Z011, token, "call uses a deprecated declaration", function),
            .choice => |each| for (each) |function| if (deprecated(self, function)) {
                try self.atDefinition(.Z011, token, "call uses a deprecated declaration", function);
                break;
            },
            .any => |why| try unknown(self, .Z011, call.callee_expr, why),
        }
    }
}

fn amendedPolicies(self: *Context) RunError!void {
    if (!selected(self, &.{ .Z012, .Z026 })) return;
    const source = self.project.at(self.file);
    const tree = &source.file.tree;
    // Z012 reads the public surface as written: a public function's signature, a public
    // constant's or variable's written type, and a field of a container the surface reaches.
    if (self.config.has(.Z012)) for (source.model.declarations, 0..) |decl, i| {
        if (decl.kind != .field and !decl.public and !decl.exported) continue;
        if (!try self.facts.onSurface(self.file, decl.scope)) continue;
        const signature: Signature = .{ .site = decl.token, .scope = decl.scope };
        switch (decl.kind) {
            .function => {
                var buffer: [1]Ast.Node.Index = undefined;
                try privateSignature(self, signature, self.file, tree.fullFnProto(&buffer, decl.node).?, 0);
            },
            .variable => try publicValue(self, signature, @fromBackingInt(@intCast(i))),
            .field => if (source.model.containerField(tree, decl.node)) |field| {
                if (field.ast.type_expr.unwrap()) |t| try privateType(self, signature, self.file, t, 0);
            },
            .parameter, .capture => {},
        }
    };
    if (self.config.has(.Z026)) for (tree.nodes.items(.tag), 0..) |tag, n| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
        // Each handler of an error: `catch`'s, and an `if`'s or a `while`'s `else |err|`.
        const handler = if (tag == .@"catch")
            tree.nodeData(node).node_and_node[1]
        else if (tree.fullIf(node)) |branch|
            (if (branch.error_token != null) branch.ast.else_expr.unwrap() orelse continue else continue)
        else if (tree.fullWhile(node)) |loop|
            (if (loop.error_token != null) loop.ast.else_expr.unwrap() orelse continue else continue)
        else
            continue;
        var memo: Handled = .empty;
        const root: Walk = .{ .file = self.file, .first = tree.firstToken(handler), .last = tree.lastToken(handler), .memo = &memo };
        const handled = try handling(self, root, handler, try takenOf(self, root, handler), 0);
        if (handled == .acts) continue;
        if (tree.fullIf(node)) |branch| if (try refusalAsserted(self, tree, branch)) continue;
        if (try Discards.dropsNothing(self, node)) continue;
        switch (handled) {
            .acts => unreachable, // unreachable: cleared above
            .discards => try self.at(.Z026, tree.nodeMainToken(node), "an error handler that discards the error; write a reason at this site"),
            .unknown => try self.undecided(.Z026, tree.tokenStart(tree.nodeMainToken(node)), .unsupported, "an error handler of a form not read: whether it does anything with the error is not known"),
        }
    };
}

/// Whether an `if`'s empty error branch is a test's assertion that the call fails: in test code
/// (`RuleContext.inTestCode`: a `test` block, or a file only tests reach), its success branch
/// leaves by an error (`leavesByError`), so the error is the assertion's pass, never discarded.
/// In production code the same shape is how a real failure reads as an answer (a permission
/// error read as "no such file"), and it stays a site; so does a `catch`, and a test's success
/// branch that goes on.
fn refusalAsserted(self: *Context, tree: *const Ast, branch: Ast.full.If) RunError!bool {
    if (!try leavesByError(self, tree, branch.ast.then_expr, 0)) return false;
    return self.inTestCode(branch.payload_token orelse branch.ast.if_token);
}

/// Whether every path through `node` leaves its function by an error: it ends in `return` of an
/// error (`return error.TestUnexpectedResult`) or in `@panic`, and nothing before that leaves or
/// jumps any other way (`break`, `continue`, a `return` of a value). A `try` leaves by an error
/// too, so it may stand anywhere.
fn leavesByError(self: *Context, tree: *const Ast, written: Ast.Node.Index, depth: usize) RunError!bool {
    if (depth == 8) return false;
    const node = Facts.ungrouped(tree, written);
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.blockStatements(&buffer, node)) |statements| {
        if (statements.len == 0) return false;
        for (statements[0 .. statements.len - 1]) |statement| if (try jumpsBut(self, tree, statement)) return false;
        return leavesByError(self, tree, statements[statements.len - 1], depth + 1);
    }
    if (Facts.isBuiltin(tree, node, "@panic")) return true;
    if (tree.nodeTag(node) != .@"return") return false;
    const operand = tree.nodeData(node).opt_node.unwrap() orelse return false;
    return try returnsError(self, operand);
}

/// Whether a `return`'s operand is an error written in place (`error.Name`), by Facts.literalOf.
fn returnsError(self: *Context, operand: Ast.Node.Index) RunError!bool {
    const literal = (try self.facts.literalOf(self.file, operand)) orelse return false;
    return literal == .error_value;
}

/// Whether a statement holds a jump other than a `return` of an error: a `break`, a `continue`,
/// or a `return` of anything else, anywhere inside it.
fn jumpsBut(self: *Context, tree: *const Ast, statement: Ast.Node.Index) RunError!bool {
    const first = tree.firstToken(statement);
    const last = tree.lastToken(statement);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const inner: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(inner);
        if (token < first or token > last) continue;
        switch (tag) {
            .@"break", .@"continue" => return true,
            .@"return" => {
                const operand = tree.nodeData(inner).opt_node.unwrap() orelse return true;
                if (!try returnsError(self, operand)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// What an error's handler does (`handling`). A handler is cleared only where it is read to do
/// something: a form not read is not known, never cleared.
const Handling = enum {
    /// Nothing: an empty block, a discard (`_ = err`), a value of nothing (`{}`, `void{}`), a
    /// value nobody takes, a call of the program's function that does nothing.
    discards,
    /// Something: a jump out of the handler, `unreachable` or `@panic`, a `try`, a store to a
    /// place outside it, a call of a function that does something, one the program does not
    /// hold or one whose callee may be any function (as it may), a value given in the error's
    /// stead.
    acts,
    unknown,
};

/// The functions read while handlers are, each by how its result is taken; one being read is
/// not known.
const Handled = std.AutoHashMapUnmanaged(struct { Facts.Decl, Taken }, Handling);
const HandledKey = @FieldType(Handled.KV, "key");

/// Where a value goes: taken by what holds it, dropped (a statement, `_ = v`, a result nobody
/// takes), or not known.
const Taken = enum { kept, dropped, unknown };

/// The code `handling` reads: the handler, or the body of a function it calls, in `file`, its
/// tokens `first` to `last`, a jump inside which lands in it. In a body, `return v` gives the
/// call's value, taken as `returned`.
const Walk = struct {
    file: Project.FileId,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    body: bool = false,
    returned: Taken = .unknown,
    memo: *Handled,

    fn inside(walk: Walk, tree: *const Ast, node: Ast.Node.Index) bool {
        return tree.firstToken(node) >= walk.first and tree.lastToken(node) <= walk.last;
    }
};

/// Where the value of `node` goes (`Facts.accesses.useOf`), through the forms that carry it on
/// (parentheses, `catch`'s handler, a branch's or a `break`'s value); in a body, a `return`'s
/// goes where the call's does.
fn takenOf(self: *Context, walk: Walk, node: Ast.Node.Index) RunError!Taken {
    var at = node;
    for (0..64) |_| switch (try Facts.accesses.useOf(self.facts, walk.file, at)) {
        .statement, .discarded => return .dropped,
        .carried => |carried| at = carried.into,
        .returned => return if (walk.body) walk.returned else .kept,
        .unknown => return .unknown,
        else => return .kept,
    };
    return .unknown;
}

/// The combination of what parts do, each run on some path: any that acts makes the whole act.
fn joined(a: Handling, b: Handling) Handling {
    if (a == .acts or b == .acts) return .acts;
    if (a == .unknown or b == .unknown) return .unknown;
    return .discards;
}

/// A value read with no effect of its own (a name, a literal, a member, `@errorName(err)`):
/// given in the error's stead where it is taken, nothing where it is dropped.
fn readValue(taken: Taken) Handling {
    return switch (taken) {
        .kept => .acts,
        .dropped => .discards,
        .unknown => .unknown,
    };
}

/// What the code at `written` does where its value is `taken` (`Handling`), by its form.
fn handling(self: *Context, walk: Walk, written: Ast.Node.Index, taken: Taken, depth: usize) RunError!Handling {
    if (depth == 64) return .unknown;
    const tree = &self.project.at(walk.file).file.tree;
    const model = &self.project.at(walk.file).model;
    const node = Facts.ungrouped(tree, written);
    if (try Facts.accesses.discardedBy(self.facts, walk.file, node)) |value| return if (inert(tree, value, 0)) .discards else handling(self, walk, value, .dropped, depth + 1);
    if (try Facts.calls.at(self.facts, walk.file, node)) |call| return calledHandling(self, walk, call, taken, depth + 1);
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.blockStatements(&buffer, node)) |statements| {
        // A labeled block's value is what its `break`s give, read at each.
        var all: Handling = .discards;
        for (statements) |statement| {
            all = joined(all, try handling(self, walk, statement, .dropped, depth + 1));
            if (all == .acts) return .acts;
        }
        return all;
    }
    switch (Facts.accesses.formOf(tree.nodeTag(node))) {
        .@"break", .@"continue" => {
            const target = Facts.accesses.breakTarget(tree, model, node) orelse return .unknown;
            // Out of the handler: the jump is its answer.
            if (!walk.inside(tree, target)) return .acts;
            if (tree.nodeTag(node) == .@"continue") return .unknown;
            const value = tree.nodeData(node).opt_token_and_opt_node[1].unwrap() orelse return .discards;
            return handling(self, walk, value, try takenOf(self, walk, target), depth + 1);
        },
        .@"return" => {
            if (!walk.body) return .acts;
            const value = tree.nodeData(node).opt_node.unwrap() orelse return .discards;
            return handling(self, walk, value, walk.returned, depth + 1);
        },
        .tried, .@"asm" => return .acts,
        .leaf => {
            const token = tree.nodeMainToken(node);
            if (tree.tokenTag(token) == .keyword_unreachable) return .acts;
            // `undefined` in the error's stead is no value given.
            if (tree.tokenTag(token) == .identifier and std.mem.eql(u8, tree.tokenSlice(token), "undefined")) return .discards;
            return readValue(taken);
        },
        .builtin => {
            if (Facts.isBuiltin(tree, node, "@panic") or Facts.isBuiltin(tree, node, "@trap")) return .acts;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (Facts.isBuiltin(tree, node, "@as") and args.len == 2) return handling(self, walk, args[1], taken, depth + 1);
            return if (inert(tree, node, 0)) readValue(taken) else .unknown;
        },
        .@"comptime", .@"nosuspend" => return handling(self, walk, tree.nodeData(node).node, taken, depth + 1),
        .member => return parts(self, walk, &.{tree.nodeData(node).node_and_token[0]}, taken, depth),
        .unwrap_optional => return parts(self, walk, &.{tree.nodeData(node).node_and_token[0]}, taken, depth),
        .address_of, .deref => return parts(self, walk, &.{tree.nodeData(node).node}, taken, depth),
        .comparison, .concatenation, .array_access => return parts(self, walk, &tree.nodeData(node).node_and_node, taken, depth),
        // A prefix operator (`-x`, `!x`) is written before its one operand.
        .operator, .logic => return if (tree.firstToken(node) == tree.nodeMainToken(node))
            parts(self, walk, &.{tree.nodeData(node).node}, taken, depth)
        else
            parts(self, walk, &tree.nodeData(node).node_and_node, taken, depth),
        .struct_literal => {
            const literal = tree.fullStructInit(&buffer, node).?; // unreachable: the form is a struct literal's
            if (literal.ast.fields.len == 0) if (literal.ast.type_expr.unwrap()) |written_type| {
                // `T{}` of `void` is nothing; of another type, a value given.
                const made = try self.facts.resolve(walk.file, written_type);
                var nothing: Facts.Join = .{};
                for (Facts.valueParts(&made)) |part| nothing.add(part, switch (part) {
                    .primitive => |name| std.mem.eql(u8, name, "void"),
                    .unknown, .alternatives => null, // not known; a choice, never a part (valueParts)
                    else => false,
                });
                return switch (taken) {
                    .dropped => .discards,
                    .kept, .unknown => if (nothing.agreed()) |void_type| (if (void_type) .discards else readValue(taken)) else .unknown,
                };
            };
            return parts(self, walk, literal.ast.fields, taken, depth);
        },
        .array_literal => return parts(self, walk, tree.fullArrayInit(&buffer, node).?.ast.elements, taken, depth), // unreachable: the form is an array literal's
        .@"if", .@"switch", .@"while", .@"for", .for_range => return chosenHandling(self, walk, node, taken, depth),
        .@"catch", .@"orelse" => return parts(self, walk, &tree.nodeData(node).node_and_node, taken, depth),
        .variable => {
            const variable = tree.fullVarDecl(node).?; // unreachable: the form is a variable's
            const init = variable.ast.init_node.unwrap() orelse return .discards;
            return handling(self, walk, init, .dropped, depth + 1);
        },
        .deferred => return handling(self, walk, tree.nodeData(node).node, .dropped, depth + 1),
        .assign, .compound_assign => {
            const target, const value = tree.nodeData(node).node_and_node;
            // A store to a variable this code declares, by name, is its own; any other place is
            // outside.
            const declared = (model.reference(target) orelse return .acts).declaration orelse return .acts;
            if (!walk.inside(tree, model.declarations[@backingInt(declared)].node)) return .acts;
            return handling(self, walk, value, .dropped, depth + 1);
        },
        else => return .unknown,
    }
}

/// What a choice or a loop does where its value is `taken`: its condition, operand or inputs
/// read for what they do, each branch, prong or body, and its `else`.
fn chosenHandling(self: *Context, walk: Walk, node: Ast.Node.Index, taken: Taken, depth: usize) RunError!Handling {
    const tree = &self.project.at(walk.file).file.tree;
    switch (Facts.accesses.formOf(tree.nodeTag(node))) {
        .@"if" => {
            const branch = tree.fullIf(node).?; // unreachable: the form is an if's
            var all = try handling(self, walk, branch.ast.cond_expr, .dropped, depth + 1);
            all = joined(all, try handling(self, walk, branch.ast.then_expr, taken, depth + 1));
            if (branch.ast.else_expr.unwrap()) |otherwise| all = joined(all, try handling(self, walk, otherwise, taken, depth + 1));
            return all;
        },
        .@"switch" => {
            const choice = tree.fullSwitch(node).?; // unreachable: the form is a switch's
            var all = try handling(self, walk, choice.ast.condition, .dropped, depth + 1);
            for (choice.ast.cases) |case| {
                all = joined(all, try handling(self, walk, tree.fullSwitchCase(case).?.ast.target_expr, taken, depth + 1)); // unreachable: a switch's cases are prongs
                if (all == .acts) return .acts;
            }
            return all;
        },
        .@"while" => {
            const loop = tree.fullWhile(node).?; // unreachable: the form is a while's
            var all = try handling(self, walk, loop.ast.cond_expr, .dropped, depth + 1);
            if (loop.ast.cont_expr.unwrap()) |next| all = joined(all, try handling(self, walk, next, .dropped, depth + 1));
            all = joined(all, try handling(self, walk, loop.ast.then_expr, .dropped, depth + 1));
            if (loop.ast.else_expr.unwrap()) |otherwise| all = joined(all, try handling(self, walk, otherwise, taken, depth + 1));
            return all;
        },
        .@"for" => {
            const loop = tree.fullFor(node).?; // unreachable: the form is a for's
            var all = try parts(self, walk, loop.ast.inputs, .dropped, depth);
            all = joined(all, try handling(self, walk, loop.ast.then_expr, .dropped, depth + 1));
            if (loop.ast.else_expr.unwrap()) |otherwise| all = joined(all, try handling(self, walk, otherwise, taken, depth + 1));
            return all;
        },
        .for_range => {
            const end = tree.nodeData(node).node_and_opt_node;
            return parts(self, walk, if (end[1].unwrap()) |last| &.{ end[0], last } else &.{end[0]}, .dropped, depth);
        },
        else => return .unknown,
    }
}

/// What the parts of a value (a member's holder, an operator's operands, a literal's fields) do
/// where the value is `taken`: given in the error's stead where it is kept; else what reading
/// them does.
fn parts(self: *Context, walk: Walk, each: []const Ast.Node.Index, taken: Taken, depth: usize) RunError!Handling {
    if (taken == .kept) return .acts;
    var all: Handling = if (taken == .unknown) .unknown else .discards;
    for (each) |part| {
        all = joined(all, try handling(self, walk, part, .dropped, depth + 1));
        if (all == .acts) return .acts;
    }
    return all;
}

/// What a call does where its value is `taken`: its arguments, and the function it calls, read
/// by its body where the program holds it. A function it does not hold does something; so does a
/// call whose callee may be any function, as it may.
fn calledHandling(self: *Context, walk: Walk, call: Facts.calls.Call, taken: Taken, depth: usize) RunError!Handling {
    var all: Handling = .discards;
    switch (call.callee) {
        .function => |function| all = try functionHandling(self, walk, function, taken, depth),
        .choice => |each| for (each) |function| {
            all = joined(all, try functionHandling(self, walk, function, taken, depth));
        },
        .any => return .acts,
    }
    if (all == .acts) return .acts;
    switch (call.args) {
        .known => |args| for (args) |arg| {
            all = joined(all, try handling(self, walk, arg, .dropped, depth + 1));
            if (all == .acts) return .acts;
        },
        .unknown => return .unknown,
    }
    return all;
}

/// What calling `function` does where its result is `taken`: its body's statements, a `return`
/// giving the call's value; read once a handler for each way its result is taken.
fn functionHandling(self: *Context, walk: Walk, function: Facts.Decl, taken: Taken, depth: usize) RunError!Handling {
    const held = self.project.at(function.file);
    const record = held.model.declarations[@backingInt(function.index)];
    if (record.kind != .function or !held.input.selected) return .acts;
    // A function's declaration is its prototype; its body is the `fn_decl` around it.
    const declared = held.model.parentOf(record.node) orelse return .acts;
    if (held.file.tree.nodeTag(declared) != .fn_decl) return .acts;
    const key: HandledKey = .{ function, taken };
    if (walk.memo.get(key)) |known| return known;
    try walk.memo.put(self.allocator, key, .unknown);
    const body = held.file.tree.nodeData(declared).node_and_node[1];
    const inner: Walk = .{ .file = function.file, .first = held.file.tree.firstToken(body), .last = held.file.tree.lastToken(body), .body = true, .returned = taken, .memo = walk.memo };
    const found = try handling(self, inner, body, .dropped, depth + 1);
    try walk.memo.put(self.allocator, key, found);
    return found;
}

/// Whether an expression only reads: a name, a member, a number, or a builtin of them
/// (`@intFromError(err)`, `@errorName(err)`), with no call and no store.
fn inert(tree: *const Ast, written: Ast.Node.Index, depth: usize) bool {
    if (depth == 8) return false;
    const node = Facts.ungrouped(tree, written);
    switch (tree.nodeTag(node)) {
        .identifier, .number_literal, .enum_literal, .string_literal, .char_literal => return true,
        .field_access => return inert(tree, tree.nodeData(node).node_and_token[0], depth + 1),
        .builtin_call_two, .builtin_call_two_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            for ([_][]const u8{ "@intFromError", "@errorName", "@errorCast", "@as" }) |pure| if (std.mem.eql(u8, name, pure)) {
                var buffer: [2]Ast.Node.Index = undefined;
                for (Facts.builtinArgs(tree, node, &buffer)) |arg| if (!inert(tree, arg, depth + 1)) return false;
                return true;
            };
            return false;
        },
        else => return false,
    }
}

/// The scope a container written at `node` opens.
fn scopeOf(model: *const Model, node: Ast.Node.Index) ?Model.Scope.Id {
    for (model.scopes, 0..) |scope, i| if (scope.kind == .container and scope.node == node) return @fromBackingInt(@intCast(i));
    return null;
}

/// The public declaration whose type Z012 reads: where it reports, and the scope it is declared
/// in, whose enclosing containers its callers name it through.
const Signature = struct { site: Ast.TokenIndex, scope: Model.Scope.Id };

/// `signature` reported at the type written at `node`, where `node` is in the checked file: each
/// type a signature exposes is a site of its own (`pub fn f(a: A) B` two), so one suppression
/// covers one of them. A type read in another file is reported where this file wrote what
/// reached it.
fn anchored(self: *const Context, signature: Signature, file: Project.FileId, node: Ast.Node.Index) Signature {
    if (file != self.file) return signature;
    return .{ .site = self.project.at(file).file.tree.firstToken(node), .scope = signature.scope };
}

fn privateSignature(self: *Context, signature: Signature, file: Project.FileId, function: Ast.full.FnProto, depth: usize) RunError!void {
    const tree = &self.project.at(file).file.tree;
    if (function.ast.return_type.unwrap()) |t| try privateType(self, signature, file, t, depth);
    var it = function.iterate(tree);
    while (it.next()) |param| if (param.type_expr) |t| try privateType(self, signature, file, t, depth);
}

/// Z012 over a type written at `node` of `file` in a public signature: each name written in it
/// that resolves to a private container with no public alias. Only the written shape is read:
/// parentheses, `?T`, `E!T`, a pointer's or an array's child, a function prototype and a container
/// written in place. A type reached any other way (a call, a builtin, a comptime choice, an
/// inferred type) is not read; a miss is allowed, a wrong report is not.
fn privateType(self: *Context, given: Signature, file: Project.FileId, written: Ast.Node.Index, depth: usize) RunError!void {
    const signature = anchored(self, given, file, written);
    const tree = &self.project.at(file).file.tree;
    const node = Facts.ungrouped(tree, written);
    // No one writes a type nested this deep; what is past it is not read.
    if (depth >= 128) return;
    if (tree.fullPtrType(node)) |pointer| return privateType(self, signature, file, pointer.ast.child_type, depth + 1);
    if (tree.fullArrayType(node)) |array| return privateType(self, signature, file, array.ast.elem_type, depth + 1);
    var prototype: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&prototype, node)) |function| return privateSignature(self, signature, file, function, depth + 1);
    var members: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&members, node)) |container| {
        // A container written in the signature is named there; its tag type and its fields'
        // types are not. The fields of one the surface reaches are read as its fields.
        if (container.ast.arg.unwrap()) |tag| try privateType(self, signature, file, tag, depth + 1);
        const model = &self.project.at(file).model;
        const scope = scopeOf(model, node) orelse return;
        // A tuple's fields are no declarations: they are read here, reached or not.
        const named = try self.facts.onSurface(file, scope);
        for (container.ast.members) |member| if (model.containerField(tree, member)) |field| {
            if (named and !field.ast.tuple_like) continue;
            if (field.ast.type_expr.unwrap()) |t| try privateType(self, signature, file, t, depth + 1);
        };
        return;
    }
    switch (tree.nodeTag(node)) {
        .identifier, .field_access => {
            const definition = switch (try self.facts.definition(file, node)) {
                .decl => |definition| definition,
                // A primitive, a member no holder declares, a name that does not resolve.
                .none, .unknown => return,
            };
            const held = self.project.at(definition.file);
            const decl = held.model.declarations[@backingInt(definition.index)];
            // A type parameter is the caller's own; a public declaration callers reach is named
            // by its path.
            if (decl.kind == .parameter) return;
            if ((decl.public or decl.exported) and try self.facts.onSurface(definition.file, decl.scope)) return;
            // A type for certain: a constant whose value is a container written in place.
            if (decl.kind != .variable) return;
            const variable = held.file.tree.fullVarDecl(decl.node) orelse return;
            if (held.file.tree.tokenTag(variable.ast.mut_token) != .keyword_const) return;
            const init = Facts.ungrouped(&held.file.tree, variable.ast.init_node.unwrap() orelse return);
            var holds: [2]Ast.Node.Index = undefined;
            if (held.file.tree.fullContainerDecl(&holds, init) == null) return;
            const scope = scopeOf(&held.model, init) orelse return;
            // A container around the signature is named through whatever names the signature,
            // as `@This()` is.
            if (definition.file == self.file and encloses(&held.model, scope, signature.scope)) return;
            if (try self.facts.aliasedOnSurface(definition.file, scope)) return;
            const holder = held.model.privateHolder(scope) orelse return;
            const message = try self.allocator.print("public signature exposes private type '{s}'", .{held.model.declarations[@backingInt(holder)].name});
            try self.atDefinition(.Z012, signature.site, message, .{ .file = definition.file, .index = holder });
        },
        .optional_type => try privateType(self, signature, file, tree.nodeData(node).node, depth + 1),
        .error_union => try privateType(self, signature, file, tree.nodeData(node).node_and_node[1], depth + 1),
        // A call, a builtin, a comptime choice, a labeled block, an error set: not read.
        else => {},
    }
}

/// A public constant's or variable's type as written: its annotation, or a type written in place
/// as its value (`pub const Many = []const Hidden;`). A name as its value is an alias, which is
/// the name callers spell; an inferred type is not read.
fn publicValue(self: *Context, signature: Signature, index: Model.Declaration.Id) RunError!void {
    const source = self.project.at(self.file);
    const decl = source.model.declarations[@backingInt(index)];
    const variable = source.file.tree.fullVarDecl(decl.node) orelse return;
    if (variable.ast.type_node.unwrap()) |t| return privateType(self, signature, self.file, t, 0);
    const init = Facts.ungrouped(&source.file.tree, variable.ast.init_node.unwrap() orelse return);
    if (try self.facts.definition(self.file, init) != .none) return;
    try privateType(self, signature, self.file, init, 0);
}

fn encloses(model: *const Model, outer: Model.Scope.Id, inner: Model.Scope.Id) bool {
    var at: ?Model.Scope.Id = inner;
    while (at) |s| : (at = model.scopes[@backingInt(s)].parent) if (s == outer) return true;
    return false;
}

fn deprecated(self: *const Context, definition: Facts.Decl) bool {
    const tree = &self.project.at(definition.file).file.tree;
    const decl = self.project.at(definition.file).model.declarations[@backingInt(definition.index)];
    var token = tree.firstToken(decl.node);
    while (token > 0) {
        token -= 1;
        if (tree.tokenTag(token) == .keyword_pub) continue;
        if (tree.tokenTag(token) != .doc_comment) break;
        const line = std.mem.trim(u8, tree.tokenSlice(token)[3..], " \t\r");
        if (std.ascii.startsWithIgnoreCase(line, "this function is deprecated")) return true;
        if (std.ascii.startsWithIgnoreCase(line, "deprecated") and (line.len == 10 or std.mem.findScalar(u8, ":;,. ", line[10]) != null)) return true;
    }
    return false;
}

fn lineLength(self: *Context) RunError!void {
    const file = self.project.at(self.file).file;
    if (self.config.has(.Z024)) for (file.lines, 0..) |_, l| {
        const line = file.lineBytes(l);
        if (line.text.len <= self.config.max_line_length) continue;
        const over = std.math.add(u32, line.start, self.config.max_line_length) catch continue;
        const end = std.math.add(u32, line.start, std.math.cast(u32, line.text.len) orelse continue) catch continue;
        try self.emit(.Z024, over, end, "line exceeds configured byte length");
    };
}

fn syntaxRules(self: *Context) RunError!void {
    if (!selected(self, &.{ .Z001, .Z005, .Z006, .Z009, .Z014, .Z031, .Z032 })) return;
    const source = self.project.at(self.file);
    const tree = &source.file.tree;
    const model = &source.model;
    for (model.declarations) |decl| if (decl.kind == .field and decl.scope == model.root()) {
        if (!names.isPascalCase(source.input.stem)) try self.emit(.Z009, 0, 0, "file struct label should use TitleCase; caller owns file naming");
        break;
    };
    for (model.declarations) |decl| {
        if (decl.kind != .variable and decl.kind != .function) continue;
        const name = decl.name;
        if (decl.exported) continue; // An external ABI fixes this spelling.
        if (decl.kind == .function) {
            var buffer: [1]Ast.Node.Index = undefined;
            const function = tree.fullFnProto(&buffer, decl.node).?;
            if (function.extern_export_inline_token) |token| if (tree.tokenTag(token) == .keyword_extern) continue;
        }
        if (names.hasUnderscorePrefix(name)) try self.at(.Z031, decl.token, "use a semantic name instead of an underscore privacy prefix");
        if (decl.kind == .function) {
            var buffer: [1]Ast.Node.Index = undefined;
            const function = tree.fullFnProto(&buffer, decl.node).?;
            const returns_type = if (function.ast.return_type.unwrap()) |t| try namesType(self, self.file, t) else false;
            if (returns_type) {
                if (!names.isPascalCase(name)) try self.at(.Z005, decl.token, "type-producing function should use TitleCase");
            } else if (!names.isValidFunctionName(name)) try self.at(.Z001, decl.token, "callable should use camelCase");
            if (names.acronymIssue(name)) try self.at(.Z032, decl.token, "treat acronyms as ordinary words, for example readXml");
            continue;
        }
        const v = tree.fullVarDecl(decl.node).?;
        if (v.ast.init_node.unwrap()) |expr| {
            if (tree.nodeTag(expr) == .error_set_decl and !names.isPascalCase(name)) try self.at(.Z014, decl.token, "named error set should use TitleCase");
            // Only Z006 needs value-kind facts. Unknown facts are coverage, never spelling guesses.
            if ((self.config.has(.Z006) and !names.isSnakeCase(name)) or (self.config.has(.Z032) and names.acronymIssue(name))) {
                var value = try self.facts.resolve(self.file, expr);
                if (v.ast.type_node.unwrap()) |type_node| {
                    const declared_type = try self.facts.resolve(self.file, type_node);
                    if (declared_type == .unknown) {
                        value = declared_type;
                    } else if (!(declared_type == .primitive and std.mem.eql(u8, declared_type.primitive, "type")) and value != .function) {
                        // A non-metatype annotation describes a value, including primitive-typed constants.
                        value = .scalar;
                    }
                }
                // A choice between types names a type; any other choice is undecided here.
                if (value == .alternatives) value = for (value.alternatives) |one| switch (one) {
                    .container, .primitive, .error_set, .pointer, .array, .optional, .error_union, .fn_type => {},
                    .alternatives => unreachable, // unreachable: choose never nests alternatives
                    else => break .{ .unknown = .unsupported },
                } else value.alternatives[0];
                switch (value) {
                    // A parameter declared `type` is a type whatever each binding gives it.
                    .unknown => |reason| if (try typeParameter(self, expr)) {
                        if (names.acronymIssue(name)) try self.at(.Z032, decl.token, "treat acronyms in type names as ordinary words, for example XmlParser");
                    } else {
                        try unknown(self, .Z006, expr, reason);
                        if (names.acronymIssue(name)) try unknown(self, .Z032, expr, reason);
                    },
                    .container, .primitive, .error_set, .pointer, .array, .optional, .error_union, .fn_type => {
                        if (names.acronymIssue(name)) try self.at(.Z032, decl.token, "treat acronyms in type names as ordinary words, for example XmlParser");
                    },
                    // A type built from field types names a type; a value of one is a value.
                    .reified => |built| if (!built.value) {
                        if (names.acronymIssue(name)) try self.at(.Z032, decl.token, "treat acronyms in type names as ordinary words, for example XmlParser");
                    } else if (!try interfaceName(self, decl, name)) try self.at(.Z006, decl.token, "value binding should use snake_case"),
                    .alternatives => unreachable, // unreachable: a choice is read as one of its parts above
                    .function => |definition| {
                        const target = &self.project.at(definition.file).file.tree;
                        const record = self.project.at(definition.file).model.declarations[@backingInt(definition.index)];
                        var buffer: [1]Ast.Node.Index = undefined;
                        const function = target.fullFnProto(&buffer, record.node).?;
                        if (std.mem.eql(u8, name, record.name)) {
                            if (record.exported) continue;
                            if (function.extern_export_inline_token) |token| if (target.tokenTag(token) == .keyword_extern) continue;
                        }
                        if (names.acronymIssue(name)) try self.at(.Z032, decl.token, "treat acronyms in callable aliases as ordinary words, for example readXml");
                        const returns_type = if (function.ast.return_type.unwrap()) |t| try namesType(self, definition.file, t) else false;
                        if (returns_type) {
                            if (!names.isPascalCase(name)) try self.at(.Z006, decl.token, "type-producing callable alias should use TitleCase");
                        } else if (!names.isValidFunctionName(name)) try self.at(.Z006, decl.token, "callable alias should use camelCase");
                    },
                    else => if (!try interfaceName(self, decl, name)) try self.at(.Z006, decl.token, "value binding should use snake_case"),
                }
            }
        }
    }
}

/// Whether a container's declaration `name` spells a member a generic reads on its type
/// parameter (`Point.identityElement` of a `comptime Point: type`) that a type outside the
/// selected sources (std's, a dependency's) also declares in public: the generic takes both,
/// so the outside type fixes the spelling.
fn interfaceName(self: *Context, decl: Model.Declaration, name: []const u8) RunError!bool {
    const model = &self.project.at(self.file).model;
    if (model.scopes[@backingInt(decl.scope)].kind != .container and model.scopes[@backingInt(decl.scope)].kind != .file) return false;
    if (!try genericReads(self, name)) return false;
    for (self.project.sources) |*each| {
        const file = each.file;
        const other = &each.model;
        const input = each.input;
        if (input.selected or file.status != .parsed) continue;
        for (other.declarations) |d| {
            if (!d.public or !std.mem.eql(u8, d.name, name)) continue;
            if (other.scopes[@backingInt(d.scope)].kind == .container or other.scopes[@backingInt(d.scope)].kind == .file) return true;
        }
    }
    return false;
}

/// Whether `node` names a parameter whose declared type is the type `type` (`comptime R: type`,
/// or through an alias of it), by the declaration the name refers to: every binding gives it a
/// type. `anytype` (its declaration's node the prototype) is not one.
fn typeParameter(self: *Context, node: Ast.Node.Index) RunError!bool {
    const named = switch (try self.facts.definition(self.file, node)) {
        .decl => |decl| decl,
        .none, .unknown => return false,
    };
    const decl = self.project.at(named.file).model.declarations[@backingInt(named.index)];
    if (decl.kind != .parameter) return false;
    return namesType(self, named.file, decl.node);
}

/// Whether `node` of `file` is the type `type`, by what it resolves to (an alias of it too).
fn namesType(self: *Context, file: Project.FileId, node: Ast.Node.Index) RunError!bool {
    const value = try self.facts.resolve(file, node);
    var each: Facts.Join = .{};
    for (Facts.valueParts(&value)) |part| each.add(part, switch (part) {
        .primitive => |name| std.mem.eql(u8, name, "type"),
        .alternatives => unreachable, // unreachable: valueParts gives no choice as a part
        else => false,
    });
    // The type `type` only where every build's is.
    return each.agreed() == true;
}

/// Whether a selected file reads `T.name` where `T` is a parameter that takes a type: declared
/// `type` (comptime by necessity) or `anytype`.
fn genericReads(self: *Context, name: []const u8) RunError!bool {
    for (self.project.sources) |*each| {
        const file = each.file;
        const model = &each.model;
        const input = each.input;
        if (!input.selected or file.status != .parsed) continue;
        const tree = &file.tree;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .field_access) continue;
            const data = tree.nodeData(@fromBackingInt(@intCast(i))).node_and_token;
            if (!std.mem.eql(u8, tree.tokenSlice(data[1]), name)) continue;
            const holder = switch (try self.facts.definition(each.id, data[0])) {
                .decl => |decl| decl,
                .none, .unknown => continue,
            };
            if (holder.file != each.id) continue;
            const parameter = model.declarations[@backingInt(holder.index)];
            if (parameter.kind != .parameter) continue;
            // `anytype` has no type expression of its own: the parameter's node is the keyword.
            if (tree.tokenTag(parameter.token + 2) == .keyword_anytype or try namesType(self, each.id, parameter.node)) return true;
        }
    }
    return false;
}

/// Z016: each call by meaning (`Facts.calls`) that resolves to std's `debug.assert` and whose
/// first argument, as written, is a conjunction (`a and b`, through parentheses and `comptime`:
/// `Model.conditionOf`). Nothing is followed: a conjunction a name, a block or a builtin gives is
/// not read. A callee or argument list not known is silent.
fn contextRules(self: *Context) RunError!void {
    if (!self.config.has(.Z016)) return;
    const tree = &self.project.at(self.file).file.tree;
    for (try Facts.calls.in(self.facts, self.file)) |call| {
        const args = switch (call.args) {
            .known => |args| args,
            .unknown => continue,
        };
        const written = if (call.receiver == .bound) args[@min(args.len, 1)..] else args;
        if (written.len == 0 or Model.conditionOf(tree, written[0]) != .both) continue;
        if (try Governed.mayCallStd(self, call.node, "debug.assert") == .yes) try self.at(.Z016, tree.nodeMainToken(call.node), "the assertion's argument is written `a and b`: consider separate assertions only when evaluation and short circuit effects are preserved");
    }
}

fn unknownCoverage(self: *Context) RunError!void {
    const tree = &self.project.at(self.file).file.tree;
    for (self.project.at(self.file).model.import_nodes) |node| {
        var b: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &b);
        if (args.len != 1 or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) continue;
        const value = try self.facts.resolve(self.file, node);
        // Zig's own per-build file is no file glint lacks: what is read of it stays unknown
        // where it is read.
        if (value == .unknown and value.unknown != .zig_own) try self.sink.coverage(self.sink, .{ .file = self.file, .start = tree.tokenStart(tree.nodeMainToken(node)), .reason = .unresolved, .detail = @tagName(value.unknown) });
    }
}

/// P005: each call by meaning (`Facts.calls`) of std's `debug.print`, wherever the file reaches
/// it from (std imported here, or through another file's alias); a call of a choice one of
/// which is it is one; one whose callee may be any function is undecided.
fn sourcePolicies(self: *Context) RunError!void {
    if (!self.config.has(.P005)) return;
    const tree = &self.project.at(self.file).file.tree;
    for (try Facts.calls.in(self.facts, self.file)) |call| {
        const token = tree.nodeMainToken(call.node);
        if (self.inTest(token)) continue;
        switch (try Governed.mayCallStd(self, call.node, "debug.print")) {
            .no => {},
            .yes => try self.at(.P005, token, "production debug print; use the project's output/logging contract"),
            .unknown => |why| try self.unknown(.P005, call.callee_expr, why),
        }
    }
}
fn functionLengths(self: *Context) RunError!void {
    if (!self.config.has(.P003)) return;
    const file = self.project.at(self.file).file;
    const tree = &file.tree;
    const used = try self.allocator.alloc(bool, self.config.function_exceptions.len);
    @memset(used, false);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .fn_decl) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Ast.Node.Index = undefined;
        const function = tree.fullFnProto(&buffer, node).?;
        const name = tree.tokenSlice(function.name_token orelse continue);
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        var count = file.line(tree.tokenStart(last)) - file.line(tree.tokenStart(first)) + 1;
        const ret = function.ast.return_type.unwrap();
        if (ret != null and try namesType(self, self.file, ret.?)) {
            var widest: u32 = 0;
            var container_buffer: [2]Ast.Node.Index = undefined;
            for (0..tree.nodes.len) |j| {
                const inner: Ast.Node.Index = @fromBackingInt(@intCast(j));
                if (tree.fullContainerDecl(&container_buffer, inner) == null) continue;
                const from = tree.firstToken(inner);
                const to = tree.lastToken(inner);
                if (from >= first and to <= last) widest = @max(widest, file.line(tree.tokenStart(to)) - file.line(tree.tokenStart(from)));
            }
            count -= widest;
        }
        var limit = self.config.max_function_lines;
        for (self.config.function_exceptions, 0..) |exception, j| if (std.mem.eql(u8, exception.function, name)) {
            used[j] = true;
            limit = exception.lines;
        };
        if (count > limit) try self.at(.P003, function.name_token.?, try self.allocator.print("function has {d} lines (configured limit {d}); returned type body is subtracted", .{ count, limit }));
    }
    for (used) |hit| if (!hit) try self.undecided(.P003, 0, .unsupported, "stale function-length exception does not match a function");
}
