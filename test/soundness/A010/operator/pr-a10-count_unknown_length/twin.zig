// precision A010 operator: a for loop makes fewer passes than usize counts, whatever memory it walks, so a count of them stepped once a pass never overflows
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const wanted = try r.takeByte();
    var n: usize = 0;
    for (r.buffer) |c| {
        if (c == wanted) n += 1;
    }
    return n;
}
