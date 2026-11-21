//! Ban: standard output or standard error written through a positional writer. std's
//! `Io.File.writer` writes its file at an offset it keeps, from 0, which a stream refuses or, where
//! the stream is a file (output redirected, `>>` among them), writes over what is there; the
//! streaming writer (`Io.File.writerStreaming`) writes where the stream is. Read: a call whose
//! every callee is std's `Io.File.writer` (`Governed.stdCall`, through aliases), whose receiver is
//! a call whose every callee is std's `Io.File.stdout` or `Io.File.stderr`, as written or as the
//! value of a local or file-level `const` it names, followed through what gives a value
//! (`Facts.accesses.valuesOf`: parentheses, `try`, `orelse`, an `if`'s or a `switch`'s results).
//! A receiver that may be a stream in one branch is reported. A `var` and a parameter are not
//! followed. Test code is read too: a test's child program writes its streams as any other. A
//! call that may be the writer, or a receiver that may be a stream, where what it reads is unknown
//! is no pass: glint's own failure makes the run incomplete, and a generic position is counted
//! outside the ban (`Context.unknownAt`).
const Ast = @import("std").zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Facts = @import("Facts.zig");
const Governed = @import("Governed.zig");
const Written = @import("Written.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (try Facts.calls.in(c.facts, c.file)) |call| {
        const token = tree.nodeMainToken(call.node);
        switch (try Governed.mayCallStd(c, call.node, "Io.File.writer")) {
            .no => continue,
            .yes => {},
            .unknown => |why| {
                try c.unknownAt(rule, token, why);
                continue;
            },
        }
        const args = switch (call.args) {
            .known => |args| args,
            .unknown => |why| {
                try c.unknownAt(rule, token, why);
                continue;
            },
        };
        // `file.writer(io, buffer)` binds the file first; `Io.File.writer(file, io, buffer)` passes it.
        if (args.len != 3) continue;
        const stream = try streamOf(c, tree, args[0], 0);
        switch (stream) {
            .none => continue,
            .unknown => |why| {
                try c.unknownAt(rule, token, why);
                continue;
            },
            .stdout, .stderr => {},
        }
        try c.at(rule, token, if (stream == .stdout)
            "standard output through a positional writer writes at an offset, over a file the output is redirected to; use writerStreaming (or ensign's streaming stdout)"
        else
            "standard error through a positional writer writes at an offset, over a file the output is redirected to; use writerStreaming (or ensign's streaming stderr)");
    }
}

const Stream = union(enum) { stdout, stderr, none, unknown: Facts.Unknown };

/// The standard stream the value at `node` may be: one where any of its values may be (a stream
/// is what is reported), none where none is, unknown where one is unknown and none is a stream.
fn streamOf(c: *Context, tree: *const Ast, node: Ast.Node.Index, depth: u8) Context.Error!Stream {
    // A chain of `const`s naming one another ends long before this.
    if (depth > 8) return .{ .unknown = .budget };
    const leaves = switch (try Facts.accesses.valuesOf(c.facts, c.file, node)) {
        .leaves => |leaves| leaves,
        .unknown => |why| return .{ .unknown = why },
    };
    var found: Stream = .none;
    for (leaves) |leaf| {
        const at = Written.ungrouped(tree, leaf);
        if (Facts.calls.written(tree, at)) {
            for ([_]struct { []const u8, Stream }{ .{ "Io.File.stdout", .stdout }, .{ "Io.File.stderr", .stderr } }) |each| switch (try Governed.mayCallStd(c, at, each[0])) {
                .yes => return each[1],
                .no => {},
                .unknown => |why| found = .{ .unknown = why },
            };
            continue;
        }
        if (tree.nodeTag(at) != .identifier) continue;
        const init = constInit(c, tree, at) orelse continue;
        const held = try streamOf(c, tree, init, depth + 1);
        switch (held) {
            .none => {},
            .unknown => found = held,
            .stdout, .stderr => return held,
        }
    }
    return found;
}

/// The value a `const` the identifier at `node` names is given, in the same file.
fn constInit(c: *Context, tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    const model = &c.project.at(c.file).model;
    const ref = model.reference(node) orelse return null;
    const index = ref.declaration orelse return null;
    const decl = model.declarations[@backingInt(index)];
    if (decl.kind != .variable) return null;
    const variable = tree.fullVarDecl(decl.node) orelse return null;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
    return variable.ast.init_node.unwrap();
}

const breadth = @import("breadth_test.zig");

test "breadth: positional stream: stdout or stderr through writer reported, as written or held in a const; writerStreaming and another file not" {
    try breadth.expectFindings(check, "const std = @import(\"std\"); pub fn f(io: std.Io, b: []u8) void { _ = std.Io.File.stdout().writer(io, b); _ = std.Io.File.stderr().writer(io, b); }", 2);
    try breadth.expectFindings(check, "const std = @import(\"std\"); const Io = std.Io; pub fn f(io: Io, b: []u8) void { const out = Io.File.stdout(); _ = out.writer(io, b); _ = Io.File.writer(Io.File.stderr(), io, b); }", 2);
    try breadth.expectFindings(check, "const std = @import(\"std\"); pub fn f(io: std.Io, b: []u8) void { _ = std.Io.File.stdout().writerStreaming(io, b); const err = std.Io.File.stderr(); _ = err.writerStreaming(io, b); }", 0);
    try breadth.expectFindings(check, "const std = @import(\"std\"); pub fn f(io: std.Io, file: std.Io.File, b: []u8) void { _ = file.writer(io, b); }", 0);
}

test "positional stream: a writer call on a value only a binding types is counted outside the ban; one on what glint does not resolve stops the run" {
    // `out`'s type is the caller's: a generic position, never a verdict.
    try breadth.expectUnknowns(check, "const std = @import(\"std\"); pub fn f(io: std.Io, out: anytype, b: []u8) void { _ = out.writer(io, b); }", 0, 0, 1);
    // A name nothing declares: glint's own failure, by name.
    try breadth.expectUnknowns(check, "const std = @import(\"std\"); pub fn f(io: std.Io, b: []u8) void { _ = nowhere.writer(io, b); }", 0, 1, 0);
    // A member another name spells is no writer call: nothing to decide.
    try breadth.expectUnknowns(check, "const std = @import(\"std\"); pub fn f(out: anytype) void { _ = out.flush(); }", 0, 0, 0);
}
