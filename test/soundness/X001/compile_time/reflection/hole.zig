// governed: reflection over a governed type outside the package is a finding: its fields
// listed, and one read by a name computed as it compiles.
const module = @import("module");

pub fn f(c: module.Counted) usize {
    const fields = @typeInfo(module.Counted).@"struct".field_names;
    return fields.len + @field(c, fields[0]);
}
