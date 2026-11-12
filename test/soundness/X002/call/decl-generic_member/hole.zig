// replaces .decl of a type function's member: the member of every instance is the declaration,
// an instance the package never makes included.
const module = @import("module");

pub fn f(b: module.Box(u16)) u16 {
    return b.unchecked();
}
