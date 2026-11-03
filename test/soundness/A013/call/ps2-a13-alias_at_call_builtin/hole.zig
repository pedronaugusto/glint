// pre-sweep-2 A013: std's assert aliased by a constant (`const check = std.debug.assert;`, no
// site: aliasCalls reads only calls whose callee is the alias), then the alias taken as a value
// (@call's callee) and called through it on a peer's byte. The direct form (`&std.debug.assert` there) is undecided.
const std = @import("std");
const check = std.debug.assert;
fn other(b: bool) void {
    _ = b;
}

pub fn f(r: *std.Io.Reader) !u8 {
    const line = try r.take(4);
    @call(.auto, check, .{line[0] > 3});
    return line[0];
}
