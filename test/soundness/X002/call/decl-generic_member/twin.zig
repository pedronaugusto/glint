// replaces .decl of a type function's member: the answer of the same instance is no finding.
const module = @import("module");

pub fn f(b: module.Box(u16)) u16 {
    return b.checked();
}
