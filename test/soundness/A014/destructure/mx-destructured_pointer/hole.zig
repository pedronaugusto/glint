// matrix: a pointer into the frame taken out of a tuple by a destructure, then returned
pub fn f() *u32 {
    var x: u32 = 1;
    x += 1;
    const p, const n = .{ &x, @as(u32, 0) };
    _ = n;
    return p;
}
