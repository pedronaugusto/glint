// A001: an optional's captured holder, read through Secret's API: none.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(o: ?*const S) u32 {
    if (o) |s| return s.expose().*;
    return 0;
}
