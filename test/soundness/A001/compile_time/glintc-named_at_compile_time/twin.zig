// A001: @field with a method's name a comptime constant holds: none.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
const name = "expose";
pub fn f(s: *const S) u32 {
    return @field(S, name)(s).*;
}
