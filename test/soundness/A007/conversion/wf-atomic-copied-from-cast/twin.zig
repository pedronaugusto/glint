// warp-fast: a word cast to a plain integer pointer and read.
pub fn f(p: *u32) u32 {
    const q: *const u32 = @ptrCast(p);
    return q.*;
}
