// warp-fast: an inline for's capture is a plain integer type.
pub fn f() u64 {
    var n: u64 = 0;
    inline for (.{ u8, u16 }) |T| {
        const x: T = 1;
        n += x;
    }
    return n;
}
