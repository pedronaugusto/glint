// review 4: u/u10_writer_fixed_buffer_field.zig
// A019: a keep (Writer.fixed) exposes the buffer through its public field; reading it there reads
// what nothing wrote.
const std = @import("std");
pub fn main() !u8 {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("ab");
    return w.buffer[10];
}
