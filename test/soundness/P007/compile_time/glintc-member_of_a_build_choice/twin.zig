// P007: the same read through a per-build choice no part of which declares the member: the
// guarded branch is compiled in no build, and nothing in it is read.
const builtin = @import("builtin");
const Narrow = struct {};
const Plain = struct {
    pub const count = 4;
};
const declared = if (builtin.mode == .debug) Plain else Narrow;
pub fn second() u8 {
    if (@hasDecl(declared, "base")) return (declared.base + 1)[0];
    return 0;
}
