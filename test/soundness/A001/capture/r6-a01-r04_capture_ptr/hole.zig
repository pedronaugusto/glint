// review 6: a01/r04_capture_ptr.zig
const err = @import("aegis").err;
// Through a pointer capture of an optional holding one.
pub fn f(secret: []const u8) ?err.PublicSource {
    var o: ?err.PublicSource = err.PublicSource.classify("fixed label", "ok");
    if (o) |*p| p.bytes = secret;
    return o;
}
