// warp-fast: a container-level var any thread may write, held by no guard.
var hits: u32 = 0;
pub fn bump() void {
    hits += 1;
}
