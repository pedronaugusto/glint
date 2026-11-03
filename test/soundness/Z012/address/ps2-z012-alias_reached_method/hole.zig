const Hidden = struct { x: u8 };
const Impl = struct {
    pub fn get() Hidden {
        return .{ .x = 1 };
    }
};
pub const Api = Impl;
