// matrix: std's ns_per_ms reached by an inline loop over std.time's declarations, by the name each gives
const std = @import("std");
pub fn f(ms: u64) u64 {
    var ns: u64 = 0;
    inline for (@typeInfo(std.time).@"struct".decl_names) |name| {
        if (comptime std.mem.eql(u8, name, "ns_per_ms")) ns = ms * @field(std.time, name);
    }
    return ns;
}
