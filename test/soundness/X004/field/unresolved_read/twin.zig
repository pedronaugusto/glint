// X004, hygiene: a reference spelling the internal field that does not resolve (an anytype
// holder) is not shown to be it, and a hygiene rule reports only what it resolves (8c). Under a
// ban (X001) the same reference is a finding.
const module = @import("module");

pub fn f(c: anytype) u32 {
    _ = module;
    return c.pkg_n;
}
