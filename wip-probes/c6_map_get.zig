const std = @import("std");
pub fn f(r: *std.Io.Reader, map: *std.AutoHashMapUnmanaged(u32, u32)) !bool {
    const n = try r.takeInt(u32, .little);
    if (map.get(n)) |v| return v == 0;
    return map.contains(n);
}
