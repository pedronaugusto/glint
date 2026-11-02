// A019 operator: the write is in the left operand of `and`, which always runs
fn set(p: *u32) bool {
    p.* = 1;
    return true;
}
pub fn leftOperand(c: bool) u32 {
    var x: u32 = undefined;
    _ = set(&x) and c;
    return x;
}
