// review 5: b/h02_loop_candidate.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const n: usize = try r.takeInt(u32, .little);
    var i: usize = 0;
    var acc: u8 = 0;
    while (i < buf.len) : (i += 1) {
        if (i == n) i += 2;
        acc +%= buf[i];
    }
    return acc;
}
