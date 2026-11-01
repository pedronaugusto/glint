// matrix: a span aegis parses as the program compiles, converted to std's
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i32);
pub fn f() std.Io.Duration {
    const span = comptime Ms.literal("250ms");
    return span.toIoDuration();
}
