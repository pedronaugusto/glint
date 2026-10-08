//! Selected rules share one frozen project and one fact resolver.
const std = @import("std");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const rules = @import("Rule.zig");
const Report = @import("Report.zig");
const Suppression = @import("Suppression.zig");
const Runner = @This();

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
file: Project.FileId = @fromBackingInt(0),

pub const RunError = Suppression.ParseError || std.mem.Allocator.Error;

pub fn run(gpa: std.mem.Allocator, project: *const Project, config: rules.Config) RunError!Report {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var runner: Runner = .{ .a = a, .project = project, .config = config, .facts = .{ .project = project, .gpa = a, .remaining = config.fact_budget } };
    defer runner.facts.deinit();
    for (project.inputs, 0..) |input, index| {
        if (!input.selected) continue;
        runner.file = @fromBackingInt(@intCast(index));
        const file = &project.files[index];
        runner.suppressions = try Suppression.parse(a, file);
        try runner.coverage.append(a, .{ .file = runner.file, .reason = switch (file.status) {
            .parsed => .parsed,
            .invalid_syntax => .invalid_syntax,
            .invalid_lowering => .invalid_lowering,
            .budget_exhausted => .budget_exhausted,
        } });
        for (std.meta.tags(rules.Rule)) |rule| {
            if (rule != .Z003 and rule != .Z013 and rule != .Z011 and rule != .Z012 and rule != .Z015 and rule != .Z023 and config.has(rule)) {
                runner.complete = false;
                try runner.coverage.append(a, .{ .file = runner.file, .rule = rule, .reason = .unsupported, .detail = "compatibility port not implemented yet" });
            }
        }
        try runner.parser();
        if (file.status == .parsed) {
            try runner.unusedImports();
            try runner.priorityRules();
        }
        if (file.status != .parsed) runner.complete = false;
        for (runner.suppressions) |suppression| if (!suppression.used) {
            runner.stale += 1;
        };
    }
    if (config.strict_suppressions and runner.stale != 0) runner.complete = false;
    std.mem.sort(Report.Diagnostic, runner.diagnostics.items, project, diagnosticLess);
    return .{ .arena = arena, .diagnostics = runner.diagnostics.items, .coverage = runner.coverage.items, .suppressed = runner.suppressed, .stale_suppressions = runner.stale, .complete = runner.complete };
}

fn diagnosticLess(project: *const Project, lhs: Report.Diagnostic, rhs: Report.Diagnostic) bool {
    const order = std.mem.order(u8, project.inputs[@backingInt(lhs.span.file)].name, project.inputs[@backingInt(rhs.span.file)].name);
    if (order != .eq) return order == .lt;
    if (lhs.span.start != rhs.span.start) return lhs.span.start < rhs.span.start;
    return @backingInt(lhs.rule) < @backingInt(rhs.rule);
}

fn emit(self: *Runner, rule: rules.Rule, start: u32, end: u32, message: []const u8) RunError!void {
    if (!self.config.has(rule)) return;
    const file = &self.project.files[@backingInt(self.file)];
    const line = file.line(start);
    for (self.suppressions) |*suppression| if (suppression.matches(rule, line)) {
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
    const tree = &self.project.files[@backingInt(self.file)].tree;
    const start = tree.tokenStart(token);
    try self.emit(rule, start, start + @as(u32, @intCast(tree.tokenSlice(token).len)), message);
}

fn parser(self: *Runner) RunError!void {
    if (!self.config.has(.Z003)) return;
    const file = &self.project.files[@backingInt(self.file)];
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
    const file_index = @backingInt(self.file);
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

fn priorityRules(self: *Runner) RunError!void {
    const index = @backingInt(self.file);
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
                    if (try self.receiver(t, decl.scope)) continue;
                }
                const order = try self.parameterOrder(t, param.comptime_noalias);
                if (order < maximum) try self.at(.Z023, param.name_token orelse tree.nodeMainToken(t), "parameter follows a later-ranked parameter");
                maximum = @max(maximum, order);
            }
        }
    }
    if (!self.config.has(.Z011)) return;
    // Node-table enumeration covers every expression position exactly once.
    for (tree.nodes.items(.tag), 0..) |_, n| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(n));
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (try self.facts.definition(self.file, call.ast.fn_expr)) |definition| {
            var is_deprecated = self.deprecated(definition);
            if (!is_deprecated) {
                const value = try self.facts.resolve(self.file, call.ast.fn_expr);
                if (value == .function) is_deprecated = self.deprecated(value.function);
            }
            if (is_deprecated) try self.at(.Z011, if (tree.nodeTag(call.ast.fn_expr) == .field_access) tree.nodeData(call.ast.fn_expr).node_and_token[1] else tree.nodeMainToken(call.ast.fn_expr), "call uses a deprecated declaration");
        }
    }
}

fn deprecated(self: *const Runner, definition: Facts.Decl) bool {
    const tree = &self.project.files[@backingInt(definition.file)].tree;
    const decl = self.project.models[@backingInt(definition.file)].declarations[definition.index];
    var token = tree.firstToken(decl.node);
    while (token > 0) {
        token -= 1;
        if (tree.tokenTag(token) == .keyword_pub) continue;
        if (tree.tokenTag(token) != .doc_comment) break;
        const line = std.mem.trim(u8, tree.tokenSlice(token)[3..], " \t\r");
        if (std.ascii.startsWithIgnoreCase(line, "this function is deprecated")) return true;
        if (std.ascii.startsWithIgnoreCase(line, "deprecated") and (line.len == 10 or std.mem.indexOfScalar(u8, ":;,. ", line[10]) != null)) return true;
    }
    return false;
}

fn privateType(self: *Runner, node: std.zig.Ast.Node.Index, site: std.zig.Ast.TokenIndex, error_position: bool, depth: usize) RunError!void {
    const tree = &self.project.files[@backingInt(self.file)].tree;
    if (depth >= 128) {
        try self.coverage.append(self.a, .{ .file = self.file, .reason = .budget_exhausted, .start = tree.tokenStart(site), .detail = "API type shape depth limit" });
        return;
    }
    switch (tree.nodeTag(node)) {
        .identifier => {
            const definition = (try self.facts.definition(self.file, node)) orelse return;
            const decl = self.project.models[@backingInt(definition.file)].declarations[definition.index];
            if (decl.kind == .parameter or decl.public or decl.exported or definition.file != self.file) return;
            const value = try self.facts.resolve(self.file, node);
            if (value == .container and value.container.scope == decl.scope) return; // @This alias.
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
    const model = &self.project.models[@backingInt(self.file)];
    var enclosing: ?u32 = scope;
    while (enclosing) |s| {
        if (model.scopes[s].kind == .container or model.scopes[s].kind == .file) return value.container.scope == s;
        enclosing = model.scopes[s].parent;
    }
    return false;
}

fn parameterOrder(self: *Runner, node: std.zig.Ast.Node.Index, modifier: ?std.zig.Ast.TokenIndex) RunError!u8 {
    const tree = &self.project.files[@backingInt(self.file)].tree;
    const value = try self.facts.resolve(self.file, node);
    if (value == .primitive and std.mem.eql(u8, value.primitive, "type")) return 0;
    if (modifier) |t| if (tree.tokenTag(t) == .keyword_comptime) return 1;
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

fn standardContainer(self: *Runner, root: Facts.Container, names: []const []const u8) RunError!?Facts.Container {
    var c = root;
    for (names) |name| {
        const decl = self.facts.member(c, name) orelse return null;
        const v = try self.facts.declaration(decl);
        if (v != .container) return null;
        c = v.container;
    }
    return c;
}

test "core diagnostics distinguish invalid parsing and unused imports" {
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "syntax", .bytes = "const x = ;" },
        .{ .name = "bindings", .bytes = "const dep = @import(\"dep\"); const used = @import(\"used\"); pub fn f() void { _ = used; }" },
    }, &.{}, .{});
    defer project.deinit();
    var report = try run(std.testing.allocator, &project, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 2), report.diagnostics.len);
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
