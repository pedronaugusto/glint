// matrix: a pointer into the frame stored through a local copy of the caller's pointer
pub fn f(out: **u32) void {
    var x: u32 = 1;
    x += 1;
    const slot = out;
    slot.* = &x;
}
