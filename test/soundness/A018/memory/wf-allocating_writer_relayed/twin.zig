// matrix: an error's name printed into an allocating writer, whose bytes never leave the program
const std = @import("std");
pub fn reply(gpa: std.mem.Allocator, err: anyerror) !usize {
    var listing: std.Io.Writer.Allocating = .init(gpa);
    defer listing.deinit();
    const out = &listing.writer;
    try out.print("failed: {s}\n", .{@errorName(err)});
    return listing.written().len;
}
