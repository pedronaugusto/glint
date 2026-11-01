// warp-fast: @divExact of the program's own multiple: no remainder
pub fn f(n: u32) u32 {
    const a = (n % 1000) * 4;
    return @divExact(a, 4);
}
