// a pointer into the frame stored by a defer, cleared by a defer declared before it, which runs after it
pub fn f(out: *?*u32) void {
    var x: u32 = 1;
    x += 1;
    defer out.* = null;
    defer out.* = &x;
}
