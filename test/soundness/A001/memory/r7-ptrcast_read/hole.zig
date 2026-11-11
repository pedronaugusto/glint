const aegis = @import("aegis");
// The secret's material read through a pointer cast of the whole owner.
pub fn f(s: *const aegis.Secret(u64)) u64 {
    const raw: *const u64 = @ptrCast(s);
    return raw.*;
}
