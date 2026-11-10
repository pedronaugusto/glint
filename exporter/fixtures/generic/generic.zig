fn id(comptime T: type, x: T) T {
    return x;
}
export fn entry(a: u8, b: u16) u16 {
    return id(u8, a) + id(u16, b);
}
