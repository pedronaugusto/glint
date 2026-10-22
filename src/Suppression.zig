//! One real comment, one exact rule, one site and a nonempty written reason; or, for the aegis
//! pack, the one escape `// aegis: <reason>: <why>`, which covers every pack finding on its site's
//! line and names one of the five reasons a raw site may have.
const std = @import("std");
const File = @import("File.zig");
const rules = @import("Rule.zig");
const Suppression = @This();

/// The rule a `glint-ignore` names; null for an aegis escape, which names none.
rule: ?rules.Rule,
line: u32,
comment: File.Comment,
reason: []const u8,
/// An aegis escape's reason; null for a `glint-ignore`.
escape: ?Reason = null,
used: bool = false,
matched_start: ?u32 = null,

/// Why a raw site stands where an aegis type is the answer (designs/aegis.md §7): the danger
/// does not exist there, a design removes the class, a measured hot loop validated once at
/// its boundary, the inside of a safe type, or a C or OS call.
pub const Reason = enum {
    @"no-danger",
    design,
    @"hot-loop",
    internal,
    boundary,
};

pub const ParseError = std.mem.Allocator.Error || error{ MalformedSuppression, AmbiguousSuppression, UnknownRule };

/// A comment that reads as a suppression or an escape and is not one, and why: the run that
/// meets it is incomplete, with the comment named, never a run that silently suppresses.
pub const Malformed = struct { comment: File.Comment, why: []const u8 };

/// The file's suppressions; a malformed one is an error.
pub fn parse(a: std.mem.Allocator, file: *const File) ParseError![]Suppression {
    var malformed: std.ArrayList(Malformed) = .empty;
    const found = try parseConfigured(a, file, &.{}, &malformed);
    if (malformed.items.len != 0) return error.MalformedSuppression;
    return found;
}

/// The file's suppressions, each malformed one appended to `malformed` instead.
pub fn parseConfigured(a: std.mem.Allocator, file: *const File, definitions: []const rules.Definition, malformed: *std.ArrayList(Malformed)) std.mem.Allocator.Error![]Suppression {
    var result: std.ArrayList(Suppression) = .empty;
    for (file.comments) |comment| switch (one(file, comment, definitions)) {
        .none => {},
        .found => |found| try result.append(a, found),
        .malformed => |why| try malformed.append(a, .{ .comment = comment, .why = why }),
    };
    return result.toOwnedSlice(a);
}

const Outcome = union(enum) { none, found: Suppression, malformed: []const u8 };

fn one(file: *const File, comment: File.Comment, definitions: []const rules.Definition) Outcome {
    const raw = std.mem.trim(u8, file.source[comment.start + 2 .. comment.end], " \t\r");
    var rule: ?rules.Rule = null;
    var escape: ?Reason = null;
    var reason: []const u8 = undefined;
    if (std.mem.startsWith(u8, raw, "aegis:")) {
        const rest = std.mem.trim(u8, raw["aegis:".len..], " \t");
        const colon = std.mem.findScalar(u8, rest, ':') orelse return .{ .malformed = "an aegis escape is `// aegis: <reason>: <why>`" };
        escape = std.meta.stringToEnum(Reason, std.mem.trim(u8, rest[0..colon], " \t")) orelse return .{ .malformed = "an aegis escape's reason is no-danger, design, hot-loop, internal or boundary" };
        reason = std.mem.trim(u8, rest[colon + 1 ..], " \t");
    } else if (std.mem.startsWith(u8, raw, "glint-ignore:")) {
        const rest = std.mem.trim(u8, raw[13..], " \t");
        const separator = std.mem.find(u8, rest, " -- ") orelse return .{ .malformed = "a suppression is `// glint-ignore: <rule> -- <reason>`" };
        const id = std.mem.trim(u8, rest[0..separator], " \t");
        rule = rules.parseConfigured(id, definitions) orelse return .{ .malformed = "a suppression names a rule glint does not have" };
        // The pack has one escape, which says why the danger is absent: never a bare reason.
        if (rules.definition(rule.?, definitions).?.exception == .aegis) return .{ .malformed = "an aegis rule takes `// aegis: <reason>: <why>`, never glint-ignore" };
        reason = std.mem.trim(u8, rest[separator + 4 ..], " \t");
    } else return .none;
    if (reason.len == 0) return .{ .malformed = "a suppression or escape needs its written reason" };
    const before = std.mem.trim(u8, file.source[file.lines[comment.line]..comment.start], " \t\r");
    var site = comment.line;
    if (before.len == 0) {
        var token: usize = 0;
        while (token < file.tree.tokens.len and file.tree.tokenStart(@intCast(token)) < comment.end) token += 1;
        if (token == file.tree.tokens.len or file.tree.tokenTag(@intCast(token)) == .eof) return .{ .malformed = "a suppression or escape stands before no code" };
        site = file.line(file.tree.tokenStart(@intCast(token)));
        if (site > comment.line + 1) return .{ .malformed = "a suppression or escape on a line of its own stands on the line before its site" };
    }
    return .{ .found = .{ .rule = rule, .line = site, .comment = comment, .reason = reason, .escape = escape } };
}

/// Whether this suppresses `rule`'s finding at `start` on `line`. An escape covers every finding
/// of an aegis rule (`aegis`) on its line; a `glint-ignore` one site of its rule.
pub fn matches(self: *Suppression, rule: rules.Rule, aegis: bool, line: u32, start: u32) error{AmbiguousSuppression}!bool {
    if (self.line != line) return false;
    if (self.escape != null) {
        if (!aegis) return false;
        self.used = true;
        return true;
    }
    if (self.rule != rule) return false;
    if (self.matched_start) |previous| if (previous != start) return error.AmbiguousSuppression;
    self.matched_start = start;
    self.used = true;
    return true;
}

test "suppression requires exact ID and reason from a real comment" {
    var file = try File.init(std.testing.allocator, "// glint-ignore: Z013 -- public fixture below\nconst unused = @import(\"unused\");\n", .{});
    defer file.deinit();
    const parsed = try parse(file.arena.allocator(), &file);
    try std.testing.expectEqual(@as(usize, 1), parsed.len); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expect(try parsed[0].matches(.Z013, false, 1, 6));
    try std.testing.expect(!try parsed[0].matches(.Z003, false, 1, 6));
    var invalid = try File.init(std.testing.allocator, "// glint-ignore: Z013\nconst x = 1;", .{});
    defer invalid.deinit();
    try std.testing.expectError(error.MalformedSuppression, parse(invalid.arena.allocator(), &invalid));
}

test "suppression one reason cannot suppress distinct sites on one line" {
    var file = try File.init(std.testing.allocator, "const a = @import(\"a\"); const b = @import(\"b\"); // glint-ignore: Z013 -- one justified site\n", .{});
    defer file.deinit();
    const parsed = try parse(file.arena.allocator(), &file);
    try std.testing.expect(try parsed[0].matches(.Z013, false, 0, 6));
    try std.testing.expectError(error.AmbiguousSuppression, parsed[0].matches(.Z013, false, 0, 31));
}

test "an aegis escape names one of five reasons and a why, and covers the pack's findings on its line" {
    var file = try File.init(std.testing.allocator, "const x = 1; // aegis: boundary: the C call takes the raw pointer\n", .{});
    defer file.deinit();
    const parsed = try parse(file.arena.allocator(), &file);
    try std.testing.expectEqual(Reason.boundary, parsed[0].escape.?);
    try std.testing.expect(try parsed[0].matches(.Z013, true, 0, 6));
    try std.testing.expect(try parsed[0].matches(.Z003, true, 0, 9));
    try std.testing.expect(!try parsed[0].matches(.Z013, false, 0, 6));
    for ([_][]const u8{ "const x = 1; // aegis: measured: fast\n", "const x = 1; // aegis: design:\n", "const x = 1; // aegis: design\n" }) |bytes| {
        var bad = try File.init(std.testing.allocator, bytes, .{});
        defer bad.deinit();
        try std.testing.expectError(error.MalformedSuppression, parse(bad.arena.allocator(), &bad));
    }
}
