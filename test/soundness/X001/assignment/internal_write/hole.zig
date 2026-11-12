// governed .internal: a write of an internal field is a finding, through an alias of the type.
const module = @import("module");
const C = module.Counted;

pub fn f(c: *C) void {
    c.pkg_n = 7;
}
