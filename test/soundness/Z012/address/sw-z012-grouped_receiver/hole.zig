// A private container written in parentheses, whose public method is read as reachable and its own type as the enclosing receiver.
const Impl = (struct {
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
