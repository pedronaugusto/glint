// A raw count written into std's Duration's bytes by std.mem.writeInt.
const std = @import("std");
pub fn f(ns: i96) std.Io.Duration {
    var d: std.Io.Duration = .zero;
    std.mem.writeInt(i96, std.mem.asBytes(&d)[0..12], ns, .little);
    return d;
}
