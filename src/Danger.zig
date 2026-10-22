//! The aegis pack's danger rules whose predicates need no flow fact (designs/aegis.md §7): each
//! finds the sites where a danger exists and aegis's type is the answer, from what the code
//! resolves to, never from a name it merely spells. A site that stands raw carries the pack's
//! escape, `// aegis: <reason>: <why>`; one the rule cannot decide is undecided.
//!
//! Every rule reads production code only: test inputs and test blocks are not shipped. An
//! operation the program runs only as it compiles (in a `comptime` block, a function returning
//! `type`, a container-level declaration's value or a field's default) has none of these
//! dangers; a type a field or variable is declared with is the program's state at run time
//! wherever it is written.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Governed = @import("Governed.zig");
const Escapes = @import("Escapes.zig");
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");
const Contract = @import("AegisContract.zig");
const Rule = @import("Rule.zig").Rule;
const Ast = std.zig.Ast;

/// A007: shared state outside aegis's guards.
pub fn sharedState(c: *Context, rule: Rule) Context.Error!void {
    const sync = [_][]const u8{ "Io.Mutex", "Io.RwLock", "Io.Condition", "Io.Semaphore", "Io.Event", "atomic.Value", "atomic.Mutex" };
    try governed(c, rule, &sync, false, "{s}: raw synchronization; aegis Guarded, BlockingGuarded, RwGuarded, SpinRwGuarded, Condition, Atomic, Once or Lazy holds the data it guards");
    const tree = &c.project.files[c.file.raw()].tree;
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: the AST's node table indexes fit u32
        const name = builtinName(tree, node) orelse continue;
        for ([_][]const u8{ "@atomicLoad", "@atomicStore", "@atomicRmw", "@cmpxchgWeak", "@cmpxchgStrong" }) |atomic| if (std.mem.eql(u8, name, atomic)) {
            if (!c.inTest(tree.nodeMainToken(node)) and atRuntime(c, node)) try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("{s}: a raw atomic; aegis Atomic holds the cell", .{name}));
        };
    }
    const model = &c.project.models[c.file.raw()];
    for (model.declarations) |decl| {
        if (decl.kind != .variable) continue;
        const scope = model.scopes[decl.scope].kind;
        if (scope != .file and scope != .container) continue;
        const variable = tree.fullVarDecl(decl.node) orelse continue;
        if (tree.tokenTag(variable.ast.mut_token) != .keyword_var or variable.threadlocal_token != null) continue;
        // An `extern var` is the unsafe set's (A019): its storage is another program's.
        if (variable.extern_export_token) |token| if (tree.tokenTag(token) == .keyword_extern) continue;
        if (c.inTest(decl.token)) continue;
        try c.at(rule, decl.token, try c.allocator.print("container-level var '{s}': mutable state any thread may reach; aegis Guarded, Atomic, Once or Lazy holds it, or Confined checks its one owner", .{decl.name}));
    }
}

/// A008: secret material outside aegis's Secret and Choice.
pub fn secrets(c: *Context, rule: Rule) Context.Error!void {
    const calls = [_][]const u8{ "crypto.secureZero", "crypto.timing_safe.eql", "crypto.timing_safe.compare" };
    try governed(c, rule, &calls, true, "{s}: secret material handled by hand; aegis Secret and SecretBytes wipe it, Choice compares in constant time");
    const keys = try secretKeys(c);
    if (keys.len == 0) return;
    const tree = &c.project.files[c.file.raw()].tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: the AST's node table indexes fit u32
        const site = switch (tag) {
            .identifier => tree.nodeMainToken(node),
            .field_access => tree.nodeData(node).node_and_token[1],
            else => continue,
        };
        const spelled = tree.tokenSlice(site);
        if (!std.mem.eql(u8, spelled, "SecretKey") and !std.mem.eql(u8, spelled, "KeyPair")) continue;
        if (c.inTest(site)) continue;
        const decl = (try c.facts.definition(c.file, node)) orelse continue;
        const origin = (try c.facts.origin(decl)) orelse decl;
        var secret = false;
        for (keys) |key| secret = secret or std.meta.eql(key, decl) or std.meta.eql(key, origin);
        if (!secret or !std.meta.eql(decl, origin) and c.project.inputs[decl.file.raw()].selected) continue;
        if (try borrowedOrSealed(c, node)) continue;
        try c.at(rule, site, try c.allocator.print("std.crypto {s} held by value outside aegis Secret: its bytes are copied and never wiped", .{spelled}));
    }
}

/// The declarations of std's secret-key and key-pair types: those named `SecretKey` or
/// `KeyPair` in the files std's `crypto` namespace reaches through its own relative imports.
fn secretKeys(c: *Context) Context.Error![]const Facts.Decl {
    var roots: std.ArrayList(Project.FileId) = .empty;
    for (c.project.imports) |mapping| if (std.mem.eql(u8, mapping.spelling, "std")) {
        for (roots.items) |seen| {
            if (seen.eql(mapping.target)) break;
        } else try roots.append(c.allocator, mapping.target);
    };
    var files: std.ArrayList(Project.FileId) = .empty;
    for (roots.items) |root| {
        const crypto = c.facts.member(.{ .file = root, .scope = 0 }, "crypto") orelse continue;
        const value = try c.facts.declaration((try c.facts.origin(crypto)) orelse crypto);
        if (value != .container) continue;
        try files.append(c.allocator, value.container.file);
    }
    var next: usize = 0;
    while (next < files.items.len) : (next += 1) {
        const file = files.items[next];
        for (c.project.imports) |mapping| {
            if (!mapping.from.eql(file) or !std.mem.endsWith(u8, mapping.spelling, ".zig")) continue;
            for (files.items) |seen| {
                if (seen.eql(mapping.target)) break;
            } else try files.append(c.allocator, mapping.target);
        }
    }
    var keys: std.ArrayList(Facts.Decl) = .empty;
    for (files.items) |file| for (c.project.models[file.raw()].declarations, 0..) |decl, d| {
        if (decl.kind != .variable or !decl.public) continue;
        if (!std.mem.eql(u8, decl.name, "SecretKey") and !std.mem.eql(u8, decl.name, "KeyPair")) continue;
        try keys.append(c.allocator, .{ .file = file, .index = @intCast(d) }); // safe: a file's declaration table indexes fit u32
    };
    return keys.items;
}

/// Whether a reference to a secret-key type stands behind a pointer (a borrow) or inside an
/// aegis `Secret` or `SecretBytes` instantiation (sealed), up to the declaration it is part of.
fn borrowedOrSealed(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) { // safe: a node index indexes its own tree's parent table
        switch (tree.nodeTag(parent)) {
            .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => return true,
            .fn_decl, .block, .block_semicolon, .block_two, .block_two_semicolon => return false,
            else => {},
        }
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buffer, parent)) |call| if (call.ast.fn_expr != at) {
            const kind = try c.role(Contract.library, try c.facts.resolve(c.file, call.ast.fn_expr));
            if (kind == .secret or kind == .bytes) return true;
        };
        if (tree.fullVarDecl(parent) != null or tree.fullContainerField(parent) != null) return false;
    }
    return false;
}

/// A011: time crossing to and from std as a raw integer.
pub fn units(c: *Context, rule: Rule) Context.Error!void {
    const doors = [_][]const u8{
        "Io.Duration.fromNanoseconds", "Io.Duration.fromMicroseconds", "Io.Duration.fromMilliseconds", "Io.Duration.fromSeconds",
        "Io.Duration.toNanoseconds",   "Io.Duration.toMicroseconds",   "Io.Duration.toMilliseconds",   "Io.Duration.toSeconds",
        "Io.Duration.nanoseconds",     "Io.Timestamp.fromNanoseconds", "Io.Timestamp.toNanoseconds",   "Io.Timestamp.toMicroseconds",
        "Io.Timestamp.toMilliseconds", "Io.Timestamp.toSeconds",       "Io.Timestamp.nanoseconds",
    };
    try governed(c, rule, &doors, true, "{s}: time as a raw integer; aegis units.Duration and Instant carry the unit and convert with toIoDuration and fromIoDuration");
    const constants = [_][]const u8{
        "time.ns_per_us",  "time.ns_per_ms",   "time.ns_per_s",   "time.ns_per_min",  "time.ns_per_hour", "time.ns_per_day",  "time.ns_per_week",
        "time.us_per_ms",  "time.us_per_s",    "time.us_per_min", "time.us_per_hour", "time.us_per_day",  "time.us_per_week", "time.ms_per_s",
        "time.ms_per_min", "time.ms_per_hour", "time.ms_per_day", "time.ms_per_week", "time.s_per_min",   "time.s_per_hour",  "time.s_per_day",
        "time.s_per_week",
    };
    var targets: [constants.len]Governed.Target = undefined;
    var indexes: [constants.len]usize = undefined;
    for (constants, &targets, &indexes, 0..) |path, *target, *index, i| {
        target.* = .{ .source = "std", .declaration = path, .production = true };
        index.* = i;
    }
    const found = try Governed.resolve(c, rule, &targets, &indexes);
    var sites: std.ArrayList(Governed.Site) = .empty;
    try Governed.sites(c, rule, found, &sites);
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    for (sites.items) |site| {
        if (site.through_alias or c.inTest(site.token) or !atRuntime(c, site.node)) continue;
        const parent = model.node_parents[@backingInt(site.node)] orelse continue; // safe: a node index indexes its own tree's parent table
        if (!arithmetic(tree.nodeTag(parent))) continue;
        try c.at(rule, site.token, try c.allocator.print("std.{s} in arithmetic: a unit converted by hand; aegis units.Duration converts between units and checks the result", .{constants[site.index]}));
    }
}

/// A013: contracts that are undefined behaviour when false in a release build.
pub fn contracts(c: *Context, rule: Rule) Context.Error!void {
    const assert = [_][]const u8{"debug.assert"};
    try governed(c, rule, &assert, true, "std.{s}: a contract a ReleaseFast build assumes true; aegis assert.invariant, pre or post checks it in every build, assert.debug states a debug-only one");
    const tree = &c.project.files[c.file.raw()].tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .unreachable_literal) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: the AST's node table indexes fit u32
        const token = tree.nodeMainToken(node);
        if (c.inTest(token) or !atRuntime(c, node)) continue;
        try c.at(rule, token, "unreachable: undefined behaviour in ReleaseFast when reached; aegis assert.never stops in every build, or return an error");
    }
}

/// A010's casts: every integer conversion that can fail or lose bits. The flow fact adds the
/// arithmetic on input (Taint.zig).
pub fn casts(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.files[c.file.raw()].tree;
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: the AST's node table indexes fit u32
        const name = builtinName(tree, node) orelse continue;
        var fallible = false;
        for ([_][]const u8{ "@intCast", "@truncate", "@intFromFloat", "@enumFromInt", "@fromBackingInt" }) |cast| fallible = fallible or std.mem.eql(u8, name, cast);
        if (!fallible) continue;
        const token = tree.nodeMainToken(node);
        if (c.inTest(token) or !atRuntime(c, node)) continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        // A literal is converted as the program compiles, which refuses one that does not fit.
        if (args.len == 1 and (tree.nodeTag(args[0]) == .number_literal or tree.nodeTag(args[0]) == .char_literal)) continue;
        try c.at(rule, token, try c.allocator.print("{s}: a conversion that is undefined behaviour in ReleaseFast when the value does not fit, or loses bits; aegis int.cast, Checked or Ranged convert with a checked result", .{name}));
    }
}

/// A019: the operations Zig leaves unchecked.
pub fn unsafeSet(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.files[c.file.raw()].tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: the AST's node table indexes fit u32
        const token = tree.nodeMainToken(node);
        switch (tag) {
            .asm_simple, .@"asm" => {
                if (!c.inTest(token) and atRuntime(c, node)) try c.at(rule, token, "inline assembly: no check of what it reads or writes; keep it behind the package's one seam with its reason");
                continue;
            },
            else => {},
        }
        const name = builtinName(tree, node) orelse continue;
        if (c.inTest(token) or !atRuntime(c, node)) continue;
        if (std.mem.eql(u8, name, "@setRuntimeSafety")) {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 1) continue;
            const literal = if (tree.nodeTag(args[0]) == .identifier) tree.tokenSlice(tree.nodeMainToken(args[0])) else "";
            if (std.mem.eql(u8, literal, "false")) {
                try c.at(rule, token, "@setRuntimeSafety(false): bounds, overflow and union checks off; only a measured hot loop validated at its boundary");
            } else if (!std.mem.eql(u8, literal, "true")) try c.unknown(rule, node, .comptime_dependent);
            continue;
        }
        for ([_][]const u8{ "@ptrCast", "@alignCast", "@constCast", "@volatileCast", "@ptrFromInt", "@intFromPtr" }) |cast| if (std.mem.eql(u8, name, cast)) {
            try c.at(rule, token, try c.allocator.print("{s}: a pointer conversion no build checks", .{name}));
        };
    }
    const model = &c.project.models[c.file.raw()];
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
}

/// A014's frame escapes (Escapes.zig).
pub fn lifetimes(c: *Context, rule: Rule) Context.Error!void {
    try Escapes.check(c, rule);
}

/// Each site in production code that reaches one of std's `paths`, past an alias the program
/// declares (its value is the site), reported with `message` naming the path. An operation
/// (`operation`: a call, a conversion) is a site only where it runs with the program; a type is
/// the program's state wherever it is named.
fn governed(c: *Context, rule: Rule, paths: []const []const u8, operation: bool, comptime message: []const u8) Context.Error!void {
    const targets = try c.allocator.alloc(Governed.Target, paths.len);
    const indexes = try c.allocator.alloc(usize, paths.len);
    for (paths, targets, indexes, 0..) |path, *target, *index, i| {
        target.* = .{ .source = "std", .declaration = path, .production = true };
        index.* = i;
    }
    const found = try Governed.resolve(c, rule, targets, indexes);
    var sites: std.ArrayList(Governed.Site) = .empty;
    try Governed.sites(c, rule, found, &sites);
    for (sites.items) |site| {
        if (site.through_alias or c.inTest(site.token)) continue;
        if (operation and !atRuntime(c, site.node)) continue;
        try c.at(rule, site.token, try c.allocator.print(message, .{paths[site.index]}));
    }
}

/// Whether the code at `node` runs when the program runs: inside a function's body that does
/// not return `type`, outside any `comptime` block and any container's declarations nested
/// there. A container-level value or a field's default is evaluated as the program compiles.
pub fn atRuntime(c: *const Context, node: Ast.Node.Index) bool {
    const tree = &c.project.files[c.file.raw()].tree;
    const model = &c.project.models[c.file.raw()];
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) { // safe: a node index indexes its own tree's parent table
        switch (tree.nodeTag(parent)) {
            .@"comptime" => return false,
            .test_decl => return true,
            .fn_decl => {
                var buffer: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buffer, tree.nodeData(parent).node_and_node[0]) orelse return true;
                const result = proto.ast.return_type.unwrap() orelse return true;
                return !(tree.nodeTag(result) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(result)), "type"));
            },
            else => {
                var buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullContainerDecl(&buffer, parent) != null) return false;
            },
        }
    }
    return false;
}

fn builtinName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => tree.tokenSlice(tree.nodeMainToken(node)),
        else => null,
    };
}

fn arithmetic(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .add, .sub, .mul, .div, .mod, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod => true,
        else => false,
    };
}
