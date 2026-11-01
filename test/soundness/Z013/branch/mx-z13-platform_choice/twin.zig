// matrix: Z013 branch: a private binding of one of two imports chosen by a comptime if, used
const builtin = @import("builtin");
const backend = if (builtin.os.tag == .windows) @import("windows.zig") else @import("posix.zig");
pub const value = backend.value;
