// A public type function made with a value of a private type: `Gen(.{...})` of Hidden cannot be written outside.
const Hidden = struct { n: u8 };
pub fn Gen(comptime h: anytype) type {
    return struct {
        pub const n = h.n;
    };
}
const config: Hidden = .{ .n = 3 };
pub fn make() Gen(config) {
    return .{};
}
