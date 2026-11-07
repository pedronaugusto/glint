//! Z026's empty error handlers that drop nothing, by what the code itself shows (the book's
//! rulings, 11-07): an error already leaving its function (the error path), a canceled task's
//! result that owns nothing and a held result whose success branch only releases it (a cancel
//! or a release), a write to the process's standard error, and a call whose every error is a
//! refusal of its input (refusals alone). Anything here that does not resolve leaves the handler
//! a site.
const std = @import("std");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Governed = @import("Governed.zig");
const AegisContract = @import("AegisContract.zig");
const release_summary = @import("releases.zig");
const Context = @import("RuleContext.zig");
const Ast = std.zig.Ast;
const Error = Context.Error;
const accesses = Facts.accesses;

/// The form of the syntax `node` is (`Facts.accesses.formOf`).
fn formAt(tree: *const Ast, node: Ast.Node.Index) accesses.Form {
    return accesses.formOf(tree.nodeTag(node));
}

/// The declaration of this file a name refers to (`Facts.definition`); null for any other.
fn ownDeclaration(c: *Context, node: Ast.Node.Index) Error!?Model.Declaration {
    return switch (try c.facts.definition(c.file, node)) {
        .decl => |found| if (found.file == c.file) c.project.at(c.file).model.declarations[@backingInt(found.index)] else null,
        .none, .unknown => null,
    };
}

/// Whether the empty handler of `site`, a `catch` or an `if`'s or `while`'s `else |err|`, drops
/// nothing (the forms this file reads).
pub fn dropsNothing(c: *Context, site: Ast.Node.Index) Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    if (try onErrorPath(c, site)) return true;
    const handled = Facts.ungrouped(tree, handledOf(tree, site) orelse return false);
    if (try canceledOwningNothing(c, handled)) return true;
    if (tree.fullIf(site)) |branch| if (try releaseOnly(c, branch)) return true;
    if (try toStderr(c, handled)) return true;
    return refusalsOnly(c, site, handled);
}

/// What a handler handles the errors of: a `catch`'s left side, an `if`'s or `while`'s condition.
fn handledOf(tree: *const Ast, site: Ast.Node.Index) ?Ast.Node.Index {
    if (tree.nodeTag(site) == .@"catch") return tree.nodeData(site).node_and_node[0];
    if (tree.fullIf(site)) |branch| return branch.ast.cond_expr;
    if (tree.fullWhile(site)) |loop| return loop.ast.cond_expr;
    return null;
}

/// The error path: the handler is inside an `errdefer`, which runs only as an error leaves; or
/// the statements after it, in the block that holds it, go on to return an error (`return
/// error.X`, or `return e` of an error a `catch |e|` or `else |e|` captured) with no other jump
/// before it. Zig returns one error: the one leaving is the failure reported, and a cleanup's own
/// can only be dropped or made a panic.
fn onErrorPath(c: *Context, site: Ast.Node.Index) Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var up = site;
    while (model.parentOf(up)) |parent| : (up = parent) switch (tree.nodeTag(parent)) {
        .@"errdefer" => return true,
        .fn_decl, .test_decl => break,
        else => {},
    };
    var at = site;
    while (model.parentOf(at)) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            // A `defer` runs on every way out, success too: what follows it is no path it is on.
            .fn_decl, .test_decl, .@"defer" => return false,
            else => {},
        }
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, parent) orelse continue;
        const position = std.mem.findScalar(Ast.Node.Index, statements, at) orelse continue;
        for (statements[position + 1 ..]) |statement| {
            if (tree.nodeTag(statement) == .@"return") return errorReturned(c, statement);
            if (jumps(tree, statement)) return false;
        }
        return false;
    }
    return false;
}

/// Whether a `return` gives its function an error: `error.X`, or an error a `catch |e|` or an
/// `if`'s or `while`'s `else |e|` captured.
fn errorReturned(c: *Context, statement: Ast.Node.Index) Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const operand = Facts.ungrouped(tree, tree.nodeData(statement).opt_node.unwrap() orelse return false);
    if (try c.facts.literalOf(c.file, operand)) |written| return written == .error_value;
    const decl = (try ownDeclaration(c, operand)) orelse return false;
    if (decl.kind != .capture) return false;
    if (tree.nodeTag(decl.node) == .@"catch") return true;
    if (tree.fullIf(decl.node)) |branch| return branch.error_token == decl.token;
    if (tree.fullWhile(decl.node)) |loop| return loop.error_token == decl.token;
    return false;
}

/// Whether a statement holds a jump anywhere inside it: a `break`, a `continue`, a `return`.
fn jumps(tree: *const Ast, statement: Ast.Node.Index) bool {
    const first = tree.firstToken(statement);
    const last = tree.lastToken(statement);
    for (tree.nodes.items(.tag), 0..) |tag, i| switch (tag) {
        .@"break", .@"continue", .@"return" => {
            const token = tree.nodeMainToken(@fromBackingInt(@intCast(i)));
            if (token >= first and token <= last) return true;
        },
        else => {},
    };
    return false;
}

/// A cancel: `f.cancel(io)` of a task std's `Io.Future` holds, whose result's payload owns
/// nothing (`ownsNothing`). Cancel is the caller's word that it gives the result up; std writes
/// `defer future.cancel(io) catch {}` itself. A payload that may own something is dropped with
/// the error, and stays a site.
fn canceledOwningNothing(c: *Context, handled: Ast.Node.Index) Error!bool {
    const call = (try Facts.calls.at(c.facts, c.file, handled)) orelse return false;
    if (!try futureCancel(c, call)) return false;
    return switch (try c.facts.resolve(c.file, call.node)) {
        .error_union => |payload| ownsNothing(c, payload.*),
        // A result chosen per build: which payload is dropped is not one known here.
        .alternatives => false,
        else => false,
    };
}

/// Whether a call is `cancel` of a future std's `Io.Future` makes, by its receiver's type.
fn futureCancel(c: *Context, call: Facts.calls.Call) Error!bool {
    const callee = switch (call.callee) {
        .function => |function| function,
        .choice, .any => return false,
    };
    const holder = switch (call.receiver) {
        .bound => |holder| holder,
        .none, .unknown => return false,
    };
    var value = try c.facts.resolve(c.file, holder);
    while (value == .pointer) value = value.pointer.child.*;
    const future = switch (value) {
        .instance, .container => |found| found,
        // A receiver chosen per build is no one future to read.
        .alternatives => return false,
        else => return false,
    };
    const made = future.made_by orelse return false;
    if (try Governed.isStd(c, made.function, "Io.Future") != .yes) return false;
    // By the declaration the future's type gives the name, never another `cancel`.
    const cancel = c.facts.member(future, "cancel") orelse return false;
    return std.meta.eql(cancel, callee);
}

/// The release: `if (r) |p| <one release of p> else |_| {}` on a held result (a name, a field,
/// a dereference) or a future's cancel. Its success branch only releases what the result owns, by
/// what the call does, never what it is called (`releasedBy`), and an error owns nothing: the
/// empty branch drops no failure a fresh call would report.
fn releaseOnly(c: *Context, branch: Ast.full.If) Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const payload = branch.payload_token orelse return false;
    const name = if (tree.tokenTag(payload) == .asterisk) payload + 1 else payload;
    const held = Facts.ungrouped(tree, branch.ast.cond_expr);
    if (Facts.calls.written(tree, held)) {
        const call = (try Facts.calls.at(c.facts, c.file, held)) orelse return false;
        if (!try futureCancel(c, call)) return false;
    }
    var statement = Facts.ungrouped(tree, branch.ast.then_expr);
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.blockStatements(&buffer, statement)) |statements| {
        if (statements.len != 1) return false;
        statement = statements[0];
    }
    const call = (try Facts.calls.at(c.facts, c.file, statement)) orelse return false;
    const released = (try releasedBy(c, call)) orelse return false;
    const decl = (try ownDeclaration(c, released)) orelse return false;
    return decl.token == name;
}

/// std's functions that release what they are given, by declaration.
const allocator_release_paths = [_][]const u8{ "mem.Allocator.free", "mem.Allocator.destroy" };
const handle_release_paths = [_][]const u8{ "Io.File.close", "Io.File.closeMany", "Io.Dir.close", "Io.Dir.closeMany", "Io.net.Stream.close", "Io.net.Socket.close", "Io.net.Socket.closeMany", "Io.net.Server.deinit", "process.Child.kill", "process.Child.wait" };

/// What a call releases, where that is all it does: what std's allocator is given to free, a
/// handle std's own contract closes, or the receiver of a function whose body releases what it
/// holds (`releasesHeld`), each function a choice may be. Null for any other call, and one that
/// does not resolve.
fn releasedBy(c: *Context, call: Facts.calls.Call) Error!?Ast.Node.Index {
    const each: []const Facts.Decl = switch (call.callee) {
        .function => |*one| one[0..1],
        .choice => |all| all,
        .any => return null,
    };
    const args = switch (call.args) {
        .known => |known| known,
        .unknown => return null,
    };
    const holder = switch (call.receiver) {
        .bound => |bound| bound,
        .none, .unknown => return null,
    };
    if (each.len == 0) return null;
    var freed = true;
    var closed = true;
    for (each) |callee| {
        if (!try amongStd(c, callee, &allocator_release_paths)) freed = false;
        if (!try amongStd(c, callee, &handle_release_paths) and !try releasesHeld(c, callee, holder)) closed = false;
    }
    // `a.free(p)` hands over its one argument after the allocator it is called on.
    if (freed) return if (args.len == 2) args[1] else null;
    return if (closed) holder else null;
}

fn amongStd(c: *Context, callee: Facts.Decl, paths: []const []const u8) Error!bool {
    for (paths) |path| if (try Governed.isStd(c, callee, path) == .yes) return true;
    return false;
}

/// Whether a function only gives up what its receiver `holder` holds, by what its body does
/// (`releases.zig`): it releases a field on every exit, and leaves each other untouched; or the
/// type owns nothing and the body does nothing at all (`idle`). A body that uses a field or the
/// receiver otherwise (real work: a flush, a count, a call handed the whole value), that releases
/// nothing and does something, or a type that does not resolve, does not.
fn releasesHeld(c: *Context, callee: Facts.Decl, holder: Ast.Node.Index) Error!bool {
    try readStdReleases(c);
    const function = switch (try c.facts.origin(callee)) {
        .decl => |origin| origin,
        .none => callee,
        .unknown => return false,
    };
    var value = try c.facts.resolve(c.file, holder);
    while (value == .pointer) value = value.pointer.child.*;
    const container = switch (value) {
        .instance, .container => |found| found,
        // A receiver chosen per build is no one type to read.
        .alternatives => return false,
        else => return false,
    };
    var any = false;
    var settled = true;
    for (try c.facts.heldFields(container)) |field| {
        const decl = field.decl orelse {
            settled = false;
            continue;
        };
        switch (try release_summary.released(c.facts, function, .{ .parameter = 0, .path = &.{decl} }, std_release)) {
            .every_exit => any = true,
            .untouched => {},
            .unknown => settled = false,
        }
    }
    return (any and settled) or (try ownsNothing(c, value) and idle(c, function));
}

/// Whether a function's body makes no call and no store: nothing it could drop by being skipped.
fn idle(c: *Context, function: Facts.Decl) bool {
    const tree = &c.project.at(function.file).file.tree;
    const model = &c.project.at(function.file).model;
    const whole = model.parentOf(model.declarations[@backingInt(function.index)].node) orelse return false;
    if (formAt(tree, whole) != .fn_decl) return false;
    const first = tree.firstToken(whole);
    const last = tree.lastToken(whole);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        switch (accesses.formOf(tag)) {
            .call, .builtin, .compound_assign, .destructure, .@"asm" => return false,
            // `_ = x` stores nothing.
            .assign => {
                const target = tree.nodeData(node).node_and_node[0];
                if (formAt(tree, target) != .leaf or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_")) return false;
            },
            else => {},
        }
    }
    return true;
}

/// std's releases, read once for the summary, whose notion is given no `Context`.
const StdReleases = struct { read: bool = false, decls: std.ArrayList(Facts.Decl) = .empty };

fn readStdReleases(c: *Context) Error!void {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(StdReleases);
    if (memo.read) return;
    memo.read = true;
    for ([_][]const []const u8{ &handle_release_paths, &allocator_release_paths }) |paths| for (paths) |path| switch (try Governed.declarations(c, "std", path)) {
        .decls => |decls| try memo.decls.appendSlice(c.allocator, decls),
        // None known: nothing is read as released through it.
        .none, .unknown => {},
    };
}

fn stdRelease(facts: *Facts, callee: Facts.Decl, owner: Facts.Value) Facts.ResolveError!bool {
    _ = owner;
    const memo = try facts.memo(StdReleases);
    const origin = switch (try facts.origin(callee)) {
        .decl => |found| found,
        .none => callee,
        .unknown => return false,
    };
    for (memo.decls.items) |decl| if (std.meta.eql(decl, callee) or std.meta.eql(decl, origin)) return true;
    return false;
}
const std_release: release_summary.Base = .{ .notion = .std_handle, .isRelease = stdRelease };

/// The one reading of an owner here: whether a value owns nothing its drop leaks. It holds no
/// address anywhere (`Facts.holdsNoAddress`: no memory it may own), no std resource by value
/// (A015's: `Io.File`, `Io.Dir`, `Io.net.Stream`, `Io.net.Server`, `process.Child`), and no
/// aegis type, any of which may be an owner. aegis's roles come through PackageRules once its
/// separation lands; this is the one function that reads them.
fn ownsNothing(c: *Context, value: Facts.Value) Error!bool {
    if (!try c.facts.holdsNoAddress(value)) return false;
    var seen: std.ArrayList(Facts.Container) = .empty;
    return !try mayOwn(c, value, &seen);
}

const resource_paths = [_][]const u8{ "Io.File", "Io.Dir", "Io.net.Stream", "Io.net.Server", "process.Child" };

fn mayOwn(c: *Context, value: Facts.Value, seen: *std.ArrayList(Facts.Container)) Error!bool {
    switch (value) {
        .primitive, .scalar, .error_set => return false,
        .array, .optional, .error_union => |inner| return mayOwn(c, inner.*, seen),
        .alternatives => |each| {
            for (each) |one| if (try mayOwn(c, one, seen)) return true;
            return false;
        },
        .container, .instance => |container| {
            for (seen.items) |known| if (known.file == container.file and known.scope == container.scope) return false;
            try seen.append(c.allocator, container);
            if (try c.inLibrary(AegisContract.library, container.file)) return true;
            for (resource_paths) |path| switch (try Governed.declarations(c, "std", path)) {
                .decls => |decls| for (decls) |decl| switch (try c.facts.declaration(decl)) {
                    .container => |resource| if (resource.file == container.file and resource.scope == container.scope) return true,
                    // A resource type chosen per build may be this one.
                    .alternatives => return true,
                    else => {},
                },
                .none => {},
                .unknown => return true,
            };
            for (try c.facts.heldFields(container)) |field| if (try mayOwn(c, field.value, seen)) return true;
            return false;
        },
        else => return true,
    }
}

/// Standard error: the handled call writes through a writer the process's standard error is,
/// by value: its receiver is a local followed through its value (`.interface`, `&w.interface`,
/// `.writer`, a method of it), down to a call of std's `Io.File.stderr`, `debug.lockStderr` or
/// `Io.lockStderr`. std drops these failures itself (`std.debug.print`): standard error is the
/// channel a failure would be reported on. Standard output, a field and a parameter are not
/// read so, and stay sites.
fn toStderr(c: *Context, handled: Ast.Node.Index) Error!bool {
    const call = (try Facts.calls.at(c.facts, c.file, handled)) orelse return false;
    return switch (call.receiver) {
        .bound => |holder| stderrValue(c, holder),
        .none, .unknown => stderrValue(c, call.callee_expr),
    };
}

fn stderrValue(c: *Context, written: Ast.Node.Index) Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    const node = Facts.ungrouped(tree, written);
    switch (formAt(tree, node)) {
        .member => return stderrValue(c, tree.nodeData(node).node_and_token[0]),
        .address_of, .tried => return stderrValue(c, tree.nodeData(node).node),
        .leaf => {
            const decl = (try ownDeclaration(c, node)) orelse return false;
            if (decl.kind != .variable) return false;
            // A local's: a container's variable may be set anywhere.
            switch (model.scopes[@backingInt(decl.scope)].kind) {
                .file, .container => return false,
                else => {},
            }
            const variable = tree.fullVarDecl(decl.node) orelse return false;
            return stderrValue(c, variable.ast.init_node.unwrap() orelse return false);
        },
        else => {},
    }
    if (!Facts.calls.written(tree, node)) return false;
    for ([_][]const u8{ "Io.File.stderr", "debug.lockStderr", "Io.lockStderr" }) |path| if (try Governed.stdCall(c, node, path) == .yes) return true;
    const call = (try Facts.calls.at(c.facts, c.file, node)) orelse return false;
    return switch (call.receiver) {
        .bound => |holder| stderrValue(c, holder),
        .none, .unknown => false,
    };
}

/// Refusals alone: every error each callee the handled call may be returns (`Facts.callErrors`)
/// is a refusal of its input, no failure of the system: none is `OutOfMemory`, `Canceled` or
/// `Unexpected`, nor spelled by a set std's system namespaces declare (`systemNames`). In test
/// code (`inTestCode`) that is enough; in production code the handler is an `if`'s whose success
/// branch leaves on every path (`leaves`), so the failure goes on to the code below, its fallback.
/// A set that does not resolve, or `anyerror`, is no refusal.
fn refusalsOnly(c: *Context, site: Ast.Node.Index, handled: Ast.Node.Index) Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const call = (try Facts.calls.at(c.facts, c.file, handled)) orelse return false;
    const each: []const Facts.Decl = switch (call.callee) {
        .function => |*one| one[0..1],
        .choice => |all| all,
        .any => return false,
    };
    const system = try systemNames(c) orelse return false;
    for (each) |callee| switch (try c.facts.callErrors(callee)) {
        .names => |errors| for (errors) |one| if (!refusal(system, one.name)) return false,
        .any, .unknown => return false,
    };
    if (try c.inTestCode(tree.nodeMainToken(site))) return true;
    const branch = tree.fullIf(site) orelse return false;
    return leaves(tree, branch.ast.then_expr);
}

/// Whether an error name is a refusal: neither a failure every operation may meet (`OutOfMemory`,
/// `Canceled`, `Unexpected`) nor one of std's system errors. By its name: Zig's error names are
/// global identities, one `error.X` program-wide whatever set spells it, so a package's own
/// `error{EndOfStream}` is std's `EndOfStream` (NAME_TABLES allows a table of them).
fn refusal(system: *const std.StringHashMapUnmanaged(void), name: []const u8) bool {
    for ([_][]const u8{ "OutOfMemory", "Canceled", "Unexpected" }) |failure| if (std.mem.eql(u8, name, failure)) return false;
    return !system.contains(name);
}

/// Every error name an error set in std's system namespaces spells (`Io`, `fs`, `posix`, `os`,
/// `process`, `Thread`, each file under the namespace's own), found once for the run. Null where
/// a namespace does not resolve: no name is then read as a refusal.
const SystemNames = struct { names: std.StringHashMapUnmanaged(void) = .empty, built: bool = false };

fn systemNames(c: *Context) Error!?*const std.StringHashMapUnmanaged(void) {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(SystemNames);
    if (memo.built) return &memo.names;
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for ([_][]const u8{ "Io", "fs", "posix", "os", "process", "Thread" }) |namespace| {
        const decls = switch (try Governed.declarations(c, "std", namespace)) {
            .decls => |decls| decls,
            // No std, or none of this name: no system set of it.
            .none => continue,
            .unknown => return null,
        };
        for (decls) |decl| {
            const root = switch (try c.facts.declaration(decl)) {
                .container => |container| c.project.at(container.file).input.name,
                // A namespace chosen per build: its files are not one known set.
                .alternatives => return null,
                else => return null,
            };
            const stem = root[0 .. root.len - (if (std.mem.endsWith(u8, root, ".zig")) @as(usize, 4) else 0)];
            for (c.project.sources) |*source| {
                const name = source.input.name;
                const under = name.len > stem.len and std.mem.startsWith(u8, name, stem) and (name[stem.len] == '/' or name[stem.len] == '\\');
                if (!std.mem.eql(u8, name, root) and !under) continue;
                if (!try c.facts.standard(source.id) or source.file.status != .parsed) continue;
                try setNames(c, &source.file.tree, &names);
            }
        }
    }
    memo.names = names;
    memo.built = true;
    return &memo.names;
}

fn setNames(c: *Context, tree: *const Ast, names: *std.StringHashMapUnmanaged(void)) Error!void {
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .error_set_decl) continue;
        const open, const close = tree.nodeData(@fromBackingInt(@intCast(i))).token_and_token;
        var token = open + 1;
        while (token < close) : (token += 1) {
            if (tree.tokenTag(token) != .identifier) continue;
            try names.put(c.allocator, try Model.identifier(c.allocator, tree.tokenSlice(token)), {});
        }
    }
}

/// Whether every path through `node` leaves: a `return`, `break`, `continue`, `unreachable` or
/// `@panic` ends it, an `if` with both branches so, a `switch` with every prong so, a block whose
/// last statement does.
fn leaves(tree: *const Ast, written: Ast.Node.Index) bool {
    const node = Facts.ungrouped(tree, written);
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.blockStatements(&buffer, node)) |statements| return statements.len != 0 and leaves(tree, statements[statements.len - 1]);
    switch (formAt(tree, node)) {
        .@"return", .@"break", .@"continue" => return true,
        .leaf => return tree.tokenTag(tree.nodeMainToken(node)) == .keyword_unreachable,
        .builtin => return Facts.isBuiltin(tree, node, "@panic"),
        .@"switch" => {
            const whole = tree.fullSwitch(node).?; // unreachable: a switch's form holds switches
            for (whole.ast.cases) |case| if (!leaves(tree, tree.fullSwitchCase(case).?.ast.target_expr)) return false; // unreachable: a switch's cases are cases
            return true;
        },
        else => {},
    }
    const branch = tree.fullIf(node) orelse return false;
    return leaves(tree, branch.ast.then_expr) and leaves(tree, branch.ast.else_expr.unwrap() orelse return false);
}
