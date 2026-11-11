const Text = struct { bytes: []const u8 };
const Other = struct { bytes: []const u8 };
pub fn f(secret: *const Text) *const Other {
    return @ptrCast(secret);
}
