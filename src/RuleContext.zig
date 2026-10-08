//! Shared contract used by built-in and compiled project rules.
const std = @import("std");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const rules = @import("Rule.zig");
const Report = @import("Report.zig");
const RuleContext = @This();
const Usage = @import("Usage.zig");

allocator: std.mem.Allocator,
project: *const Project,
file: Project.FileId,
config: rules.Config,
facts: *Facts,
usage: ?*const Usage = null,
definitions: []const rules.Definition,
sink: Sink,

pub const Error = Facts.ResolveError || Project.QueryError || error{ AmbiguousSuppression, InvalidSelection };
pub const Sink = struct {
    data: *anyopaque,
    diagnostic: *const fn (*anyopaque, rules.Rule, u32, u32, []const u8, []const Report.Span) Error!void,
    coverage: *const fn (*anyopaque, Report.Coverage) Error!void,
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
/// Content identity of one frozen source; computed at most once per rule run.
pub fn sourceDigest(self: *RuleContext, file: Project.FileId) Error![32]u8 {
    _ = try self.project.handle(file);
    return self.facts.sourceDigest(file);
}

/// Reports one site; common runner supplies ordering, metadata and reason suppression.
pub fn emit(self: *RuleContext, rule: rules.Rule, start: u32, end: u32, message: []const u8) Error!void {
    return self.emitRelated(rule, start, end, message, &.{});
}
pub fn emitRelated(self: *RuleContext, rule: rules.Rule, start: u32, end: u32, message: []const u8, related: []const Report.Span) Error!void {
    if (!self.config.has(rule)) return;
    if (rules.definition(rule, self.definitions) == null) return error.InvalidSelection;
    const bytes = try self.project.source(try self.source());
    if (start > end or end > bytes.len) return error.InvalidHandle;
    for (related) |span| {
        const target = try self.project.handle(span.file);
        if (span.start > span.end or span.end > (try self.project.source(target)).len) return error.InvalidHandle;
    }
    // Rules may retain no temporary message storage in the report: the sink copies it.
    return self.sink.diagnostic(self.sink.data, rule, start, end, message, related);
}
/// Required uncertainty cannot be suppressed into a completed gating run.
pub fn undecided(self: *RuleContext, rule: rules.Rule, start: u32, reason: Report.Coverage.Reason, detail: []const u8) Error!void {
    if (!self.config.has(rule)) return;
    if (rules.definition(rule, self.definitions) == null) return error.InvalidSelection;
    if (start > (try self.project.source(try self.source())).len) return error.InvalidHandle;
    return self.sink.coverage(self.sink.data, .{ .file = self.file, .rule = rule, .start = start, .reason = reason, .detail = detail });
}
pub fn at(self: *RuleContext, rule: rules.Rule, token: std.zig.Ast.TokenIndex, message: []const u8) Error!void {
    const tree = try self.project.syntax(try self.source());
    if (token >= tree.tokens.len) return error.InvalidHandle;
    const start = tree.tokenStart(token);
    try self.emit(rule, start, start + @as(u32, @intCast(tree.tokenSlice(token).len)), message); // safe: source budget bounds the token span.
}
pub fn unknown(self: *RuleContext, rule: rules.Rule, node: std.zig.Ast.Node.Index, reason: Facts.Unknown) Error!void {
    const tree = try self.project.syntax(try self.source());
    if (@backingInt(node) >= tree.nodes.len) return error.InvalidHandle; // safe: reject compiler node indexes outside the frozen source.
    try self.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), if (reason == .budget) .budget_exhausted else .unresolved, @tagName(reason));
}
pub fn selected(self: *const RuleContext, selection: []const rules.Rule) bool {
    for (selection) |rule| if (self.config.has(rule)) return true;
    return false;
}
pub fn atDefinition(self: *RuleContext, rule: rules.Rule, token: std.zig.Ast.TokenIndex, message: []const u8, definition: Facts.Decl) Error!void {
    const h = try self.project.handle(definition.file);
    const tree = try self.project.syntax(h);
    const declarations = try self.project.declarations(h);
    if (definition.index >= declarations.len) return error.InvalidHandle;
    const start = tree.tokenStart(declarations[definition.index].token);
    const file = &self.project.files[definition.file.raw()];
    const line = file.line(start);
    const related = [_]Report.Span{.{ .file = definition.file, .start = start, .end = start + @as(u32, @intCast(tree.tokenSlice(declarations[definition.index].token).len)), .line = line + 1, .column = start - file.lines[line] + 1 }}; // safe: source budget bounds the token span.
    const site_tree = try self.project.syntax(try self.source());
    const site = site_tree.tokenStart(token);
    try self.emitRelated(rule, site, site + @as(u32, @intCast(site_tree.tokenSlice(token).len)), message, &related); // safe: source budget bounds the site span.
}
