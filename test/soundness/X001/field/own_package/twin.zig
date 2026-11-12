// governed: the declaring package touching its own fields is no finding (module.zig's raw and
// add read `n`); a consumer calling them is none either.
const module = @import("module");

pub fn f(c: module.Counted) !module.Counted {
    return c.add(1);
}
