// A019 conversion: a cast reads the local whole, written on one path only
pub fn castRead(c: bool) u8 {
    var x: u32 = undefined;
    if (c) x = 1;
    return @truncate(x);
}
