// A Duration copied into another through the program's own byte view.
const std = @import("std");
fn bytes(p: *std.Io.Duration) []u8 {
    return std.mem.asBytes(p);
}
pub fn f(src: std.Io.Duration) std.Io.Duration {
    var d: std.Io.Duration = .zero;
    @memcpy(bytes(&d), std.mem.asBytes(&src));
    return d;
}
