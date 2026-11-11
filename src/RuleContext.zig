//! Shared contract used by built-in and compiled project rules.
const std = @import("std");
const Project = @import("Project.zig");
const Ast = std.zig.Ast;
const Facts = @import("Facts.zig");
const PackageRules = @import("PackageRules.zig");
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
    coverage: *const fn (*Sink, Report.Coverage) Error!void,
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
/// Compiled rule. Metadata and callback are validated once before execution. `facts` are the
/// flow facts its check asks (`Taint.get`), solved once for every rule that asks one. `roles` are
/// the role names its pack reads from what packages declare (the fields of its `Library(R)`'s
/// `R`, `std.meta.fieldNames(R)`): glint's own packs' are known without it. A role a package's
/// `lint_rules` names that no pack of the run knows is a problem where it is written, and a name
/// two packs give different lists for is refused (`error.InvalidSelection`), so an entry's name
/// names one pack.
pub const Rule = struct { definition: rules.Definition, check: *const fn (*RuleContext) Error!void, roles: []const []const u8 = &.{} };
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
/// Null when the value is none of its declarations with a role; recognition follows the roles
/// the library's package declares in `lint_rules`, never file bytes or names.
pub fn role(self: *RuleContext, library: anytype, value: Facts.Value) Error!?@TypeOf(library).Role {
    return PackageRules.role(self.facts, @TypeOf(library).Role, library, value);
}
/// Whether `file` is one of the library's own files: of its package, by the identity the caller states.
pub fn inLibrary(self: *RuleContext, library: anytype, file: Project.FileId) Error!bool {
    const found = try PackageRules.publication(self.facts, @TypeOf(library).Role, library);
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
/// Where a library's roles are not all read (`PackageRules.Gap`), at the first import in this file of
/// that root, under whatever name and however spelled: the import is the root where Facts
/// resolves it to that root. Recognition of that library is incomplete here, so a rule reports
/// it as coverage. A library's modules are the program's: a file only a build script's
/// compilation compiles imports none of them, whatever it names. `detail` says what, and where.
pub const Drift = struct { detail: []const u8, start: u32 };
pub fn drift(self: *RuleContext, library: anytype) Error!?Drift {
    if (!self.project.at(self.file).input.compilations.inProgram()) return null;
    const found = try PackageRules.publication(self.facts, @TypeOf(library).Role, library);
    const tree = try self.project.syntax(try self.source());
    const model = &self.project.at(self.file).model;
    for (found.gaps) |gap| for (model.import_nodes) |node| {
        const value = try self.facts.resolve(self.file, node);
        if (value != .container or value.container.file != gap.root) continue;
        const name = library.package.name;
        const detail = if (gap.problem) |problem| blk: {
            const written = &self.project.at(problem.file).file.tree;
            const line = written.tokenLocation(0, written.firstToken(problem.node)).line + 1;
            break :blk try self.allocator.print("{s}'s lint_rules at {s}:{d}: {s}; the roles it declares are not all read in this file", .{ name, self.project.at(problem.file).input.name, line, problemText(problem.why) });
        } else try self.allocator.print("{s}'s root {s} declares no lint_rules; the roles of its types are not read in this file", .{ name, self.project.at(gap.root).input.name });
        return .{ .detail = detail, .start = tree.tokenStart(tree.nodeMainToken(node)) };
    };
    return null;
}
/// What part of a package's `lint_rules` could not be read, in words.
fn problemText(why: PackageRules.Problem.Why) []const u8 {
    return switch (why) {
        .unknown_version => "a version of the vocabulary this glint does not read",
        .unknown_rule => "a replacement naming a rule the package does not declare to read replacements",
        .duplicate_rule => "a rule id declared twice",
        .unknown_builtin => "a builtin the language does not have",
        .unknown_field => "a field the vocabulary does not have",
        .malformed => "a value not of the form the vocabulary gives it",
        .unresolved => "a reference that does not resolve",
        .foreign => "a declaration outside the package",
        .refused => "a pair refused as written",
        .unknown_role => "a role no pack of this run reads",
    };
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
/// Whether a finding of `rule` at `token` would be suppressed (`Sink.suppresses`), the
/// suppression left unused.
pub fn suppressedAt(self: *RuleContext, rule: rules.Rule, token: std.zig.Ast.TokenIndex) Error!bool {
    const tree = try self.project.syntax(try self.source());
    if (token >= tree.tokens.len) return error.InvalidHandle;
    return self.sink.suppresses(self.sink, rule, tree.tokenStart(token));
}
pub fn unknown(self: *RuleContext, rule: rules.Rule, node: std.zig.Ast.Node.Index, reason: Facts.Unknown) Error!void {
    const tree = try self.project.syntax(try self.source());
    if (@backingInt(node) >= tree.nodes.len) return error.InvalidHandle; // safe: reject compiler node indexes outside the frozen source.
    try self.undecided(rule, tree.tokenStart(tree.nodeMainToken(node)), if (reason == .budget) .budget_exhausted else .unresolved, @tagName(reason));
}
/// Whether a token is test code: a test input, or inside a `test` block.
pub fn inTest(self: *const RuleContext, token: std.zig.Ast.TokenIndex) bool {
    return inTestScope(self.project.at(self.file), token);
}
/// Whether a token is test code, as a program's files are classified: inside a `test` block or
/// a test input (`inTest`), anywhere in a file only tests reach (`testReached`), or inside a
/// private function only tests reach (`testOnly`: a fuzz target, a property's helper). One answer
/// for every rule that reads test code so.
pub fn inTestCode(self: *RuleContext, token: std.zig.Ast.TokenIndex) Error!bool {
    return inTestCodeOf(self, self.file, token);
}

/// `inTestCode` of a token in `file`, which need not be the file the rule checks.
pub fn inTestCodeOf(self: *RuleContext, file: Project.FileId, token: std.zig.Ast.TokenIndex) Error!bool {
    return inTestScope(self.project.at(file), token) or try testReached(self, file) or try inTestOnlyFunction(self, file, token);
}

/// Which files only tests reach, one entry a file by its id, found as each is asked and kept for
/// the run.
const TestReached = struct { known: []Reach = &.{} };
const Reach = enum { unasked, asking, only_tests, not_only };

/// Whether `file` is reached only from tests: imported somewhere, and every `@import` of it is
/// in a `test` block or in a file only tests reach. A file nothing imports (a module's root, a
/// test root the build names) is not: what the build compiles it as is not read here.
fn testReached(self: *RuleContext, file: Project.FileId) Error!bool {
    // What it keeps in its memo stays for the run.
    const rule_memory = self.keep();
    defer self.allocator = rule_memory;
    return testReachedIn(self, try self.facts.memo(TestReached), file, 0);
}

fn testReachedIn(self: *RuleContext, memo: *TestReached, file: Project.FileId, depth: usize) Error!bool {
    if (memo.known.len == 0) {
        memo.known = try self.allocator.alloc(Reach, self.project.sources.len);
        @memset(memo.known, .unasked);
    }
    const entry = &memo.known[@backingInt(file)];
    switch (entry.*) {
        .unasked => {},
        // Asked again while it is being read (an import cycle): not only tests', as nothing shows it.
        .asking, .not_only => return false,
        .only_tests => return true,
    }
    if (depth == 32) return false;
    entry.* = .asking;
    const only = try importedOnlyFromTests(self, memo, file, depth);
    entry.* = if (only) .only_tests else .not_only;
    return only;
}

fn importedOnlyFromTests(self: *RuleContext, memo: *TestReached, file: Project.FileId, depth: usize) Error!bool {
    var imported = false;
    for (self.project.imports, 0..) |edge, k| {
        if (edge.target != file or !edge.in.inProgram()) continue;
        // Each importer once: an earlier edge from it to `file` read its imports already.
        const read = for (self.project.imports[0..k]) |earlier| {
            if (earlier.from == edge.from and earlier.target == file and earlier.in.inProgram()) break true;
        } else false;
        if (read) continue;
        const from = self.project.at(edge.from);
        if (from.file.status != .parsed) return false;
        const tree = &from.file.tree;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            switch (tag) {
                .builtin_call_two, .builtin_call_two_comma => {},
                else => continue,
            }
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 1 or tree.nodeTag(args[0]) != .string_literal) continue;
            // The import as Facts reads it: the literal's value, resolved by the caller's
            // mapping in the importing file's compilations (`Project.importedAll`).
            const spelling = std.zig.string_literal.parseAlloc(self.allocator, tree.tokenSlice(tree.nodeMainToken(args[0]))) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidLiteral => continue,
            };
            var reached: [2]Project.FileId = undefined;
            const targets = self.project.importedAll(edge.from, spelling, &reached);
            if (std.mem.findScalar(Project.FileId, targets, file) == null) continue;
            imported = true;
            if (inTestScope(from, tree.nodeMainToken(node))) continue;
            if (!try testReachedIn(self, memo, edge.from, depth + 1)) return false;
        }
    }
    return imported;
}

/// Which private functions only tests reach, by declaration, found as each is asked and kept for
/// the run.
const TestOnly = struct { files: []?[]Reach = &.{} };

/// Whether `token` of `file` is inside a function only tests reach (`testOnly`): itself or any
/// function around it.
fn inTestOnlyFunction(self: *RuleContext, file: Project.FileId, token: Ast.TokenIndex) Error!bool {
    // What it keeps in its memo stays for the run.
    const rule_memory = self.keep();
    defer self.allocator = rule_memory;
    return inTestOnlyIn(self, try self.facts.memo(TestOnly), file, token);
}

fn inTestOnlyIn(self: *RuleContext, memo: *TestOnly, file: Project.FileId, token: Ast.TokenIndex) Error!bool {
    const model = &self.project.at(file).model;
    var scope: ?Model.Scope.Id = model.scopeOf(token);
    while (scope) |id| : (scope = model.scopes[@backingInt(id)].parent) {
        const each = &model.scopes[@backingInt(id)];
        if (each.kind != .function) continue;
        const function = functionDeclaration(&self.project.at(file).file.tree, model, each) orelse continue;
        if (try testOnly(self, memo, .{ .file = file, .index = function })) return true;
    }
    return false;
}

/// The function a `fn_decl` declares: the declaration whose node is its prototype.
/// Looked up by its name in the scope around the function's, where it is declared.
fn functionDeclaration(tree: *const Ast, model: *const Model, scope: *const Model.Scope) ?Model.Declaration.Id {
    if (tree.nodeTag(scope.node) != .fn_decl) return null;
    const prototype = tree.nodeData(scope.node).node_and_node[0];
    var buffer: [1]Ast.Node.Index = undefined;
    const name = (tree.fullFnProto(&buffer, prototype) orelse return null).name_token orelse return null;
    const around = scope.parent orelse return null;
    const id = model.scopes[@backingInt(around)].names.get(tree.tokenSlice(name)) orelse return null;
    const decl = model.declarations[@backingInt(id)];
    return if (decl.kind == .function and decl.node == prototype) id else null;
}

/// A string literal's value; null where it does not decode.
fn decoded(a: std.mem.Allocator, literal: []const u8) error{OutOfMemory}!?[]const u8 {
    return std.zig.string_literal.parseAlloc(a, literal) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidLiteral => null,
    };
}

/// Whether production code of `held` writes a `@field` whose name is computed: it may name any
/// declaration of a type, a private function's too, without spelling it. A string literal names
/// the one name it decodes to; one that does not decode is computed.
fn computedField(a: std.mem.Allocator, held: *const Project.Source) error{OutOfMemory}!bool {
    const tree = &held.file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@field")) continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        if (args.len == 2 and tree.nodeTag(args[1]) == .string_literal and try decoded(a, tree.tokenSlice(tree.nodeMainToken(args[1]))) != null) continue;
        if (inTestScope(held, tree.nodeMainToken(node))) continue;
        return true;
    }
    return false;
}

/// Whether a function only tests reach: private (no `pub`, no `export`), so only its own file
/// can name it (Zig's visibility, as D001 reads it), named there at least once, and every
/// spelling of its name in that file, an identifier or a string (`@field`), but its own
/// declaration's, is test code: in a `test` block, or in another function only tests reach. A
/// spelling of the same name that means another declaration counts too, so a name shared with
/// production code is not only tests'. A function asked again while it is read (they name each
/// other) is not only tests', as nothing shows it.
fn testOnly(self: *RuleContext, memo: *TestOnly, function: Facts.Decl) Error!bool {
    const held = self.project.at(function.file);
    const decl = held.model.declarations[@backingInt(function.index)];
    if (decl.public or decl.exported) return false;
    const entry = try testOnlyEntry(self, memo, function);
    switch (entry.*) {
        .unasked => {},
        .asking, .not_only => return false,
        .only_tests => return true,
    }
    if (try computedField(self.allocator, held)) {
        entry.* = .not_only;
        return false;
    }
    entry.* = .asking;
    const tree = &held.file.tree;
    var named = false;
    const only = for (0..tree.tokens.len) |i| {
        const token: Ast.TokenIndex = @intCast(i);
        if (token == decl.token) continue;
        const spelled = switch (tree.tokenTag(token)) {
            .identifier => blk: {
                const raw = tree.tokenSlice(token);
                // `@"name"` is read as its name; any other identifier is its own spelling.
                break :blk if (raw[0] == '@') std.mem.eql(u8, try Model.identifier(self.allocator, raw), decl.name) else std.mem.eql(u8, raw, decl.name);
            },
            // A string by its value, as `@field` reads it (`Facts.fieldName`); one that does not
            // decode may be any name.
            .string_literal => if (try decoded(self.allocator, tree.tokenSlice(token))) |text| std.mem.eql(u8, text, decl.name) else true,
            else => false,
        };
        if (!spelled) continue;
        named = true;
        if (inTestScope(held, token)) continue;
        if (!try inTestOnlyIn(self, memo, function.file, token)) break false;
    } else named;
    entry.* = if (only) .only_tests else .not_only;
    return only;
}

/// `function`'s entry in the run's memo, its file's entries made when first asked.
fn testOnlyEntry(self: *RuleContext, memo: *TestOnly, function: Facts.Decl) Error!*Reach {
    if (memo.files.len == 0) {
        memo.files = try self.allocator.alloc(?[]Reach, self.project.sources.len);
        @memset(memo.files, null);
    }
    const slot = &memo.files[@backingInt(function.file)];
    if (slot.* == null) {
        const made = try self.allocator.alloc(Reach, self.project.at(function.file).model.declarations.len);
        @memset(made, .unasked);
        slot.* = made;
    }
    return &slot.*.?[@backingInt(function.index)];
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
