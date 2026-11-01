// review 6: a01/r01_destructure.zig
const err = @import("aegis").err;
// The field rewritten by a destructure.
pub fn f(secret: []const u8) err.PublicSource {
    var p = err.PublicSource.classify("fixed label", "ok");
    var n: usize = 0;
    p.bytes, n = .{ secret, 1 };
    _ = &n;
    return p;
}
