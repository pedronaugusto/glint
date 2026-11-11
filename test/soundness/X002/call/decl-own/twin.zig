// replaces .decl of the package's own declaration: its answer is no finding.
const module = @import("module");

pub fn f() u32 {
    return module.newName();
}
