// warp-fast: the copy appended to a std list is the list's to close, and the function closes it there only
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator) !void {
    var list: std.ArrayList(std.Io.File) = .empty;
    defer list.deinit(gpa);
    const file = try dir.openFile(io, "a", .{});
    errdefer file.close(io);
    try list.append(gpa, file);
    for (list.items) |x| x.close(io);
}
