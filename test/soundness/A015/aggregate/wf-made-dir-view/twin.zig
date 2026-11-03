// warp-fast: the same Dir made only to read through, while another Dir the program is given is closed
const std = @import("std");
const S = @import("before.zig").S;
fn dirOf(handle: std.Io.File.Handle) std.Io.Dir {
    return .{ .handle = handle };
}
pub fn size(s: *S, io: std.Io) !u64 {
    const st = try dirOf(s.d.handle).statFile(io, "a", .{});
    return st.size;
}
pub fn finish(owned: std.Io.Dir, io: std.Io) void {
    var d = owned;
    d.close(io);
}
