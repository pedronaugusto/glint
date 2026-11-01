// review 4: u/u14_memset_undefined.zig
// A019: @memset with undefined counts as writing the local whole.
pub fn main(c: bool) u8 {
    var buf: [4]u8 = undefined;
    if (c) buf[0] = 1;
    @memset(&buf, undefined);
    return buf[3];
}
