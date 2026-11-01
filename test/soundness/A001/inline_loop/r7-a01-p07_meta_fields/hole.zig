// review 7 pre: a01/p07_meta_fields.zig
const err = @import("aegis").err;

// Every field rewritten by reflection.
pub fn f(secret: []const u8) err.PublicSource {
    var p = err.PublicSource.classify("fixed label", "ok");
    inline for (@typeInfo(err.PublicSource).@"struct".field_names) |name| @field(p, name) = secret;
    return p;
}
