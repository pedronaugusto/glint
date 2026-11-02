// review 7 A007: a dependency's generic record made over a raw std.Io.Mutex (by the dependency), held by value as the program's field.
const dep = @import("dep.zig");
pub const Server = struct {
    state: dep.Locked = .{ .value = .init },
};
