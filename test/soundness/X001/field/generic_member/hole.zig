// governed .generic member: the internal field of every instance's member type is the
// package's, an instance it never makes included.
const module = @import("module");

pub fn f(h: module.Box(u64).Handle) u32 {
    return h.slot;
}
