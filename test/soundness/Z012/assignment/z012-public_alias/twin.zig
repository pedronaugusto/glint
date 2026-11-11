// A private type behind a public alias: callers name it as Api.
const Hidden = struct { x: u8 };
pub const Api = Hidden;
pub fn make() Hidden {
    return .{ .x = 1 };
}
