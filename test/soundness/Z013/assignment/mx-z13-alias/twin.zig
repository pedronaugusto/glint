// matrix: Z013 assignment: a private import used through a private alias of it
const extra = @import("extra.zig");
const alias = extra;
pub const value = alias.value;
