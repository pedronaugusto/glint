// Z013: an unused private import; an enum literal elsewhere spells its name
const extra = @import("extra.zig");
pub const Kind = enum { extra, plain };
pub fn pick() Kind {
    return .extra;
}
