// governed: the type's own API, and a field the entry does not name, are no finding.
const module = @import("module");

pub fn f(c: module.Counted) u32 {
    return c.raw() + c.tag;
}
