// Z026 twin: the write's failure is counted
const std = @import("std");
var failures: u32 = 0;
pub fn report(io: std.Io, buf: []u8) void {
    var w = std.Io.File.stderr().writer(io, buf);
    w = std.Io.File.stdout().writer(io, buf);
    w.interface.writeAll("result\n") catch {
        failures += 1;
    };
}
