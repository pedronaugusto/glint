// review 4: u/u10e_fba_buffer.zig
// A019: FixedBufferAllocator keeps the buffer; its public field gives the unwritten bytes back.
const std = @import("std");
pub fn main() u8 {
    var buf: [16]u8 = undefined;
    const fba: std.heap.FixedBufferAllocator = .init(&buf);
    return fba.buffer[3];
}
