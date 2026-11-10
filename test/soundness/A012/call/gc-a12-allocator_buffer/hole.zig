// glint-c: an allocator's state reached back through its pointer: its buffer was cut by the peer's number, so the buffer's length is that number, and an allocation sized by it is found
const std = @import("std");
pub fn f(gpa: std.mem.Allocator, r: *std.Io.Reader, buffer: []u8) ![]u8 {
    const n = try r.takeInt(u32, .big);
    var fixed: std.heap.FixedBufferAllocator = .init(buffer[0..n]);
    const a = fixed.allocator();
    const state: *std.heap.FixedBufferAllocator = @ptrCast(@alignCast(a.ptr));
    return gpa.alloc(u8, state.buffer.len);
}
