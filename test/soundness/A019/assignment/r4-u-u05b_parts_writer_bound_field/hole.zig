// review 4: u/u05b_parts_writer_bound_field.zig
// A019: a parts writer whose slice bound is a field changed between write and return.
const Cursor = struct { n: usize };
fn fill(p: []u8, cur: *Cursor, src: []const u8) []u8 {
    @memcpy(p[0..cur.n], src[0..cur.n]);
    cur.n += 4;
    return p[0..cur.n];
}
pub fn main(src: []const u8) u8 {
    var buf: [16]u8 = undefined;
    var cur: Cursor = .{ .n = 4 };
    const s = fill(&buf, &cur, src);
    return s[7];
}
