// matrix: Z013 field: a private import used beside tags its name spells
const extra = @import("extra.zig");
pub const Kind = enum { extra, plain };
pub const Op = union(enum) { extra, read: u32 };
pub const value = extra.value;
