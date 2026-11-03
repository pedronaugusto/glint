// matrix: Z013 field: an unused private import whose name an enum's and a union's tags spell (`extra,`), which name themselves
const extra = @import("extra.zig");
pub const Kind = enum { extra, plain };
pub const Op = union(enum) { extra, read: u32 };
