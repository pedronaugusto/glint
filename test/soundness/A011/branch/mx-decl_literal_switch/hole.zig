// matrix: raw counts made std's Duration by decl literals in a switch's prongs
const std = @import("std");
pub fn f(n: i64, unit: enum { ms, s }) std.Io.Duration {
    return switch (unit) {
        .ms => .fromMilliseconds(n),
        .s => .fromSeconds(n),
    };
}
