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

fn unusedImports(self: *Context) RunError!void {
    if (!self.config.has(.Z013)) return;
    const source = self.project.at(self.file);
    const tree = &source.file.tree;
    const model = &source.model;
    const declarations = model.declarations;
    var indexes: std.ArrayList(Model.Declaration.Id) = .empty;
    for (declarations, 0..) |decl, index| {
        if (decl.kind != .variable or decl.public or decl.exported or decl.references != 0) continue;
        const value = tree.fullVarDecl(decl.node).?.ast.init_node.unwrap() orelse continue;
        // An `@import` written there is one, whatever module it names; any other value is one
        // by meaning: what it holds is another file's root, however it is reached (an alias of
        // one, a type function or `@as` given one, a block's `break`), or a choice of such
        // roots (one per target). One that does not resolve, or a choice of a root and
        // something else, is undecided.
        var buffer: [2]Ast.Node.Index = undefined;
        const written = Facts.builtinArgs(tree, value, &buffer).len == 1 and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "@import");
        if (!written) switch (importOf(self, try self.facts.declaration(.{ .file = self.file, .index = @fromBackingInt(@intCast(index)) }))) {
            .yes => {},
            .no => continue,
            .unknown => |why| {
                try unknown(self, .Z013, decl.node, why);
                continue;
            },
        };
        try indexes.append(self.allocator, @fromBackingInt(@intCast(index)));
    }
    if (indexes.items.len == 0) return;
    var used: Used = .empty;
    var undecided: Used = .empty;
    // One pass for all candidates: a member reaches a candidate only as Zig's lookup in the
    // candidate's own container finds it by that name; what it resolves to decides the use.
    for (tree.nodes.items(.tag), 0..) |tag, n| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
        if (tag != .field_access) {
            try reflectedImport(self, node, indexes.items, &used, &undecided);
            continue;
        }
        const pair = tree.nodeData(node).node_and_token;
        const name = try Model.identifier(self.allocator, tree.tokenSlice(pair[1]));
        if (!namedBy(model, indexes.items, name)) continue;
        switch (try self.facts.definition(self.file, node)) {
            .decl => |definition| if (definition.file == self.file) try used.put(self.allocator, definition.index, {}),
            // A member its holder does not declare, or of a number: no import of this file.
            .none => {},
            .unknown => |why| {
                try unknown(self, .Z013, node, why);
                try markNamed(self, model, indexes.items, name, &undecided);
            },
        }
    }
    for (indexes.items) |index| {
        const decl = declarations[@backingInt(index)];
        if (!used.contains(index) and !undecided.contains(index)) try self.at(.Z013, decl.token, try self.allocator.print("unused private import '{s}'", .{decl.name}));
    }
}

/// Whether candidate `index` is the one its own container declares under `name`, as Zig's
/// member lookup finds it (`Model.Scope.names`).
fn declaresAs(model: *const Model, index: Model.Declaration.Id, name: []const u8) bool {
    const scope = model.declarations[@backingInt(index)].scope;
    return model.scopes[@backingInt(scope)].names.get(name) == index;
}

/// Whether a member spelled `name` may be one of the candidates.
fn namedBy(model: *const Model, indexes: []const Model.Declaration.Id, name: []const u8) bool {
    for (indexes) |index| if (declaresAs(model, index, name)) return true;
    return false;
}

/// Puts in `into` every candidate a member spelled `name` may be.
fn markNamed(self: *Context, model: *const Model, indexes: []const Model.Declaration.Id, name: []const u8, into: *Used) RunError!void {
    for (indexes) |index| if (declaresAs(model, index, name)) try into.put(self.allocator, index, {});
}

/// Whether `value` is another file's root, or a choice of nothing but such roots.
fn importOf(self: *const Context, value: Facts.Value) Governed.Is {
    switch (value) {
        .container => |container| return if (container.file != self.file and self.project.at(container.file).model.scopes[@backingInt(container.scope)].kind == .file) .yes else .no,
        .unknown => |why| return .{ .unknown = why },
        .alternatives => |each| {
            var roots: usize = 0;
            for (each) |one| switch (importOf(self, one)) {
                .yes => roots += 1,
                .no => {},
                .unknown => |why| return .{ .unknown = why },
            };
            if (roots == 0) return .no;
            return if (roots == each.len) .yes else .{ .unknown = .comptime_dependent };
        },
        else => return .no,
    }
}

/// The candidate imports a selected file names.
const Used = std.AutoHashMapUnmanaged(Model.Declaration.Id, void);

fn reflectedImport(self: *Context, node: Ast.Node.Index, indexes: []const Model.Declaration.Id, used: *Used, undecided: *Used) RunError!void {
    const tree = &self.project.at(self.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len != 2) return;
    // `@field` reads a private declaration of its own file; `@hasDecl` sees none, even of
    // its own file, so it never uses a private import.
    if (!Facts.isBuiltin(tree, node, "@field")) return;
    // The one name it spells; any other is read by its holder below.
    const name: ?[]const u8 = switch (try self.facts.fieldName(self.file, args[1])) {
        .name => |one| one,
        .each_of, .names, .computed => null,
    };
    const model = &self.project.at(self.file).model;
    if (name) |one| {
        if (!namedBy(model, indexes, one)) return;
        switch (try self.facts.reflected(self.file, node)) {
            .decl => |definition| {
                if (definition.file == self.file) try used.put(self.allocator, definition.index, {});
                return;
            },
            // Read by its holder below.
            .none, .unknown => {},
        }
    }
    const value = try self.facts.resolve(self.file, args[0]);
    const container: ?Facts.Container = switch (value) {
        .container, .instance => |v| v,
        else => null,
    };
    if (container) |known| if (!known.symbolic) {
        // A literal missing member, or a foreign namespace, cannot use this file's import.
        if (name != null or known.file != self.file) return;
    };
    var affected = false;
    for (indexes) |index| {
        const decl = model.declarations[@backingInt(index)];
        if (name) |literal| if (!declaresAs(model, index, literal)) continue;
        if (container) |known| if (!known.symbolic and (known.file != self.file or known.scope != decl.scope)) continue;
        try undecided.put(self.allocator, index, {});
        affected = true;
    }
    if (affected) try unknown(self, .Z013, node, if (value == .unknown) value.unknown else .comptime_dependent);
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
    // Z012 reads the public surface: a public function's signature, a public constant's or
    // variable's type, written or inferred, and a field of a container the surface reaches.
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
        if (!try discards(self, handler, 0)) continue;
        if (tree.fullIf(node)) |branch| if (try refusalAsserted(self, tree, branch)) continue;
        if (try Discards.dropsNothing(self, node)) continue;
        try self.at(.Z026, tree.nodeMainToken(node), "an error handler that discards the error; write a reason at this site");
    };
}

/// Whether an `if`'s empty error branch is a test's assertion that the call fails: in test code
/// (`RuleContext.inTestCode`: a `test` block, or a file only tests reach), its success branch
/// leaves by an error (`leavesByError`), so the error is the assertion's pass, never discarded.
/// In production code the same shape is how a real failure reads as an answer (a permission
/// error read as "no such file"), and it stays a site; so does a `catch`, and a test's success
/// branch that goes on.
fn refusalAsserted(self: *Context, tree: *const Ast, branch: Ast.full.If) RunError!bool {
    if (!leavesByError(tree, branch.ast.then_expr, 0)) return false;
    return self.inTestCode(branch.payload_token orelse branch.ast.if_token);
}

/// Whether every path through `node` leaves its function by an error: it ends in `return` of an
/// error (`return error.TestUnexpectedResult`) or in `@panic`, and nothing before that leaves or
/// jumps any other way (`break`, `continue`, a `return` of a value). A `try` leaves by an error
/// too, so it may stand anywhere.
fn leavesByError(tree: *const Ast, written: Ast.Node.Index, depth: usize) bool {
    if (depth == 8) return false;
    const node = Facts.ungrouped(tree, written);
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.blockStatements(&buffer, node)) |statements| {
        if (statements.len == 0) return false;
        for (statements[0 .. statements.len - 1]) |statement| if (jumpsBut(tree, statement)) return false;
        return leavesByError(tree, statements[statements.len - 1], depth + 1);
    }
    switch (tree.nodeTag(node)) {
        .@"return" => {
            const operand = tree.nodeData(node).opt_node.unwrap() orelse return false;
            return tree.nodeTag(Facts.ungrouped(tree, operand)) == .error_value;
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@panic"),
        else => return false,
    }
}

/// Whether a statement holds a jump other than a `return` of an error: a `break`, a `continue`,
/// or a `return` of anything else, anywhere inside it.
fn jumpsBut(tree: *const Ast, statement: Ast.Node.Index) bool {
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
                if (tree.nodeTag(Facts.ungrouped(tree, operand)) != .error_value) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Whether an error's handler does nothing with it: an empty block, or one whose every
/// statement is a discard (`_ = err`, `_ = @intFromError(err)`), a grouping of one, a `switch`
/// whose every prong is one, or a call of the program's function whose body is empty
/// (`ignore(err)`). A call whose callee may be any function does something, as it may.
fn discards(self: *Context, written: Ast.Node.Index, depth: usize) RunError!bool {
    if (depth == 8) return false;
    const tree = &self.project.at(self.file).file.tree;
    const node = Facts.ungrouped(tree, written);
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.blockStatements(&buffer, node)) |statements| {
        for (statements) |statement| if (!try discards(self, statement, depth + 1)) return false;
        return true;
    }
    if (try Facts.accesses.discardedBy(self.facts, self.file, node)) |value| return inert(tree, value, 0);
    switch (tree.nodeTag(node)) {
        .@"switch", .switch_comma => {
            const whole = tree.fullSwitch(node).?; // unreachable: tagged a switch
            for (whole.ast.cases) |case| if (!try discards(self, tree.fullSwitchCase(case).?.ast.target_expr, depth + 1)) return false; // unreachable: a switch's cases are cases
            return true;
        },
        else => {},
    }
    const call = (try Facts.calls.at(self.facts, self.file, node)) orelse return false;
    const function = switch (call.callee) {
        .function => |function| function,
        .choice, .any => return false,
    };
    const callee_tree = &self.project.at(function.file).file.tree;
    const record = self.project.at(function.file).model.declarations[@backingInt(function.index)];
    if (record.kind != .function or !self.project.at(function.file).input.selected) return false;
    // A function's declaration is its prototype; its body is the `fn_decl` around it.
    const declared = self.project.at(function.file).model.parentOf(record.node) orelse return false;
    if (callee_tree.nodeTag(declared) != .fn_decl) return false;
    var body_buffer: [2]Ast.Node.Index = undefined;
    const body = callee_tree.blockStatements(&body_buffer, callee_tree.nodeData(declared).node_and_node[1]) orelse return false;
    if (body.len != 0) return false;
    const args = switch (call.args) {
        .known => |known| known,
        .unknown => return false,
    };
    for (args) |arg| if (!inert(tree, arg, 0)) return false;
    return true;
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

fn privateSignature(self: *Context, signature: Signature, file: Project.FileId, function: Ast.full.FnProto, depth: usize) RunError!void {
    const tree = &self.project.at(file).file.tree;
    if (function.ast.return_type.unwrap()) |t| try privateType(self, signature, file, t, depth);
    var it = function.iterate(tree);
    while (it.next()) |param| if (param.type_expr) |t| try privateType(self, signature, file, t, depth);
}

/// Z012 over a type written at `node` of `file` in a public signature: each type a caller has to
/// name to use it, read by what it is. A form this does not read leaves the signature undecided.
fn privateType(self: *Context, signature: Signature, file: Project.FileId, written: Ast.Node.Index, depth: usize) RunError!void {
    const tree = &self.project.at(file).file.tree;
    const node = Facts.ungrouped(tree, written);
    if (depth >= 128) return undecidedType(self, signature, file, node, .budget);
    // A parameter, a part of one (`M.Event`) or `@TypeOf` of one: the type the caller gave.
    if (try fromParameter(self, file, node)) return;
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
        const scope = scopeOf(model, node) orelse return undecidedType(self, signature, file, node, .unsupported);
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
            switch (try self.facts.definition(file, node)) {
                .decl => |definition| {
                    const decl = self.project.at(definition.file).model.declarations[@backingInt(definition.index)];
                    // A type parameter is the caller's own; a public declaration callers reach is
                    // named by its path.
                    if (decl.kind == .parameter) return;
                    if ((decl.public or decl.exported) and self.project.at(definition.file).model.surfaceReachable(decl.scope)) return;
                    const value = try self.facts.resolve(file, node);
                    if (value == .unknown) if (initOf(self, definition)) |init| return privateType(self, signature, definition.file, init, depth + 1);
                    return exposedValue(self, signature, file, node, value, depth + 1);
                },
                // A primitive, or a member no holder declares: what it resolves to says.
                .none => {},
                .unknown => |why| return undecidedType(self, signature, file, node, why),
            }
            try exposedValue(self, signature, file, node, try self.facts.resolve(file, node), depth + 1);
        },
        .optional_type => try privateType(self, signature, file, tree.nodeData(node).node, depth + 1),
        .error_union => try privateType(self, signature, file, tree.nodeData(node).node_and_node[1], depth + 1),
        // Error-set policy is not Z012.
        .error_set_decl, .merge_error_sets => {},
        // A type function's call is named by its callee and its arguments, whatever it makes.
        .call, .call_comma, .call_one, .call_one_comma => try writtenCall(self, signature, file, node, depth + 1, false),
        // A comptime choice is one of its branches: each is read.
        .@"if", .if_simple, .@"switch", .switch_comma => try eachBranch(self, signature, file, node, depth + 1),
        // A builtin or a comptime choice: the type it gives.
        else => try exposedValue(self, signature, file, node, try self.facts.resolve(file, node), depth + 1),
    }
}

/// Z012 over each type a comptime choice written at `node` may give: an `if`'s branches, a
/// `switch`'s prongs.
fn eachBranch(self: *Context, signature: Signature, file: Project.FileId, node: Ast.Node.Index, depth: usize) RunError!void {
    const tree = &self.project.at(file).file.tree;
    if (tree.fullIf(node)) |branch| {
        try chosen(self, signature, file, branch.ast.then_expr, depth);
        if (branch.ast.else_expr.unwrap()) |other| try chosen(self, signature, file, other, depth);
        return;
    }
    const choice = tree.fullSwitch(node) orelse return undecidedType(self, signature, file, node, .unsupported);
    for (choice.ast.cases) |case| try chosen(self, signature, file, tree.fullSwitchCase(case).?.ast.target_expr, depth);
}

/// One branch of a comptime choice: a type is read as written, a value by its type
/// (`if (builtin.is_test) u8 else Hidden{ .x = 1 }` gives a Hidden in every other build).
fn chosen(self: *Context, signature: Signature, file: Project.FileId, node: Ast.Node.Index, depth: usize) RunError!void {
    const value = try self.facts.resolve(file, node);
    if (value == .unknown or isType(value)) return privateType(self, signature, file, node, depth);
    try exposedInferred(self, signature, file, node, value, depth, false);
}

/// Z012 over a type `node` of `file` resolves to: the containers a caller has to name to use it.
fn exposedValue(self: *Context, signature: Signature, file: Project.FileId, node: Ast.Node.Index, value: Facts.Value, depth: usize) RunError!void {
    if (depth >= 128) return undecidedType(self, signature, file, node, .budget);
    switch (value) {
        .unknown => |why| try undecidedType(self, signature, file, node, why),
        // A primitive alias can be named as the primitive; error-set policy is not Z012.
        .primitive, .scalar, .error_set => {},
        .pointer => |inner| try exposedValue(self, signature, file, node, inner.child.*, depth + 1),
        .array, .optional, .error_union => |inner| try exposedValue(self, signature, file, node, inner.*, depth + 1),
        .alternatives => |each| for (each) |one| try exposedValue(self, signature, file, node, one, depth + 1),
        .fn_type => |key| {
            var prototype: [1]Ast.Node.Index = undefined;
            const function = self.project.at(key.file).file.tree.fullFnProto(&prototype, key.node) orelse return undecidedType(self, signature, file, node, .unsupported);
            try privateSignature(self, signature, key.file, function, depth + 1);
        },
        .container => |container| try exposedContainer(self, signature, file, node, container, depth + 1),
        .instance, .function, .literal, .reflected, .reified => try undecidedType(self, signature, file, node, .unsupported),
    }
}

fn exposedContainer(self: *Context, signature: Signature, file: Project.FileId, node: Ast.Node.Index, container: Facts.Container, depth: usize) RunError!void {
    const model = &self.project.at(container.file).model;
    // A container around the function is named through whatever names the function, as
    // `@This()` is.
    if (container.file == self.file and encloses(model, container.scope, signature.scope)) return;
    if (container.made_by) |made| {
        // A made container is named by its type function's call: the function and each argument.
        const maker = self.project.at(made.function.file).model.declarations[@backingInt(made.function.index)];
        if (!(maker.public or maker.exported) or !self.project.at(made.function.file).model.surfaceReachable(maker.scope))
            return self.atDefinition(.Z012, signature.site, try self.allocator.print("public signature exposes private type function '{s}'", .{maker.name}), made.function);
        var buffer: [1]Ast.Node.Index = undefined;
        const call = self.project.at(made.file).file.tree.fullCall(&buffer, made.call) orelse return undecidedType(self, signature, file, node, .unsupported);
        for (call.ast.params) |argument| try exposedArgument(self, signature, made.file, argument, depth + 1, false);
        return;
    }
    if (container.symbolic) return undecidedType(self, signature, file, node, .comptime_dependent);
    const holder = model.privateHolder(container.scope) orelse return;
    if (try self.facts.aliasedOnSurface(container.file, container.scope)) return;
    const decl = model.declarations[@backingInt(holder)];
    const message = if (decl.kind == .function)
        try self.allocator.print("public signature exposes a type private function '{s}' writes", .{decl.name})
    else
        try self.allocator.print("public signature exposes private type '{s}'", .{decl.name});
    try self.atDefinition(.Z012, signature.site, message, .{ .file = container.file, .index = holder });
}

/// A call written where a caller has to name what it gives (a type function's, or a function's
/// whose result a public constant holds): named by its callee and its arguments, whatever it
/// makes.
/// `held` as for `exposedArgument`: the call is inside one a public constant holds.
fn writtenCall(self: *Context, signature: Signature, file: Project.FileId, node: Ast.Node.Index, depth: usize, held: bool) RunError!void {
    const tree = &self.project.at(file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node).?;
    if (!try fromParameter(self, file, call.ast.fn_expr)) switch (try self.facts.definition(file, call.ast.fn_expr)) {
        .decl => |definition| try namedDeclaration(self, signature, definition),
        .none => try exposedValue(self, signature, file, call.ast.fn_expr, try self.facts.resolve(file, call.ast.fn_expr), depth + 1),
        .unknown => |why| try undecidedType(self, signature, file, call.ast.fn_expr, why),
    };
    for (call.ast.params) |argument| try exposedArgument(self, signature, file, argument, depth + 1, held);
}

/// A type function's argument: a type a caller names, or a value, named by its declaration
/// (`Wrap(helper)`, `Gen(config)`) or written in the call. `held`: the call is what a public
/// constant holds (`pub const File = OwnedIo(Io.File, closeFile)`), so the constant is the name a
/// user spells and a value argument is read by its type, what of it comes back through the result;
/// a call written in a signature cannot be spelled where a value it takes is private.
fn exposedArgument(self: *Context, signature: Signature, file: Project.FileId, node: Ast.Node.Index, depth: usize, held: bool) RunError!void {
    if (depth >= 128) return undecidedType(self, signature, file, node, .budget);
    const tree = &self.project.at(file).file.tree;
    if (selfNamed(tree, node) or try fromParameter(self, file, node)) return;
    switch (tree.nodeTag(node)) {
        .call, .call_comma, .call_one, .call_one_comma => return writtenCall(self, signature, file, node, depth + 1, held),
        .identifier, .field_access => switch (try self.facts.definition(file, node)) {
            .decl => |definition| {
                const value = try self.facts.resolve(file, node);
                // A type is named by what it is; a value by its declaration, or, in a call a public
                // constant holds, by its type.
                if (isType(value) and value != .unknown) return exposedValue(self, signature, file, node, value, depth + 1);
                if (value == .unknown) {
                    if (initOf(self, definition)) |init| return exposedArgument(self, signature, definition.file, init, depth + 1, held);
                    return namedDeclaration(self, signature, definition);
                }
                if (held) return exposedInferred(self, signature, file, node, value, depth + 1, true);
                return namedDeclaration(self, signature, definition);
            },
            .none => {},
            .unknown => |why| return undecidedType(self, signature, file, node, why),
        },
        else => {},
    }
    const value = try self.facts.resolve(file, node);
    if (isType(value)) return exposedValue(self, signature, file, node, value, depth + 1);
    try exposedInferred(self, signature, file, node, value, depth + 1, held);
}

/// Whether `node` is a literal its own text names: a number, a string, a character, an enum
/// literal, `true`, `null`.
fn selfNamed(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .number_literal, .string_literal, .multiline_string_literal, .char_literal, .enum_literal => true,
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            return std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false") or std.mem.eql(u8, name, "null") or std.mem.eql(u8, name, "undefined");
        },
        else => false,
    };
}

/// Whether a value `resolve` gives is a type, not a value of one.
fn isType(value: Facts.Value) bool {
    return switch (value) {
        .container, .primitive, .error_set, .fn_type, .unknown => true,
        .instance, .scalar, .literal, .function, .reflected => false,
        .reified => |reified| !reified.value,
        .pointer => |inner| isType(inner.child.*),
        .array, .optional, .error_union => |inner| isType(inner.*),
        .alternatives => |each| each.len != 0 and isType(each[0]),
    };
}

/// A declaration a caller has to name: a parameter is the caller's own; any other is named by
/// its path only where it is public and the surface reaches it.
fn namedDeclaration(self: *Context, signature: Signature, definition: Facts.Decl) RunError!void {
    const model = &self.project.at(definition.file).model;
    const decl = model.declarations[@backingInt(definition.index)];
    if (decl.kind == .parameter) return;
    if ((decl.public or decl.exported) and model.surfaceReachable(decl.scope)) return;
    try self.atDefinition(.Z012, signature.site, try self.allocator.print("public signature names private declaration '{s}'", .{decl.name}), definition);
}

/// A public constant's or variable's type: the type written, or the type of its value.
fn publicValue(self: *Context, signature: Signature, index: Model.Declaration.Id) RunError!void {
    const source = self.project.at(self.file);
    const decl = source.model.declarations[@backingInt(index)];
    const variable = source.file.tree.fullVarDecl(decl.node) orelse return;
    if (variable.ast.type_node.unwrap()) |t| return privateType(self, signature, self.file, t, 0);
    const init = variable.ast.init_node.unwrap() orelse return;
    // A part of a parameter (a generic's `h.n`) has the type the caller gave it.
    if (try fromParameter(self, self.file, init)) return;
    // A choice is one of its branches, each a type or a value of one.
    switch (source.file.tree.nodeTag(init)) {
        .@"if", .if_simple, .@"switch", .switch_comma => return eachBranch(self, signature, self.file, init, 0),
        else => {},
    }
    const value = try self.facts.declaration(.{ .file = self.file, .index = index });
    // A public constant holding a type is a name for it: what the type is written as is read
    // (a slice or a function type of a private type, a tuple's fields, a type function's
    // arguments), and a container it names is reached through it.
    if (value != .unknown and isType(value)) {
        // A type function's call it holds is named by the constant: its callee is no part of the
        // surface (`pub const Step = StepOf(u8);`), its arguments are.
        var made: [1]Ast.Node.Index = undefined;
        if (source.file.tree.fullCall(&made, Facts.ungrouped(&source.file.tree, init))) |call| {
            for (call.ast.params) |argument| try exposedArgument(self, signature, self.file, argument, 1, true);
            return;
        }
        return privateType(self, signature, self.file, init, 0);
    }
    if (value == .unknown) {
        // What a call gives is of the type its callee declares it returns.
        var buffer: [1]Ast.Node.Index = undefined;
        const call = source.file.tree.fullCall(&buffer, init) orelse return exposedInferred(self, signature, self.file, init, value, 0, false);
        const callee = switch (try self.facts.definition(self.file, call.ast.fn_expr)) {
            .decl => |callee| callee,
            .none => return exposedInferred(self, signature, self.file, init, value, 0, false),
            .unknown => |why| return undecidedType(self, signature, self.file, call.ast.fn_expr, why),
        };
        const callee_source = self.project.at(callee.file);
        var prototype: [1]Ast.Node.Index = undefined;
        const function = callee_source.file.tree.fullFnProto(&prototype, callee_source.model.declarations[@backingInt(callee.index)].node) orelse return exposedInferred(self, signature, self.file, init, value, 0, false);
        const result = function.ast.return_type.unwrap() orelse return;
        // A type function's call is a type: the constant names it.
        if (try namesType(self, callee.file, result)) return;
        return privateType(self, signature, callee.file, result, 0);
    }
    try exposedInferred(self, signature, self.file, init, value, 0, false);
}

/// What a constant is written as, for an alias whose value does not resolve: `const Repr =
/// Backing(T)` names what `Backing(T)` does.
fn initOf(self: *Context, definition: Facts.Decl) ?Ast.Node.Index {
    const source = self.project.at(definition.file);
    const decl = source.model.declarations[@backingInt(definition.index)];
    if (decl.kind != .variable) return null;
    const variable = source.file.tree.fullVarDecl(decl.node) orelse return null;
    if (source.file.tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
    return variable.ast.init_node.unwrap();
}

/// Whether `node` reads a parameter or a field of one, as `h` or `h.n`.
fn fromParameter(self: *Context, file: Project.FileId, node: Ast.Node.Index) RunError!bool {
    const tree = &self.project.at(file).file.tree;
    var at = node;
    while (true) {
        const path = try Facts.accesses.pathOf(self.facts, file, at);
        for (path.steps) |step| if (step.kind != .field and step.kind != .root) return false;
        switch (path.root) {
            .decl => |definition| return self.project.at(definition.file).model.declarations[@backingInt(definition.index)].kind == .parameter,
            .unknown => return false,
            .none => {},
        }
        // `@TypeOf(x)` of a parameter is the type the caller gave.
        const root = path.steps[path.steps.len - 1].node;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, root, &buffer);
        if (args.len != 1 or !Facts.isBuiltin(tree, root, "@TypeOf")) return false;
        at = args[0];
    }
}

/// The types a value exposes: an instance's container, a function's signature, a literal's
/// fields' values. A type held is named by the declaration holding it.
/// `held` as for `exposedArgument`: a literal's fields are read as the call holding it reads its
/// arguments.
fn exposedInferred(self: *Context, signature: Signature, file: Project.FileId, node: Ast.Node.Index, value: Facts.Value, depth: usize, held: bool) RunError!void {
    if (depth >= 128) return undecidedType(self, signature, file, node, .budget);
    switch (value) {
        .unknown => |why| try undecidedType(self, signature, file, node, why),
        .container, .primitive, .error_set, .fn_type, .scalar => {},
        .instance => |container| try exposedContainer(self, signature, file, node, container, depth + 1),
        .pointer => |inner| try exposedInferred(self, signature, file, node, inner.child.*, depth + 1, held),
        .array, .optional, .error_union => |inner| try exposedInferred(self, signature, file, node, inner.*, depth + 1, held),
        .alternatives => |each| for (each) |one| try exposedInferred(self, signature, file, node, one, depth + 1, held),
        .function => |function| {
            // An alias of a function: its signature, named through the alias.
            const model = &self.project.at(function.file).model;
            const decl = model.declarations[@backingInt(function.index)];
            if ((decl.public or decl.exported) and model.surfaceReachable(decl.scope)) return;
            var prototype: [1]Ast.Node.Index = undefined;
            const proto = self.project.at(function.file).file.tree.fullFnProto(&prototype, decl.node) orelse return undecidedType(self, signature, file, node, .unsupported);
            try privateSignature(self, signature, function.file, proto, depth + 1);
        },
        .literal => |key| {
            const tree = &self.project.at(key.file).file.tree;
            var buffer: [2]Ast.Node.Index = undefined;
            const init = tree.fullStructInit(&buffer, key.node) orelse return undecidedType(self, signature, file, node, .unsupported);
            for (init.ast.fields) |field| try exposedArgument(self, signature, key.file, field, depth + 1, held);
        },
        .reified => |reified| if (reified.value) try undecidedType(self, signature, file, node, .unsupported),
        .reflected => try undecidedType(self, signature, file, node, .unsupported),
    }
}

fn encloses(model: *const Model, outer: Model.Scope.Id, inner: Model.Scope.Id) bool {
    var at: ?Model.Scope.Id = inner;
    while (at) |s| : (at = model.scopes[@backingInt(s)].parent) if (s == outer) return true;
    return false;
}

/// An undecided Z012: at the node when it is in the file checked, else at the signature.
fn undecidedType(self: *Context, signature: Signature, file: Project.FileId, node: Ast.Node.Index, why: Facts.Unknown) RunError!void {
    if (file == self.file) return unknown(self, .Z012, node, why);
    const tree = &self.project.at(self.file).file.tree;
    try self.undecided(.Z012, tree.tokenStart(signature.site), if (why == .budget) .budget_exhausted else .unresolved, @tagName(why));
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
                    else => break .{ .unknown = .unsupported },
                } else value.alternatives[0];
                switch (value) {
                    .unknown => |reason| {
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

/// Whether `node` of `file` is the type `type`, by what it resolves to (an alias of it too).
fn namesType(self: *Context, file: Project.FileId, node: Ast.Node.Index) RunError!bool {
    return switch (try self.facts.resolve(file, node)) {
        .primitive => |name| std.mem.eql(u8, name, "type"),
        else => false,
    };
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

/// Z016: each call by meaning (`Facts.calls`) that may be std's `debug.assert` and asserts a
/// conjunction; one whose callee may be any function, or whose arguments are not known, is
/// undecided.
fn contextRules(self: *Context) RunError!void {
    if (!self.config.has(.Z016)) return;
    const tree = &self.project.at(self.file).file.tree;
    for (try Facts.calls.in(self.facts, self.file)) |call| {
        const first: ?Ast.Node.Index = switch (call.args) {
            .known => |args| first: {
                const written = if (call.receiver == .bound) args[@min(args.len, 1)..] else args;
                if (written.len == 0) continue;
                break :first written[0];
            },
            .unknown => null,
        };
        if (first) |arg| if (Model.conditionOf(tree, arg) != .both) continue;
        switch (try Governed.mayCallStd(self, call.node, "debug.assert")) {
            .no => {},
            .yes => if (first == null)
                try self.unknown(.Z016, call.node, call.args.unknown)
            else
                try self.at(.Z016, tree.nodeMainToken(call.node), "consider separate assertions only when evaluation and short circuit effects are preserved"),
            .unknown => |why| try self.unknown(.Z016, call.callee_expr, why),
        }
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
