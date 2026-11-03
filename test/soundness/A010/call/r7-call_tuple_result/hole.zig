// A010: @call given a tuple variable: what read1 returns is the peer's number, whose product overflows
const std = @import("std");
fn read1(r: *std.Io.Reader) !u64 {
    return r.takeInt(u64, .little);
}
pub fn f(r: *std.Io.Reader) !u64 {
    const args = .{r};
    const v = try @call(.auto, read1, args);
    return v * 3;
}
