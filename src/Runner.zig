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
            try runner.amendedPolicies();
            try runner.syntaxRules();
            try runner.contextRules();
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
    return self.emitRelated(rule, start, end, message, &.{});
}
fn emitRelated(self: *Runner, rule: rules.Rule, start: u32, end: u32, message: []const u8, related: []const Report.Span) RunError!void {
    if (!self.config.has(rule)) return;
    const file = &self.project.files[@backingInt(self.file)]; // safe: enum identities index their owning frozen tables without narrowing.
    const line = file.line(start);
    for (self.suppressions) |*suppression| if (try suppression.matches(rule, line, start)) {
        self.suppressed += 1;
        return;
    };
    try self.diagnostics.append(self.a, .{ .rule = rule, .rule_version = 2, .class = switch (rule.group()) {
        .correctness => .correctness,
        .zig_style => .zig_style,
        .family_policy => .family_policy,
    }, .severity = if (rule == .Z003) .@"error" else .warning, .span = .{ .file = self.file, .start = start, .end = end, .line = line + 1, .column = start - file.lines[line] + 1 }, .message = message, .related = related, .bug_class = rule.purpose() });
}

fn at(self: *Runner, rule: rules.Rule, token: std.zig.Ast.TokenIndex, message: []const u8) RunError!void {
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const start = tree.tokenStart(token);
    try self.emit(rule, start, start + @as(u32, @intCast(tree.tokenSlice(token).len)), message); // safe: validated file identities and budgeted std source indexes fit u32.
}

fn atDefinition(self: *Runner, rule: rules.Rule, token: Ast.TokenIndex, message: []const u8, definition: Facts.Decl) RunError!void {
    const file = &self.project.files[@backingInt(definition.file)]; // safe: a resolved declaration carries a validated file identity.
    const declaration = self.project.models[@backingInt(definition.file)].declarations[definition.index]; // safe: the definition indexes its owning frozen declaration table.
    const start = file.tree.tokenStart(declaration.token);
    const line = file.line(start);
    const related = try self.a.dupe(Report.Span, &.{.{ .file = definition.file, .start = start, .end = start + @as(u32, @intCast(file.tree.tokenSlice(declaration.token).len)), .line = line + 1, .column = start - file.lines[line] + 1 }}); // safe: token lengths and offsets are bounded by the checked u32 source budget.
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: the selected runner file indexes its frozen project.
    const site = tree.tokenStart(token);
    try self.emitRelated(rule, site, site + @as(u32, @intCast(tree.tokenSlice(token).len)), message, related); // safe: the selected token lies within the checked u32 source budget.
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
    const file_index = @backingInt(self.file); // safe: selected identity indexes this frozen project.
    const tree = &self.project.files[file_index].tree;
    const declarations = self.project.models[file_index].declarations;
    var candidates: std.StringHashMapUnmanaged(void) = .empty;
    defer candidates.deinit(self.a);
    var indexes: std.ArrayList(u32) = .empty;
    for (declarations, 0..) |decl, index| {
        if (decl.kind != .variable or decl.public or decl.exported or decl.references != 0) continue;
        const value = tree.fullVarDecl(decl.node).?.ast.init_node.unwrap() orelse continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, value, &buffer);
        if (args.len != 1 or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "@import")) continue;
        try candidates.put(self.a, decl.name, {});
        try indexes.append(self.a, @intCast(index)); // safe: bounded declaration table fits u32.
    }
    if (indexes.items.len == 0) return;
    const used = try self.a.alloc(bool, declarations.len);
    @memset(used, false);
    var undecided: std.StringHashMapUnmanaged(void) = .empty;
    defer undecided.deinit(self.a);
    // One pass for all candidates: spelling filters work, declaration identity decides usage.
    for (tree.nodes.items(.tag), 0..) |tag, n| {
        if (tag != .field_access) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n)); // safe: bounded AST node table fits u32.
        const pair = tree.nodeData(node).node_and_token;
        const name = try Model.identifier(self.a, tree.tokenSlice(pair[1]));
        if (!candidates.contains(name)) continue;
        if (try self.facts.definition(self.file, node)) |definition| {
            if (definition.file == self.file) used[definition.index] = true;
        } else {
            const receiver = try self.facts.resolve(self.file, pair[0]);
            try self.unknown(.Z013, node, if (receiver == .unknown) receiver.unknown else .unsupported);
            try undecided.put(self.a, name, {});
        }
    }
    for (indexes.items) |index| {
        const decl = declarations[index];
        if (!used[index] and !undecided.contains(decl.name)) try self.at(.Z013, decl.token, try self.a.print("unused private import '{s}'", .{decl.name}));
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
    if (!self.config.has(.Z011)) return;
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: selected identity belongs to the frozen project.
    // Node-table enumeration covers every expression position exactly once.
    for (tree.nodes.items(.tag), 0..) |_, n| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(n)); // safe: validated file identities and budgeted std source indexes fit u32.
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (try self.facts.definition(self.file, call.ast.fn_expr)) |definition| {
            var deprecated_definition: ?Facts.Decl = if (self.deprecated(definition)) definition else null;
            if (deprecated_definition == null) {
                const value = try self.facts.resolve(self.file, call.ast.fn_expr);
                if (value == .function and self.deprecated(value.function)) deprecated_definition = value.function;
            }
            if (deprecated_definition) |resolved| try self.atDefinition(.Z011, if (tree.nodeTag(call.ast.fn_expr) == .field_access) tree.nodeData(call.ast.fn_expr).node_and_token[1] else tree.nodeMainToken(call.ast.fn_expr), "call uses a deprecated declaration", resolved);
        } else {
            const value = try self.facts.resolve(self.file, call.ast.fn_expr);
            try self.unknown(.Z011, call.ast.fn_expr, if (value == .unknown) value.unknown else .unsupported);
        }
    }
}

fn amendedPolicies(self: *Runner) RunError!void {
    if (!self.selected(&.{ .Z012, .Z026 })) return;
    const index = @backingInt(self.file); // safe: validated file identity indexes its frozen project.
    const tree = &self.project.files[index].tree;
    if (self.config.has(.Z012)) for (self.project.models[index].declarations) |decl| {
        if (decl.kind != .function or !decl.public) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const function = tree.fullFnProto(&buffer, decl.node).?;
        if (function.ast.return_type.unwrap()) |t| try self.privateType(t, decl.token, 0);
        var it = function.iterate(tree);
        while (it.next()) |param| if (param.type_expr) |t| try self.privateType(t, decl.token, 0);
    };
    if (self.config.has(.Z026)) for (tree.nodes.items(.tag), 0..) |tag, n| {
        if (tag != .@"catch") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n)); // safe: bounded std AST indexes fit u32.
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.blockStatements(&buffer, tree.nodeData(node).node_and_node[1])) |statements| {
            if (statements.len == 0) try self.at(.Z026, tree.nodeMainToken(node), "empty catch discards an error; write a reason at this site");
        }
    };
}

fn privateType(self: *Runner, node: Ast.Node.Index, site: Ast.TokenIndex, depth: usize) RunError!void {
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: validated source identity.
    if (depth >= 128) return self.unknown(.Z012, node, .budget);
    if (tree.fullPtrType(node)) |pointer| return self.privateType(pointer.ast.child_type, site, depth + 1);
    switch (tree.nodeTag(node)) {
        .identifier, .field_access => {
            const definition = (try self.facts.definition(self.file, node)) orelse {
                const value = try self.facts.resolve(self.file, node);
                if (value == .unknown) try self.unknown(.Z012, node, value.unknown);
                return;
            };
            const decl = self.project.models[@backingInt(definition.file)].declarations[definition.index]; // safe: resolved declaration belongs to frozen model.
            if (decl.kind == .parameter or decl.public or decl.exported) return;
            const value = try self.facts.resolve(self.file, node);
            if (value == .unknown) return self.unknown(.Z012, node, value.unknown);
            // A primitive alias can be named as the primitive; error-set policy is not Z012.
            if (value != .container) return;
            if (value.container.scope == decl.scope) return; // An enclosing @This receiver is nameable through its public owner.
            if (try self.facts.origin(definition)) |origin| {
                const original = self.project.models[@backingInt(origin.file)].declarations[origin.index]; // safe: resolved alias provenance.
                if (original.public or original.exported) return;
            }
            // A public alias to this same concrete container makes the type nameable.
            for (self.project.models[@backingInt(definition.file)].declarations, 0..) |alias, i| {
                if (!alias.public or alias.kind != .variable) continue;
                const exposed = try self.facts.declaration(.{ .file = definition.file, .index = @intCast(i) }); // safe: bounded declaration inventory.
                if (exposed == .container and std.meta.eql(exposed.container, value.container)) return;
            }
            try self.atDefinition(.Z012, site, try self.a.print("public signature exposes private type '{s}'", .{decl.name}), definition);
        },
        .optional_type => try self.privateType(tree.nodeData(node).node, site, depth + 1),
        .error_union => try self.privateType(tree.nodeData(node).node_and_node[1], site, depth + 1),
        .grouped_expression => try self.privateType(tree.nodeData(node).node_and_token[0], site, depth + 1),
        .call, .call_one, .call_comma, .call_one_comma => try self.unknown(.Z012, node, .comptime_dependent),
        else => {},
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

fn lineLength(self: *Runner) RunError!void {
    const file = &self.project.files[@backingInt(self.file)]; // safe: enum identities index their owning frozen tables without narrowing.
    if (self.config.has(.Z024)) for (file.lines, 0..) |start, l| {
        var end: u32 = if (l + 1 < file.lines.len) file.lines[l + 1] - 1 else @intCast(file.source.len); // safe: validated file identities and budgeted std source indexes fit u32.
        if (end > start and file.source[end - 1] == '\r') end -= 1;
        if (end - start > self.config.max_line_length) try self.emit(.Z024, start + self.config.max_line_length, end, "line exceeds configured byte length");
    };
}

fn syntaxRules(self: *Runner) RunError!void {
    if (!self.selected(&.{ .Z001, .Z005, .Z006, .Z009, .Z014, .Z031, .Z032 })) return;
    const index = @backingInt(self.file); // safe: selected identity indexes this frozen project.
    const tree = &self.project.files[index].tree;
    const model = &self.project.models[index];
    for (model.declarations) |decl| if (decl.kind == .field and decl.scope == 0) {
        if (!names.isPascalCase(self.project.inputs[index].stem)) try self.emit(.Z009, 0, 0, "file struct label should use TitleCase; caller owns file naming");
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
                switch (value) {
                    .unknown => |reason| {
                        try self.unknown(.Z006, expr, reason);
                        if (names.acronymIssue(name)) try self.unknown(.Z032, expr, reason);
                    },
                    .container, .primitive, .error_set, .pointer, .optional, .error_union => {
                        if (names.acronymIssue(name)) try self.at(.Z032, decl.token, "treat acronyms in type names as ordinary words, for example XmlParser");
                    },
                    .function => |definition| {
                        const target = &self.project.files[@backingInt(definition.file)].tree; // safe: resolved declaration belongs to its frozen file.
                        const record = self.project.models[@backingInt(definition.file)].declarations[definition.index];
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
                    else => try self.at(.Z006, decl.token, "value binding should use snake_case"),
                }
            }
        }
    }
}

fn contextRules(self: *Runner) RunError!void {
    if (!self.config.has(.Z016)) return;
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: selected file identity belongs to the project.
    for (tree.nodes.items(.tag), 0..) |_, n| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n)); // safe: bounded AST node table fits u32.
        var cb: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&cb, node)) |call| {
            if (self.config.has(.Z016) and call.ast.params.len != 0 and tree.nodeTag(call.ast.params[0]) == .bool_and) {
                const value = try self.facts.resolve(self.file, call.ast.fn_expr);
                if (value == .function) for (self.project.imports) |mapping| {
                    if (!std.mem.eql(u8, mapping.spelling, "std")) continue;
                    const debug = (try self.standardContainer(.{ .file = mapping.target, .scope = 0 }, &.{"debug"})) orelse continue;
                    const assertion = self.facts.member(debug, "assert") orelse continue;
                    if (std.meta.eql(assertion, value.function)) {
                        try self.at(.Z016, tree.nodeMainToken(node), "consider separate assertions only when evaluation and short circuit effects are preserved");
                        break;
                    }
                };
            }
        }
    }
}

fn unknownCoverage(self: *Runner) RunError!void {
    const tree = &self.project.files[@backingInt(self.file)].tree; // safe: enum identities index their owning frozen tables without narrowing.
    for (self.project.models[@backingInt(self.file)].import_nodes) |node| { // safe: the selected file indexes its frozen project model.
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
