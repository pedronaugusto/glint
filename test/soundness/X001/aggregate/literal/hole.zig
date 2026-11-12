// governed: a struct literal naming an internal field makes the type around its maker: typed,
// and by a declaration literal's result type.
const module = @import("module");

pub fn f() [2]module.Counted {
    return .{ module.Counted{ .pkg_n = 1 }, .{ .pkg_n = 2 } };
}
