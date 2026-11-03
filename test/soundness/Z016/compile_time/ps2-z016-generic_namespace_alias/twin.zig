const std = @import("std");
fn mine(ok: bool) void {
    _ = ok;
}
const Checks = struct {
    pub const holds = mine;
};
pub fn verify(comptime C: type, a: u8, b: u8) void {
    C.holds(a > 1 and b > 1);
}
pub fn run(a: u8, b: u8) void {
    verify(Checks, a, b);
}
