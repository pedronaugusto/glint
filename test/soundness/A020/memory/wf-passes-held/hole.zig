// warp-fast: the count bounding the loop is input and no memory held bounds
// its passes: a peer chooses how long it runs.
const std = @import("std");
pub fn queue(io: std.Io, r: *std.Io.Reader) !usize {
    _ = io;
    const n = try r.takeInt(u64, .little);
    var count: usize = 0;
    var last = false;
    while (count < n and !last) : (count += 1) {
        last = (try r.takeByte()) == 0;
    }
    return count;
}
