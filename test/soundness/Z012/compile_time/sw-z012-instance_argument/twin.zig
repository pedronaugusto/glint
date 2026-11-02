// The same type function made with a public value of a public type.
pub const Shown = struct { n: u8 };
pub fn Gen(comptime h: anytype) type {
    return struct {
        pub const n = h.n;
    };
}
pub const config: Shown = .{ .n = 3 };
pub fn make() Gen(config) {
    return .{};
}
