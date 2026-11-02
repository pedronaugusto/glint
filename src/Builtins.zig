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
    const declarations = source.model.declarations;
    var candidates: std.StringHashMapUnmanaged(void) = .empty;
    defer candidates.deinit(self.allocator);
    var indexes: std.ArrayList(Model.Declaration.Id) = .empty;
    for (declarations, 0..) |decl, index| {
        if (decl.kind != .variable or decl.public or decl.exported or decl.references != 0) continue;
        const value = tree.fullVarDecl(decl.node).?.ast.init_node.unwrap() orelse continue;
        // An `@import` written there is one, whatever module it names; any other value is one
        // by meaning: what it holds is another file's root, however it is reached (an alias of
        // one, a type function or `@as` given one, a block's `break`). One that does not resolve
        // is undecided.
        var buffer: [2]Ast.Node.Index = undefined;
        const written = Facts.builtinArgs(tree, value, &buffer).len == 1 and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "@import");
        if (!written) switch (try self.facts.declaration(.{ .file = self.file, .index = @fromBackingInt(@intCast(index)) })) {
            .container => |container| {
                if (container.file == self.file) continue;
                if (self.project.at(container.file).model.scopes[@backingInt(container.scope)].kind != .file) continue;
            },
            .unknown => |why| {
                try unknown(self, .Z013, decl.node, why);
                continue;
            },
            else => continue,
        };
        try candidates.put(self.allocator, decl.name, {});
        try indexes.append(self.allocator, @fromBackingInt(@intCast(index)));
    }
    if (indexes.items.len == 0) return;
    var used: Used = .empty;
    var undecided: std.StringHashMapUnmanaged(void) = .empty;
    defer undecided.deinit(self.allocator);
    // One pass for all candidates: spelling filters work, declaration identity decides usage.
    for (tree.nodes.items(.tag), 0..) |tag, n| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
        if (tag != .field_access) {
            try reflectedImport(self, node, candidates, indexes.items, &used, &undecided);
            continue;
        }
        const pair = tree.nodeData(node).node_and_token;
        const name = try Model.identifier(self.allocator, tree.tokenSlice(pair[1]));
        if (!candidates.contains(name)) continue;
        switch (try self.facts.definition(self.file, node)) {
            .decl => |definition| if (definition.file == self.file) try used.put(self.allocator, definition.index, {}),
            // A member its holder does not declare, or of a number: no import of this file.
            .none => {},
            .unknown => |why| {
                try unknown(self, .Z013, node, why);
                try undecided.put(self.allocator, name, {});
            },
        }
    }
    for (indexes.items) |index| {
        const decl = declarations[@backingInt(index)];
        if (!used.contains(index) and !undecided.contains(decl.name)) try self.at(.Z013, decl.token, try self.allocator.print("unused private import '{s}'", .{decl.name}));
    }
}

/// The candidate imports a selected file names.
const Used = std.AutoHashMapUnmanaged(Model.Declaration.Id, void);

fn reflectedImport(self: *Context, node: Ast.Node.Index, candidates: std.StringHashMapUnmanaged(void), indexes: []const Model.Declaration.Id, used: *Used, undecided: *std.StringHashMapUnmanaged(void)) RunError!void {
    const tree = &self.project.at(self.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len != 2) return;
    const builtin = tree.tokenSlice(tree.nodeMainToken(node));
    // `@field` reads a private declaration of its own file; `@hasDecl` sees none, even of
    // its own file, so it never uses a private import.
    if (!std.mem.eql(u8, builtin, "@field")) return;
    var name: ?[]const u8 = null;
    if (tree.nodeTag(args[1]) == .string_literal) {
        name = std.zig.string_literal.parseAlloc(self.allocator, tree.tokenSlice(tree.nodeMainToken(args[1]))) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        if (!candidates.contains(name.?)) return;
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
        const decl = self.project.at(self.file).model.declarations[@backingInt(index)];
        if (name) |literal| if (!std.mem.eql(u8, literal, decl.name)) continue;
        if (container) |known| if (!known.symbolic and (known.file != self.file or known.scope != decl.scope)) continue;
        try undecided.put(self.allocator, decl.name, {});
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
    if (self.config.has(.Z012)) for (source.model.declarations) |decl| {
        if (decl.kind != .function or !decl.public) continue;
        if (!reachable(&source.model, decl.scope)) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const function = tree.fullFnProto(&buffer, decl.node).?;
        try privateSignature(self, .{ .site = decl.token, .scope = decl.scope }, self.file, function, 0);
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
        if (try discards(self, handler, 0)) try self.at(.Z026, tree.nodeMainToken(node), "an error handler that discards the error; write a reason at this site");
    };
}

/// Whether an error's handler does nothing with it: an empty block, or one whose every
/// statement is a discard (`_ = err`, `_ = @intFromError(err)`), a grouping of one, a `switch`
/// whose every prong is one, or a call of the program's function whose body is empty
/// (`ignore(err)`). A call whose callee may be any function does something, as it may.
fn discards(self: *Context, node: Ast.Node.Index, depth: usize) RunError!bool {
    if (depth == 8) return false;
    const tree = &self.project.at(self.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.blockStatements(&buffer, node)) |statements| {
        for (statements) |statement| if (!try discards(self, statement, depth + 1)) return false;
        return true;
    }
    switch (tree.nodeTag(node)) {
        .grouped_expression => return discards(self, tree.nodeData(node).node_and_token[0], depth + 1),
        .assign => {
            const target, const value = tree.nodeData(node).node_and_node;
            if (tree.nodeTag(target) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_")) return false;
            return inert(tree, value, 0);
        },
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
fn inert(tree: *const Ast, node: Ast.Node.Index, depth: usize) bool {
    if (depth == 8) return false;
    switch (tree.nodeTag(node)) {
        .identifier, .number_literal, .enum_literal, .string_literal, .char_literal => return true,
        .field_access => return inert(tree, tree.nodeData(node).node_and_token[0], depth + 1),
        .grouped_expression => return inert(tree, tree.nodeData(node).node_and_token[0], depth + 1),
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

/// Whether a caller outside the file can name what is declared in `scope`: each container around
/// it held by a public or exported declaration, up to the file. A container a private declaration
/// holds is named by nobody outside, so its `pub` methods are no public signature (reactor's
/// backend sinks, called through `anytype`; a test's harness).
fn reachable(model: *const Model, scope: Model.Scope.Id) bool {
    return privateHolder(model, scope) == null;
}

/// The first declaration, from `scope` outward, that holds a container around it and is neither
/// public nor exported: what keeps callers outside the file from naming the scope.
fn privateHolder(model: *const Model, scope: Model.Scope.Id) ?Model.Declaration.Id {
    var at: ?Model.Scope.Id = scope;
    while (at) |s| : (at = model.scopes[@backingInt(s)].parent) {
        if (model.scopes[@backingInt(s)].kind != .container) continue;
        const node = @backingInt(model.scopes[@backingInt(s)].node);
        if (node >= model.node_parents.len) continue;
        const holder = model.node_parents[node] orelse continue;
        for (model.declarations, 0..) |d, i| if (d.kind == .variable and d.node == holder) {
            if (!d.public and !d.exported) return @fromBackingInt(@intCast(i));
            break;
        };
    }
    return null;
}

/// The public function whose signature Z012 reads: where it reports, and the scope it is
/// declared in, whose enclosing containers its callers name it through.
const Signature = struct { site: Ast.TokenIndex, scope: Model.Scope.Id };

fn privateSignature(self: *Context, signature: Signature, file: Project.FileId, function: Ast.full.FnProto, depth: usize) RunError!void {
    const tree = &self.project.at(file).file.tree;
    if (function.ast.return_type.unwrap()) |t| try privateType(self, signature, file, t, depth);
    var it = function.iterate(tree);
    while (it.next()) |param| if (param.type_expr) |t| try privateType(self, signature, file, t, depth);
}

/// Z012 over a type written at `node` of `file` in a public signature: each type a caller has to
/// name to use it, read by what it is. A form this does not read leaves the signature undecided.
fn privateType(self: *Context, signature: Signature, file: Project.FileId, node: Ast.Node.Index, depth: usize) RunError!void {
    const tree = &self.project.at(file).file.tree;
    if (depth >= 128) return undecidedType(self, signature, file, node, .budget);
    if (tree.fullPtrType(node)) |pointer| return privateType(self, signature, file, pointer.ast.child_type, depth + 1);
    if (tree.fullArrayType(node)) |array| return privateType(self, signature, file, array.ast.elem_type, depth + 1);
    var prototype: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&prototype, node)) |function| return privateSignature(self, signature, file, function, depth + 1);
    var members: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&members, node)) |container| {
        // A container written in the signature is named there; its fields' types are not.
        for (container.ast.members) |member| if (tree.fullContainerField(member)) |field| {
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
                    if ((decl.public or decl.exported) and reachable(&self.project.at(definition.file).model, decl.scope)) return;
                },
                // A primitive, or a member no holder declares: what it resolves to says.
                .none => {},
                .unknown => |why| return undecidedType(self, signature, file, node, why),
            }
            try exposedValue(self, signature, file, node, try self.facts.resolve(file, node), depth + 1);
        },
        .optional_type => try privateType(self, signature, file, tree.nodeData(node).node, depth + 1),
        .error_union => try privateType(self, signature, file, tree.nodeData(node).node_and_node[1], depth + 1),
        .grouped_expression => try privateType(self, signature, file, tree.nodeData(node).node_and_token[0], depth + 1),
        // Error-set policy is not Z012.
        .error_set_decl, .merge_error_sets => {},
        // A call, a builtin or a comptime choice: the type it gives.
        else => try exposedValue(self, signature, file, node, try self.facts.resolve(file, node), depth + 1),
    }
}

/// Z012 over a type `node` of `file` resolves to: the containers a caller has to name to use it.
fn exposedValue(self: *Context, signature: Signature, file: Project.FileId, node: Ast.Node.Index, value: Facts.Value, depth: usize) RunError!void {
    if (depth >= 128) return undecidedType(self, signature, file, node, .budget);
    switch (value) {
        .unknown => |why| try undecidedType(self, signature, file, node, why),
        // A primitive alias can be named as the primitive; error-set policy is not Z012.
        .primitive, .scalar, .error_set => {},
        .pointer, .array, .optional, .error_union => |inner| try exposedValue(self, signature, file, node, inner.*, depth + 1),
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
        if (!(maker.public or maker.exported) or !reachable(&self.project.at(made.function.file).model, maker.scope))
            return self.atDefinition(.Z012, signature.site, try self.allocator.print("public signature exposes private type function '{s}'", .{maker.name}), made.function);
        var buffer: [1]Ast.Node.Index = undefined;
        const call = self.project.at(made.file).file.tree.fullCall(&buffer, made.call) orelse return undecidedType(self, signature, file, node, .unsupported);
        for (call.ast.params) |argument| try exposedArgument(self, signature, made.file, argument, depth + 1);
        return;
    }
    if (container.symbolic) return undecidedType(self, signature, file, node, .comptime_dependent);
    const holder = privateHolder(model, container.scope) orelse return;
    // A public alias to this same container makes it nameable.
    for (model.declarations, 0..) |alias, i| {
        if (!alias.public or alias.kind != .variable or !reachable(model, alias.scope)) continue;
        const exposed = try self.facts.declaration(.{ .file = container.file, .index = @fromBackingInt(@intCast(i)) });
        if (exposed == .container and exposed.container.file == container.file and exposed.container.scope == container.scope and !exposed.container.symbolic) return;
    }
    const decl = model.declarations[@backingInt(holder)];
    try self.atDefinition(.Z012, signature.site, try self.allocator.print("public signature exposes private type '{s}'", .{decl.name}), .{ .file = container.file, .index = holder });
}

/// A type function's argument: a type a caller names, or a value written in the call.
fn exposedArgument(self: *Context, signature: Signature, file: Project.FileId, node: Ast.Node.Index, depth: usize) RunError!void {
    const value = try self.facts.resolve(file, node);
    switch (value) {
        .instance, .literal, .function => {},
        else => try exposedValue(self, signature, file, node, value, depth),
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
            const returns_type = if (function.ast.return_type.unwrap()) |t| tree.nodeTag(t) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(t)), "type") else false;
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
                        const returns_type = if (function.ast.return_type.unwrap()) |t| target.nodeTag(t) == .identifier and std.mem.eql(u8, target.tokenSlice(target.nodeMainToken(t)), "type") else false;
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
            if (tree.nodeTag(data[0]) != .identifier) continue;
            const index = (model.reference(data[0]) orelse continue).declaration orelse continue;
            const parameter = model.declarations[@backingInt(index)];
            if (parameter.kind != .parameter) continue;
            // `anytype` has no type expression of its own: the parameter's node is the keyword.
            const typed = tree.nodeTag(parameter.node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(parameter.node)), "type");
            if (typed or tree.tokenTag(parameter.token + 2) == .keyword_anytype) return true;
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
        if (first) |arg| if (tree.nodeTag(arg) != .bool_and) continue;
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
        if (value == .unknown) try self.sink.coverage(self.sink, .{ .file = self.file, .start = tree.tokenStart(tree.nodeMainToken(node)), .reason = .unresolved, .detail = @tagName(value.unknown) });
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
        if (ret != null and tree.nodeTag(ret.?) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(ret.?)), "type")) {
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
