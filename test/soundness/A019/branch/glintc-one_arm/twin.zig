// A019 branch: each arm of the if writes; the read after it reads a value
pub fn eachArm(c: bool) u32 {
    var x: u32 = undefined;
    if (c) x = 1 else x = 2;
    return x;
}
