// review 5: a20/c01_flag_literals.zig
const std = @import("std");
// `more` is given only literals, the false one under a condition input decides: the loop runs
// as long as the peer's seed says.
pub fn churn(io: std.Io, r: *std.Io.Reader) !u64 {
    _ = io;
    const seed = try r.takeInt(u64, .little);
    var more = true;
    var total: u64 = 0;
    while (more) {
        total +%= 1;
        if (total == seed) more = false;
    }
    return total;
}
