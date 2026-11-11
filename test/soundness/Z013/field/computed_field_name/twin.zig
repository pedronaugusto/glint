// matrix: Z013 field: a private import reached only by @field with a computed name: the file's reports are withheld
const extra = @import("extra.zig");
fn member(comptime name: []const u8) type {
    return @field(@This(), name);
}
pub const value = member("ext" ++ "ra").value;
