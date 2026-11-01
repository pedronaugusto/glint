// matrix A009 call: input passed to a function of a file the run does not select, which indexes memory with it
const std = @import("std");
const w = @import("w.zig");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const i: usize = try r.takeInt(u32, .little);
    return w.pick(buf, i);
}
