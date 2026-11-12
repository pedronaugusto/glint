// replaces .decl of the package's own declaration: a consumer's call of it is a finding.
const module = @import("module");

pub fn f() u32 {
    return module.oldName();
}
