// a reference that does not resolve, in a file a replaces rule checks, may be the target: it is
// a finding ("cannot show this is not std.Io.File.sync"), never undecided.
const std = @import("std");
const gone = @import("gone");

pub fn f(file: std.Io.File, io: std.Io) !void {
    try gone.flush(file, io);
}
