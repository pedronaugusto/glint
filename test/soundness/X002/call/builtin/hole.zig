// replaces .builtin: a use of the builtin outside the package is a finding.
pub fn f(cell: *const u32) u32 {
    return @atomicLoad(u32, cell, .acquire);
}
