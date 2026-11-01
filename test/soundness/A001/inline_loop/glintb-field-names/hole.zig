// glint-b: A001 inline_loop (field names): the unsafe shape, which must flag
const err = @import("aegis").err;
const Text = struct { bytes: []const u8 };
pub fn f(p: *err.PublicSource, t: Text) void {
    inline for (@typeInfo(Text).@"struct".field_names) |name| @field(p, name) = @field(t, name);
}
