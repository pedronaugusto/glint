// glint-b: A002 unwrap (optional): the unsafe shape, which must flag
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(o: *?S) void {
    var copy = o.*.?;
    copy.deinit();
}
