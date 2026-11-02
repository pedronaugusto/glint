// A019 branch: the write is on one arm of an if only; the read after it may read undefined
pub fn oneArm(c: bool) u32 {
    var x: u32 = undefined;
    if (c) x = 1;
    return x;
}
