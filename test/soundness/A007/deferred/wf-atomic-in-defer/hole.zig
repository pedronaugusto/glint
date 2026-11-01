// warp-fast: a raw atomic run by a defer.
pub fn f(p: *u32) void {
    defer _ = @atomicRmw(u32, p, .Add, 1, .seq_cst);
}
