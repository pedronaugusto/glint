//! Built-in code rules use the public rule context, like project-owned rules.
const std = @import("std");
const Facts = @import("Facts.zig");
const rules = @import("Rule.zig");
const Model = @import("Model.zig");
const names = @import("names.zig");
const Ast = std.zig.Ast;
const Project = @import("Project.zig");
const Context = @import("RuleContext.zig");
const DeadDeclarations = @import("DeadDeclarations.zig");
const RunError = Context.Error;

pub fn check(context: *Context) RunError!void {
    try parser(context);
    try lineLength(context);
    if ((try context.project.status(try context.source())) != .parsed) return;
    try unusedImports(context);
    try priorityRules(context);
    try amendedPolicies(context);
    try syntaxRules(context);
    try contextRules(context);
    try sourcePolicies(context);
    try functionLengths(context);
    try disallowed(context);
    try DeadDeclarations.check(context);
    try unknownCoverage(context);
}

fn parser(self: *Context) RunError!void {
    if (!self.config.has(.Z003)) return;
    const file = &self.project.files[self.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    for (file.tree.errors) |err| {
        if (err.is_note) continue;
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        file.tree.renderError(err, &writer.writer) catch return error.OutOfMemory;
        const offset = file.tree.tokenStart(err.token) + file.tree.errorOffset(err);
        try self.emit(.Z003, offset, offset, try writer.toOwnedSlice());
    }
}

fn unusedImports(self: *Context) RunError!void {
    if (!self.config.has(.Z013)) return;
    const file_index = self.file.raw(); // safe: selected identity indexes this frozen project.
    const tree = &self.project.files[file_index].tree;
    const declarations = self.project.models[file_index].declarations;
    var candidates: std.StringHashMapUnmanaged(void) = .empty;
    defer candidates.deinit(self.allocator);
    var indexes: std.ArrayList(u32) = .empty;
    for (declarations, 0..) |decl, index| {
        if (decl.kind != .variable or decl.public or decl.exported or decl.references != 0) continue;
        const value = tree.fullVarDecl(decl.node).?.ast.init_node.unwrap() orelse continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, value, &buffer);
        if (args.len != 1 or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "@import")) continue;
        try candidates.put(self.allocator, decl.name, {});
        try indexes.append(self.allocator, @intCast(index)); // safe: bounded declaration table fits u32.
    }
    if (indexes.items.len == 0) return;
    const used = try self.allocator.alloc(bool, declarations.len);
    @memset(used, false);
    var undecided: std.StringHashMapUnmanaged(void) = .empty;
    defer undecided.deinit(self.allocator);
    // One pass for all candidates: spelling filters work, declaration identity decides usage.
    for (tree.nodes.items(.tag), 0..) |tag, n| {
        if (tag != .field_access) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n)); // safe: bounded AST node table fits u32.
        const pair = tree.nodeData(node).node_and_token;
        const name = try Model.identifier(self.allocator, tree.tokenSlice(pair[1]));
        if (!candidates.contains(name)) continue;
        if (try self.facts.definition(self.file, node)) |definition| {
            if (definition.file.eql(self.file)) used[definition.index] = true;
        } else {
            const receiver = try self.facts.resolve(self.file, pair[0]);
            try unknown(self, .Z013, node, if (receiver == .unknown) receiver.unknown else .unsupported);
            try undecided.put(self.allocator, name, {});
        }
    }
    for (indexes.items) |index| {
        const decl = declarations[index];
        if (!used[index] and !undecided.contains(decl.name)) try self.at(.Z013, decl.token, try self.allocator.print("unused private import '{s}'", .{decl.name}));
    }
}

fn selected(self: *const Context, selection: []const rules.Rule) bool {
    return self.selected(selection);
}
fn unknown(self: *Context, rule: rules.Rule, node: Ast.Node.Index, reason: Facts.Unknown) RunError!void {
    return self.unknown(rule, node, reason);
}

fn priorityRules(self: *Context) RunError!void {
    if (!self.config.has(.Z011)) return;
    const tree = &self.project.files[self.file.raw()].tree; // safe: selected identity belongs to the frozen project.
    // Node-table enumeration covers every expression position exactly once.
    for (tree.nodes.items(.tag), 0..) |_, n| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(n)); // safe: validated file identities and budgeted std source indexes fit u32.
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (try self.facts.definition(self.file, call.ast.fn_expr)) |definition| {
            var deprecated_definition: ?Facts.Decl = if (deprecated(self, definition)) definition else null;
            if (deprecated_definition == null) {
                const value = try self.facts.resolve(self.file, call.ast.fn_expr);
                if (value == .function and deprecated(self, value.function)) deprecated_definition = value.function;
            }
            if (deprecated_definition) |resolved| try self.atDefinition(.Z011, if (tree.nodeTag(call.ast.fn_expr) == .field_access) tree.nodeData(call.ast.fn_expr).node_and_token[1] else tree.nodeMainToken(call.ast.fn_expr), "call uses a deprecated declaration", resolved);
        } else {
            const value = try self.facts.resolve(self.file, call.ast.fn_expr);
            try unknown(self, .Z011, call.ast.fn_expr, if (value == .unknown) value.unknown else .unsupported);
        }
    }
}

fn amendedPolicies(self: *Context) RunError!void {
    if (!selected(self, &.{ .Z012, .Z026 })) return;
    const index = self.file.raw(); // safe: validated file identity indexes its frozen project.
    const tree = &self.project.files[index].tree;
    if (self.config.has(.Z012)) for (self.project.models[index].declarations) |decl| {
        if (decl.kind != .function or !decl.public) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const function = tree.fullFnProto(&buffer, decl.node).?;
        if (function.ast.return_type.unwrap()) |t| try privateType(self, t, decl.token, 0);
        var it = function.iterate(tree);
        while (it.next()) |param| if (param.type_expr) |t| try privateType(self, t, decl.token, 0);
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

fn privateType(self: *Context, node: Ast.Node.Index, site: Ast.TokenIndex, depth: usize) RunError!void {
    const tree = &self.project.files[self.file.raw()].tree; // safe: validated source identity.
    if (depth >= 128) return unknown(self, .Z012, node, .budget);
    if (tree.fullPtrType(node)) |pointer| return privateType(self, pointer.ast.child_type, site, depth + 1);
    switch (tree.nodeTag(node)) {
        .identifier, .field_access => {
            const definition = (try self.facts.definition(self.file, node)) orelse {
                const value = try self.facts.resolve(self.file, node);
                if (value == .unknown) try unknown(self, .Z012, node, value.unknown);
                return;
            };
            const decl = self.project.models[definition.file.raw()].declarations[definition.index]; // safe: resolved declaration belongs to frozen model.
            if (decl.kind == .parameter or decl.public or decl.exported) return;
            const value = try self.facts.resolve(self.file, node);
            if (value == .unknown) return unknown(self, .Z012, node, value.unknown);
            // A primitive alias can be named as the primitive; error-set policy is not Z012.
            if (value != .container) return;
            if (value.container.scope == decl.scope) return; // An enclosing @This receiver is nameable through its public owner.
            if (try self.facts.origin(definition)) |origin| {
                const original = self.project.models[origin.file.raw()].declarations[origin.index]; // safe: resolved alias provenance.
                if (original.public or original.exported) return;
            }
            // A public alias to this same concrete container makes the type nameable.
            for (self.project.models[definition.file.raw()].declarations, 0..) |alias, i| {
                if (!alias.public or alias.kind != .variable) continue;
                const exposed = try self.facts.declaration(.{ .file = definition.file, .index = @intCast(i) }); // safe: bounded declaration inventory.
                if (exposed == .container and std.meta.eql(exposed.container, value.container)) return;
            }
            try self.atDefinition(.Z012, site, try self.allocator.print("public signature exposes private type '{s}'", .{decl.name}), definition);
        },
        .optional_type => try privateType(self, tree.nodeData(node).node, site, depth + 1),
        .error_union => try privateType(self, tree.nodeData(node).node_and_node[1], site, depth + 1),
        .grouped_expression => try privateType(self, tree.nodeData(node).node_and_token[0], site, depth + 1),
        .call, .call_one, .call_comma, .call_one_comma => try unknown(self, .Z012, node, .comptime_dependent),
        else => {},
    }
}

fn deprecated(self: *const Context, definition: Facts.Decl) bool {
    const tree = &self.project.files[definition.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const decl = self.project.models[definition.file.raw()].declarations[definition.index]; // safe: enum identities index their owning frozen tables without narrowing.
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

fn standardContainer(self: *Context, root: Facts.Container, path_parts: []const []const u8) RunError!?Facts.Container {
    var c = root;
    for (path_parts) |name| {
        const decl = self.facts.member(c, name) orelse return null;
        const v = try self.facts.declaration(decl);
        if (v != .container) return null;
        c = v.container;
    }
    return c;
}

fn lineLength(self: *Context) RunError!void {
    const file = &self.project.files[self.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    if (self.config.has(.Z024)) for (file.lines, 0..) |start, l| {
        var end: u32 = if (l + 1 < file.lines.len) file.lines[l + 1] - 1 else @intCast(file.source.len); // safe: validated file identities and budgeted std source indexes fit u32.
        if (end > start and file.source[end - 1] == '\r') end -= 1;
        if (end - start > self.config.max_line_length) try self.emit(.Z024, start + self.config.max_line_length, end, "line exceeds configured byte length");
    };
}

fn syntaxRules(self: *Context) RunError!void {
    if (!selected(self, &.{ .Z001, .Z005, .Z006, .Z009, .Z014, .Z031, .Z032 })) return;
    const index = self.file.raw(); // safe: selected identity indexes this frozen project.
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
                        try unknown(self, .Z006, expr, reason);
                        if (names.acronymIssue(name)) try unknown(self, .Z032, expr, reason);
                    },
                    .container, .primitive, .error_set, .pointer, .optional, .error_union => {
                        if (names.acronymIssue(name)) try self.at(.Z032, decl.token, "treat acronyms in type names as ordinary words, for example XmlParser");
                    },
                    .function => |definition| {
                        const target = &self.project.files[definition.file.raw()].tree; // safe: resolved declaration belongs to its frozen file.
                        const record = self.project.models[definition.file.raw()].declarations[definition.index];
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

fn contextRules(self: *Context) RunError!void {
    if (!self.config.has(.Z016)) return;
    const tree = &self.project.files[self.file.raw()].tree; // safe: selected file identity belongs to the project.
    for (tree.nodes.items(.tag), 0..) |_, n| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n)); // safe: bounded AST node table fits u32.
        var cb: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&cb, node)) |call| {
            if (self.config.has(.Z016) and call.ast.params.len != 0 and tree.nodeTag(call.ast.params[0]) == .bool_and) {
                const value = try self.facts.resolve(self.file, call.ast.fn_expr);
                if (value == .unknown) try self.unknown(.P005, call.ast.fn_expr, value.unknown);
                if (value == .function) for (self.project.imports) |mapping| {
                    if (!std.mem.eql(u8, mapping.spelling, "std")) continue;
                    const debug = (try standardContainer(self, .{ .file = mapping.target, .scope = 0 }, &.{"debug"})) orelse continue;
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

fn unknownCoverage(self: *Context) RunError!void {
    const tree = &self.project.files[self.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    for (self.project.models[self.file.raw()].import_nodes) |node| { // safe: the selected file indexes its frozen project model.
        var b: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &b);
        if (args.len != 1 or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) continue;
        const value = try self.facts.resolve(self.file, node);
        if (value == .unknown) try self.sink.coverage(self.sink.data, .{ .file = self.file, .start = tree.tokenStart(tree.nodeMainToken(node)), .reason = .unresolved, .detail = @tagName(value.unknown) });
    }
}

fn inTest(self: *const Context, token: Ast.TokenIndex) bool {
    if (self.project.inputs[self.file.raw()].classification == .@"test") return true;
    const model = &self.project.models[self.file.raw()];
    var scope: ?u32 = model.token_scopes[token];
    while (scope) |index| {
        if (model.scopes[index].kind == .@"test") return true;
        scope = model.scopes[index].parent;
    }
    return false;
}
fn hasReason(self: *const Context, token: Ast.TokenIndex, prefix: []const u8, previous: bool) bool {
    const file = &self.project.files[self.file.raw()];
    const line = file.line(file.tree.tokenStart(token));
    for (file.comments) |comment| {
        if (comment.line != line and !(previous and line != 0 and comment.line == line - 1)) continue;
        const raw = std.mem.trim(u8, file.source[comment.start + 2 .. comment.end], " \t\r");
        if (std.mem.startsWith(u8, raw, prefix) and std.mem.trim(u8, raw[prefix.len..], " \t\r").len != 0) return true;
    }
    return false;
}
fn isCast(name: []const u8, all: bool) bool {
    const builtin = std.zig.BuiltinFn.list.get(name) orelse return false;
    return switch (builtin.tag) {
        .const_cast, .ptr_cast, .align_cast, .int_from_ptr => true,
        .as, .bit_cast, .int_cast, .float_cast, .float_from_int, .int_from_float, .ptr_from_int, .truncate, .enum_from_int, .int_from_enum, .from_backing_int, .backing_int, .addrspace_cast, .error_cast, .error_from_int, .int_from_error, .int_from_bool, .volatile_cast => all,
        else => false,
    };
}
fn sourcePolicies(self: *Context) RunError!void {
    if (!self.selected(&.{ .P001, .P002, .P004, .P005 })) return;
    const tree = &self.project.files[self.file.raw()].tree;
    if (self.config.has(.P001)) for (tree.tokens.items(.tag), 0..) |tag, i| {
        if (tag != .builtin) continue;
        const token: Ast.TokenIndex = @intCast(i); // safe: std tokens fit the checked source inventory.
        if (self.config.cast_scope == .production and inTest(self, token)) continue;
        if (isCast(tree.tokenSlice(token), self.config.casts == .all) and !hasReason(self, token, "safe:", false)) try self.at(.P001, token, "cast needs // safe: <site reason> on its line");
    };
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: std AST inventory fits u32.
        const token = tree.nodeMainToken(node);
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        if (self.config.has(.P002) and args.len == 1 and std.mem.eql(u8, tree.tokenSlice(token), "@setRuntimeSafety")) {
            if (tree.nodeTag(args[0]) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(args[0])), "false")) {
                if (!hasReason(self, token, "safe:", false)) try self.at(.P002, token, "safety-off site needs // safe: <boundary invariant and measured hot-loop evidence>");
            } else if (!(tree.nodeTag(args[0]) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(args[0])), "true"))) try self.unknown(.P002, node, .comptime_dependent);
        }
        if (inTest(self, token)) continue;
        if (self.config.has(.P004) and tag == .@"catch") {
            var rhs = tree.nodeData(node).node_and_node[1];
            while (tree.nodeTag(rhs) == .grouped_expression) rhs = tree.nodeData(rhs).node_and_token[0];
            if (tree.nodeTag(rhs) == .unreachable_literal and !hasReason(self, token, "unreachable:", true)) try self.at(.P004, token, "catch unreachable needs // unreachable: <invariant> on this or the previous line");
        }
        if (self.config.has(.P005)) {
            var call_buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&call_buffer, node) orelse continue;
            const value = try self.facts.resolve(self.file, call.ast.fn_expr);
            if (value == .unknown) try self.unknown(.P005, call.ast.fn_expr, value.unknown);
            if (value == .function) for (self.project.imports) |mapping| {
                if (!mapping.from.eql(self.file) or !std.mem.eql(u8, mapping.spelling, "std")) continue;
                const debug = (try standardContainer(self, .{ .file = mapping.target, .scope = 0 }, &.{"debug"})) orelse continue;
                const print = self.facts.member(debug, "print") orelse continue;
                if (std.meta.eql(print, value.function)) {
                    try self.atDefinition(.P005, token, "production debug print; use the project's output/logging contract", print);
                    break;
                }
            };
        }
    }
}
fn functionLengths(self: *Context) RunError!void {
    if (!self.config.has(.P003)) return;
    const file = &self.project.files[self.file.raw()];
    const tree = &file.tree;
    const used = try self.allocator.alloc(bool, self.config.function_exceptions.len);
    @memset(used, false);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .fn_decl) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: checked AST inventory.
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
                const inner: Ast.Node.Index = @fromBackingInt(@intCast(j)); // safe: checked AST inventory.
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
fn disallowed(self: *Context) RunError!void {
    if (!self.config.has(.P006) or self.config.disallowed.len == 0) return;
    const targets = try self.allocator.alloc(?Facts.Decl, self.config.disallowed.len);
    for (self.config.disallowed, 0..) |entry, e| {
        targets[e] = null;
        var source: ?Project.FileId = null;
        for (self.project.inputs, 0..) |input, i| if (std.mem.eql(u8, input.name, entry.source)) {
            if (source != null) return error.InvalidSelection;
            source = Project.FileId.fromRaw(@intCast(i)); // safe: checked project inventory.
        };
        const id = source orelse {
            try self.undecided(.P006, 0, .unresolved, "disallowed declaration source was not supplied");
            continue;
        };
        var parts = std.mem.splitScalar(u8, entry.declaration, '.');
        const first = parts.next().?;
        var definition: ?Facts.Decl = if (self.project.models[id.raw()].scopes[0].names.get(first)) |d| .{ .file = id, .index = d } else null;
        while (parts.next()) |part| {
            const previous = definition orelse break;
            const value = try self.facts.declaration(previous);
            if (value != .container or value.container.symbolic) {
                definition = null;
                break;
            }
            definition = self.facts.member(value.container, part);
        }
        if (definition) |resolved| targets[e] = try self.facts.origin(resolved);
        if (targets[e] == null) try self.undecided(.P006, 0, .unresolved, "disallowed declaration identity could not be resolved");
    }
    const tree = &self.project.files[self.file.raw()].tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier and tag != .field_access) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: checked AST inventory.
        const definition = (try self.facts.definition(self.file, node)) orelse {
            const value = try self.facts.resolve(self.file, node);
            if (value == .unknown) try self.unknown(.P006, node, value.unknown);
            continue;
        };
        const origin = (try self.facts.origin(definition)) orelse {
            try self.unknown(.P006, node, .cycle);
            continue;
        };
        for (targets, self.config.disallowed) |target, entry| if (target != null and std.meta.eql(target.?, origin)) {
            try self.atDefinition(.P006, tree.nodeMainToken(node), try self.allocator.print("disallowed declaration: {s}; use {s}", .{ entry.reason, entry.replacement }), origin);
        };
    }
}
