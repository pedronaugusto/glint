const aegis = @import("aegis");
pub fn f(s: *const aegis.Secret(u64)) u64 {
    const raw: *const u64 = @ptrCast(s.expose());
    return raw.*;
}
