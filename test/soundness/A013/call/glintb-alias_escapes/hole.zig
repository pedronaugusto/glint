// glint-b: std's assert aliased and handed to a function that calls it on a peer's byte: its value escapes, so the calls through it are not all known
const std = @import("std");
const check = std.debug.assert;
fn each(call: *const fn (bool) void, b: bool) void {
    call(b);
}
pub fn f(r: *std.Io.Reader) !u8 {
    const line = try r.take(4);
    each(&check, line[0] > 3);
    return line[0];
}
