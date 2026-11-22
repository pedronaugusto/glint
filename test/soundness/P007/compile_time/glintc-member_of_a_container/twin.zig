// P007: the same read of a container that does not declare the member: Zig declares none
// conditionally, so the guarded branch is compiled in no build, and nothing in it is read.
const Narrow = struct {
    pub const count = 4;
};
pub fn second() u8 {
    if (@hasDecl(Narrow, "base")) return (Narrow.base + 1)[0];
    return 0;
}
