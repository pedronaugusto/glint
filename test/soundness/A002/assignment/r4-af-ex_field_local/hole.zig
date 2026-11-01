// review 4: af/ex_field_local.zig
const S = @import("aegis").Secret;
const R = struct { v: *const u32 };
pub fn f(s: *S(u32)) R {
    var r: R = undefined;
    r.v = s.expose();
    return r;
}
