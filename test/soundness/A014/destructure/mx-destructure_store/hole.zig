// matrix: a pointer into the frame stored through the caller's pointer by a destructuring assignment
pub fn f(out: **u32, count: *u32) void {
    var x: u32 = 1;
    x += 1;
    out.*, count.* = .{ &x, 1 };
}
