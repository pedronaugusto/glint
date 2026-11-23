// P007: a compound assignment into an element of a slice of arrays taken from a slice: the
// slice holds arrays, its element one, and nothing in the statement is a many-item pointer
// (aperture's quantize, review b9).
const std = @import("std");
pub fn spread(gpa: std.mem.Allocator, w: usize, e: f32) !void {
    const err = try gpa.alloc([4]f32, 2 * (w + 2));
    defer gpa.free(err);
    var this = err[0 .. w + 2];
    var next = err[w + 2 ..];
    for (0..4) |k| {
        this[1][k] += e * 7 / 16;
        next[2][k] += e * 3 / 16;
    }
    std.mem.swap([][4]f32, &this, &next);
}
