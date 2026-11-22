// A001: a defer writing through Secret's API: none.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(s: *S) void {
    defer s.exposeMut().* = 0;
}
