// warp-fast: a function returns a std lock by value.
const std = @import("std");
pub fn make() std.Io.Mutex {
    return .init;
}
