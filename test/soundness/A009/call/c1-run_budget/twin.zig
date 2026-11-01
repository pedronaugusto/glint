// c1: after before.zig, a constant index: no input reaches it
pub fn g(table: *const [16]u8) u8 {
    return table[3];
}
