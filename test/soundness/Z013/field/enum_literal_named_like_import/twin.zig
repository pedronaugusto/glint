// Z013 twin: the import is used
const extra = @import("extra.zig");
pub const Kind = enum { extra, plain };
pub fn pick() Kind {
    return .extra;
}
pub const value = extra.value;
