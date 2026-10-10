//! Compile the std-only token API at a different pointer width.
const std = @import("std");
const token = @import("token");
export fn tokenImports() usize {
    var buffer: [32768]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const facts = token.scanSentinel(fixed.allocator(), "pub const dependency = @import(\"unmapped\").read;", null) catch return 0;
    return facts.imports.len;
}
