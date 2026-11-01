// review 4: u/u10d_keeps_only_returns_buffer.zig
// A019: the program's own "keeps only" function hands the buffer to Writer.fixed and returns the
// writer's buffer field: all of the caller's unwritten buffer comes back as a slice.
const std = @import("std");
fn view(p: *[16]u8) []u8 {
    const w: std.Io.Writer = .fixed(p);
    return w.buffer;
}
pub fn main() u8 {
    var buf: [16]u8 = undefined;
    const s = view(&buf);
    return s[10];
}
