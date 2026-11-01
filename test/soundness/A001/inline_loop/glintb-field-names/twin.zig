// glint-b: A001 inline_loop (field names): the same shape made safe, which must stay clean
const err = @import("aegis").err;
const Label = struct { title: []const u8 };
const Text = struct { bytes: []const u8, title: []const u8 };
pub fn f(p: *Text, t: Label) void {
    _ = err;
    inline for (@typeInfo(Label).@"struct".field_names) |name| @field(p, name) = @field(t, name);
}
