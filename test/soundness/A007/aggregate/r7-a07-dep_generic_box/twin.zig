// review 7 A007: the same record made over a number.
const dep = @import("dep.zig");
pub const Server = struct {
    state: dep.Counted = .{ .value = 0 },
};
