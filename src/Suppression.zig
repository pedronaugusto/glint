//! One real comment, the rules it names, one site each and a nonempty written reason, in the
//! form `form` spells, on its site's line or the line before. Every rule
//! takes it, glint's own and those a package declares.
const std = @import("std");
const File = @import("File.zig");
const rules = @import("Rule.zig");
const Suppression = @This();

/// The rules it names, in order, each with the start of the one site it suppresses.
named: [max_named]rules.Rule = undefined,
matched: [max_named]?u32 = @splat(null),
named_len: u8 = 0,
line: u32,
comment: File.Comment,
reason: []const u8,
used: bool = false,
/// Met a second site of a rule it names on its line (`matches`): malformed, reported once.
ambiguous: bool = false,

/// The word a suppression opens with: the tool's name and `-ignore`. Written in two parts, so a
/// search of a tree for suppressions finds the real ones alone; everything that writes or reads
/// one takes it from here.
pub const keyword = "glint" ++ "-ignore";
/// What a suppression's comment opens with, the rules it names following it.
pub const opening = "// " ++ keyword ++ ": ";
/// A suppression's whole form, as messages show it.
pub const form = opening ++ "<rule>, ... -- <reason>";

/// How many rules one suppression may name.
pub const max_named = 8;

pub const ParseError = std.mem.Allocator.Error || error{ MalformedSuppression, AmbiguousSuppression, UnknownRule };

/// A comment that reads as a suppression and is not one, and why: the run that meets it is
/// incomplete, with the comment named, never a run that silently suppresses.
pub const Malformed = struct { comment: File.Comment, why: []const u8 };

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
    const head = keyword ++ ":";
    if (!std.mem.startsWith(u8, raw, head)) return .none;
    const rest = std.mem.trim(u8, raw[head.len..], " \t");
    const listed, const why = std.mem.cut(u8, rest, " -- ") orelse return .{ .malformed = "a suppression is `" ++ form ++ "`" };
    var found: Suppression = .{ .line = comment.line, .comment = comment, .reason = std.mem.trim(u8, why, " \t") };
    var listed_names = std.mem.tokenizeAny(u8, listed, ", \t");
    while (listed_names.next()) |id| {
        const rule = rules.parseConfigured(id, definitions) orelse return .{ .malformed = "a suppression names a rule glint does not have" };
        for (0..found.named_len) |i| if (found.named[i] == rule) return .{ .malformed = "a suppression names each rule once" };
        if (found.named_len == max_named) return .{ .malformed = "a suppression names at most eight rules" };
        found.named[found.named_len] = rule;
        found.named_len += 1;
    }
    if (found.named_len == 0) return .{ .malformed = "a suppression names the rules it suppresses" };
    if (found.reason.len == 0) return .{ .malformed = "a suppression needs its written reason" };
    const before = std.mem.trim(u8, file.source[file.lines[comment.line]..comment.start], " \t\r");
    if (before.len == 0) {
        var token: usize = 0;
        while (token < file.tree.tokens.len and file.tree.tokenStart(@intCast(token)) < comment.end) token += 1;
        if (token == file.tree.tokens.len or file.tree.tokenTag(@intCast(token)) == .eof) return .{ .malformed = "a suppression stands before no code" };
        found.line = file.line(file.tree.tokenStart(@intCast(token)));
        if (found.line > comment.line + 1) return .{ .malformed = "a suppression on a line of its own stands on the line before its site" };
    }
    return .{ .found = found };
}

/// The rules it names.
pub fn names(self: *const Suppression) []const rules.Rule {
    return self.named[0..self.named_len];
}

/// Whether this suppresses `rule`'s finding at `start` on `line`: one site of each rule it names;
/// a second site of the same rule on the line is ambiguous.
pub fn matches(self: *Suppression, rule: rules.Rule, line: u32, start: u32) error{AmbiguousSuppression}!bool {
    if (!self.applies(rule, line)) return false;
    const at = std.mem.findScalar(rules.Rule, self.names(), rule).?;
    if (self.matched[at]) |previous| if (previous != start) return error.AmbiguousSuppression;
    self.matched[at] = start;
    self.used = true;
    return true;
}

/// Whether this covers a finding of `rule` on `line` (`matches`), asked without using it.
pub fn applies(self: *const Suppression, rule: rules.Rule, line: u32) bool {
    return self.line == line and std.mem.findScalar(rules.Rule, self.names(), rule) != null;
}

test "a suppression naming a rule glint does not have is malformed, whatever the id" {
    var file = try File.init(std.testing.allocator, "const x = 1; " ++ opening ++ "A010 -- gone\nconst y = 1; " ++ opening ++ "Z999 -- never\n", .{});
    defer file.deinit();
    var malformed: std.ArrayList(Malformed) = .empty;
    _ = try parseConfigured(file.arena.allocator(), &file, &.{}, &malformed);
    try std.testing.expectEqual(@as(usize, 2), malformed.items.len);
    try std.testing.expectEqualStrings("a suppression names a rule glint does not have", malformed.items[0].why);
    try std.testing.expectEqualStrings("a suppression names a rule glint does not have", malformed.items[1].why);
}

test "suppression requires exact ID and reason from a real comment" {
    var file = try File.init(std.testing.allocator, opening ++ "Z013 -- public fixture below\nconst unused = @import(\"unused\");\n", .{});
    defer file.deinit();
    var malformed: std.ArrayList(Malformed) = .empty;
    const parsed = try parseConfigured(file.arena.allocator(), &file, &.{}, &malformed);
    try std.testing.expectEqual(@as(usize, 0), malformed.items.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.len); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expect(try parsed[0].matches(.Z013, 1, 6));
    try std.testing.expect(!try parsed[0].matches(.Z003, 1, 6));
    var invalid = try File.init(std.testing.allocator, opening ++ "Z013\nconst x = 1;", .{});
    defer invalid.deinit();
    var invalid_malformed: std.ArrayList(Malformed) = .empty;
    _ = try parseConfigured(invalid.arena.allocator(), &invalid, &.{}, &invalid_malformed);
    try std.testing.expectEqual(@as(usize, 1), invalid_malformed.items.len);
}

test "suppression one reason cannot suppress distinct sites on one line" {
    var file = try File.init(std.testing.allocator, "const a = @import(\"a\"); const b = @import(\"b\"); " ++ opening ++ "Z013 -- one justified site\n", .{});
    defer file.deinit();
    var malformed: std.ArrayList(Malformed) = .empty;
    const parsed = try parseConfigured(file.arena.allocator(), &file, &.{}, &malformed);
    try std.testing.expectEqual(@as(usize, 0), malformed.items.len);
    try std.testing.expect(try parsed[0].matches(.Z013, 0, 6));
    try std.testing.expectError(error.AmbiguousSuppression, parsed[0].matches(.Z013, 0, 31));
}

test "a suppression names several rules, one site each; the aegis escape form is malformed" {
    var file = try File.init(std.testing.allocator, "const x = 1; " ++ opening ++ "Z013, Z003 -- both read here\n", .{});
    defer file.deinit();
    var malformed: std.ArrayList(Malformed) = .empty;
    const parsed = try parseConfigured(file.arena.allocator(), &file, &.{}, &malformed);
    try std.testing.expectEqual(@as(usize, 0), malformed.items.len);
    try std.testing.expect(try parsed[0].matches(.Z013, 0, 6));
    try std.testing.expect(try parsed[0].matches(.Z003, 0, 9));
    try std.testing.expect(!try parsed[0].matches(.Z011, 0, 6));
    for ([_][]const u8{ "const x = 1; " ++ opening ++ "Z013, Z013 -- twice\n", "const x = 1; " ++ opening ++ "-- none\n" }) |bytes| {
        var bad = try File.init(std.testing.allocator, bytes, .{});
        defer bad.deinit();
        var bad_malformed: std.ArrayList(Malformed) = .empty;
        _ = try parseConfigured(bad.arena.allocator(), &bad, &.{}, &bad_malformed);
        try std.testing.expectEqual(@as(usize, 1), bad_malformed.items.len);
    }
}
