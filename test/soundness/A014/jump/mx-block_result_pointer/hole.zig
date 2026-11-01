// matrix: a pointer into the frame the result of a labeled block, stored through the caller's pointer
pub fn f(out: **u32, wide: bool) void {
    var x: u32 = 1;
    var y: u32 = 2;
    x += 1;
    y += 1;
    out.* = blk: {
        if (wide) break :blk &y;
        break :blk &x;
    };
}
