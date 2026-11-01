// review 6: a15/o06_identity_method.zig
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
// The program's function returning its parameter: a view of nothing held.
fn keep(f: std.Io.File, n: *u32) std.Io.File {
    n.* += 1;
    return f;
}
pub fn store(s: *Stored, dir: std.Io.Dir, io: std.Io) !void {
    const f = try dir.openFile(io, "a", .{});
    s.file = keep(f, &s.n);
}
