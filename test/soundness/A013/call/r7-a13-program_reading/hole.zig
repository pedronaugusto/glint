// The program's own reading shaped as std's (`return switch (q.nodeTag(n))`), whose tag read
// takes the next tag a peer sent each time: the check and the reading see two tags, and the
// `.?` meets null. Only std's own reading is pure.
const std = @import("std");
const Tag = std.zig.Ast.Node.Tag;
const Queue = struct {
    tags: []const u8,
    at: usize = 0,
    fn nodeTag(q: *Queue, n: usize) Tag {
        defer q.at += 1;
        return if (q.tags[(q.at + n) % q.tags.len] == 0) .if_simple else .@"while";
    }
    fn body(q: *Queue, n: usize) Wrapper {
        return .{ .at = q.at + n };
    }
    fn fullIf(q: *Queue, n: usize) ?Wrapper {
        return switch (q.nodeTag(n)) {
            .if_simple => q.body(n),
            else => null,
        };
    }
};
const Wrapper = struct { at: usize };
pub fn f(r: *std.Io.Reader) !usize {
    const bytes = try r.take(16);
    var q: Queue = .{ .tags = bytes };
    const n: usize = bytes[0];
    if (q.nodeTag(n) == .if_simple) return q.fullIf(n).?.at;
    return 0;
}
