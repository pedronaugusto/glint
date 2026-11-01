// warp-fast: a defer that writes through a pointer without atomics.
pub fn f(p: *u32) void {
    defer p.* += 1;
}
