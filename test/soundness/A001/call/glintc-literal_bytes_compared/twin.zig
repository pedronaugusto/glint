// A001: std.mem.eql over a header's bytes and a string literal's: no governed value is named,
// and a literal's bytes, `"chroncdx".*`, are plain bytes (chronicle's index format, review b9).
const std = @import("std");
const aegis = @import("aegis");
const WatchId = aegis.id.Id(enum { watch }, u32);
const magic = "chroncdx".*;
pub fn read(b: *const [56]u8) bool {
    return std.mem.eql(u8, b[0..8], &magic);
}
pub fn first(ids: []const WatchId) ?WatchId {
    return if (ids.len == 0) null else ids[0];
}
