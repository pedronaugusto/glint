// matrix: a raw count of milliseconds stored as std's Duration through a decl literal, the door never spelled with its type
const std = @import("std");
pub fn f(ms: i64) std.Io.Duration {
    var d: std.Io.Duration = .zero;
    d = .fromMilliseconds(ms);
    return d;
}
