// matrix: a pointer into the frame held in a local optional, returned through `.?`
pub fn f() *u32 {
    var x: u32 = 1;
    x += 1;
    const maybe: ?*u32 = &x;
    return maybe.?;
}
