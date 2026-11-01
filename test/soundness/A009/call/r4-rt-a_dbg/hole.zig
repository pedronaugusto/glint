// review 4: rt/a_dbg.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []u8) !u8 {
    const at: usize = try r.takeInt(u32, .little);
    std.debug.assert(at < buf.len);
    return buf[at];
}
