const std = @import("std");
// A dependency's table of types, chosen by index.
pub const types = [_]type{ std.Io.Mutex, Kind };
pub const Kind = enum { a, b, init };
pub fn Pick(comptime n: usize) type {
    return types[n];
}
