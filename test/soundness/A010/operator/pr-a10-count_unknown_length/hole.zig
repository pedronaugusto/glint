// precision A010 operator: the count starts at the peer's number, so a step once a pass may overflow it
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const wanted = try r.takeByte();
    var n: u64 = try r.takeInt(u64, .little);
    for (r.buffer) |c| {
        if (c == wanted) n += 1;
    }
    return n;
}
