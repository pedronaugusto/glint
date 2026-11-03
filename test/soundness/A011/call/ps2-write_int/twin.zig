// A raw count written into a plain integer's bytes.
const std = @import("std");
pub fn f(ns: i96) i96 {
    var d: i96 = 0;
    std.mem.writeInt(i96, std.mem.asBytes(&d)[0..12], ns, .little);
    return d;
}
