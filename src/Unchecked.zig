//! P007: the operations Zig leaves unchecked, a ban outside the seams a project declares. Inline
//! assembly; `@setRuntimeSafety` off in a build that keeps the checks; the pointer conversions no
//! build checks (`@ptrCast`, `@alignCast`, `@constCast`, `@volatileCast`, `@addrSpaceCast`,
//! `@ptrFromInt`); an `extern` declaration and `@extern`; `noalias`; `@setFloatMode(.optimized)`;
//! C variadic arguments (`@cVaStart`, `@cVaArg`, `@cVaCopy`, `@cVaEnd`); arithmetic on, indexing
//! or slicing of a many-item or C pointer, which carries no length (a slice's `.ptr` is one);
//! std's `mem.bytesAsValue` and
//! `mem.bytesAsSlice`, a reinterpretation by another name; and any member of std's raw OS and C
//! bindings (`std.c`, `std.os.linux`, `std.os.windows`, and `std.posix.system`, one of them by
//! target), which the program reaches past std's checked layer; and an import of a module a build
//! step makes (translate-c's C bindings, a Run step's output), which glint reads none of.
//! Production code only; an
//! operation the program runs only as it compiles has none of these dangers, but for assembly,
//! `@extern` and `@ptrFromInt`, whose symbol or address the program uses where it runs. Zig's two
//! interface idioms are not read, as neither has an alternative: `@fieldParentPtr`, bare or as the
//! operand of an `@alignCast` (`@alignCast(@fieldParentPtr("f", p))`), read as one: both spellings
//! make the same parent-pointer claim, neither proves the field pointer was taken from that parent,
//! and the `@alignCast` adds a runtime check where Zig already proved the alignment as it compiled,
//! so a rule that read one spelling would push code toward the worse one; it is std's own
//! interface idiom (std.Io's readers and writers recovering their state), which glint cannot tell
//! from a misuse; and a
//! `@ptrCast`, with or without the `@alignCast` inside it, from a `*anyopaque` to a pointer to one
//! item, how std.mem.Allocator's `ptr`, std.Io's `userdata` and every hand-written vtable recover
//! their owner. A `@ptrCast` from `*anyopaque` to a slice or a many-item pointer stays a finding.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Governed = @import("Governed.zig");
const Facts = @import("Facts.zig");
const Written = @import("Written.zig");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Rule = @import("Rule.zig").Rule;
const slashed = @import("Rule.zig").slashed;

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
            if (args.len == 2) switch (try namespaceBinding(c, try c.resolveIn(c.file, args[0]))) {
                .binding => |binding| try c.at(rule, token, try c.allocator.print("std.{s}: a raw binding past std's checked layer; only at the package's seam", .{binding})),
                .none => {},
                .unknown => |why| try c.unknownAt(rule, token, why),
            };
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
            if (args.len != 1) continue;
            // The mode is a compile-time value, read as the program fixes it: written (`.optimized`),
            // through a constant holding it, or by its full name (`std.builtin.FloatMode.optimized`).
            if (try c.comptimeValue(c.file, args[0])) |mode| {
                if (mode == .tag and std.mem.eql(u8, mode.tag.name, "optimized"))
                    try c.at(rule, token, "@setFloatMode(.optimized): float results no build checks; only a measured hot loop validated at its boundary");
                continue;
            }
            // Not fixed where it is written: a `comptime` parameter's is the instantiation's to
            // decide; anything else (a build's choice) glint does not read, and says so.
            var root = args[0];
            while (tree.nodeTag(root) == .field_access) root = tree.nodeData(root).node_and_token[0];
            const value = try c.resolveIn(c.file, args[0]);
            try c.unknownAt(rule, token, if (c.comptimeParameter(c.file, root)) .generic else if (value == .unknown) value.unknown else .unsupported);
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
    try externalImports(c, rule);
}

/// An import of a module whose bytes a build step makes (`Project.Input.external`: translate-c's
/// C bindings, a Run step's output): glint reads none of it, so what the program reaches through
/// it, a C function among it, is no site of its own. The import is the one site, which a seam
/// declaration answers. Production code only.
fn externalImports(c: *Context, rule: Rule) Context.Error!void {
    const held = c.project.at(c.file);
    const tree = &held.file.tree;
    for (held.model.import_nodes) |node| {
        const token = tree.nodeMainToken(node);
        if (!std.mem.eql(u8, tree.tokenSlice(token), "@import") or c.inTest(token)) continue;
        const value = try c.imported(c.file, node);
        if (value != .unknown or value.unknown != .external) continue;
        try c.at(rule, token, "an import of a module a build step makes (translate-c's C bindings, a Run step's output), which glint reads none of: only at the package's seam");
    }
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
    var from = try c.resolveIn(c.file, operand);
    if (from == .optional) from = from.optional.*;
    if (from != .pointer or from.pointer.size != .one) return false;
    if (from.pointer.child.* != .primitive or !std.mem.eql(u8, from.pointer.child.primitive, "anyopaque")) return false;
    const made = try c.castType(c.file, node);
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
        if (prefetched(c, tree, node)) continue;
        const value = try c.resolveIn(c.file, operand);
        const size: Facts.Size = if (try slicePointer(c, tree, operand)) .many else switch (value) {
            // A null size is a slicing's (a slice or a pointer to an array, never lengthless), or
            // one only a binding decides: no pass.
            .pointer => |pointer| pointer.size orelse {
                if (!pointer.decided) try c.unknownAt(rule, token, .comptime_dependent);
                continue;
            },
            // An operand whose type is unknown may be a many-item pointer: no pass.
            .unknown => |why| {
                try c.unknownAt(rule, token, why);
                continue;
            },
            else => continue,
        };
        if (size != .many and size != .c) continue;
        try c.at(rule, token, try c.allocator.print("{s} a {s} pointer, which carries no length to check", .{ what, if (size == .many) "many-item" else "C" }));
    }
}

/// Whether the address `node` gives (`p + 16`, or `p[i]`'s by `&p[i]`) is only `@prefetch`'s
/// pointer, past parentheses: a hint to the cache that reads and writes nothing, so no memory is
/// reached through it (warp's hash tables' `@prefetch(&table[h], ...)`).
fn prefetched(c: *Context, tree: *const Ast, node: Ast.Node.Index) bool {
    const model = &c.project.at(c.file).model;
    var at = node;
    var parent = model.parentOf(at) orelse return false;
    while (tree.nodeTag(parent) == .grouped_expression) : (parent = model.parentOf(at) orelse return false) at = parent;
    if (tree.nodeTag(node) == .array_access) {
        if (tree.nodeTag(parent) != .address_of) return false;
        at = parent;
        parent = model.parentOf(at) orelse return false;
        while (tree.nodeTag(parent) == .grouped_expression) : (parent = model.parentOf(at) orelse return false) at = parent;
    } else switch (tree.nodeTag(node)) {
        .add, .sub, .add_wrap, .sub_wrap => {},
        else => return false,
    }
    if (!Facts.isBuiltin(tree, parent, "@prefetch")) return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, parent, &buffer);
    return args.len != 0 and args[0] == at;
}

/// Whether `node` is a slice's `.ptr`, its many-item pointer (`b.ptr + 1`), past parentheses.
fn slicePointer(c: *Context, tree: *const Ast, written: Ast.Node.Index) Context.Error!bool {
    var node = written;
    while (tree.nodeTag(node) == .grouped_expression) node = tree.nodeData(node).node_and_token[0];
    if (tree.nodeTag(node) != .field_access) return false;
    const object, const field = tree.nodeData(node).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(field), "ptr")) return false;
    var value = try c.resolveIn(c.file, object);
    if (value == .pointer and value.pointer.size == .one) value = value.pointer.child.*;
    if (value == .pointer and value.pointer.size == .slice) return true;
    // A name whose declaration writes a slice type (`b: []const u8`), where the value is not read.
    const declared = Written.typeOf(tree, &c.project.at(c.file).model, object) orelse return false;
    const pointer = tree.fullPtrType(declared) orelse return false;
    return pointer.size == .slice;
}

/// std's reinterpretations by name: `mem.bytesAsValue` and `mem.bytesAsSlice`. A reference spelling
/// one that does not resolve is no pass, as under any ban (`Context.unknownAt`).
fn reinterpreted(c: *Context, rule: Rule) Context.Error!void {
    // A std that declares neither has none to reference: silent, as a lookup that finds none is.
    var found: std.ArrayList(Governed.Governed) = .empty;
    for ([_][]const u8{ "mem.bytesAsValue", "mem.bytesAsSlice" }, 0..) |path, i| {
        const decls = switch (try Governed.declarations(c, "std", path)) {
            .decls => |decls| decls,
            .none => continue,
            // A std the run cannot read: the file's first token stands for every site of it.
            .unknown => |why| {
                try c.unknownAt(rule, 0, why);
                continue;
            },
        };
        try found.append(c.allocator, .{ .target = .{ .source = "std", .declaration = path, .production = true }, .index = i, .name = path["mem.".len..], .decls = decls, .symbol = null });
    }
    var sites: std.ArrayList(Governed.Site) = .empty;
    var unread: std.ArrayList(Governed.Unread) = .empty;
    try Governed.sitesLeaving(c, found.items, &sites, &unread);
    for (sites.items) |site| try c.atDefinition(rule, site.token, "a reinterpretation of bytes as another type no build checks", site.decl);
    const tree = &c.project.at(c.file).file.tree;
    for (unread.items) |missed| try c.unknownAt(rule, tree.firstToken(missed.node), missed.why);
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
        switch (try namespaceBinding(c, try c.resolveIn(c.file, tree.nodeData(node).node_and_token[0]))) {
            .binding => |binding| try c.at(rule, member, try c.allocator.print("std.{s}: a raw binding past std's checked layer; only at the package's seam", .{binding})),
            .none => {},
            .unknown => |why| try c.unknownAt(rule, member, why),
        }
    }
}

/// The raw binding a holder is, or any build's choice of it is: a binding's namespace, the file
/// itself (or a file of its directory), never a type it declares, so a constant std's portable
/// layer takes from it (`std.posix.E.AGAIN`) is none. Unknown where the holder is.
const Binding = union(enum) { binding: []const u8, none, unknown: Facts.Unknown };
fn namespaceBinding(c: *Context, value: Facts.Value) Context.Error!Binding {
    for (Facts.valueParts(&value)) |part| switch (part) {
        .container => |container| {
            if (container.scope != c.rootOf(container.file).scope) continue;
            if (try bindingOf(c, container.file)) |binding| return .{ .binding = binding };
        },
        .unknown => |why| return .{ .unknown = why },
        else => {},
    };
    return .none;
}

/// Which raw binding a std file is, if one: `c`, `os.linux` or `os.windows`, or a file of theirs.
fn bindingOf(c: *Context, file: Project.FileId) Context.Error!?[]const u8 {
    if (!try c.standard(file)) return null;
    // std's files are named as the run found them: on Windows with `\` between their parts.
    const name = try slashed(c.allocator, c.project.at(file).input.name);
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
                return !try c.typeIsType(c.file, result);
            },
            else => {
                var buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullContainerDecl(&buffer, parent) != null) return false;
            },
        }
    }
    return false;
}
