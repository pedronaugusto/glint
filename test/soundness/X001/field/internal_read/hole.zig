// governed .internal: a read of an internal field outside the package is a finding.
const module = @import("module");

pub fn f(c: module.Counted) u32 {
    return c.pkg_n;
}
