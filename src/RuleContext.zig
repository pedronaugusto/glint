//! Shared contract used by built-in and compiled project rules.
const std = @import("std");
const Project = @import("Project.zig");
const Ast = std.zig.Ast;
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const rules = @import("Rule.zig");
const Report = @import("Report.zig");
const RuleContext = @This();

allocator: std.mem.Allocator,
project: *const Project,
file: Project.FileId,
config: rules.Config,
facts: *Facts,
definitions: []const rules.Definition,
sink: *Sink,

pub const Error = Facts.ResolveError || Project.QueryError || error{ AmbiguousSuppression, InvalidSelection };
/// Where a rule's findings go. Its owner embeds it in its own state and gets that back from
/// the sink a callback is given with `@fieldParentPtr`.
pub const Sink = struct {
    diagnostic: *const fn (*Sink, rules.Rule, u32, u32, []const u8, []const Report.Span, []const Report.Edit) Error!void,
    coverage: *const fn (*Sink, Report.Coverage) Error!void,
    /// The configuration another selected file is checked with.
    config: *const fn (*Sink, Project.FileId) rules.Config,
};
/// Compiled rule. Metadata and callback are validated once before execution.
pub const Rule = struct { definition: rules.Definition, check: *const fn (*RuleContext) Error!void };
/// Checked immutable handle for all model queries.
pub fn source(self: *const RuleContext) Project.QueryError!Project.Handle {
    return self.project.handle(self.file);
}
/// Same-run declaration/type resolver. Unknown values carry their missing fact.
pub fn resolve(self: *RuleContext, node: Project.NodeId) Error!Facts.Value {
    return self.facts.resolve(self.file, try self.project.node(try self.source(), node));
}
/// The role `library` publishes for a resolved value: a function it declares, or a type or
/// instance of a container it declares, seen through pointers, optionals and error unions.
/// Null when the value is none of its published declarations; recognition follows the module
/// the program imports the library by, never file bytes or names.
pub fn role(self: *RuleContext, library: anytype, value: Facts.Value) Error!?@TypeOf(library).Role {
    return self.facts.role(library, value);
}
/// Whether `file` is one of the library's own files, reached from its module roots.
pub fn inLibrary(self: *RuleContext, library: anytype, file: Project.FileId) Error!bool {
    const found = try self.facts.publication(library);
    for (found.files) |own| if (own == file) return true;
    return false;
}
/// Whether `decl`'s parameters, past the first `skip` (a method's receiver), can take the
/// arguments of `call` (written in the checked file), by what Zig allows: as many, none a
/// literal where a struct is taken, and none a type where a value of a struct, a pointer or a
/// number is taken (a type goes only to a `type` or `anytype` parameter).
pub fn accepts(self: *RuleContext, decl: Facts.Decl, call: Ast.full.Call, skip: usize) Error!bool {
    const target = &self.project.at(decl.file).file.tree;
    const tree = &self.project.at(self.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const function = target.fullFnProto(&buffer, self.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return true;
    var it = function.iterate(target);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        if (position < skip) continue;
        const index = position - skip;
        if (index >= call.ast.params.len) return false;
        const argument = call.ast.params[index];
        const written = param.type_expr orelse continue;
        const literal = switch (tree.nodeTag(argument)) {
            .enum_literal, .number_literal, .string_literal, .char_literal => true,
            else => false,
        };
        const given_type = !literal and try self.isType(argument);
        if (!literal and !given_type) continue;
        const kind = try self.facts.resolve(decl.file, written);
        if (given_type) switch (kind) {
            .container, .pointer, .optional => return false,
            .primitive => |name| if (!std.mem.eql(u8, name, "type")) return false,
            else => {},
        };
        if (literal and kind == .container) {
            const scope_node = self.project.at(kind.container.file).model.scopes[@backingInt(kind.container.scope)].node;
            const owner = &self.project.at(kind.container.file).file.tree;
            if (scope_node == .root or owner.tokenTag(owner.nodeMainToken(scope_node)) == .keyword_struct) return false;
        }
    }
    return position - @min(position, skip) == call.ast.params.len;
}
/// Whether `node`, in the checked file, is a type: written as one (a pointer, array, optional or
/// error union type, a container), naming one, made by a call to a function that returns
/// `type`, or given by a builtin that makes types.
fn isType(self: *RuleContext, node: Ast.Node.Index) Error!bool {
    const tree = &self.project.at(self.file).file.tree;
    if (tree.fullPtrType(node) != null or tree.fullArrayType(node) != null) return true;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&buffer, node) != null) return true;
    var call_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&call_buffer, node)) |call| {
        const decl = (try self.facts.definition(self.file, call.ast.fn_expr)) orelse return false;
        const function = (try self.facts.origin(decl)) orelse return false;
        const record = self.project.at(function.file).model.declarations[@backingInt(function.index)];
        if (record.kind != .function) return false;
        const written = &self.project.at(function.file).file.tree;
        var proto_buffer: [1]Ast.Node.Index = undefined;
        const proto = written.fullFnProto(&proto_buffer, record.node) orelse return false;
        const result = proto.ast.return_type.unwrap() orelse return false;
        return written.nodeTag(result) == .identifier and std.mem.eql(u8, written.tokenSlice(written.nodeMainToken(result)), "type");
    }
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            for ([_][]const u8{ "@TypeOf", "@Vector", "@FieldType", "@Struct", "@Union", "@Tuple", "@Enum", "@EnumLiteral", "@Int", "@Pointer", "@Fn", "@This" }) |made| if (std.mem.eql(u8, name, made)) return true;
            return false;
        },
        .optional_type, .error_union => return true,
        .identifier, .field_access => return switch (try self.facts.resolve(self.file, node)) {
            .container => true,
            .primitive => |name| !std.mem.eql(u8, name, "type"),
            else => false,
        },
        else => return false,
    }
}
/// A required library member that did not resolve, at the first import of its module in this
/// file. Recognition of that library is incomplete here, so a rule reports it as coverage.
pub const Drift = struct { module: []const u8, path: []const u8, why: Facts.Unknown, start: u32 };
pub fn drift(self: *RuleContext, library: anytype) Error!?Drift {
    const found = try self.facts.publication(library);
    const tree = try self.project.syntax(try self.source());
    const model = &self.project.at(self.file).model;
    for (found.gaps) |gap| for (model.import_nodes) |node| {
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        if (args.len != 1 or tree.nodeTag(args[0]) != .string_literal) continue;
        const literal = tree.tokenSlice(tree.nodeMainToken(args[0]));
        if (literal.len != gap.module.len + 2 or !std.mem.eql(u8, literal[1 .. literal.len - 1], gap.module)) continue;
        return .{ .module = gap.module, .path = gap.path, .why = gap.why, .start = tree.tokenStart(tree.nodeMainToken(node)) };
    };
    return null;
}

/// Reports one site; common runner supplies ordering, metadata and reason suppression.
pub fn emit(self: *RuleContext, rule: rules.Rule, start: u32, end: u32, message: []const u8) Error!void {
    return self.emitRelated(rule, start, end, message, &.{});
}
pub fn emitRelated(self: *RuleContext, rule: rules.Rule, start: u32, end: u32, message: []const u8, related: []const Report.Span) Error!void {
    return self.emitFixed(rule, start, end, message, related, &.{});
}
/// Reports one site with its deterministic fix: edits of the checked file's bytes.
pub fn emitFixed(self: *RuleContext, rule: rules.Rule, start: u32, end: u32, message: []const u8, related: []const Report.Span, fix: []const Report.Edit) Error!void {
    if (!self.config.has(rule)) return;
    if (rules.definition(rule, self.definitions) == null) return error.InvalidSelection;
    const bytes = try self.project.source(try self.source());
    if (start > end or end > bytes.len) return error.InvalidHandle;
    for (related) |span| {
        const target = self.project.handle(span.file);
        if (span.start > span.end or span.end > (try self.project.source(target)).len) return error.InvalidHandle;
    }
    for (fix) |e| if (e.start > e.end or e.end > bytes.len) return error.InvalidHandle;
    // Rules may retain no temporary message storage in the report: the sink copies it.
    return self.sink.diagnostic(self.sink, rule, start, end, message, related, fix);
}
/// Required uncertainty cannot be suppressed into a completed gating run.
pub fn undecided(self: *RuleContext, rule: rules.Rule, start: u32, reason: Report.Coverage.Reason, detail: []const u8) Error!void {
    if (!self.config.has(rule)) return;
    if (rules.definition(rule, self.definitions) == null) return error.InvalidSelection;
    if (start > (try self.project.source(try self.source())).len) return error.InvalidHandle;
    return self.sink.coverage(self.sink, .{ .file = self.file, .rule = rule, .start = start, .reason = reason, .detail = detail });
}
/// A site at `token` with its deterministic fix.
pub fn fixedAt(self: *RuleContext, rule: rules.Rule, token: std.zig.Ast.TokenIndex, message: []const u8, fix: []const Report.Edit) Error!void {
    const tree = try self.project.syntax(try self.source());
    if (token >= tree.tokens.len) return error.InvalidHandle;
    const span = tree.tokenToSpan(token);
    try self.emitFixed(rule, span.start, span.end, message, &.{}, fix);
}
pub fn at(self: *RuleContext, rule: rules.Rule, token: std.zig.Ast.TokenIndex, message: []const u8) Error!void {
    const tree = try self.project.syntax(try self.source());
    if (token >= tree.tokens.len) return error.InvalidHandle;
    const span = tree.tokenToSpan(token);
    try self.emit(rule, span.start, span.end, message);
}
pub fn unknown(self: *RuleContext, rule: rules.Rule, node: std.zig.Ast.Node.Index, reason: Facts.Unknown) Error!void {
    const tree = try self.project.syntax(try self.source());
    if (@backingInt(node) >= tree.nodes.len) return error.InvalidHandle; // safe: reject compiler node indexes outside the frozen source.
    try self.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), if (reason == .budget) .budget_exhausted else .unresolved, @tagName(reason));
}
/// The configuration `file` is checked with: a fact computed for the whole program reads
/// only the files whose rules ask for it.
pub fn configOf(self: *const RuleContext, file: Project.FileId) rules.Config {
    return self.sink.config(self.sink, file);
}
/// Whether a token is test code: a test input, or inside a `test` block.
pub fn inTest(self: *const RuleContext, token: std.zig.Ast.TokenIndex) bool {
    if (self.project.at(self.file).input.classification == .@"test") return true;
    const model = &self.project.at(self.file).model;
    var scope: ?Model.Scope.Id = model.scopeOf(token);
    while (scope) |id| {
        const each = &model.scopes[@backingInt(id)];
        if (each.kind == .@"test") return true;
        scope = each.parent;
    }
    return false;
}
pub fn selected(self: *const RuleContext, selection: []const rules.Rule) bool {
    for (selection) |rule| if (self.config.has(rule)) return true;
    return false;
}
/// A token of a file, as a finding's related place.
pub fn spanOf(self: *const RuleContext, file: Project.FileId, token: std.zig.Ast.TokenIndex) Report.Span {
    const held = &self.project.at(file).file;
    const named = held.tree.tokenToSpan(token);
    const line = held.line(named.start);
    return .{ .file = file, .start = named.start, .end = named.end, .line = line + 1, .column = held.column(named.start) };
}
pub fn atDefinition(self: *RuleContext, rule: rules.Rule, token: std.zig.Ast.TokenIndex, message: []const u8, definition: Facts.Decl) Error!void {
    const named = self.project.at(definition.file).model.declarations[@backingInt(definition.index)].token;
    const related = [_]Report.Span{self.spanOf(definition.file, named)};
    const site_tree = try self.project.syntax(try self.source());
    const site = site_tree.tokenToSpan(token);
    try self.emitRelated(rule, site.start, site.end, message, &related);
}
