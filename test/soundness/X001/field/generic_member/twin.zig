// governed .generic member: a field the entry does not name is no finding.
const module = @import("module");

pub fn f(h: module.Box(u64).Handle) u64 {
    return h.value;
}
