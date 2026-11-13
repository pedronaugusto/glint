// X004, a governed rule a package declares as hygiene: an internal field read outside the
// package through a reference that resolves is a finding.
const module = @import("module");

pub fn f(c: module.Counted) u32 {
    return c.pkg_n;
}
