//! Correctness: a file opened write-only, then stat or read through the same handle in the same
//! function. A read fails on every system, and Windows refuses the stat as well: a handle opened
//! without read access lacks FILE_READ_ATTRIBUTES there, where POSIX's fstat needs none.
//! The handle is opened write-only where std's `Io.Dir.createFile` or `createFileAbsolute` is
//! given a literal options struct with no `.read = true`, or `Io.Dir.openFile` or
//! `openFileAbsolute` a literal with `.mode = .write_only`; and it is held in a local the call
//! initializes, past `try` and `catch`. Through that local, `stat` and the reads (`readStreaming`,
//! `readPositional`, `readPositionalAll`, `reader`, `readerStreaming`) are reported; `length`,
//! `setLength`, `sync`, `setTimestamps`, `setPermissions` and the writes need no read access and
//! are not. Not read: options that are no literal (a name, a call's result), a `.read` or `.mode`
//! the literal sets to anything but a literal, a callee that does not resolve to std's, a `var`
//! the function assigns again, and a handle that leaves the local (handed to a call, stored in a
//! field, returned): what is done with it there is not this function's to read.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Governed = @import("Governed.zig");
const Model = @import("Model.zig");
const Rule = @import("Rule.zig").Rule;
const Written = @import("Written.zig");

/// How a write-only handle came to be, which says how to open it for reading.
const Opened = enum { created, opened };

const openers = [_]struct { []const u8, Opened }{
    .{ "Io.Dir.createFile", .created },
    .{ "Io.Dir.createFileAbsolute", .created },
    .{ "Io.Dir.openFile", .opened },
    .{ "Io.Dir.openFileAbsolute", .opened },
};

/// The handle's methods that need read access: `stat` (Windows alone), and the reads.
const reads = [_][]const u8{ "stat", "readStreaming", "readPositional", "readPositionalAll", "reader", "readerStreaming" };

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .call_one, .call_one_comma, .call, .call_comma => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (call.ast.params.len == 0) continue;
        // Cheap first: a literal that opens write-only, then whether the callee is std's.
        const opened = writeOnly(tree, call.ast.params[call.ast.params.len - 1]) orelse continue;
        const named = callee(tree, call.ast.fn_expr) orelse continue;
        const kind = for (openers) |opener| {
            if (opened.kind != opener[1] or !std.mem.eql(u8, opener[0][std.mem.findScalarLast(u8, opener[0], '.').? + 1 ..], named)) continue;
            if (try Governed.stdCall(c, node, opener[0]) == .yes) break opener[1];
        } else continue;
        const local = handle(tree, model, node) orelse continue;
        if (reassigned(tree, model, local)) continue;
        for (model.references) |reference| {
            if (reference.declaration != local) continue;
            const method = readThrough(tree, model, reference.node) orelse continue;
            const name = model.declarations[@backingInt(local)].name;
            const how, const fix = switch (kind) {
                .created => .{ "created without `.read = true`", "create it with `.read = true`" },
                .opened => .{ "opened `.mode = .write_only`", "open it `.mode = .read_write`" },
            };
            const message = if (std.mem.eql(u8, method.name, "stat"))
                try c.allocator.print("`{s}.stat` on a file {s}: Windows refuses it, as the handle lacks read-attributes access (FILE_READ_ATTRIBUTES); {s}, or take its size with `length()`", .{ name, how, fix })
            else
                try c.allocator.print("`{s}.{s}` reads a file {s}: the handle has no read access on any system; {s}", .{ name, method.name, how, fix });
            try c.at(rule, method.token, message);
        }
    }
}

/// The options literal's verdict: write-only (and how), or null where it opens for reading or is
/// not read.
fn writeOnly(tree: *const Ast, options: Ast.Node.Index) ?struct { kind: Opened } {
    var buffer: [2]Ast.Node.Index = undefined;
    const literal = tree.fullStructInit(&buffer, Written.ungrouped(tree, options)) orelse return null;
    if (literal.ast.type_expr != .none) return null;
    var read: ?bool = false;
    var mode: ?[]const u8 = null;
    var mode_literal = true;
    for (literal.ast.fields) |field| {
        const name = tree.tokenSlice(tree.firstToken(field) - 2);
        const value = Written.ungrouped(tree, field);
        if (std.mem.eql(u8, name, "read")) {
            const spelled = if (tree.nodeTag(value) == .identifier) tree.tokenSlice(tree.nodeMainToken(value)) else "";
            read = if (std.mem.eql(u8, spelled, "true")) true else if (std.mem.eql(u8, spelled, "false")) false else null;
        } else if (std.mem.eql(u8, name, "mode")) {
            if (tree.nodeTag(value) == .enum_literal) mode = tree.tokenSlice(tree.nodeMainToken(value)) else mode_literal = false;
        }
    }
    // `.mode` belongs to openFile's options, `.read` to createFile's: the literal says which.
    if (mode != null or !mode_literal) {
        if (!mode_literal) return null;
        return if (std.mem.eql(u8, mode.?, "write_only")) .{ .kind = .opened } else null;
    }
    return if (read == false) .{ .kind = .created } else null;
}

/// The name a call's callee is written with: `createFile` of `dir.createFile`, or of
/// `std.Io.Dir.createFile`; null for anything else.
fn callee(tree: *const Ast, fn_expr: Ast.Node.Index) ?[]const u8 {
    return switch (tree.nodeTag(fn_expr)) {
        .field_access => tree.tokenSlice(tree.nodeData(fn_expr).node_and_token[1]),
        .identifier => tree.tokenSlice(tree.nodeMainToken(fn_expr)),
        else => null,
    };
}

/// The local of a function the call's result initializes, past parentheses, `try` and the left
/// of a `catch`: `const f = try dir.createFile(...)`; null for any other place.
fn handle(tree: *const Ast, model: *const Model, call: Ast.Node.Index) ?Model.Declaration.Id {
    var child = call;
    var parent = model.parentOf(call) orelse return null;
    while (true) {
        switch (tree.nodeTag(parent)) {
            .grouped_expression, .@"try" => {},
            .@"catch" => if (tree.nodeData(parent).node_and_node[0] != child) return null,
            else => break,
        }
        child = parent;
        parent = model.parentOf(parent) orelse return null;
    }
    const declaration = tree.fullVarDecl(parent) orelse return null;
    if (declaration.ast.init_node.unwrap() != child) return null;
    for (model.declarations, 0..) |each, index| {
        if (each.kind != .variable or each.node != parent) continue;
        return switch (model.scopes[@backingInt(each.scope)].kind) {
            .file, .container => null,
            else => @fromBackingInt(@intCast(index)),
        };
    }
    return null;
}

/// Whether a `var` local is assigned again: a later value may be another file.
fn reassigned(tree: *const Ast, model: *const Model, local: Model.Declaration.Id) bool {
    for (model.references) |reference| {
        if (reference.declaration != local) continue;
        const parent = model.parentOf(reference.node) orelse continue;
        if (tree.nodeTag(parent) == .assign and tree.nodeData(parent).node_and_node[0] == reference.node) return true;
    }
    return false;
}

/// The method needing read access a reference of the handle calls (`f.stat(io)`), its name and
/// token; null for any other use.
fn readThrough(tree: *const Ast, model: *const Model, reference: Ast.Node.Index) ?struct { name: []const u8, token: Ast.TokenIndex } {
    const access = model.parentOf(reference) orelse return null;
    if (tree.nodeTag(access) != .field_access) return null;
    const receiver, const name_token = tree.nodeData(access).node_and_token;
    if (receiver != reference) return null;
    const name = tree.tokenSlice(name_token);
    for (reads) |each| {
        if (!std.mem.eql(u8, each, name)) continue;
        const call_node = model.parentOf(access) orelse return null;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, call_node) orelse return null;
        if (call.ast.fn_expr != access) return null;
        return .{ .name = each, .token = name_token };
    }
    return null;
}

const breadth = @import("breadth_test.zig");

test "breadth: write-only stat: stat and reads on a handle created without .read = true or opened .write_only; .read = true, .read_write, length and non-literal options not" {
    const prelude =
        \\const std = @import("std");
        \\
    ;
    try breadth.expectFindings(check, prelude ++
        \\pub fn f(dir: std.Io.Dir, io: std.Io) !u64 {
        \\    const file = try dir.createFile(io, "out", .{});
        \\    defer file.close(io);
        \\    return (try file.stat(io)).size;
        \\}
    , 1);
    try breadth.expectFindings(check, prelude ++
        \\pub fn f(dir: std.Io.Dir, io: std.Io, buffer: []u8) !usize {
        \\    const file = dir.openFile(io, "in", .{ .mode = .write_only }) catch |err| return err;
        \\    defer file.close(io);
        \\    _ = try file.stat(io);
        \\    return file.readPositional(io, &.{buffer}, 0);
        \\}
    , 2);
    try breadth.expectFindings(check, prelude ++
        \\pub fn f(dir: std.Io.Dir, io: std.Io) !u64 {
        \\    const file = try dir.createFile(io, "out", .{ .read = true, .truncate = false });
        \\    defer file.close(io);
        \\    const opened = try dir.openFile(io, "in", .{ .mode = .read_write });
        \\    defer opened.close(io);
        \\    _ = try opened.stat(io);
        \\    return (try file.stat(io)).size;
        \\}
    , 0);
    try breadth.expectFindings(check, prelude ++
        \\pub fn f(dir: std.Io.Dir, io: std.Io, options: std.Io.Dir.CreateFileOptions) !u64 {
        \\    const file = try dir.createFile(io, "out", .{});
        \\    defer file.close(io);
        \\    try file.setLength(io, 0);
        \\    try file.sync(io);
        \\    const other = try dir.createFile(io, "other", options);
        \\    defer other.close(io);
        \\    _ = try other.stat(io);
        \\    return file.length(io);
        \\}
    , 0);
}
