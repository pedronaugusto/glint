// matrix: Z013 address: an unused private import whose name a member access on another file spells
const extra = @import("extra.zig");
const other = @import("other.zig");
pub const value = other.extra;
