// A019 inline_loop: every unrolled pass writes, and there is at least one
pub fn everyPass() u32 {
    var x: u32 = undefined;
    inline for (.{ 0, 1 }) |k| {
        x = k;
    }
    return x;
}
