// A019 inline_loop: a runtime break leaves the unrolled loop before its write
pub fn runtimeBreak(c: bool) u32 {
    var x: u32 = undefined;
    inline for (.{ 0, 1 }) |k| {
        if (c) break;
        x = k;
    }
    return x;
}
