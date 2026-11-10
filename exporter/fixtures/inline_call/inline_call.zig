inline fn twice(x: u8) u8 {
    return x *% 2;
}
fn plain(x: u8) u8 {
    return x +% 1;
}
export fn entry(a: u8) u8 {
    return twice(a) +% twice(plain(a));
}
