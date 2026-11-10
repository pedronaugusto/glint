inline fn inner(x: u8) u8 {
    return x *% 2;
}
inline fn outer(x: u8, y: u8) u8 {
    return inner(x) +% inner(y +% 1);
}
export fn entry(a: u8) u8 {
    return outer(3, 5) +% a;
}
