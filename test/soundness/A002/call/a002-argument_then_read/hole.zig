// a002: A002 call: a borrow handed to a call that may give it back, then returned itself beside it, which must flag
const S = @import("aegis").Secret;
const Pair = struct { kept: *const u32, own: *const u32 };
pub fn f(s: *S(u32), keep: *const fn (*const u32) *const u32) Pair {
    const b = s.expose();
    return .{ .kept = keep(b), .own = b };
}
