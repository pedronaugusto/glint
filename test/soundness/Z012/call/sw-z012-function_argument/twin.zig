// The same type function made with a public function: callers write Wrap(helper).
pub fn Wrap(comptime g: fn () u8) type {
    return struct {
        pub fn get() u8 {
            return g();
        }
    };
}
pub fn helper() u8 {
    return 1;
}
pub fn make() Wrap(helper) {
    return .{};
}
