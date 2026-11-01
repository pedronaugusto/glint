// matrix: Z034 operator: a wrapping sum and a bit mask meeting without parentheses, which Zig 0.18 refuses
pub fn wrap(a: u32, b: u32, mask: u32) u32 {
    return a +% b & mask;
}
