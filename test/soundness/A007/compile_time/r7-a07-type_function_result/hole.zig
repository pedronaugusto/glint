// review 7 A007: a local holding a raw std.Io.Mutex by value, its type given by a std type function (std.meta.Child of a pointer to it): the only spelled site is behind the pointer, and the result is read as known only as the program compiles.
const std = @import("std");
pub fn run(io: std.Io) void {
    var m: std.meta.Child(*const std.Io.Mutex) = .init;
    m.lockUncancelable(io);
    m.unlock(io);
}
