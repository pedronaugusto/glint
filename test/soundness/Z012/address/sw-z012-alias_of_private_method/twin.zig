// The same alias of a public container's method.
pub const Impl = struct {
    x: u8,
    pub fn init() Impl {
        return .{ .x = 1 };
    }
};
pub const init = Impl.init;
