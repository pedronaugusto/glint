// governed: a cast to or from a governed type outside the package is a finding: an id made from
// an integer, and its integer read back.
const module = @import("module");

pub fn f(n: u32) u32 {
    const id: module.Id = @enumFromInt(n);
    return @intFromEnum(id);
}
