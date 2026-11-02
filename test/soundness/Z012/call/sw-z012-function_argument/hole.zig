// A public type function made with a private function as its argument: `Wrap(helper)` cannot be named outside.
pub fn Wrap(comptime g: fn () u8) type {
    return struct {
        pub fn get() u8 {
            return g();
        }
    };
}
fn helper() u8 {
    return 1;
}
pub fn make() Wrap(helper) {
    return .{};
}
