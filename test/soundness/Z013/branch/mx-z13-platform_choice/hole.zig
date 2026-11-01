// matrix: Z013 branch: a private binding of one of two imports chosen by a comptime if, named nowhere
const builtin = @import("builtin");
const backend = if (builtin.os.tag == .windows) @import("windows.zig") else @import("posix.zig");
pub const ready = builtin.is_test;
