// Z026 twin: the read's failure is counted
const std = @import("std");
var failures: u32 = 0;
pub fn poll(io: std.Io, buf: []u8) void {
    var r = std.Io.File.stderr().reader(io, buf);
    _ = r.interface.takeByte() catch {
        failures += 1;
    };
}
