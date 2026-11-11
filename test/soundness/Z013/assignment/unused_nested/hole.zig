// matrix: Z013 assignment: a private import in a nested container, named nowhere else
pub const Inner = struct {
    const extra = @import("extra.zig");
    pub const ready = true;
};
