const std = @import("std");
const impl = @import("impl.zig");

pub const syncFile = impl.syncFile;

pub const lint_rules = .{
    .version = 1,
    .replaces = .{.{ .std = std.Io.File.sync, .with = syncFile, .why = "durability belongs to syncFile" }},
};
