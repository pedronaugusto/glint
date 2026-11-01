// matrix: Z013 conversion: a private binding of an import through @as(type, ...), used
const extra = @as(type, @import("extra.zig"));
pub const value = extra.value;
