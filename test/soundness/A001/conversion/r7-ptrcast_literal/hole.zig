const err = @import("aegis").err;
// A plain struct reinterpreted as a public source: no classify, no reason.
const Text = struct { bytes: []const u8 };
pub fn f(secret: *const Text) *const err.PublicSource {
    return @ptrCast(secret);
}
