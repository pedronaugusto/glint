//! One real comment, one exact rule, one site and a nonempty written reason.
const std = @import("std");
const File = @import("File.zig");
const rules = @import("Rule.zig");
const Suppression = @This();

rule: rules.Rule,
line: u32,
comment: File.Comment,
reason: []const u8,
used: bool = false,

pub const ParseError = std.mem.Allocator.Error || error{ MalformedSuppression, UnknownRule };

pub fn parse(a: std.mem.Allocator, file: *const File) ParseError![]Suppression {
    var result: std.ArrayList(Suppression) = .empty;
    for (file.comments) |comment| {
        const raw = std.mem.trim(u8, file.source[comment.start + 2 .. comment.end], " \t");
        if (!std.mem.startsWith(u8, raw, "glint-ignore:")) continue;
        const rest = std.mem.trim(u8, raw[13..], " \t");
        const separator = std.mem.find(u8, rest, " -- ") orelse return error.MalformedSuppression;
        const id = std.mem.trim(u8, rest[0..separator], " \t");
        const rule = rules.Rule.parse(id) orelse return error.UnknownRule;
        const reason = std.mem.trim(u8, rest[separator + 4 ..], " \t");
        if (reason.len == 0) return error.MalformedSuppression;
        const before = std.mem.trim(u8, file.source[file.lines[comment.line]..comment.start], " \t\r");
        var site = comment.line;
        if (before.len == 0) {
            var token: usize = 0;
            while (token < file.tree.tokens.len and file.tree.tokenStart(@intCast(token)) < comment.end) token += 1;
            if (token == file.tree.tokens.len or file.tree.tokenTag(@intCast(token)) == .eof) return error.MalformedSuppression;
            site = file.line(file.tree.tokenStart(@intCast(token)));
            if (site > comment.line + 1) return error.MalformedSuppression;
        }
        try result.append(a, .{ .rule = rule, .line = site, .comment = comment, .reason = reason });
    }
    return result.toOwnedSlice(a);
}

pub fn matches(self: *Suppression, rule: rules.Rule, line: u32) bool {
    if (self.rule != rule or self.line != line) return false;
    self.used = true;
    return true;
}

test "suppression requires exact ID and reason from a real comment" {
    var file = try File.init(std.testing.allocator, "// glint-ignore: Z013 -- public fixture below\nconst unused = @import(\"unused\");\n", .{});
    defer file.deinit();
    const parsed = try parse(file.arena.allocator(), &file);
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expect(parsed[0].matches(.Z013, 1));
    try std.testing.expect(!parsed[0].matches(.Z003, 1));
    var invalid = try File.init(std.testing.allocator, "// glint-ignore: Z013\nconst x = 1;", .{});
    defer invalid.deinit();
    try std.testing.expectError(error.MalformedSuppression, parse(invalid.arena.allocator(), &invalid));
}
