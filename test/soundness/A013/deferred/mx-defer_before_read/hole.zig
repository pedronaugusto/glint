// matrix: a defer asserts a local the body writes input into after the defer is made
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    var kind: u8 = 0;
    defer std.debug.assert(kind < 4);
    kind = try r.takeByte();
    return kind;
}
