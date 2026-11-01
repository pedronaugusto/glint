// review 4: u/u05_parts_writer_bound_through_pointer.zig
// A019: a parts writer whose slice bound changes through a pointer between write and return.
fn fill(p: []u8, k: *usize, src: []const u8) []u8 {
    @memcpy(p[0..k.*], src[0..k.*]);
    k.* += 4;
    return p[0..k.*];
}
pub fn main(src: []const u8) u8 {
    var buf: [16]u8 = undefined;
    var k: usize = 4;
    const s = fill(&buf, &k, src);
    return s[7];
}
