const std = @import("std");
const Checks = struct {
    pub const holds = std.debug.assert;
};
pub fn verify(comptime C: type, a: u8, b: u8) void {
    C.holds(a > 1 and b > 1);
}
pub fn run(a: u8, b: u8) void {
    verify(Checks, a, b);
}
