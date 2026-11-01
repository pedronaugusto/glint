// matrix: a peer's byte converted to a non-exhaustive enum, its unknown tags an error
const std = @import("std");
const Kind = enum(u8) { a, b, _ };
pub fn f(r: *std.Io.Reader) !u8 {
    const k: Kind = @enumFromInt(try r.takeByte());
    return switch (k) {
        .a => 1,
        .b => 2,
        _ => error.UnknownKind,
    };
}
