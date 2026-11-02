// A019 operator: the write is in the right operand of `and`, which a false left one skips
fn set(p: *u32) bool {
    p.* = 1;
    return true;
}
pub fn rightOperand(c: bool) u32 {
    var x: u32 = undefined;
    _ = c and set(&x);
    return x;
}
