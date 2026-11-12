// P007: a pointer moved between address spaces, a conversion no build checks (review 8, m3).
pub fn f(p: *addrspace(.generic) u32) *u32 {
    return @addrSpaceCast(p);
}
