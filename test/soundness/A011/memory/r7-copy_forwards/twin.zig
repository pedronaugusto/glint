// A Duration's bytes copied into another by std's copyForwards.
const std = @import("std");
pub fn f(src: std.Io.Duration) std.Io.Duration {
    var d: std.Io.Duration = .zero;
    std.mem.copyForwards(u8, std.mem.asBytes(&d), std.mem.asBytes(&src));
    return d;
}
