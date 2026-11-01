// matrix: Z034 operator: orelse under a bitwise or without parentheses
pub fn pick(a: ?u32, b: u32, c: u32) u32 {
    return a orelse b | c;
}
