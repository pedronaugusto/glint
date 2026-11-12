// replaces .decl of a type: the package's answer holding it is no finding here.
const module = @import("module");

pub const State = struct {
    locked: module.Locked = .{},
};
