fn size(comptime T: type) u8 {
    return @sizeOf(T);
}
export fn entry() u8 {
    var total: u8 = 0;
    inline for (.{ u8, u16, u32 }) |T| {
        total +%= size(T);
    }
    return total;
}
