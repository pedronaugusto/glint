//! One real comment, the rules it names, one site each and a nonempty written reason:
//! `// glint-ignore: <rule>, ... -- <reason>`, on its site's line or the line before. Every rule
//! takes it, glint's own and those a package declares. A comment in the aegis pack's escape form
//! (`// aegis: ...`) is read no more: it is malformed, and `glint --fix` rewrites it.
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

/// How many rules one suppression may name.
pub const max_named = 8;

pub const ParseError = std.mem.Allocator.Error || error{ MalformedSuppression, AmbiguousSuppression, UnknownRule };

/// A comment that reads as a suppression and is not one, and why: the run that meets it is
/// incomplete, with the comment named, never a run that silently suppresses.
pub const Malformed = struct { comment: File.Comment, why: []const u8 };

/// What an escape in the aegis pack's form is told: the form it is now, and the fix that writes it.
pub const old_escape = "an aegis escape is read no more: `// glint-ignore: <rule>, ... -- <reason>` (glint --fix rewrites it)";

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
    for (file.comments) |comment| switch (try one(a, file, comment, definitions)) {
        .none => {},
        .found => |found| try result.append(a, found),
        .malformed => |why| try malformed.append(a, .{ .comment = comment, .why = why }),
    };
    return result.toOwnedSlice(a);
}

const Outcome = union(enum) { none, found: Suppression, malformed: []const u8 };

fn one(a: std.mem.Allocator, file: *const File, comment: File.Comment, definitions: []const rules.Definition) std.mem.Allocator.Error!Outcome {
    const raw = std.mem.trim(u8, file.source[comment.start + 2 .. comment.end], " \t\r");
    if (std.mem.startsWith(u8, raw, "aegis:")) return .{ .malformed = old_escape };
    if (!std.mem.startsWith(u8, raw, "glint-ignore:")) return .none;
    const rest = std.mem.trim(u8, raw["glint-ignore:".len..], " \t");
    const listed, const why = std.mem.cut(u8, rest, " -- ") orelse return .{ .malformed = "a suppression is `// glint-ignore: <rule>, ... -- <reason>`" };
    var found: Suppression = .{ .line = comment.line, .comment = comment, .reason = std.mem.trim(u8, why, " \t") };
    var listed_names = std.mem.tokenizeAny(u8, listed, ", \t");
    while (listed_names.next()) |id| {
        const rule = rules.parseConfigured(id, definitions) orelse {
            // One 0.8 removed: what to write instead, as a configuration naming it is told.
            const gone = rules.removed(id) orelse return .{ .malformed = "a suppression names a rule glint does not have" };
            var text: std.Io.Writer.Allocating = .init(a);
            text.writer.writeAll("a suppression names a rule glint does not have: ") catch return error.OutOfMemory;
            gone.write(&text.writer) catch return error.OutOfMemory;
            return .{ .malformed = text.written() };
        };
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

test "a suppression naming a rule 0.8 removed is told what to write instead" {
    var file = try File.init(std.testing.allocator, "const x = 1; // glint-ignore: A010 -- gone\nconst y = 1; // glint-ignore: Z999 -- never\n", .{});
    defer file.deinit();
    var malformed: std.ArrayList(Malformed) = .empty;
    _ = try parseConfigured(file.arena.allocator(), &file, &.{}, &malformed);
    try std.testing.expectEqual(@as(usize, 2), malformed.items.len);
    try std.testing.expectEqualStrings("a suppression names a rule glint does not have: `A010` was removed in glint 0.8: remove it", malformed.items[0].why);
    try std.testing.expectEqualStrings("a suppression names a rule glint does not have", malformed.items[1].why);
}

test "suppression requires exact ID and reason from a real comment" {
    var file = try File.init(std.testing.allocator, "// glint-ignore: Z013 -- public fixture below\nconst unused = @import(\"unused\");\n", .{});
    defer file.deinit();
    const parsed = try parse(file.arena.allocator(), &file);
    try std.testing.expectEqual(@as(usize, 1), parsed.len); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expect(try parsed[0].matches(.Z013, 1, 6));
    try std.testing.expect(!try parsed[0].matches(.Z003, 1, 6));
    var invalid = try File.init(std.testing.allocator, "// glint-ignore: Z013\nconst x = 1;", .{});
    defer invalid.deinit();
    try std.testing.expectError(error.MalformedSuppression, parse(invalid.arena.allocator(), &invalid));
}

test "suppression one reason cannot suppress distinct sites on one line" {
    var file = try File.init(std.testing.allocator, "const a = @import(\"a\"); const b = @import(\"b\"); // glint-ignore: Z013 -- one justified site\n", .{});
    defer file.deinit();
    const parsed = try parse(file.arena.allocator(), &file);
    try std.testing.expect(try parsed[0].matches(.Z013, 0, 6));
    try std.testing.expectError(error.AmbiguousSuppression, parsed[0].matches(.Z013, 0, 31));
}

test "a suppression names several rules, one site each; the aegis escape form is malformed" {
    var file = try File.init(std.testing.allocator, "const x = 1; // glint-ignore: Z013, Z003 -- both read here\n", .{});
    defer file.deinit();
    const parsed = try parse(file.arena.allocator(), &file);
    try std.testing.expect(try parsed[0].matches(.Z013, 0, 6));
    try std.testing.expect(try parsed[0].matches(.Z003, 0, 9));
    try std.testing.expect(!try parsed[0].matches(.Z011, 0, 6));
    for ([_][]const u8{ "const x = 1; // aegis: boundary(Z003): the C call\n", "const x = 1; // aegis: boundary: the C call\n", "const x = 1; // glint-ignore: Z013, Z013 -- twice\n", "const x = 1; // glint-ignore: -- none\n" }) |bytes| {
        var bad = try File.init(std.testing.allocator, bytes, .{});
        defer bad.deinit();
        try std.testing.expectError(error.MalformedSuppression, parse(bad.arena.allocator(), &bad));
    }
}
