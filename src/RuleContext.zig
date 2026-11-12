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
/// An allocator that frees, under `allocator` (the run's arena, which keeps all it gives until the
/// run ends): what a rule makes and drops within its own work, a scratch arena among them
/// (`Bounds`' reading of one function), is made on it, so dropping it gives the memory back.
backing: std.mem.Allocator = std.heap.page_allocator,
project: *const Project,
file: Project.FileId,
config: rules.Config,
facts: *Facts,
definitions: []const rules.Definition,
sink: *Sink,
/// The run's compiled rules: the facts they declare are the ones `Taint` solves together.
compiled: []const Rule = &.{},

pub const Error = Facts.ResolveError || Project.QueryError || error{ AmbiguousSuppression, InvalidSelection };

/// Makes `allocator` the run's own (`Facts.gpa`) and returns the one it was: what a function
/// that fills a `Facts.memo` computes, its callees' memory among it, is kept for the run, as a
/// rule's own memory for one file is given back when the rule is done with the file. Restored
/// on the way out: `const rule_memory = c.keep(); defer c.allocator = rule_memory;`.
pub fn keep(self: *RuleContext) std.mem.Allocator {
    const own = self.allocator;
    self.allocator = self.facts.gpa;
    return own;
}
/// Where a rule's findings go. Its owner embeds it in its own state and gets that back from
/// the sink a callback is given with `@fieldParentPtr`.
pub const Sink = struct {
    diagnostic: *const fn (*Sink, rules.Rule, u32, u32, []const u8, []const Report.Span, []const Report.Edit) Error!void,
    /// A run error of the checked file: a configuration that names nothing there.
    refuse: *const fn (*Sink, []const u8) Error!void,
    /// The configuration another selected file is checked with.
    config: *const fn (*Sink, Project.FileId) rules.Config,
    /// Whether a finding of the rule at the offset would be suppressed, asked without using
    /// a suppression: a rule that leaves a finding to another (D001's container for what it
    /// holds) leaves it only where that one is reported. A sink that suppresses nothing says no.
    suppresses: *const fn (*Sink, rules.Rule, u32) bool = suppressesNothing,

    fn suppressesNothing(_: *Sink, _: rules.Rule, _: u32) bool {
        return false;
    }
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
        // A type given where the parameter takes a value: turned away only where every build's
        // parameter type does.
        if (given_type) {
            var rejects: Facts.Join = .{};
            for (Facts.valueParts(&kind)) |part| rejects.add(part, switch (part) {
                .container, .pointer, .optional => true,
                .primitive => |name| !std.mem.eql(u8, name, "type"),
                .alternatives => null, // a choice, never a part (valueParts): not known
                else => false,
            });
            if (rejects.all() == true) return false;
        }
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
        // A callee that does not resolve may make anything: its call is no type shown, so it
        // turns no candidate away (`accepts` rejects only on a type it sees given).
        const decl = switch (try self.facts.definition(self.file, call.ast.fn_expr)) {
            .decl => |found| found,
            .none, .unknown => return false,
        };
        const function = switch (try self.facts.origin(decl)) {
            .decl => |found| found,
            .none, .unknown => return false,
        };
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
        // A type in every build's reading of the name.
        .identifier, .field_access => {
            const value = try self.facts.resolve(self.file, node);
            var each: Facts.Join = .{};
            for (Facts.valueParts(&value)) |part| each.add(part, switch (part) {
                .container => true,
                .primitive => |name| !std.mem.eql(u8, name, "type"),
                .alternatives => null, // a choice, never a part (valueParts): not known
                else => false,
            });
            return each.all() == true;
        },
        else => return false,
    }
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
/// Whether a finding of `rule` at `token` would be suppressed (`Sink.suppresses`), the
/// suppression left unused.
pub fn suppressedAt(self: *RuleContext, rule: rules.Rule, token: std.zig.Ast.TokenIndex) Error!bool {
    const tree = try self.project.syntax(try self.source());
    if (token >= tree.tokens.len) return error.InvalidHandle;
    return self.sink.suppresses(self.sink, rule, tree.tokenStart(token));
}
/// Stops the run: what the configuration asks of the checked file names nothing in it (a stale
/// function-length exception, a disallowed declaration that does not resolve). A site is a
/// finding or nothing; a configuration that cannot be read is neither.
pub fn refuse(self: *RuleContext, why: []const u8) Error!void {
    return self.sink.refuse(self.sink, why);
}
/// Whether a token is test code: inside a `test` block, or in an input the caller classifies as a
/// test. Nothing else is: a file only tests import, a private function only tests call and a fuzz
/// target outside a `test` block are production code. The one answer for every rule that exempts
/// test code.
pub fn inTest(self: *const RuleContext, token: std.zig.Ast.TokenIndex) bool {
    return inTestScope(self.project.at(self.file), token);
}
/// Whether a token of `held` is test code: a test input, or inside a `test` block.
fn inTestScope(held: *const Project.Source, token: Ast.TokenIndex) bool {
    if (held.input.classification == .@"test") return true;
    var scope: ?Model.Scope.Id = held.model.scopeOf(token);
    while (scope) |id| {
        const each = &held.model.scopes[@backingInt(id)];
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
    const held = self.project.at(file).file;
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
