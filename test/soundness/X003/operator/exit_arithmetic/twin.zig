// governed .exits (hygiene): the type's own operation is no report, and neither is an exit's
// value kept in a name first: a hygiene rule reports only the shape it is sure of.
const module = @import("module");

pub fn f(c: module.Counted) !u32 {
    const bare = c.raw();
    _ = bare;
    return (try c.add(1)).raw();
}
