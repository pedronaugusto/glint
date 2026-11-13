pub const Counted = struct {
    pkg_n: u32,
    tag: u8 = 0,

    pub fn init(value: u32) Counted {
        return .{ .pkg_n = value };
    }
    pub fn raw(self: Counted) u32 {
        return self.pkg_n;
    }
    pub fn add(self: Counted, by: u32) !Counted {
        return .{ .pkg_n = try @import("std").math.add(u32, self.pkg_n, by), .tag = self.tag };
    }
};

pub const Id = enum(u32) {
    _,
    pub fn first() Id {
        return @enumFromInt(0);
    }
};

pub fn Box(comptime T: type) type {
    return struct {
        pub const Handle = struct { pkg_slot: u32, value: T };
        pub fn make(value: T) Handle {
            return .{ .pkg_slot = 0, .value = value };
        }
    };
}

pub const lint_rules = .{
    .version = 2,
    .rules = .{
        .{ .id = .X004, .name = "governed state, hygiene", .kind = .hygiene, .reads = .governed, .default = true, .purpose = "a governed type's internal fields, read as hygiene: only what resolves" },
    },
    .governed = .{
        .{ .type = Counted, .internal = .{.pkg_n}, .exits = .{.raw} },
    },
};
