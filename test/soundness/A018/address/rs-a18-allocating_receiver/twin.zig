// rule-small: an error's name printed through an allocating writer's `writer` as the method's receiver: its bytes never leave the program
const std = @import("std");
pub fn reply(gpa: std.mem.Allocator, err: anyerror) !usize {
    var listing: std.Io.Writer.Allocating = .init(gpa);
    defer listing.deinit();
    try listing.writer.print("failed: {s}\n", .{@errorName(err)});
    return listing.written().len;
}
