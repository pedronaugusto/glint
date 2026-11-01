// review 7 pre: a01/p08_atfield_escaped.zig
const err = @import("aegis").err;

// The field rewritten through @field, its name written with an escape.
pub fn f(secret: []const u8) err.PublicSource {
    var p = err.PublicSource.classify("fixed label", "ok");
    @field(p, "\x62ytes") = secret;
    return p;
}
