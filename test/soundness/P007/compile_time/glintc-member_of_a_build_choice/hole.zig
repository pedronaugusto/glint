// P007: a member read through a per-build choice of containers one part of which declares it
// (`base`, a many-item pointer in a debug build): the branch `@hasDecl` guards is live in that
// build, and the arithmetic on the pointer there is read.
const builtin = @import("builtin");
const Wide = struct {
    var storage = [_]u8{ 1, 2, 3, 4 };
    pub const base: [*]u8 = &storage;
};
const Narrow = struct {};
const declared = if (builtin.mode == .debug) Wide else Narrow;
pub fn second() u8 {
    if (@hasDecl(declared, "base")) return (declared.base + 1)[0];
    return 0;
}
