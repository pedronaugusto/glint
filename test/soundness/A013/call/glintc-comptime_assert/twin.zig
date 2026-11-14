// A013: std.debug.assert evaluated as the program compiles, in a `comptime` block or as a
// `comptime` call, fails as a compile error, never in a fast build (visor's cell.zig and
// shm.zig; tycho-b9's report, 8i).
const aegis = @import("aegis");
const std = @import("std");
const max_inline = 6;
const max_name = 32;
comptime {
    std.debug.assert(@sizeOf(u32) + @sizeOf(u16) == max_inline);
}
pub fn name(buffer: []u8) []u8 {
    comptime std.debug.assert("/v-ffffffff-ffffffffffffffff".len <= max_name);
    return buffer[0..@min(buffer.len, max_name)];
}
