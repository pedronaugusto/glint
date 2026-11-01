// glint-b: A002 inline_loop (names): the unsafe shape, which must flag
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H) void {
    inline for (.{"s"}) |name| {
        var copy = @field(h, name);
        copy.deinit();
    }
}
