//! P007: the operations Zig leaves unchecked, a ban outside the seams a project declares. Inline
//! assembly; `@setRuntimeSafety` off in a build that keeps the checks; the pointer conversions no
//! build checks (`@ptrCast`, `@alignCast`, `@constCast`, `@volatileCast`, `@addrSpaceCast`,
//! `@ptrFromInt`); an `extern` declaration and `@extern`; `noalias`; `@setFloatMode(.optimized)`;
//! C variadic arguments (`@cVaStart`, `@cVaArg`, `@cVaCopy`, `@cVaEnd`); arithmetic on, indexing
//! or slicing of a many-item or C pointer, which carries no length; std's `mem.bytesAsValue` and
//! `mem.bytesAsSlice`, a reinterpretation by another name; and any member of std's raw OS and C
//! bindings (`std.c`, `std.os.linux`, `std.os.windows`, and `std.posix.system`, one of them by
//! target), which the program reaches past std's checked layer. Production code only; an
//! operation the program runs only as it compiles has none of these dangers, but for assembly,
//! `@extern` and `@ptrFromInt`, whose symbol or address the program uses where it runs. Zig's two
//! interface idioms are not read, as neither has an alternative: `@fieldParentPtr`, and the
//! `@alignCast` whose operand it is (`@alignCast(@fieldParentPtr("f", p))`, std.Io's own); and a
//! `@ptrCast`, with or without the `@alignCast` inside it, from a `*anyopaque` to a pointer to one
//! item, how std.mem.Allocator's `ptr`, std.Io's `userdata` and every hand-written vtable recover
//! their owner. A `@ptrCast` from `*anyopaque` to a slice or a many-item pointer stays a finding.
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
            // Global assembly (`comptime { asm (...) }`) too: it defines what the program calls.
            .asm_simple, .@"asm" => {
                if (!c.inTest(token)) try c.at(rule, token, "inline assembly: no check of what it reads or writes; keep it behind the package's one seam with its reason");
                continue;
            },
            else => {},
        }
        const name = Facts.builtinName(tree, node) orelse continue;
        if (c.inTest(token)) continue;
        // A symbol bound or an address made as the program compiles is still called or
        // dereferenced where it runs (`const reg: *volatile u32 = @ptrFromInt(0x4000_0000);`).
        if (std.mem.eql(u8, name, "@extern")) {
            try c.at(rule, token, "@extern: a symbol whose definition Zig does not check; only the raw call, at the package's seam");
            continue;
        }
        if (std.mem.eql(u8, name, "@ptrFromInt")) {
            // Inside a cast written around it, the outer one is the site where that one is read.
            if (!nestedCast(c, tree, node) or !try atRuntime(c, node)) try c.at(rule, token, "@ptrFromInt: a pointer conversion no build checks");
            continue;
        }
        // Any member of a raw binding, named by `@field` (`@field(std.c, "getpid")`).
        if (std.mem.eql(u8, name, "@field")) {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len == 2) if (try namespaceBinding(c, try c.facts.resolve(c.file, args[0]))) |binding|
                try c.at(rule, token, try c.allocator.print("std.{s}: a raw binding past std's checked layer; only at the package's seam", .{binding}));
            continue;
        }
        if (!try atRuntime(c, node)) continue;
        if (std.mem.eql(u8, name, "@setRuntimeSafety")) {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 1) continue;
            // A condition on the build mode: off in the modes whose checks it turns off. A mode
            // that builds without them (fast, small) loses nothing to it.
            const on = (try Model.modes(c.allocator, tree, &c.project.at(c.file).model, args[0], 0)) orelse {
                try c.at(rule, token, "@setRuntimeSafety on a value the build mode does not decide: the checks cannot be shown to stay on; only a measured hot loop validated at its boundary");
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
        // A cast written straight inside another (`@ptrCast(@alignCast(p))`) is one conversion:
        // the outermost is its site, so one suppression names it.
        if (pointerCast(name) and !nestedCast(c, tree, node) and !recovery(tree, node, name) and !try ownerRecovery(c, tree, node, name)) {
            try c.at(rule, token, try c.allocator.print("{s}: a pointer conversion no build checks", .{name}));
        }
        if (std.mem.startsWith(u8, name, "@cVa")) try c.at(rule, token, try c.allocator.print("{s}: C variadic arguments read as whatever type the program names, which no build checks", .{name}));
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

fn pointerCast(name: []const u8) bool {
    for ([_][]const u8{ "@ptrCast", "@alignCast", "@constCast", "@volatileCast", "@addrSpaceCast", "@ptrFromInt" }) |cast| if (std.mem.eql(u8, name, cast)) return true;
    return false;
}

/// Whether the cast at `node` is a `@ptrCast` (of an `@alignCast` or not) of a value typed
/// `*anyopaque` (`?*anyopaque`, `*const anyopaque` alike) to a pointer to one item.
fn ownerRecovery(c: *Context, tree: *const Ast, node: Ast.Node.Index, name: []const u8) Context.Error!bool {
    if (!std.mem.eql(u8, name, "@ptrCast")) return false;
    var operand = only(tree, node) orelse return false;
    if (std.mem.eql(u8, Facts.builtinName(tree, operand) orelse "", "@alignCast")) operand = only(tree, operand) orelse return false;
    var from = try c.facts.resolve(c.file, operand);
    if (from == .optional) from = from.optional.*;
    if (from != .pointer or from.pointer.size != .one) return false;
    if (from.pointer.child.* != .primitive or !std.mem.eql(u8, from.pointer.child.primitive, "anyopaque")) return false;
    const made = try c.facts.castTypeIn(null, c.file, node);
    return made == .pointer and made.pointer.size == .one;
}

/// A builtin call's one argument, past parentheses.
fn only(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len != 1) return null;
    var operand = args[0];
    while (tree.nodeTag(operand) == .grouped_expression) operand = tree.nodeData(operand).node_and_token[0];
    return operand;
}

/// Whether the cast at `node` is `@alignCast` of a `@fieldParentPtr`, past parentheses.
fn recovery(tree: *const Ast, node: Ast.Node.Index, name: []const u8) bool {
    if (!std.mem.eql(u8, name, "@alignCast")) return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len != 1) return false;
    var operand = args[0];
    while (tree.nodeTag(operand) == .grouped_expression) operand = tree.nodeData(operand).node_and_token[0];
    return std.mem.eql(u8, Facts.builtinName(tree, operand) orelse return false, "@fieldParentPtr");
}

/// Whether the pointer cast at `node` is the operand of another, past parentheses.
fn nestedCast(c: *Context, tree: *const Ast, node: Ast.Node.Index) bool {
    const model = &c.project.at(c.file).model;
    var parent = model.parentOf(node) orelse return false;
    while (tree.nodeTag(parent) == .grouped_expression) parent = model.parentOf(parent) orelse return false;
    return pointerCast(Facts.builtinName(tree, parent) orelse return false);
}

/// Arithmetic on, or an index into, a many-item or C pointer: it carries no length to check.
fn lengthless(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, raw| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const operand: Ast.Node.Index, const what: []const u8 = switch (tag) {
            .add, .sub, .assign_add, .assign_sub, .add_wrap, .sub_wrap => .{ tree.nodeData(node).node_and_node[0], "arithmetic on" },
            .array_access => .{ tree.nodeData(node).node_and_node[0], "an index into" },
            // A slice's length is the program's word: `p[0..n]` checks no `n` against the memory.
            .slice_open, .slice, .slice_sentinel => .{ (tree.fullSlice(node) orelse continue).ast.sliced, "a slice of" },
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
    try Governed.sitesLeaving(c, found.items, &sites, &unread);
    for (sites.items) |site| try c.atDefinition(rule, site.token, "a reinterpretation of bytes as another type no build checks", site.decl);
    const tree = &c.project.at(c.file).file.tree;
    for (unread.items) |missed| try c.at(rule, tree.firstToken(missed.node), try c.allocator.print("a reference spelling std's mem.bytesAsValue or bytesAsSlice does not resolve ({t}), so it cannot be shown to be another", .{missed.why}));
}

/// A member of std's raw OS and C bindings, named where the program reaches it: a member access
/// whose holder is one of those namespaces (an alias of one is reported where it is used), or
/// may be in the build that compiles it (`std.posix.system`, std.c or std.os.linux by target).
fn rawBindings(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, raw| {
        if (tag != .field_access) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const member = tree.nodeData(node).node_and_token[1];
        if (c.inTest(member)) continue;
        const binding = (try namespaceBinding(c, try c.facts.resolve(c.file, tree.nodeData(node).node_and_token[0]))) orelse continue;
        try c.at(rule, member, try c.allocator.print("std.{s}: a raw binding past std's checked layer; only at the package's seam", .{binding}));
    }
}

/// The raw binding a holder is, or any build's choice of it is: a binding's namespace, the file
/// itself (or a file of its directory), never a type it declares, so a constant std's portable
/// layer takes from it (`std.posix.E.AGAIN`) is none.
fn namespaceBinding(c: *Context, value: Facts.Value) Context.Error!?[]const u8 {
    for (Facts.valueParts(&value)) |part| switch (part) {
        .container => |container| {
            if (container.scope != c.facts.rootOf(container.file).scope) continue;
            if (try bindingOf(c, container.file)) |binding| return binding;
        },
        else => {},
    };
    return null;
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
