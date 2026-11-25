//! Shared contract used by built-in and compiled project rules.
const std = @import("std");
const Project = @import("Project.zig");
const Ast = std.zig.Ast;
const Facts = @import("Facts.zig");
const answers = @import("compiled/Answers.zig");
const Model = @import("Model.zig");
const PackageRules = @import("PackageRules.zig");
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
/// The run's facts, behind this context: a rule asks through its methods, the one door, and none
/// of them hands Facts out, so a rule that reaches Facts itself does not compile (`hold`).
held: *Facts.Door,
definitions: []const rules.Definition,
sink: *Sink,
/// The run's compiled rules: the facts they declare are the ones `Taint` solves together.
compiled: []const Rule = &.{},

pub const Error = Facts.ResolveError || Project.QueryError || error{ AmbiguousSuppression, InvalidSelection };

/// The run's facts, held for a context: what its runner gives `held`, their door, from which only
/// this file gets them back.
pub fn hold(run: *Facts) *Facts.Door {
    return &run.door;
}
fn facts(self: *const RuleContext) *Facts {
    return @alignCast(@fieldParentPtr("door", self.held));
}

/// Makes `allocator` the run's own (`Facts.gpa`) and returns the one it was: what a function
/// that fills a `Facts.memo` computes, its callees' memory among it, is kept for the run, as a
/// rule's own memory for one file is given back when the rule is done with the file. Restored
/// on the way out: `const rule_memory = c.keep(); defer c.allocator = rule_memory;`.
pub fn keep(self: *RuleContext) std.mem.Allocator {
    const own = self.allocator;
    self.allocator = self.facts().gpa;
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
    /// A site of the rule at the offset that is outside its language (`Facts.Unknown.meaning`):
    /// counted per rule, never a finding. A sink that counts nothing drops it.
    outside: *const fn (*Sink, rules.Rule, u32) Error!void = countsNothing,
    /// A site of the rule at the offset in code no compiled root holds
    /// (`Facts.Unknown.not_reached`): counted per rule apart from `outside`, never a finding.
    /// A sink that counts nothing drops it.
    not_reached: *const fn (*Sink, rules.Rule, u32) Error!void = countsNothing,

    fn suppressesNothing(_: *Sink, _: rules.Rule, _: u32) bool {
        return false;
    }
    fn countsNothing(_: *Sink, _: rules.Rule, _: u32) Error!void {}
};
/// Compiled rule. Metadata and callback are validated once before execution.
pub const Rule = struct { definition: rules.Definition, check: *const fn (*RuleContext) Error!void };
/// Checked immutable handle for all model queries.
pub fn source(self: *const RuleContext) Project.QueryError!Project.Handle {
    return self.project.handle(self.file);
}
/// Same-run declaration/type resolver. Unknown values carry their missing fact. With compiled
/// roots, a site in code none of them holds is not reached (`Facts.Unknown.not_reached`): the
/// compiler established nothing there, and the source does not stand in for it. A syntactic
/// rule asks no such question, so it reads every file, reached or not.
pub fn resolve(self: *RuleContext, node: Project.NodeId) Error!Facts.Value {
    return self.resolveIn(self.file, try self.project.node(try self.source(), node));
}

/// `resolve`, of a node of `file`.
pub fn resolveIn(self: *RuleContext, file: Project.FileId, node: Ast.Node.Index) Error!Facts.Value {
    if (!try self.reached(file, node)) return .{ .unknown = .not_reached };
    return self.facts().resolve(file, node);
}
/// What an `@import` node of `file` names: the run's mapping, read in every file, reached or
/// not. Which module or file a name maps to is the run's, not the compiler's answer at a site
/// (a file-scope `@import` is comptime-only, a node no compiled root holds).
pub fn imported(self: *RuleContext, file: Project.FileId, node: Ast.Node.Index) Error!Facts.Value {
    return self.facts().resolve(file, node);
}
/// Whether a node of `file` is in code a compiled root holds, or there are none (a plain run,
/// which reads every file as reached). Unknown reachability (no function or declaration holds
/// the node) is reached: the source answers, as it does without compiled roots.
fn reached(self: *const RuleContext, file: Project.FileId, node: Ast.Node.Index) Error!bool {
    const compiled = self.facts().compiled;
    if (compiled.len == 0) return true;
    const tree = &self.project.at(file).file.tree;
    const reach = try answers.site(self.project, compiled, file, tree.firstToken(node)) orelse return true;
    return reach != .not_reached;
}

// The facts a rule reads, each through this context. A site query (what a node resolves to,
// names, casts to, holds, or fixes at compile time) answers not reached where no compiled root holds
// the node, as `resolve` does; a query of a declaration, a container or a file reads it as
// Facts does, its site having been asked first.

/// The declaration a name or member access at `node` refers to (`Facts.definition`).
pub fn definition(self: *const RuleContext, file: Project.FileId, node: Ast.Node.Index) Error!Facts.Named {
    if (!try self.reached(file, node)) return .{ .unknown = .not_reached };
    return self.facts().definition(file, node);
}
/// The declaration a reflective builtin at `node` names (`Facts.reflected`).
pub fn reflected(self: *const RuleContext, file: Project.FileId, node: Ast.Node.Index) Error!Facts.Named {
    if (!try self.reached(file, node)) return .{ .unknown = .not_reached };
    return self.facts().reflected(file, node);
}
/// The declarations a literal's `name` may be, by the type its place gives it
/// (`Facts.literalDeclarations`).
pub fn literalDeclarations(self: *const RuleContext, file: Project.FileId, node: Ast.Node.Index, name: []const u8) Error!Facts.Definitions {
    if (!try self.reached(file, node)) return .{ .unknown = .not_reached };
    return self.facts().literalDeclarations(file, node, name);
}
/// The type a cast at `node` makes, by its place (`Facts.castTypeIn`, outside any binding).
pub fn castType(self: *const RuleContext, file: Project.FileId, node: Ast.Node.Index) Error!Facts.Value {
    if (!try self.reached(file, node)) return .{ .unknown = .not_reached };
    return self.facts().castTypeIn(null, file, node);
}
/// The compile-time value at `node`, null where it is not fixed there or not reached
/// (`Facts.comptimeValue`, outside any binding).
pub fn comptimeValue(self: *const RuleContext, file: Project.FileId, node: Ast.Node.Index) Error!?Facts.Comptime {
    if (!try self.reached(file, node)) return null;
    return self.facts().comptimeValue(null, file, node);
}
/// The field name a builtin's argument spells (`Facts.fieldName`).
pub fn fieldName(self: *const RuleContext, file: Project.FileId, node: Ast.Node.Index) Error!Facts.FieldName {
    return self.facts().fieldName(file, node);
}
/// Whether `name` is a field of `holder`'s own type (`Facts.fieldNameOwn`).
pub fn fieldNameOwn(self: *const RuleContext, file: Project.FileId, holder: Ast.Node.Index, name: Ast.Node.Index) Error!bool {
    return self.facts().fieldNameOwn(file, holder, name);
}
/// Whether a field name may be `name` (`Facts.mayName`).
pub fn mayName(self: *const RuleContext, named: Facts.FieldName, name: []const u8) bool {
    return self.facts().mayName(named, name);
}
/// Whether the expression at `node` is a value, not a type (`Facts.isValue`).
pub fn isValue(self: *const RuleContext, file: Project.FileId, node: Ast.Node.Index) Error!bool {
    return self.facts().isValue(file, node);
}
/// Whether the type written at `node` is `type` (`Facts.typeIsType`).
pub fn typeIsType(self: *const RuleContext, file: Project.FileId, node: Ast.Node.Index) Error!bool {
    return self.facts().typeIsType(file, node);
}
/// Whether `node` names a `comptime` parameter (`Facts.comptimeParameter`).
pub fn comptimeParameter(self: *const RuleContext, file: Project.FileId, node: Ast.Node.Index) bool {
    return self.facts().comptimeParameter(file, node);
}
/// The function whose body holds `node` (`Facts.functionHolding`).
pub fn functionHolding(self: *const RuleContext, file: Project.FileId, node: Ast.Node.Index) ?Facts.Decl {
    return self.facts().functionHolding(file, node);
}
/// The value a declaration gives (`Facts.declaration`).
pub fn declaration(self: *const RuleContext, decl: Facts.Decl) Error!Facts.Value {
    return self.facts().declaration(decl);
}
/// The declaration an alias chain from `decl` ends at (`Facts.origin`).
pub fn origin(self: *const RuleContext, decl: Facts.Decl) Error!Facts.Named {
    return self.facts().origin(decl);
}
/// Every declaration an alias chain from `decl` may end at (`Facts.origins`).
pub fn origins(self: *const RuleContext, decl: Facts.Decl) Error!Facts.Definitions {
    return self.facts().origins(decl);
}
/// The value a function returns, as a template of its result (`Facts.template`).
pub fn template(self: *const RuleContext, decl: Facts.Decl) Error!?Facts.Value {
    return self.facts().template(decl);
}
/// The expressions a function returns (`Facts.returnedValues`).
pub fn returnedValues(self: *const RuleContext, function: Facts.Decl) Error!?[]const Ast.Node.Index {
    return self.facts().returnedValues(function);
}
/// The member `name` of a container (`Facts.member`).
pub fn member(self: *const RuleContext, container: Facts.Container, name: []const u8) ?Facts.Decl {
    return self.facts().member(container, name);
}
/// A file's root container (`Facts.rootOf`).
pub fn rootOf(self: *const RuleContext, file: Project.FileId) Facts.Container {
    return self.facts().rootOf(file);
}
/// Whether a file is std's (`Facts.standard`).
pub fn standard(self: *const RuleContext, file: Project.FileId) Error!bool {
    return self.facts().standard(file);
}
/// Whether a file is the program's own (`Facts.program`).
pub fn program(self: *const RuleContext, file: Project.FileId) Error!bool {
    return self.facts().program(file);
}
/// Whether a scope is on the module's public surface (`Facts.onSurface`).
pub fn onSurface(self: *const RuleContext, file: Project.FileId, scope: Model.Scope.Id) Error!bool {
    return self.facts().onSurface(file, scope);
}
/// Whether a scope is exported on the surface (`Facts.exportedSurface`).
pub fn exportedSurface(self: *const RuleContext, file: Project.FileId, scope: Model.Scope.Id) Error!bool {
    return self.facts().exportedSurface(file, scope);
}
/// Whether a scope is on the surface through an alias (`Facts.aliasedOnSurface`).
pub fn aliasedOnSurface(self: *const RuleContext, file: Project.FileId, scope: Model.Scope.Id) Error!bool {
    return self.facts().aliasedOnSurface(file, scope);
}
/// The run's one `T`, kept across files (`Facts.memo`).
pub fn memo(self: *const RuleContext, comptime T: type) Error!*T {
    return self.facts().memo(T);
}
/// The run's allocator: what a `memo` holds is made on it (`keep`).
pub fn runAllocator(self: *const RuleContext) std.mem.Allocator {
    return self.facts().gpa;
}
/// Whether the run's fact budget is spent (`Facts.budgetSpent`).
pub fn budgetSpent(self: *const RuleContext) bool {
    return self.facts().budgetSpent();
}
/// The calls a file makes (`Facts.calls.in`).
pub fn callsIn(self: *const RuleContext, file: Project.FileId) Error![]const Facts.calls.Call {
    return Facts.calls.in(self.facts(), file);
}
/// The call at `node`, if one is there (`Facts.calls.at`).
pub fn callAt(self: *const RuleContext, file: Project.FileId, node: Ast.Node.Index) Error!?Facts.calls.Call {
    return Facts.calls.at(self.facts(), file, node);
}
/// The values an expression may hold (`Facts.accesses.valuesOf`).
pub fn valuesOf(self: *const RuleContext, file: Project.FileId, node: Ast.Node.Index) Error!Facts.accesses.Values {
    if (!try self.reached(file, node)) return .{ .unknown = .not_reached };
    return Facts.accesses.valuesOf(self.facts(), file, node);
}
/// The access path an expression spells (`Facts.accesses.pathOf`).
pub fn pathOf(self: *const RuleContext, file: Project.FileId, node: Ast.Node.Index) Error!Facts.accesses.Path {
    return Facts.accesses.pathOf(self.facts(), file, node);
}
/// Whether two expressions are the same place (`Facts.accesses.samePlace`).
pub fn samePlace(self: *const RuleContext, file: Project.FileId, a: Ast.Node.Index, b: Ast.Node.Index) Error!Facts.Is {
    return Facts.accesses.samePlace(self.facts(), file, a, b);
}
/// The rules a package root declares (`PackageRules.of`).
pub fn packageRules(self: *const RuleContext, root: Project.FileId) Error!*const PackageRules.Rules {
    return PackageRules.of(self.facts(), root);
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
        const kind = try self.facts().resolve(decl.file, written);
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
        const decl = switch (try self.facts().definition(self.file, call.ast.fn_expr)) {
            .decl => |found| found,
            .none, .unknown => return false,
        };
        const function = switch (try self.facts().origin(decl)) {
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
            const value = try self.facts().resolve(self.file, node);
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
/// A ban's site where a fact it reads is unknown (`why`), never a pass and never a finding. Where
/// the unknown is glint's own failure the run is incomplete: a run error names the rule, the
/// place and the reason, so the gate fails by name. Where it is outside the ban's language (a
/// generic position, `Facts.Unknown.meaning`) the site is counted for the rule in the report, and
/// a site in code no compiled root holds is counted apart, as not reached. Hygiene stays silent
/// on an unknown and never calls this.
pub fn unknownAt(self: *RuleContext, rule: rules.Rule, token: Ast.TokenIndex, why: Facts.Unknown) Error!void {
    const tree = try self.project.syntax(try self.source());
    if (token >= tree.tokens.len) return error.InvalidHandle;
    const start = tree.tokenStart(token);
    if (why == .not_reached) return self.sink.not_reached(self.sink, rule, start);
    switch (why.meaning()) {
        .outside => return self.sink.outside(self.sink, rule, start),
        .failure => {
            const location = tree.tokenLocation(0, token);
            const named = (rules.definition(rule, self.definitions) orelse return error.InvalidSelection).name;
            try self.refuse(try self.allocator.print("{d}:{d}: {s} cannot read `{s}`: glint does not resolve what it reads there ({t}), so it can neither report nor pass the site", .{ location.line + 1, location.column + 1, named, tree.tokenSlice(token), why }));
        },
    }
}
/// Whether a token is test code: inside a `test` block, or in an input the caller classifies as a
/// test or the configuration's `test_inputs` names, whoever runs glint. Nothing else is: a file
/// only tests import, a private function only tests call and a fuzz target outside a `test` block
/// are production code. The one answer for every rule that exempts test code.
pub fn inTest(self: *const RuleContext, token: std.zig.Ast.TokenIndex) bool {
    const held = self.project.at(self.file);
    if (self.config.testInput(held.input.name) != null) return true;
    return inTestScope(held, token);
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
pub fn atDefinition(self: *RuleContext, rule: rules.Rule, token: std.zig.Ast.TokenIndex, message: []const u8, target: Facts.Decl) Error!void {
    return self.atDefinitionFixed(rule, token, message, target, &.{});
}
/// A site at `token` naming `target`, with its deterministic fix.
pub fn atDefinitionFixed(self: *RuleContext, rule: rules.Rule, token: std.zig.Ast.TokenIndex, message: []const u8, target: Facts.Decl, fix: []const Report.Edit) Error!void {
    const named = self.project.at(target.file).model.declarations[@backingInt(target.index)].token;
    const related = [_]Report.Span{self.spanOf(target.file, named)};
    const site_tree = try self.project.syntax(try self.source());
    const site = site_tree.tokenToSpan(token);
    try self.emitFixed(rule, site.start, site.end, message, &related, fix);
}

test "a rule reaches Facts only through the context: no field or method hands Facts out" {
    // A rule writing `c.facts.resolve(...)` does not compile: the context holds only Facts'
    // door, which carries nothing a rule reads, and nothing public of it gives Facts back.
    try std.testing.expectEqual(@as(usize, 1), @typeInfo(Facts.Door).@"struct".field_names.len);
    inline for (@typeInfo(RuleContext).@"struct".field_types) |field| {
        try std.testing.expect(!handsFacts(field));
    }
    inline for (@typeInfo(RuleContext).@"struct".decl_names) |name| {
        const T = @TypeOf(@field(RuleContext, name));
        if (@typeInfo(T) == .@"fn") {
            if (@typeInfo(T).@"fn".return_type) |returned| try std.testing.expect(!handsFacts(returned));
        }
    }
}
/// Whether a type is, or wraps in an error union or optional, a pointer to Facts.
fn handsFacts(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child == Facts,
        .optional => |o| handsFacts(o.child),
        .error_union => |e| handsFacts(e.payload),
        else => false,
    };
}
