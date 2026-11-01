// warp-fast: the comptime name reaches only a read of the handle: the field is a borrow.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
fn handleNamed(s: *Stored, comptime name: []const u8) std.Io.File.Handle {
    return @field(s, name).handle;
}
pub fn handle(s: *Stored) std.Io.File.Handle {
    return handleNamed(s, "file");
}
