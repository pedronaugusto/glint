// matrix: a pointer into the frame converted by @ptrCast, returned
pub fn f() *[4]u8 {
    var x: u32 = 1;
    x += 1;
    return @ptrCast(&x);
}
