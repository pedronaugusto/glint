// warp-fast: a raw atomic store on a word the program owns.
pub fn f(p: *u32) void {
    @atomicStore(u32, p, 1, .release);
}
