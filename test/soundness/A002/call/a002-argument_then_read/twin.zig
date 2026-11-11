// a002: A002 call: the same shape from a plain pointer, which must stay clean
const Pair = struct { kept: *const u32, own: *const u32 };
pub fn f(p: *const u32, keep: *const fn (*const u32) *const u32) Pair {
    const b = p;
    return .{ .kept = keep(b), .own = b };
}
