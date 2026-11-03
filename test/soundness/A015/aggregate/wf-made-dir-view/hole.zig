// warp-fast: a Dir made of another file's field's handle, closed: this releases another's owner
const std = @import("std");
const S = @import("before.zig").S;
fn dirOf(handle: std.Io.File.Handle) std.Io.Dir {
    return .{ .handle = handle };
}
pub fn drop(s: *S, io: std.Io) void {
    dirOf(s.d.handle).close(io);
}
