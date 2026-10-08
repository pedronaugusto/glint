//! Owned immutable front-end input. AST spans supplement, never replace, std ZIR.
const std = @import("std");
const File = @This();

arena: std.heap.ArenaAllocator,
source: [:0]const u8,
tree: std.zig.Ast,
zir: ?std.zig.Zir,
status: Status,
comments: []const Comment,
lines: []const u32,

pub const Status = enum { parsed, invalid_syntax, invalid_lowering, budget_exhausted };
pub const Limits = struct {
    bytes: usize = 16 * 1024 * 1024,
    nodes: usize = 1_000_000,
    instructions: usize = 2_000_000,
};
pub const Comment = struct { start: u32, end: u32, line: u32 };
pub const InitError = std.mem.Allocator.Error || error{SourceTooLarge};

pub fn init(gpa: std.mem.Allocator, bytes: []const u8, limits: Limits) InitError!File {
    if (bytes.len > limits.bytes or bytes.len > std.math.maxInt(u32)) return error.SourceTooLarge;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const source = try a.dupeSentinel(u8, bytes, 0);
    const tree = try std.zig.Ast.parse(a, source, .{});
    var status: Status = if (tree.errors.len == 0) .parsed else .invalid_syntax;
    var zir: ?std.zig.Zir = null;
    if (bytes.len > limits.bytes or tree.nodes.len > limits.nodes) {
        status = .budget_exhausted;
    } else if (status == .parsed) {
        zir = try std.zig.AstGen.generate(a, tree);
        if (zir.?.hasCompileErrors()) status = .invalid_lowering;
        if (zir.?.instructions.len > limits.instructions) status = .budget_exhausted;
    }
    var lines: std.ArrayList(u32) = .empty;
    try lines.append(a, 0);
    for (source, 0..) |byte, offset| if (byte == '\n') {
        try lines.append(a, @intCast(offset + 1));
    };
    const comment_list = try scanComments(a, source, lines.items);
    return .{ .arena = arena, .source = source, .tree = tree, .zir = zir, .status = status, .lines = try lines.toOwnedSlice(a), .comments = comment_list };
}

pub fn deinit(self: *File) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn line(self: *const File, offset: u32) u32 {
    return lineIndex(self.lines, offset);
}

fn lineIndex(lines: []const u32, offset: u32) u32 {
    var lo: usize = 0;
    var hi = lines.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (lines[mid] <= offset) lo = mid + 1 else hi = mid;
    }
    return @intCast(lo - 1);
}

fn scanComments(a: std.mem.Allocator, source: [:0]const u8, lines: []const u32) InitError![]const Comment {
    var result: std.ArrayList(Comment) = .empty;
    var lexer: std.zig.Tokenizer = .init(source);
    var end: usize = 0;
    while (true) {
        const token = lexer.next();
        // Ordinary comments are gaps in the real tokenizer. Strings, character
        // literals and multiline-string lines have token spans and are skipped.
        var cursor = end;
        while (cursor < token.loc.start) {
            if (source[cursor] == '/' and cursor + 1 < token.loc.start and source[cursor + 1] == '/') {
                const start = cursor;
                while (cursor < token.loc.start and source[cursor] != '\n') cursor += 1;
                try result.append(a, .{ .start = @intCast(start), .end = @intCast(cursor), .line = lineIndex(lines, @intCast(start)) });
            } else cursor += 1;
        }
        if (token.tag == .doc_comment or token.tag == .container_doc_comment) {
            try result.append(a, .{ .start = @intCast(token.loc.start), .end = @intCast(token.loc.end), .line = lineIndex(lines, @intCast(token.loc.start)) });
        }
        end = token.loc.end;
        if (token.tag == .eof) break;
    }
    return result.toOwnedSlice(a);
}

test "front end lowers through std ZIR and retains lazy declarations" {
    var file = try init(std.testing.allocator, "const unused = struct { const value: u8 = 1; };", .{});
    defer file.deinit();
    try std.testing.expectEqual(Status.parsed, file.status);
    try std.testing.expect(file.zir.?.instructions.len > 0);
}

test "front end invalid syntax and lowering are distinct" {
    var syntax = try init(std.testing.allocator, "const x = ;", .{});
    defer syntax.deinit();
    try std.testing.expectEqual(Status.invalid_syntax, syntax.status);
    try std.testing.expect(syntax.zir == null);
    var lowering = try init(std.testing.allocator, "fn f(x: u8) void {}", .{});
    defer lowering.deinit();
    try std.testing.expectEqual(Status.invalid_lowering, lowering.status);
}

test "comment parser rejects string lookalikes" {
    var file = try init(std.testing.allocator, "const s = \"// glint-ignore: Z013 -- fake\"; // real\n// next\n", .{});
    defer file.deinit();
    try std.testing.expectEqual(@as(usize, 2), file.comments.len);
    try std.testing.expectEqualStrings("// real", file.source[file.comments[0].start..file.comments[0].end]);
}
