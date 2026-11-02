// The same container, public.
pub const Impl = (struct {
    x: u8,
    pub fn init() Impl {
        return .{ .x = 1 };
    }
});
pub const Api = struct {
    pub fn make() Impl {
        return Impl.init();
    }
};
