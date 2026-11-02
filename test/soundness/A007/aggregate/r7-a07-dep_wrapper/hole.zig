// review 7 A007: a dependency's record holding a raw std.Io.Mutex by value, held by value in the program: nothing in this file names a lock.
const std = @import("std");
const dep = @import("dep.zig");
pub const Server = struct {
    state: dep.Shared = .{},
    pub fn count(s: *Server) u32 {
        return s.state.count;
    }
};
