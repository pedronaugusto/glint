// governed: the type's size is no reflection over its fields: no finding.
const module = @import("module");

pub fn f() usize {
    return @sizeOf(module.Counted);
}
