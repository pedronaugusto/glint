// A019 conversion: the local is written through a cast, then read through one
pub fn castRead(v: u64) u8 {
    var x: u32 = undefined;
    x = @intCast(v & 0xffff);
    return @truncate(x);
}
