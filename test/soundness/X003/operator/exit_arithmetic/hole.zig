// governed .exits (hygiene): an exit's result given straight to arithmetic, a comparison or a
// narrowing cast is reported.
const module = @import("module");

pub fn f(c: module.Counted) !u16 {
    if (c.raw() > 10) return error.Large;
    return @intCast(c.raw() + 1);
}
