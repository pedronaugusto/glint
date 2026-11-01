// matrix A009 call: the program's own index passed to that function, input read beside it
const std = @import("std");
const w = @import("w.zig");
pub fn f(r: *std.Io.Reader, buf: *const [16]u8) !u8 {
    _ = try r.takeInt(u32, .little);
    return w.pick(buf, 3);
}
