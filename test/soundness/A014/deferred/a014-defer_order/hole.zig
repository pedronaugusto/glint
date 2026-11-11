// a pointer into the frame stored by a defer, cleared by a defer declared after it, which runs before it
pub fn f(out: *?*u32) void {
    var x: u32 = 1;
    x += 1;
    defer out.* = &x;
    defer out.* = null;
}
