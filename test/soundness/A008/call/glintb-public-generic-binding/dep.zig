// A dependency's public generic that makes a value of its type parameter and keeps it.
const std = @import("std");
pub fn made(comptime T: type, io: std.Io) usize {
    const value: T = .generate(io);
    return @sizeOf(@TypeOf(value));
}
