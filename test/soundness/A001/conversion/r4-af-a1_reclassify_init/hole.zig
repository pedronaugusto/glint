// review 4: af/a1_reclassify_init.zig
const err = @import("aegis").err;
pub fn f(secret: []const u8) err.PublicSource {
    var p = err.PublicSource.classify("fixed label", "ok");
    p = .{ .bytes = secret };
    return p;
}
