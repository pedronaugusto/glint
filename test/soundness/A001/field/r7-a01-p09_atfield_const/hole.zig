// review 7 pre: a01/p09_atfield_const.zig
const err = @import("aegis").err;
const field_name = "bytes";
// The field rewritten through @field with a named constant.
pub fn f(secret: []const u8) err.PublicSource {
    var p = err.PublicSource.classify("fixed label", "ok");
    @field(p, field_name) = secret;
    return p;
}
