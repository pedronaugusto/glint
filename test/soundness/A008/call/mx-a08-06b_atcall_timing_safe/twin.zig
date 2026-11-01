// matrix A008: the same @call to aegis's comparison, which answers a Choice.
const aegis = @import("aegis");
pub fn same(a: *const [32]u8, b: *const [32]u8) bool {
    return @call(.auto, aegis.secret.equal, .{ 32, a, b }).declassify("the caller acts on the match");
}
