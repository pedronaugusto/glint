// matrix: std's assert reached by @field with a name held in a constant, its condition on input
const std = @import("std");
const check = "assert";
pub fn f(r: *std.Io.Reader) !u8 {
    const b = try r.takeByte();
    @field(std.debug, check)(b < 4);
    return b;
}
