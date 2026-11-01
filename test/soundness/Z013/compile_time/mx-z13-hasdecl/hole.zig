// matrix: Z013 compile_time: a private import only @hasDecl names, which sees no private declaration
const extra = @import("extra.zig");
pub const has = @hasDecl(@This(), "extra");
