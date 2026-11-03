// std's process.run reserves options.reserve_amount bytes for the child's output: a peer's
// number handed in a typed struct literal is read as the literal's own level (clean, its fields
// held by their declarations), so the size site never reaches the sink. The same through a
// `var` assigned field by field is flagged.
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, io: std.Io) !std.process.RunResult {
    const n = try r.takeInt(u32, .little);
    return std.process.run(gpa, io, .{ .argv = &.{"true"}, .reserve_amount = n });
}
