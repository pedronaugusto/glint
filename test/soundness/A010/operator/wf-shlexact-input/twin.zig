// warp-fast: @shlExact of the program's own small value: no bits shifted out
pub fn f(n: u32) u32 {
    const a = n % 16;
    return @shlExact(a, 4);
}
