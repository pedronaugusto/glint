// governed: a pointer cast over a governed type reaches its fields: a finding.
const module = @import("module");

pub fn f(c: *module.Counted) *u32 {
    return @ptrCast(c);
}
