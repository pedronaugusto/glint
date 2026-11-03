// pre-sweep-2 A013: std's assert aliased by a constant (`const check = std.debug.assert;`, no
// site: aliasCalls reads only calls whose callee is the alias), then the alias taken as a value
// (a table of function pointers) and called through it on a peer's byte. The direct form (`&std.debug.assert` there) is undecided.
const std = @import("std");
const check = std.debug.assert;
fn other(b: bool) void {
    _ = b;
}
const table = [_]*const fn (bool) void{ &check, &other };
pub fn f(r: *std.Io.Reader) !u8 {
    const line = try r.take(4);
    table[line[1] & 1](line[0] > 3);
    return line[0];
}
