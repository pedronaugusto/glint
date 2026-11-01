// matrix: an if expression chooses input on one side, the choice asserted
const std = @import("std");
pub fn f(r: *std.Io.Reader, wide: bool) !u8 {
    const kind: u8 = if (wide) try r.takeByte() else 3;
    std.debug.assert(kind < 4);
    return kind;
}
