// matrix: Z013 field: an unused private import whose name a @field on another file's container spells
const extra = @import("extra.zig");
const other = @import("other.zig");
pub const value = @field(other, "extra");
