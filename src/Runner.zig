//! Selected rules share one frozen project and one fact resolver.
const std = @import("std");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const rules = @import("Rule.zig");
const Report = @import("Report.zig");
const Suppression = @import("Suppression.zig");
const Runner = @This();
const names = @import("names.zig");
const Model = @import("Model.zig");
const Poison = @import("Poison.zig");
const Ast = std.zig.Ast;

a: std.mem.Allocator,
project: *const Project,
config: rules.Config,
facts: Facts,
diagnostics: std.ArrayList(Report.Diagnostic) = .empty,
coverage: std.ArrayList(Report.Coverage) = .empty,
suppressions: []Suppression = &.{},
suppressed: usize = 0,
stale: usize = 0,
complete: bool = true,
file: Project.FileId = @fromBackingInt(0), // safe: validated file identities and budgeted std source indexes fit u32.

pub const RunError = Suppression.ParseError || Facts.ResolveError || error{InvalidSelection};

pub fn run(gpa: std.mem.Allocator, project: *const Project, config: rules.Config) RunError!Report {
    try config.validate();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var runner: Runner = .{ .a = a, .project = project, .config = config, .facts = .{ .project = project, .gpa = a, .remaining = config.fact_budget } };
    defer runner.facts.deinit();
    for (project.inputs, 0..) |input, index| {
        if (!input.selected) continue;
        runner.file = @fromBackingInt(@intCast(index)); // safe: validated file identities and budgeted std source indexes fit u32.
        const file = &project.files[index];
        runner.suppressions = try Suppression.parse(a, file);
        try runner.coverage.append(a, .{ .file = runner.file, .reason = switch (file.status) {
            .parsed => .parsed,
            .invalid_syntax => .invalid_syntax,
            .invalid_lowering => .invalid_lowering,
            .budget_exhausted => .budget_exhausted,
        }, .detail = switch (file.status) {
            .parsed => "std AST and AstGen/ZIR lowered; no compiler type checking or generic evaluation",
            .invalid_syntax => "std parser rejected source; semantic rules skipped",
            .invalid_lowering => "std AstGen rejected source; semantic rules skipped",
            .budget_exhausted => "front-end work budget exhausted; semantic rules skipped",
        } });
        if (file.status == .parsed) {
            const lowered_coverage = project.models[index].lowered_coverage;
            try runner.coverage.append(a, .{ .file = runner.file, .reason = if (lowered_coverage == .budget_exhausted) .budget_exhausted else .unsupported, .detail = "std-ZIR declaration references are indexed only through supported structured bodies; lexical references are indexed separately" });
            if (lowered_coverage == .budget_exhausted) runner.complete = false;
        }
        try runner.parser();
        try runner.lineLength();
        if (file.status == .parsed) {
            try runner.unusedImports();
            try runner.priorityRules();
            try runner.syntaxRules();
            try runner.contextRules();
            try runner.poisonRule();
            try runner.unknownCoverage();
        }
        if (file.status != .parsed) runner.complete = false;
        for (runner.suppressions) |suppression| if (!suppression.used) {
            runner.stale += 1;
        };
    }
    if (runner.facts.remaining == 0) {
        runner.complete = false;
        try runner.coverage.append(a, .{ .file = runner.file, .reason = .budget_exhausted, .detail = "semantic fact budget exhausted" });
    }
    if (config.strict_suppressions and runner.stale != 0) runner.complete = false;
    std.mem.sort(Report.Diagnostic, runner.diagnostics.items, project, diagnosticLess);
    return .{ .arena = arena, .snapshot = project.identity, .diagnostics = runner.diagnostics.items, .coverage = runner.coverage.items, .suppressed = runner.suppressed, .stale_suppressions = runner.stale, .complete = runner.complete };
}

fn diagnosticLess(project: *const Project, lhs: Report.Diagnostic, rhs: Report.Diagnostic) bool {
    const order = std.mem.order(u8, project.inputs[@backingInt(lhs.span.file)].name, project.inputs[@backingInt(rhs.span.file)].name); // safe: enum identities index their owning frozen tables without narrowing.
    if (order != .eq) return order == .lt;
    if (lhs.span.start != rhs.span.start) return lhs.span.start < rhs.span.start;
    return @backingInt(lhs.rule) < @backingInt(rhs.rule); // safe: enum identities index their owning frozen tables without narrowing.
}

fn emit(self: *Runner, rule: rules.Rule, start: u32, end: u32, message: []const u8) RunError!void {
    if (!self.config.has(rule)) return;
    const file = &self.project.files[@backingInt(self.file)]; // safe: enum identities index their owning frozen tables without narrowing.
    const line = file.line(start);
    for (self.suppressions) |*suppression| if (try suppression.matches(rule, line, start)) {
        self.suppressed += 1;
        return;
    };
    try self.diagnostics.append(self.a, .{ .rule = rule, .class = switch (rule) {
        .Z003 => .correctness,
        .Z013 => .hygiene,
        .Z007, .Z026 => .suspicious,
        else => .style,
    }, .severity = if (rule == .Z003) .@"error" else .warning, .span = .{ .file = self.file, .start = start, .end = end, .line = line + 1, .column = start - file.lines[line] + 1 }, .message = message, .bug_class = switch (rule) {
        .Z003 => "syntax incompatibility",
        .Z013 => "dead private import binding",
        else => "selected compatibility policy",
    } });
}

fn at(self: *Runner, rule: rules.Rule, token: std.zig.Ast.TokenIndex, message: []const u8) RunError!void {
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const start = tree.tokenStart(token);
    try self.emit(rule, start, start + @as(u32, @intCast(tree.tokenSlice(token).len)), message); // safe: validated file identities and budgeted std source indexes fit u32.
}

fn parser(self: *Runner) RunError!void {
    if (!self.config.has(.Z003)) return;
    const file = &self.project.files[@backingInt(self.file)]; // safe: enum identities index their owning frozen tables without narrowing.
    for (file.tree.errors) |err| {
        if (err.is_note) continue;
        var writer: std.Io.Writer.Allocating = .init(self.a);
        file.tree.renderError(err, &writer.writer) catch return error.OutOfMemory;
        const offset = file.tree.tokenStart(err.token) + file.tree.errorOffset(err);
        try self.emit(.Z003, offset, offset, try writer.toOwnedSlice());
    }
}

fn unusedImports(self: *Runner) RunError!void {
    if (!self.config.has(.Z013)) return;
    const file_index = @backingInt(self.file); // safe: enum identities index their owning frozen tables without narrowing.
    const tree = &self.project.files[file_index].tree;
    for (self.project.models[file_index].declarations) |decl| {
        if (decl.kind != .variable or decl.public or decl.exported or decl.references != 0) continue;
        const variable = tree.fullVarDecl(decl.node).?;
        const value = variable.ast.init_node.unwrap() orelse continue;
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, value, &buffer);
        if (args.len == 1 and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "@import")) {
            try self.at(.Z013, decl.token, try self.a.print("unused private import '{s}'", .{decl.name}));
        }
    }
}

fn selected(self: *const Runner, selection: []const rules.Rule) bool {
    for (selection) |rule| if (self.config.has(rule)) return true;
    return false;
}

fn unknown(self: *Runner, rule: rules.Rule, node: Ast.Node.Index, reason: Facts.Unknown) RunError!void {
    if (!self.config.has(rule)) return;
    if (reason == .budget) self.complete = false;
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: enum identities index their owning frozen tables without narrowing.
    try self.coverage.append(self.a, .{ .file = self.file, .rule = rule, .start = tree.tokenStart(tree.nodeMainToken(node)), .reason = if (reason == .budget) .budget_exhausted else .unresolved, .detail = @tagName(reason) });
}

fn priorityRules(self: *Runner) RunError!void {
    if (!self.selected(&.{ .Z011, .Z012, .Z015, .Z023 })) return;
    const index = @backingInt(self.file); // safe: enum identities index their owning frozen tables without narrowing.
    const tree = &self.project.files[index].tree;
    for (self.project.models[index].declarations) |decl| {
        if (decl.kind != .function) continue;
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const function = tree.fullFnProto(&buffer, decl.node).?;
        if (decl.public and (self.config.has(.Z012) or self.config.has(.Z015))) {
            if (function.ast.return_type.unwrap()) |t| try self.privateType(t, decl.token, false, 0);
            var it = function.iterate(tree);
            while (it.next()) |param| if (param.type_expr) |t| try self.privateType(t, decl.token, false, 0);
        }
        if (self.config.has(.Z023)) {
            var it = function.iterate(tree);
            var first = true;
            var maximum: u8 = 0;
            while (it.next()) |param| {
                const t = param.type_expr orelse continue;
                if (first) {
                    first = false;
                    var receiver_value = try self.facts.resolve(self.file, t);
                    while (receiver_value == .pointer) receiver_value = receiver_value.pointer.*;
                    if (receiver_value == .unknown) {
                        try self.unknown(.Z023, t, receiver_value.unknown);
                        continue;
                    }
                    if (try self.receiver(t, decl.scope)) continue;
                }
                const order = (try self.parameterOrder(t, param.comptime_noalias)) orelse continue;
                if (order < maximum) try self.at(.Z023, param.name_token orelse tree.nodeMainToken(t), "parameter follows a later-ranked parameter");
                maximum = @max(maximum, order);
            }
        }
    }
    if (!self.config.has(.Z011)) return;
    // Node-table enumeration covers every expression position exactly once.
    for (tree.nodes.items(.tag), 0..) |_, n| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(n)); // safe: validated file identities and budgeted std source indexes fit u32.
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (try self.facts.definition(self.file, call.ast.fn_expr)) |definition| {
            var is_deprecated = self.deprecated(definition);
            if (!is_deprecated) {
                const value = try self.facts.resolve(self.file, call.ast.fn_expr);
                if (value == .function) is_deprecated = self.deprecated(value.function);
            }
            if (is_deprecated) try self.at(.Z011, if (tree.nodeTag(call.ast.fn_expr) == .field_access) tree.nodeData(call.ast.fn_expr).node_and_token[1] else tree.nodeMainToken(call.ast.fn_expr), "call uses a deprecated declaration");
        } else {
            const value = try self.facts.resolve(self.file, call.ast.fn_expr);
            try self.unknown(.Z011, call.ast.fn_expr, if (value == .unknown) value.unknown else .unsupported);
        }
    }
}

fn deprecated(self: *const Runner, definition: Facts.Decl) bool {
    const tree = &self.project.files[@backingInt(definition.file)].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const decl = self.project.models[@backingInt(definition.file)].declarations[definition.index]; // safe: enum identities index their owning frozen tables without narrowing.
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

fn privateType(self: *Runner, node: std.zig.Ast.Node.Index, site: std.zig.Ast.TokenIndex, error_position: bool, depth: usize) RunError!void {
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: enum identities index their owning frozen tables without narrowing.
    if (depth >= 128) {
        self.complete = false;
        try self.coverage.append(self.a, .{ .file = self.file, .reason = .budget_exhausted, .start = tree.tokenStart(site), .detail = "API type shape depth limit" });
        return;
    }
    switch (tree.nodeTag(node)) {
        .identifier => {
            const definition = (try self.facts.definition(self.file, node)) orelse return;
            const decl = self.project.models[@backingInt(definition.file)].declarations[definition.index]; // safe: enum identities index their owning frozen tables without narrowing.
            if (decl.kind == .parameter or decl.public or decl.exported or definition.file != self.file) return;
            if (try self.facts.origin(definition)) |origin| {
                const original = self.project.models[@backingInt(origin.file)].declarations[origin.index]; // safe: resolved origin indexes its own frozen declaration table.
                if (origin.file != self.file or original.public or original.exported) return;
            }
            const value = try self.facts.resolve(self.file, node);
            if (value == .unknown) {
                try self.unknown(if (error_position) .Z015 else .Z012, node, value.unknown);
                return;
            }
            if (value == .container and (value.container.file != self.file or value.container.scope == decl.scope)) return; // @This alias.
            try self.at(if (error_position) .Z015 else .Z012, site, try self.a.print("public signature exposes private '{s}'", .{decl.name}));
        },
        .optional_type => try self.privateType(tree.nodeData(node).node, site, error_position, depth + 1),
        .error_union, .merge_error_sets => {
            const pair = tree.nodeData(node).node_and_node;
            try self.privateType(pair[0], site, true, depth + 1);
            try self.privateType(pair[1], site, tree.nodeTag(node) == .merge_error_sets, depth + 1);
        },
        .grouped_expression => try self.privateType(tree.nodeData(node).node_and_token[0], site, error_position, depth + 1),
        else => {}, // Preserve the selected predecessor's shape contract.
    }
}

fn receiver(self: *Runner, node: std.zig.Ast.Node.Index, scope: u32) RunError!bool {
    var value = try self.facts.resolve(self.file, node);
    while (value == .pointer) value = value.pointer.*;
    if (value != .container or value.container.file != self.file) return false;
    const model = &self.project.models[@backingInt(self.file)]; // safe: enum identities index their owning frozen tables without narrowing.
    var enclosing: ?u32 = scope;
    while (enclosing) |s| {
        if (model.scopes[s].kind == .container or model.scopes[s].kind == .file) return value.container.scope == s;
        enclosing = model.scopes[s].parent;
    }
    return false;
}

fn parameterOrder(self: *Runner, node: std.zig.Ast.Node.Index, modifier: ?std.zig.Ast.TokenIndex) RunError!?u8 {
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const value = try self.facts.resolve(self.file, node);
    if (value == .primitive and std.mem.eql(u8, value.primitive, "type")) return 0;
    if (modifier) |t| if (tree.tokenTag(t) == .keyword_comptime) return 1;
    if (value == .unknown) {
        try self.unknown(.Z023, node, value.unknown);
        return null;
    }
    if (value == .container) {
        for (self.project.imports) |mapping| {
            if (!std.mem.eql(u8, mapping.spelling, "std")) continue;
            const root: Facts.Container = .{ .file = mapping.target, .scope = 0 };
            if (try self.standardContainer(root, &.{ "mem", "Allocator" })) |c| if (std.meta.eql(c, value.container)) return 2;
            if (try self.standardContainer(root, &.{"Io"})) |c| if (std.meta.eql(c, value.container)) return 3;
        }
    }
    return 4;
}

fn standardContainer(self: *Runner, root: Facts.Container, path_parts: []const []const u8) RunError!?Facts.Container {
    var c = root;
    for (path_parts) |name| {
        const decl = self.facts.member(c, name) orelse return null;
        const v = try self.facts.declaration(decl);
        if (v != .container) return null;
        c = v.container;
    }
    return c;
}

fn parent(self: *const Runner, node: Ast.Node.Index) ?Ast.Node.Index {
    return self.project.models[@backingInt(self.file)].node_parents[@backingInt(node)]; // safe: enum identities index their owning frozen tables without narrowing.
}

fn under(self: *const Runner, node: Ast.Node.Index, kind: enum { cleanup, test_scope, function }) bool {
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var cursor = self.parent(node);
    while (cursor) |p| {
        const tag = tree.nodeTag(p);
        if (kind == .cleanup and (tag == .@"defer" or tag == .@"errdefer")) return true;
        if (kind == .test_scope and tag == .test_decl) return true;
        if (tag == .fn_decl) return kind == .function;
        cursor = self.parent(p);
    }
    return false;
}

fn typePolicy(tree: *const Ast, node: Ast.Node.Index, binding: []const u8) bool {
    var b: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&b, node) != null or tree.fullPtrType(node) != null or tree.fullArrayType(node) != null) return true;
    switch (tree.nodeTag(node)) {
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            return names.isPascalCase(name) or Model.primitive(name);
        },
        .field_access => return names.isPascalCase(tree.tokenSlice(tree.nodeData(node).node_and_token[1])),
        .error_set_decl, .merge_error_sets, .optional_type, .error_union, .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => return true,
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            return std.mem.eql(u8, name, "@This") or std.mem.eql(u8, name, "@import") or std.mem.eql(u8, name, "@Type") or std.mem.eql(u8, name, "@TypeOf");
        },
        .call, .call_comma, .call_one, .call_one_comma => {
            var cb: [1]Ast.Node.Index = undefined;
            const c = tree.fullCall(&cb, node).?;
            const t = if (tree.nodeTag(c.ast.fn_expr) == .field_access) tree.nodeData(c.ast.fn_expr).node_and_token[1] else tree.nodeMainToken(c.ast.fn_expr);
            return names.isPascalCase(tree.tokenSlice(t));
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon, .@"if", .if_simple, .@"switch", .switch_comma => return names.isPascalCase(binding),
        else => return false,
    }
}

fn functionAliasPolicy(tree: *const Ast, node: Ast.Node.Index) bool {
    const t = switch (tree.nodeTag(node)) {
        .identifier => tree.nodeMainToken(node),
        .field_access => tree.nodeData(node).node_and_token[1],
        else => return false,
    };
    const name = tree.tokenSlice(t);
    return name.len != 0 and std.ascii.isLower(name[0]) and std.mem.findScalar(u8, name, '_') == null;
}

fn lineLength(self: *Runner) RunError!void {
    const file = &self.project.files[@backingInt(self.file)]; // safe: enum identities index their owning frozen tables without narrowing.
    if (self.config.has(.Z024)) for (file.lines, 0..) |start, l| {
        var end: u32 = if (l + 1 < file.lines.len) file.lines[l + 1] - 1 else @intCast(file.source.len); // safe: validated file identities and budgeted std source indexes fit u32.
        if (end > start and file.source[end - 1] == '\r') end -= 1;
        if (end - start > self.config.max_line_length) try self.emit(.Z024, start + self.config.max_line_length, end, "line exceeds configured byte length");
    };
}

fn syntaxRules(self: *Runner) RunError!void {
    if (!self.selected(&.{ .Z001, .Z002, .Z004, .Z005, .Z006, .Z007, .Z009, .Z010, .Z014, .Z017, .Z018, .Z019, .Z020, .Z021, .Z022, .Z024, .Z025, .Z026, .Z028, .Z031, .Z032, .Z033 })) return;
    const index = @backingInt(self.file); // safe: enum identities index their owning frozen tables without narrowing.
    const tree = &self.project.files[index].tree;
    var imports: std.StringHashMapUnmanaged(void) = .empty;
    defer imports.deinit(self.a);
    var top_fields = false;
    for (self.project.models[index].declarations) |decl| if (decl.kind == .field and decl.scope == 0) {
        top_fields = true;
    };
    if (top_fields and !names.isPascalCase(self.project.inputs[index].stem)) try self.emit(.Z009, 0, 0, "file struct stem must be PascalCase");
    for (tree.nodes.items(.tag), 0..) |tag, n| {
        if (n == 0) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n)); // safe: validated file identities and budgeted std source indexes fit u32.
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullVarDecl(node)) |v| {
            const token = v.ast.mut_token + 1;
            const name = tree.tokenSlice(token);
            const init_node = v.ast.init_node.unwrap();
            if (names.hasUnderscorePrefix(name)) {
                if (init_node != null) try self.at(.Z002, token, "initialized named discard");
                try self.at(.Z031, token, "single underscore prefix");
            }
            const type_alias = if (init_node) |expr| typePolicy(tree, expr, name) else false;
            if (!names.isSnakeCase(name) and !type_alias and !(if (init_node) |expr| functionAliasPolicy(tree, expr) else false)) try self.at(.Z006, token, "variable name must be snake_case");
            if (type_alias) {
                if (names.acronymIssue(name)) try self.at(.Z032, token, "acronym must be title-cased");
                if (names.findRedundantWord(name)) |_| try self.at(.Z033, token, "redundant word in type name");
            }
            if (init_node) |expr| {
                if (tree.nodeTag(expr) == .error_set_decl and !names.isPascalCase(name)) try self.at(.Z014, token, "error set name must be PascalCase");
                if (tree.fullStructInit(&buffer, expr)) |value| if (value.ast.type_expr != .none and v.ast.type_node == .none) try self.at(.Z004, v.ast.mut_token, "put the initializer type on the declaration");
                const args = Facts.builtinArgs(tree, expr, &buffer);
                if (args.len == 1 and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(expr)), "@import")) {
                    const raw = tree.tokenSlice(tree.nodeMainToken(args[0]));
                    const entry = try imports.getOrPut(self.a, raw);
                    if (entry.found_existing) try self.at(.Z007, token, "duplicate import binding (selected policy)");
                }
                if (v.ast.type_node.unwrap()) |t| try self.redundantAs(.Z018, t, self.file, expr, token);
            }
        }
        if (tag == .fn_decl) {
            var fb: [1]Ast.Node.Index = undefined;
            const f = tree.fullFnProto(&fb, node).?;
            if (f.name_token) |token| {
                const name = tree.tokenSlice(token);
                const returns_type = if (f.ast.return_type.unwrap()) |t| tree.nodeTag(t) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(t)), "type") else false;
                if (returns_type) {
                    if (!names.isPascalCase(name)) try self.at(.Z005, token, "type function name must be PascalCase");
                } else if (!names.isValidFunctionName(name)) try self.at(.Z001, token, "function name must be camelCase");
                if (names.hasUnderscorePrefix(name)) try self.at(.Z031, token, "single underscore prefix");
                if (names.acronymIssue(name)) try self.at(.Z032, token, "acronym must be title-cased");
            }
        }
        if (tag == .@"return") if (tree.nodeData(node).opt_node.unwrap()) |expr| {
            if (tree.nodeTag(expr) == .@"try") try self.at(.Z017, tree.nodeMainToken(node), "hoist try before returning; preserve return coercion");
            if (self.enclosingFunction(node)) |fn_node| {
                var fb: [1]Ast.Node.Index = undefined;
                const f = tree.fullFnProto(&fb, fn_node).?;
                if (f.ast.return_type.unwrap()) |t| {
                    try self.redundantType(expr, .{ .file = self.file, .node = t }, true);
                    try self.redundantAs(.Z018, t, self.file, expr, tree.nodeMainToken(node));
                }
            }
        };
        if (tag == .@"catch") {
            const pair = tree.nodeData(node).node_and_node;
            var bb: [2]Ast.Node.Index = undefined;
            if (tree.blockStatements(&bb, pair[1])) |statements| if (statements.len == 0 and !self.under(node, .cleanup)) try self.at(.Z026, tree.nodeMainToken(node), "empty catch discards the error (selected policy)");
            const token = tree.nodeMainToken(node);
            if (tree.tokenTag(token + 1) == .pipe and tree.nodeTag(pair[1]) == .@"return") {
                if (tree.nodeData(pair[1]).opt_node.unwrap()) |value| if (tree.nodeTag(value) == .identifier and std.mem.eql(u8, tree.tokenSlice(token + 2), tree.tokenSlice(tree.nodeMainToken(value)))) try self.at(.Z025, token, "catch returns its captured error; prefer try");
            }
        }
        const builtin = tree.tokenSlice(tree.nodeMainToken(node));
        const args = Facts.builtinArgs(tree, node, &buffer);
        if (std.mem.eql(u8, builtin, "@This") and args.len == 0 and (tag == .builtin_call_two or tag == .builtin_call_two_comma)) try self.thisRules(node, top_fields);
        if (std.mem.eql(u8, builtin, "@import") and args.len == 1) try self.importRule(node);
    }
}

fn enclosingFunction(self: *const Runner, node: Ast.Node.Index) ?Ast.Node.Index {
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var cursor = self.parent(node);
    while (cursor) |p| {
        if (tree.nodeTag(p) == .fn_decl) return p;
        cursor = self.parent(p);
    }
    return null;
}

fn sameType(expected: Facts.Value, actual: Facts.Value) bool {
    if (expected == .primitive and actual == .primitive) return std.mem.eql(u8, expected.primitive, actual.primitive);
    return expected == .container and actual == .container and !expected.container.symbolic and !actual.container.symbolic and std.meta.eql(expected.container, actual.container);
}

fn redundantType(self: *Runner, node: Ast.Node.Index, expected: Facts.Key, fields: bool) RunError!void {
    if (!self.config.has(.Z010)) return;
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: the runner's file identity was validated by project construction.
    var b: [2]Ast.Node.Index = undefined;
    var context = try self.facts.resolve(expected.file, expected.node);
    while (context == .optional or context == .error_union) context = if (context == .optional) context.optional.* else context.error_union.*;
    if (tree.fullStructInit(&b, node)) |value| {
        if (value.ast.type_expr.unwrap()) |t| {
            const actual = try self.facts.resolve(self.file, t);
            if (sameType(context, actual)) try self.at(.Z010, tree.nodeMainToken(t), "known context supplies this initializer type") else if (context == .unknown) try self.unknown(.Z010, t, context.unknown);
        }
    } else if (fields and tree.nodeTag(node) == .field_access) {
        const pair = tree.nodeData(node).node_and_token;
        const actual = try self.facts.resolve(self.file, pair[0]);
        if (!sameType(context, actual) or actual != .container) return;
        const c = actual.container;
        const target = &self.project.files[@backingInt(c.file)].tree; // safe: resolved container belongs to this frozen project.
        const record = self.project.models[@backingInt(c.file)].scopes[c.scope]; // safe: the fact carries the originating file's validated scope.
        if (target.tokenTag(target.nodeMainToken(record.node)) == .keyword_enum) try self.at(.Z010, tree.nodeMainToken(pair[0]), "known enum context supplies this literal type");
    }
}

fn redundantAs(self: *Runner, rule: rules.Rule, expected: Ast.Node.Index, expected_file: Project.FileId, value: Ast.Node.Index, site: Ast.TokenIndex) RunError!void {
    if (!self.config.has(rule)) return;
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, value, &buffer);
    if (args.len != 2 or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "@as")) return;
    const expected_value = try self.facts.resolve(expected_file, expected);
    const actual_value = try self.facts.resolve(self.file, args[0]);
    if (sameType(expected_value, actual_value)) try self.at(rule, site, "context already supplies the @as type");
    if (expected_value == .unknown) try self.unknown(rule, value, expected_value.unknown);
    if (actual_value == .unknown) try self.unknown(rule, value, actual_value.unknown);
}

fn thisRules(self: *Runner, node: Ast.Node.Index, top_fields: bool) RunError!void {
    const index = @backingInt(self.file); // safe: enum identities index their owning frozen tables without narrowing.
    const tree = &self.project.files[index].tree;
    const p = self.parent(node) orelse return;
    var cb: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&cb, p) != null) return;
    const variable = tree.fullVarDecl(p);
    if (variable == null or variable.?.ast.init_node.unwrap() != node or tree.tokenTag(variable.?.ast.mut_token) != .keyword_const) {
        try self.at(.Z020, tree.nodeMainToken(node), "bind @This to a named const");
        return;
    }
    const name = tree.tokenSlice(variable.?.ast.mut_token + 1);
    const value = try self.facts.resolve(self.file, node);
    if (value != .container) return;
    const model = &self.project.models[index];
    if (value.container.scope == 0) {
        if (top_fields and !std.mem.eql(u8, name, "Self") and !std.ascii.eqlIgnoreCase(name, self.project.inputs[index].stem)) try self.at(.Z021, tree.nodeMainToken(node), "@This alias must be Self or the file struct stem");
    } else {
        var named = false;
        for (model.declarations) |decl| {
            if (decl.kind != .variable) continue;
            const v = tree.fullVarDecl(decl.node).?;
            if (v.ast.init_node.unwrap() == model.scopes[value.container.scope].node and !self.under(decl.node, .function) and !self.under(decl.node, .test_scope)) {
                named = true;
                break;
            }
        }
        if (named) try self.at(.Z019, tree.nodeMainToken(node), "named container can use its declaration name") else if (!std.mem.eql(u8, name, "Self")) try self.at(.Z022, tree.nodeMainToken(node), "anonymous or local container alias must be Self");
    }
}

fn importRule(self: *Runner, node: Ast.Node.Index) RunError!void {
    if (!self.config.has(.Z028)) return;
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var cursor = node;
    while (self.parent(cursor)) |p| {
        if (tree.nodeTag(p) == .field_access) {
            cursor = p;
            continue;
        }
        if (tree.fullVarDecl(p)) |v| {
            const scope = self.project.models[@backingInt(self.file)].token_scopes[v.ast.mut_token]; // safe: enum identities index their owning frozen tables without narrowing.
            if (tree.tokenTag(v.ast.mut_token) == .keyword_const and v.ast.init_node.unwrap() == cursor and (scope == 0 or self.under(p, .test_scope))) return;
        }
        if (tree.nodeTag(p) == .assign and self.under(p, .test_scope)) {
            const lhs = tree.nodeData(p).node_and_node[0];
            if (tree.nodeTag(lhs) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(lhs)), "_")) return;
        }
        break;
    }
    try self.at(.Z028, tree.nodeMainToken(node), "import must be a file const or an explicit test import");
}

fn contextRules(self: *Runner) RunError!void {
    if (!self.selected(&.{ .Z010, .Z016, .Z027, .Z029 })) return;
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: enum identities index their owning frozen tables without narrowing.
    for (tree.nodes.items(.tag), 0..) |tag, n| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n)); // safe: validated file identities and budgeted std source indexes fit u32.
        var b: [2]Ast.Node.Index = undefined;
        var cb: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&cb, node)) |call| {
            if (self.config.has(.Z016) and call.ast.params.len != 0 and tree.nodeTag(call.ast.params[0]) == .bool_and) {
                const value = try self.facts.resolve(self.file, call.ast.fn_expr);
                if (value == .function) for (self.project.imports) |mapping| {
                    if (!std.mem.eql(u8, mapping.spelling, "std")) continue;
                    const debug = (try self.standardContainer(.{ .file = mapping.target, .scope = 0 }, &.{"debug"})) orelse continue;
                    const assertion = self.facts.member(debug, "assert") orelse continue;
                    if (std.meta.eql(assertion, value.function)) {
                        try self.at(.Z016, tree.nodeMainToken(node), "split conjunction into separate assertions");
                        break;
                    }
                };
            }
            if (self.selected(&.{ .Z010, .Z029 })) {
                const value = try self.facts.resolve(self.file, call.ast.fn_expr);
                if (value == .function) {
                    const d = value.function;
                    const target = &self.project.files[@backingInt(d.file)].tree; // safe: enum identities index their owning frozen tables without narrowing.
                    const decl = self.project.models[@backingInt(d.file)].declarations[d.index]; // safe: enum identities index their owning frozen tables without narrowing.
                    var fb: [1]Ast.Node.Index = undefined;
                    const function = target.fullFnProto(&fb, decl.node).?;
                    var it = function.iterate(target);
                    // Method syntax consumes the receiver parameter implicitly.
                    if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
                        const lhs = tree.nodeData(call.ast.fn_expr).node_and_token[0];
                        var receiver_value = try self.facts.resolve(self.file, lhs);
                        while (receiver_value == .pointer) receiver_value = receiver_value.pointer.*;
                        if (receiver_value == .instance) _ = it.next();
                    }
                    for (call.ast.params) |arg| {
                        const param = it.next() orelse break;
                        if (param.type_expr) |t| {
                            try self.redundantType(arg, .{ .file = d.file, .node = t }, false);
                            try self.redundantAs(.Z029, t, d.file, arg, tree.nodeMainToken(arg));
                        }
                    }
                }
            }
        }
        if (tag == .field_access and self.config.has(.Z027)) {
            const pair = tree.nodeData(node).node_and_token;
            var value = try self.facts.resolve(self.file, pair[0]);
            while (value == .pointer) value = value.pointer.*;
            if (value == .instance) {
                if (self.facts.member(value.instance, tree.tokenSlice(pair[1]))) |decl| {
                    const record = self.project.models[@backingInt(decl.file)].declarations[decl.index]; // safe: enum identities index their owning frozen tables without narrowing.
                    if (record.kind != .field and record.kind != .function) try self.at(.Z027, pair[1], "access container declaration through its type");
                }
            }
        }
        if (self.config.has(.Z029)) {
            if (tree.fullArrayInit(&b, node)) |array| {
                if (array.ast.type_expr.unwrap()) |t| if (tree.fullArrayType(t)) |shape| for (array.ast.elements) |element| try self.redundantAs(.Z029, shape.ast.elem_type, self.file, element, tree.nodeMainToken(element));
            }
            if (tree.fullStructInit(&b, node)) |value| {
                var container: ?Facts.Container = null;
                if (value.ast.type_expr.unwrap()) |t| {
                    const fact = try self.facts.resolve(self.file, t);
                    if (fact == .container) container = fact.container;
                } else if (self.parent(node)) |p| {
                    if (tree.fullVarDecl(p)) |v| if (v.ast.type_node.unwrap()) |t| {
                        const fact = try self.facts.resolve(self.file, t);
                        if (fact == .container) container = fact.container;
                    };
                    if (tree.nodeTag(p) == .@"return") if (self.enclosingFunction(p)) |fn_node| {
                        var fb: [1]Ast.Node.Index = undefined;
                        if (tree.fullFnProto(&fb, fn_node).?.ast.return_type.unwrap()) |t| {
                            const fact = try self.facts.resolve(self.file, t);
                            if (fact == .container) container = fact.container;
                        }
                    };
                }
                if (container) |c| for (value.ast.fields) |field_value| {
                    const first = tree.firstToken(field_value);
                    if (first < 2 or tree.tokenTag(first - 1) != .equal) continue;
                    const name = tree.tokenSlice(first - 2);
                    const decl = self.facts.member(c, name) orelse continue;
                    const target = &self.project.files[@backingInt(decl.file)].tree; // safe: enum identities index their owning frozen tables without narrowing.
                    const record = self.project.models[@backingInt(decl.file)].declarations[decl.index]; // safe: enum identities index their owning frozen tables without narrowing.
                    if (record.kind != .field) continue;
                    if (target.fullContainerField(record.node).?.ast.type_expr.unwrap()) |t| try self.redundantAs(.Z029, t, decl.file, field_value, tree.nodeMainToken(field_value));
                };
            }
        }
    }
}

fn poisonRule(self: *Runner) RunError!void {
    if (!self.config.has(.Z030)) return;
    for (self.project.models[@backingInt(self.file)].declarations) |decl| { // safe: enum identities index their owning frozen tables without narrowing.
        switch (try Poison.analyze(self.a, self.project, self.file, decl)) {
            .irrelevant, .accepted => {},
            .budget => {
                self.complete = false;
                try self.coverage.append(self.a, .{ .file = self.file, .rule = .Z030, .reason = .budget_exhausted, .detail = "Z030 instruction/depth budget exhausted" });
            },
            .warning => |message| try self.at(.Z030, decl.token, message),
            .unknown => |detail| try self.coverage.append(self.a, .{ .file = self.file, .rule = .Z030, .reason = .unsupported, .detail = detail }),
        }
    }
}

fn unknownCoverage(self: *Runner) RunError!void {
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: enum identities index their owning frozen tables without narrowing.
    for (tree.nodes.items(.tag), 0..) |_, n| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n)); // safe: validated file identities and budgeted std source indexes fit u32.
        var b: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &b);
        if (args.len != 1 or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) continue;
        const value = try self.facts.resolve(self.file, node);
        if (value == .unknown) try self.coverage.append(self.a, .{ .file = self.file, .start = tree.tokenStart(tree.nodeMainToken(node)), .reason = .unresolved, .detail = @tagName(value.unknown) });
    }
}

test "core diagnostics distinguish invalid parsing and unused imports" {
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "syntax", .bytes = "const x = ;" },
        .{ .name = "bindings", .bytes = "const dep = @import(\"dep\"); const used = @import(\"used\"); pub fn f() void { _ = used; }" },
    }, &.{}, .{});
    defer project.deinit();
    var report = try run(std.testing.allocator, &project, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 2), report.diagnostics.len); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expectEqual(rules.Rule.Z013, report.diagnostics[0].rule);
    try std.testing.expectEqual(rules.Rule.Z003, report.diagnostics[1].rule);
}

test "core diagnostics suppression cannot hide incomplete lowering" {
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "fn f(x: u8) void {}" }}, &.{}, .{});
    defer project.deinit();
    var report = try run(std.testing.allocator, &project, .{});
    defer report.deinit();
    try std.testing.expect(!report.complete);
    try std.testing.expectEqual(.invalid_lowering, report.coverage[0].reason);
}
