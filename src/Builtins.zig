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
const BuildOption = @import("BuildOption.zig");
const ConstantCondition = @import("ConstantCondition.zig");
const DeadErrdefer = @import("DeadErrdefer.zig");
const DiscardedCount = @import("DiscardedCount.zig");
const DocComment = @import("DocComment.zig");
const EmptyBranch = @import("EmptyBranch.zig");
const ExpectComparison = @import("ExpectComparison.zig");
const ExpectEqualOrder = @import("ExpectEqualOrder.zig");
const FieldNaming = @import("FieldNaming.zig");
const FixedComparison = @import("FixedComparison.zig");
const FunctionShape = @import("FunctionShape.zig");
const InexactFloat = @import("InexactFloat.zig");
const LargeStackArray = @import("LargeStackArray.zig");
const LeftoverDebugging = @import("LeftoverDebugging.zig");
const NanComparison = @import("NanComparison.zig");
const NarrowCounter = @import("NarrowCounter.zig");
const NarrowWidened = @import("NarrowWidened.zig");
const NeverLoops = @import("NeverLoops.zig");
const PublicAnytype = @import("PublicAnytype.zig");
const RepeatedCondition = @import("RepeatedCondition.zig");
const SameOperands = @import("SameOperands.zig");
const SelfRecursion = @import("SelfRecursion.zig");
const UndefinedConst = @import("UndefinedConst.zig");
const UndefinedReason = @import("UndefinedReason.zig");
const UnwrapTrap = @import("UnwrapTrap.zig");
const Unchecked = @import("Unchecked.zig");
const SameTypeIds = @import("SameTypeIds.zig");
const Escapes = @import("Escapes.zig");
const RunError = Context.Error;

pub fn check(context: *Context) RunError!void {
    try parser(context);
    try lineLength(context);
    if ((try context.project.status(try context.source())) != .parsed) return;
    try unusedImports(context);
    try priorityRules(context);
    try amendedPolicies(context);
    try emptyHandlers(context);
    try syntaxRules(context);
    try precedence(context);
    try contextRules(context);
    try @import("Replaced.zig").debugPrints(context);
    try functionLengths(context);
    try Disallowed.check(context);
    try DeadDeclarations.check(context);
    try breadth(context);
    try unmappedImports(context);
}

/// The breadth rules (glint 0.8), each in its own file, each run where it is selected.
fn breadth(context: *Context) RunError!void {
    if (context.config.has(.Z035)) try SameOperands.check(context, .Z035);
    if (context.config.has(.Z036)) try RepeatedCondition.check(context, .Z036);
    if (context.config.has(.Z037)) try NarrowWidened.check(context, .Z037);
    if (context.config.has(.Z038)) try LargeStackArray.check(context, .Z038);
    if (context.config.has(.Z039)) try FixedComparison.check(context, .Z039);
    if (context.config.has(.Z040)) try ExpectComparison.check(context, .Z040);
    if (context.config.has(.Z041)) try DiscardedCount.check(context, .Z041);
    if (context.config.has(.Z042)) try ExpectEqualOrder.check(context, .Z042);
    if (context.config.has(.Z043)) try NeverLoops.check(context, .Z043);
    if (context.config.has(.Z044)) try SelfRecursion.check(context, .Z044);
    if (context.config.has(.Z045)) try DocComment.check(context, .Z045);
    if (context.config.has(.Z046)) try FieldNaming.check(context, .Z046);
    if (context.config.has(.Z047)) try ConstantCondition.check(context, .Z047);
    if (context.config.has(.Z048)) try InexactFloat.check(context, .Z048);
    if (context.config.has(.Z049)) try NanComparison.check(context, .Z049);
    if (context.config.has(.Z051)) try NarrowCounter.check(context, .Z051);
    if (context.config.has(.Z052)) try UndefinedConst.check(context, .Z052);
    if (context.config.has(.Z053)) try DeadErrdefer.check(context, .Z053);
    if (context.config.has(.Z054)) try BuildOption.check(context, .Z054);
    if (context.config.has(.Z055)) try PublicAnytype.check(context, .Z055);
    if (context.config.has(.Z056)) try EmptyBranch.check(context, .Z056);
    if (context.config.has(.P007)) try Unchecked.check(context, .P007);
    if (context.config.has(.P008)) try SameTypeIds.check(context, .P008);
    if (context.config.has(.P009)) try Escapes.check(context, .P009);
    if (context.config.has(.P010)) try UnwrapTrap.check(context, .P010);
    if (context.config.has(.P011)) try UndefinedReason.check(context, .P011);
    if (context.config.has(.P012)) try LeftoverDebugging.check(context, .P012);
    if (context.config.has(.P013)) try FunctionShape.check(context, .P013);
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

/// Z011: each call by meaning (`Facts.calls`: a direct call, a method's, `@call`, a callee
/// through `@field` or a function pointer) of a deprecated declaration, or through an alias
/// that is one. A choice of callees counts only when every one is deprecated. A callee that
/// does not resolve is silent: a miss is allowed, a wrong report is not.
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
            .choice => |each| if (each.len != 0 and for (each) |function| {
                if (!deprecated(self, function)) break false;
            } else true) try self.atDefinition(.Z011, token, "call uses a deprecated declaration", each[0]),
            .any => {},
        }
    }
}

fn amendedPolicies(self: *Context) RunError!void {
    if (!selected(self, &.{.Z012})) return;
    const source = self.project.at(self.file);
    const tree = &source.file.tree;
    // Z012 reads the public surface a consumer reaches: a public function's signature, a public
    // constant's or variable's written type, and a field of a container the surface reaches, in
    // what the exported roots reach (Facts.exportedSurface; none stated, none).
    if (self.config.has(.Z012)) for (source.model.declarations, 0..) |decl, i| {
        if (decl.kind != .field and !decl.public and !decl.exported) continue;
        // On the surface a consumer reaches: from the roots the package exports (8f).
        if (!try self.facts.exportedSurface(self.file, decl.scope)) continue;
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
}

/// Z026: each error handler written empty (`emptyHandler`), and one that only traps (`catch
/// unreachable`, `traps`), outside a `test` block: a discarded error needs a reason written at
/// the site. The handlers are `catch`'s and an `if`'s or a `while`'s `else |err|`. Only the handler's syntax is read: a
/// handler that calls anything or gives a value is not empty, whatever the callee does with the
/// error. `orelse` handles a null, which is no error: `orelse unreachable` and `.?` are another
/// rule's (an unwrap that can trap, opt-in).
fn emptyHandlers(self: *Context) RunError!void {
    if (!self.config.has(.Z026)) return;
    const tree = &self.project.at(self.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, n| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
        const handler = if (tag == .@"catch" or tag == .@"orelse")
            tree.nodeData(node).node_and_node[1]
        else if (tree.fullIf(node)) |branch|
            (if (branch.error_token == null) continue else branch.ast.else_expr.unwrap() orelse continue)
        else if (tree.fullWhile(node)) |loop|
            (if (loop.error_token == null) continue else loop.ast.else_expr.unwrap() orelse continue)
        else
            continue;
        const token = tree.nodeMainToken(node);
        if (self.inTest(token)) continue;
        if (tag == .@"orelse") continue;
        if (traps(tree, handler, 0)) {
            const message = "catch unreachable: a panic, or undefined behaviour in a ReleaseFast build; return the error, or write the reason at this site";
            // 0.7's reason comment on its line (`// unreachable: <why>`) is that reason in the form
            // glint read then: --fix writes it as the suppression it reads now.
            if (try oldReason(self, token)) |fix| try self.fixedAt(.Z026, token, message, fix) else try self.at(.Z026, token, message);
        } else if (emptyHandler(tree, handler)) {
            try self.at(.Z026, token, "an error handler that does nothing with the error; write the reason at this site");
        }
    }
}

/// Whether a handler only traps: `unreachable`, a block that is only that, or a `switch` every
/// prong of which only traps (`catch |e| switch (e) { error.Empty => unreachable }`).
fn traps(tree: *const Ast, written: Ast.Node.Index, depth: u8) bool {
    if (depth == 8) return false;
    const node = ungrouped(tree, written);
    if (tree.nodeTag(node) == .unreachable_literal) return true;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.blockStatements(&buffer, node)) |statements| return statements.len == 1 and traps(tree, statements[0], depth + 1);
    const full = tree.fullSwitch(node) orelse return false;
    if (full.ast.cases.len == 0) return false;
    for (full.ast.cases) |case| if (!traps(tree, tree.fullSwitchCase(case).?.ast.target_expr, depth + 1)) return false;
    return true;
}

/// The edit that rewrites a `// unreachable: <why>` comment, 0.7's reason for a `catch
/// unreachable`, on `token`'s line or alone on the line before it (0.7's two forms), as `//
/// glint-ignore: Z026 -- <why>`; none where the site's line holds another such site, which one
/// suppression cannot name, so the reason is its owner's to place.
fn oldReason(self: *Context, token: Ast.TokenIndex) RunError!?[]const Report.Edit {
    const file = self.project.at(self.file).file;
    const line = file.line(file.tree.tokenStart(token));
    const tree = &file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, n| {
        if (tag != .@"catch") continue;
        const other = tree.nodeMainToken(@fromBackingInt(@intCast(n)));
        if (other == token or file.line(tree.tokenStart(other)) != line) continue;
        if (traps(tree, tree.nodeData(@fromBackingInt(@intCast(n))).node_and_node[1], 0)) return null;
    }
    for (file.comments) |comment| {
        const above = comment.line + 1 == line and std.mem.trim(u8, file.source[file.lines[comment.line]..comment.start], " \t").len == 0;
        if (comment.line != line and !above) continue;
        const text = file.source[comment.start..comment.end];
        const why = std.mem.trim(u8, std.mem.cutPrefix(u8, text, "// unreachable:") orelse continue, " \t");
        if (why.len == 0) return null;
        const fix = try self.allocator.alloc(Report.Edit, 1);
        fix[0] = .{ .start = comment.start, .end = comment.end, .text = try self.allocator.print("// glint-ignore: Z026 -- {s}", .{why}) };
        return fix;
    }
    return null;
}

/// Whether a handler is written empty, parentheses aside: a block (labeled or not) whose every
/// statement is empty by this list or is `_ = X` of a `quiet` X; `@as(void, h)` of an empty `h`
/// (Zig 0.17 refuses `void{}`); an `if` (a missing `else` empty) or a `switch` whose condition is `quiet` and
/// every branch or prong empty; `return`, `break` or `continue` with no operand.
fn emptyHandler(tree: *const Ast, written: Ast.Node.Index) bool {
    const node = ungrouped(tree, written);
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.blockStatements(&buffer, node)) |statements| {
        for (statements) |statement| {
            if (tree.nodeTag(statement) == .assign) {
                const target, const value = tree.nodeData(statement).node_and_node;
                if (isName(tree, target, "_")) {
                    if (!quiet(tree, value)) return false;
                    continue;
                }
            }
            if (!emptyHandler(tree, statement)) return false;
        }
        return true;
    }
    switch (tree.nodeTag(node)) {
        .@"return" => return tree.nodeData(node).opt_node == .none,
        .@"break", .@"continue" => return tree.nodeData(node).opt_token_and_opt_node[1] == .none,
        .builtin_call_two, .builtin_call_two_comma => {
            const args = tree.builtinCallParams(&buffer, node).?; // unreachable: the node is a builtin call
            return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@as") and args.len == 2 and isName(tree, args[0], "void") and emptyHandler(tree, args[1]);
        },
        .if_simple, .@"if" => {
            const branch = tree.fullIf(node).?; // unreachable: the node is an if
            if (!quiet(tree, branch.ast.cond_expr) or !emptyHandler(tree, branch.ast.then_expr)) return false;
            return if (branch.ast.else_expr.unwrap()) |otherwise| emptyHandler(tree, otherwise) else true;
        },
        .@"switch", .switch_comma => {
            const choice = tree.fullSwitch(node).?; // unreachable: the node is a switch
            if (!quiet(tree, choice.ast.condition)) return false;
            for (choice.ast.cases) |case| if (!emptyHandler(tree, tree.fullSwitchCase(case).?.ast.target_expr)) return false; // unreachable: a switch's cases are prongs
            return true;
        },
        else => return false,
    }
}

/// Whether a value read does nothing: no call anywhere in it, and no builtin but these. Zig 0.17
/// has no `async`.
fn quiet(tree: *const Ast, node: Ast.Node.Index) bool {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    if (first == last) return true;
    for (tree.nodes.items(.tag), tree.nodes.items(.main_token)) |tag, token| {
        if (token < first or token > last) continue;
        switch (tag) {
            .call_one, .call_one_comma, .call, .call_comma => return false,
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const name = tree.tokenSlice(token);
                for ([_][]const u8{ "@intFromError", "@errorName", "@errorCast", "@as", "@intCast", "@truncate", "@TypeOf" }) |each| {
                    if (std.mem.eql(u8, name, each)) break;
                } else return false;
            },
            else => {},
        }
    }
    return true;
}

fn isName(tree: *const Ast, node: Ast.Node.Index, name: []const u8) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name);
}

fn ungrouped(tree: *const Ast, written: Ast.Node.Index) Ast.Node.Index {
    var node = written;
    while (tree.nodeTag(node) == .grouped_expression) node = tree.nodeData(node).node_and_token[0];
    return node;
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
        // A line past what a u32 position holds is none the report can name.
        const over = std.math.cast(u32, @as(u64, line.start) + self.config.max_line_length) orelse continue;
        const end = std.math.cast(u32, @as(u64, line.start) + line.text.len) orelse continue;
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
                // A call of a function declared to return `type` names a type, whatever its result
                // is read as (`std.meta.Child(@TypeOf(x))`).
                if (v.ast.type_node.unwrap() == null and try callsTypeFunction(self, expr)) {
                    if (names.acronymIssue(name)) try self.at(.Z032, decl.token, "treat acronyms in type names as ordinary words, for example XmlParser");
                    continue;
                }
                // A choice between types names a type; any other choice is undecided here.
                if (value == .alternatives) value = for (value.alternatives) |one| switch (one) {
                    .container, .primitive, .error_set, .pointer, .array, .optional, .error_union, .fn_type => {},
                    .alternatives => unreachable, // unreachable: choose never nests alternatives
                    else => break .{ .unknown = .unsupported },
                } else value.alternatives[0];
                switch (value) {
                    // A parameter declared `type` is a type whatever each binding gives it; a value
                    // that does not resolve is no sure shape, and a style rule says nothing of it.
                    .unknown => if (try typeParameter(self, expr)) {
                        if (names.acronymIssue(name)) try self.at(.Z032, decl.token, "treat acronyms in type names as ordinary words, for example XmlParser");
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

/// Whether `node` is a call whose callee, every one it may be, is a function declared to return
/// `type`.
fn callsTypeFunction(self: *Context, node: Ast.Node.Index) RunError!bool {
    const call = (try Facts.calls.at(self.facts, self.file, node)) orelse return false;
    const definition = switch (call.callee) {
        .function => |function| function,
        .choice, .any => return false,
    };
    const target = &self.project.at(definition.file).file.tree;
    const record = self.project.at(definition.file).model.declarations[@backingInt(definition.index)];
    var buffer: [1]Ast.Node.Index = undefined;
    const function = target.fullFnProto(&buffer, record.node) orelse return false;
    const returned = function.ast.return_type.unwrap() orelse return false;
    return namesType(self, definition.file, returned);
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

/// Each `@import` that names no file of the run stops it: the bans read none of what it would
/// bring. Zig's own per-build file (`builtin`) is no file glint lacks. One written under a branch
/// (an `if`, a `switch`, an `orelse`) may be one a build for another target takes, whose module
/// this build does not provide: nothing (preflight maps the modules of every target the repository
/// builds for, so only a module none of them provides is left out, a limit the design names).
fn unmappedImports(self: *Context) RunError!void {
    const tree = &self.project.at(self.file).file.tree;
    const model = &self.project.at(self.file).model;
    for (model.import_nodes) |node| {
        var b: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &b);
        if (args.len != 1 or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) continue;
        const value = try self.facts.resolve(self.file, node);
        // Zig's own per-build file, and a module whose bytes a build step makes (external): no gap.
        if (value != .unknown or value.unknown == .zig_own or value.unknown == .external) continue;
        if (underBranch(tree, model, node)) continue;
        const at = tree.tokenLocation(0, tree.nodeMainToken(node));
        try self.refuse(try self.allocator.print("{d}:{d}: `@import({s})` names no module or file this run maps, so no rule read what it brings: map it (`--module NAME=FILE`, or the build graph's module preflight passes)", .{ at.line + 1, at.column + 1, tree.getNodeSource(args[0]) }));
    }
}

/// Whether `node` is written under a branch of its declaration: an `if`, a `switch` or an `orelse`.
fn underBranch(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    var at = model.parentOf(node);
    while (at) |parent| : (at = model.parentOf(parent)) switch (tree.nodeTag(parent)) {
        .@"if", .if_simple, .@"switch", .switch_comma, .switch_case, .switch_case_one, .switch_case_inline, .switch_case_inline_one, .@"orelse" => return true,
        .fn_decl, .simple_var_decl, .global_var_decl, .local_var_decl, .aligned_var_decl, .container_field, .container_field_init, .container_field_align => return false,
        else => {},
    };
    return false;
}

/// P005: each call by meaning (`Facts.calls`) of std's `debug.print`, wherever the file reaches
/// it from (std imported here, or through another file's alias); a call of a choice one of
/// which is it is one; one whose callee may be any function is undecided.
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
    for (used, self.config.function_exceptions) |hit, exception| if (!hit) try self.refuse(try self.allocator.print("the function-length exception for `{s}` names no function of this file: remove it, or name the function", .{exception.function}));
}
