// matrix: a pointer into the caller's memory the result of a labeled block, stored through the caller's pointer
pub fn f(out: **u32, wide: bool, a: *u32, b: *u32) void {
    out.* = blk: {
        if (wide) break :blk b;
        break :blk a;
    };
}
