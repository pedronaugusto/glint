// A public signature's type named by @field on the file's own namespace: a private declaration.
const Hidden = struct { x: u8 };
pub fn make() @field(@This(), "Hidden") {
    return .{ .x = 1 };
}
