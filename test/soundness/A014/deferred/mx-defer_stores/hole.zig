// matrix: the store of a pointer into the frame made by a defer itself, as the frame goes
pub fn f(out: **u32) void {
    var x: u32 = 1;
    x += 1;
    defer out.* = &x;
}
