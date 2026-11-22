// P007: a member of a container written in the program that declares it (`base`, a
// many-item pointer): the branch `@hasDecl` guards is live, and the arithmetic there is read.
const Wide = struct {
    var storage = [_]u8{ 1, 2, 3, 4 };
    pub const base: [*]u8 = &storage;
};
pub fn second() u8 {
    if (@hasDecl(Wide, "base")) return (Wide.base + 1)[0];
    return 0;
}
