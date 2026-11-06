// relic-b (pre-sweep-4): an optional tagged union (`?Address`) written in two functions and switched
// on, given only whole values from elsewhere: a value (an address), no state set (A017's ruling,
// 11-06). reactor src/ext/net/connect.zig:30 `local_address: ?net.IpAddress`.
pub const Address = union(enum) { ip4: [4]u8, ip6: [16]u8 };
pub const Options = struct {
    local: ?Address = null,
    pub fn bind(o: *Options, a: Address) void {
        o.local = switch (a) {
            .ip4 => a,
            .ip6 => if (o.local) |l| l else a,
        };
    }
    pub fn family(o: *const Options) u8 {
        return switch (o.local orelse return 0) {
            .ip4 => 4,
            .ip6 => 6,
        };
    }
    pub fn clear(o: *Options) void {
        if (o.local != null) o.local = null;
    }
};
