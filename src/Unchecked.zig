//! P007: the operations Zig leaves unchecked, a ban outside the seams a project declares. Inline
//! assembly; `@setRuntimeSafety` off in a build that keeps the checks; the pointer conversions no
//! build checks (`@ptrCast`, `@alignCast`, `@constCast`, `@volatileCast`, `@ptrFromInt`,
//! `@fieldParentPtr`); an `extern` declaration and `@extern`; `noalias`; `@setFloatMode(.optimized)`;
//! arithmetic on or indexing of a many-item or C pointer, which carries no length; std's
//! `mem.bytesAsValue` and `mem.bytesAsSlice`, a reinterpretation by another name; and any member of
//! std's raw OS and C bindings (`std.c`, `std.os.linux`, `std.os.windows`), which the program
//! reaches past std's checked layer. Production code only; an operation the program runs only as
//! it compiles has none of these dangers.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Governed = @import("Governed.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Rule = @import("Rule.zig").Rule;

const Ast = std.zig.Ast;

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        switch (tag) {
            .asm_simple, .@"asm" => {
                if (!c.inTest(token) and try atRuntime(c, node)) try c.at(rule, token, "inline assembly: no check of what it reads or writes; keep it behind the package's one seam with its reason");
                continue;
            },
            else => {},
        }
        const name = Facts.builtinName(tree, node) orelse continue;
        if (c.inTest(token) or !try atRuntime(c, node)) continue;
        if (std.mem.eql(u8, name, "@setRuntimeSafety")) {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 1) continue;
            // A condition on the build mode: off in the modes whose checks it turns off. A mode
            // that builds without them (fast, small) loses nothing to it.
            const on = (try Model.modes(c.allocator, tree, &c.project.at(c.file).model, args[0], 0)) orelse {
                try c.unknown(rule, node, .comptime_dependent);
                continue;
            };
            // Off in every mode (`false`, a constant that holds it).
            if (on.count() == 0) {
                try c.at(rule, token, "@setRuntimeSafety(false): bounds, overflow and union checks off; only a measured hot loop validated at its boundary");
                continue;
            }
            var off: Model.Modes = .initMany(&.{ .debug, .safe });
            off.setIntersection(on.complement());
            var it = off.iterator();
            const first = it.next() orelse continue;
            const names = if (it.next() != null) "debug and safe" else @tagName(first);
            try c.at(rule, token, try c.allocator.print("@setRuntimeSafety off in {s} builds: bounds, overflow and union checks off where the build keeps them; only a measured hot loop validated at its boundary", .{names}));
            continue;
        }
        // An address read out of a pointer (`@intFromPtr`) is never undefined behavior.
        for ([_][]const u8{ "@ptrCast", "@alignCast", "@constCast", "@volatileCast", "@ptrFromInt", "@fieldParentPtr" }) |cast| if (std.mem.eql(u8, name, cast)) {
            try c.at(rule, token, try c.allocator.print("{s}: a pointer conversion no build checks", .{name}));
        };
        if (std.mem.eql(u8, name, "@extern")) try c.at(rule, token, "@extern: a symbol whose definition Zig does not check; only the raw call, at the package's seam");
        if (std.mem.eql(u8, name, "@setFloatMode")) {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len == 1 and tree.nodeTag(args[0]) == .enum_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(args[0])), "optimized"))
                try c.at(rule, token, "@setFloatMode(.optimized): float results no build checks; only a measured hot loop validated at its boundary");
        }
    }
    const model = &c.project.at(c.file).model;
    for (model.declarations) |decl| {
        if (decl.kind != .variable and decl.kind != .function) continue;
        const token: ?Ast.TokenIndex = if (decl.kind == .function) blk: {
            var buffer: [1]Ast.Node.Index = undefined;
            break :blk (tree.fullFnProto(&buffer, decl.node) orelse continue).extern_export_inline_token;
        } else (tree.fullVarDecl(decl.node) orelse continue).extern_export_token;
        const keyword = token orelse continue;
        if (tree.tokenTag(keyword) != .keyword_extern or c.inTest(decl.token)) continue;
        try c.at(rule, keyword, try c.allocator.print("extern '{s}': a declaration whose definition Zig does not check; only the raw call, at the package's seam", .{decl.name}));
    }
    for (0..tree.tokens.len) |raw| {
        const token: Ast.TokenIndex = @intCast(raw);
        if (tree.tokenTag(token) != .keyword_noalias or c.inTest(token)) continue;
        try c.at(rule, token, "noalias: a promise of no aliasing no build checks");
    }
    try lengthless(c, rule);
    try reinterpreted(c, rule);
    try rawBindings(c, rule);
}

/// Arithmetic on, or an index into, a many-item or C pointer: it carries no length to check.
fn lengthless(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, raw| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const operand: Ast.Node.Index, const what: []const u8 = switch (tag) {
            .add, .sub, .assign_add, .assign_sub, .add_wrap, .sub_wrap => .{ tree.nodeData(node).node_and_node[0], "arithmetic on" },
            .array_access => .{ tree.nodeData(node).node_and_node[0], "an index into" },
            else => continue,
        };
        const token = tree.nodeMainToken(node);
        if (c.inTest(token) or !try atRuntime(c, node)) continue;
        const value = try c.facts.resolve(c.file, operand);
        const size = switch (value) {
            .pointer => |pointer| pointer.size orelse continue,
            else => continue,
        };
        if (size != .many and size != .c) continue;
        try c.at(rule, token, try c.allocator.print("{s} a {s} pointer, which carries no length to check", .{ what, if (size == .many) "many-item" else "C" }));
    }
}

/// std's reinterpretations by name: `mem.bytesAsValue` and `mem.bytesAsSlice`. A reference spelling
/// one that does not resolve cannot be shown to be another: a finding, as under any ban.
fn reinterpreted(c: *Context, rule: Rule) Context.Error!void {
    // A std that declares neither has none to reference: silent, as a lookup that finds none is.
    var found: std.ArrayList(Governed.Governed) = .empty;
    for ([_][]const u8{ "mem.bytesAsValue", "mem.bytesAsSlice" }, 0..) |path, i| {
        const decls = switch (try Governed.declarations(c, "std", path)) {
            .decls => |decls| decls,
            .none, .unknown => continue,
        };
        try found.append(c.allocator, .{ .target = .{ .source = "std", .declaration = path, .production = true }, .index = i, .name = path["mem.".len..], .decls = decls, .symbol = null });
    }
    var sites: std.ArrayList(Governed.Site) = .empty;
    var unread: std.ArrayList(Governed.Unread) = .empty;
    try Governed.sitesLeaving(c, rule, found.items, &sites, &unread);
    for (sites.items) |site| try c.atDefinition(rule, site.token, "a reinterpretation of bytes as another type no build checks", site.decl);
    const tree = &c.project.at(c.file).file.tree;
    for (unread.items) |missed| try c.at(rule, tree.firstToken(missed.node), try c.allocator.print("a reference spelling std's mem.bytesAsValue or bytesAsSlice does not resolve ({t}), so it cannot be shown to be another", .{missed.why}));
}

/// A member of std's raw OS and C bindings, named where the program reaches it: a member access
/// whose holder is one of those namespaces (an alias of one is reported where it is used).
fn rawBindings(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, raw| {
        if (tag != .field_access) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const member = tree.nodeData(node).node_and_token[1];
        if (c.inTest(member)) continue;
        const holder = switch (try c.facts.resolve(c.file, tree.nodeData(node).node_and_token[0])) {
            .container => |container| container,
            else => continue,
        };
        const binding = (try bindingOf(c, holder.file)) orelse continue;
        try c.at(rule, member, try c.allocator.print("std.{s}: a raw binding past std's checked layer; only at the package's seam", .{binding}));
    }
}

/// Which raw binding a std file is, if one: `c`, `os.linux` or `os.windows`, or a file of theirs.
fn bindingOf(c: *Context, file: Project.FileId) Context.Error!?[]const u8 {
    if (!try c.facts.standard(file)) return null;
    const name = c.project.at(file).input.name;
    for ([_]struct { []const u8, []const u8 }{ .{ "std/c.zig", "c" }, .{ "std/os/linux.zig", "os.linux" }, .{ "std/os/windows.zig", "os.windows" } }) |each| {
        if (std.mem.endsWith(u8, name, each[0])) return each[1];
        // A file of the binding's own directory (`std/os/linux/io_uring.zig`).
        const directory = each[0][0 .. each[0].len - ".zig".len];
        if (std.mem.find(u8, name, try c.allocator.print("{s}/", .{directory})) != null) return each[1];
    }
    return null;
}

/// Whether the code at `node` runs when the program runs: inside a function's body that does
/// not return `type`, outside any `comptime` block and any container's declarations nested
/// there. A container-level value or a field's default is evaluated as the program compiles.
fn atRuntime(c: *const Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            .@"comptime" => return false,
            .test_decl => return true,
            .fn_decl => {
                var buffer: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buffer, tree.nodeData(parent).node_and_node[0]) orelse return true;
                const result = proto.ast.return_type.unwrap() orelse return true;
                return !try c.facts.typeIsType(c.file, result);
            },
            else => {
                var buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullContainerDecl(&buffer, parent) != null) return false;
            },
        }
    }
    return false;
}
