pub const Key = struct {
    bytes: [32]u8,
    pub fn generate(seed: u8) Key {
        return .{ .bytes = @splat(seed) };
    }
};

/// The package's answer: an owner that makes its key in place.
pub fn Owner(comptime T: type) type {
    return struct {
        value: T,
        pub fn make(self: *@This(), comptime maker: anytype, args: anytype) void {
            self.value = @call(.auto, maker, args);
        }
    };
}

pub const lint_rules = .{
    .version = 2,
    .rules = .{
        .{ .id = .X002, .name = "replaced", .kind = .ban, .reads = .replaces, .default = true, .purpose = "a declaration the package's answer stands for, outside a seam" },
    },
    .replaces = .{.{ .rule = .X002, .decl = Key, .with = .{ Owner, .{ .generic = Owner, .member = .make } }, .why = "a key is held only through Owner" }},
};
