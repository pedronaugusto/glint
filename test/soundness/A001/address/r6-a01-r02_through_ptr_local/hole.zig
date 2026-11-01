// review 6: a01/r02_through_ptr_local.zig
const err = @import("aegis").err;
// Rewritten through a pointer to the whole source.
pub fn f(secret: []const u8) err.PublicSource {
    var p = err.PublicSource.classify("fixed label", "ok");
    const q = &p;
    q.bytes = secret;
    return p;
}
