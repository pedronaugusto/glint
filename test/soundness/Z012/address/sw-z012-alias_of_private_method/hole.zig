// A public alias of a private container's public method.
const Impl = struct {
    x: u8,
    pub fn init() Impl {
        return .{ .x = 1 };
    }
};
pub const init = Impl.init;
