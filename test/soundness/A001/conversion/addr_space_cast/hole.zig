// A001: @addrSpaceCast over a pointer to a governed type is a cast no maker sees (review 8, m3).
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f(p: *addrspace(.generic) const S) *const S {
    return @addrSpaceCast(p);
}
