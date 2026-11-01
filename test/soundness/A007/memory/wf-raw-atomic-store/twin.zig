// warp-fast: the word written by @memset, no atomics.
pub fn f(p: []u32) void {
    @memset(p, 1);
}
