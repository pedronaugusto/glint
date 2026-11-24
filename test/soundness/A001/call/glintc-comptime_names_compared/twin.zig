// A001: std.mem.eql over two slices of u8, option names a command spells at compile time: the
// type named first is no governed type, whatever the names are (ensign's model, review b9).
const std = @import("std");
const aegis = @import("aegis");
const WatchId = aegis.id.Id(enum { watch }, u32);
const Option = struct { long: []const u8, aliases: []const []const u8 = &.{} };
const Info = struct { options: []const Option };
pub fn validate(comptime i: Info) void {
    comptime {
        var longs: []const []const u8 = &.{};
        for (i.options) |o| {
            for (.{o.long} ++ o.aliases) |name| {
                for (longs) |seen| if (std.mem.eql(u8, seen, name)) @compileError("--" ++ name ++ " names two options");
                longs = longs ++ .{name};
            }
        }
    }
}
pub fn first(ids: []const WatchId) ?WatchId {
    return if (ids.len == 0) null else ids[0];
}
