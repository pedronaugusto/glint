const std = @import("std");

pub fn syncFile(file: std.Io.File, io: std.Io) !void {
    try file.sync(io);
}

pub const lint_rules = .{
    .version = 2,
    .rules = .{
        .{ .id = .X001, .name = "governed state", .kind = .ban, .reads = .governed, .default = true, .purpose = "a governed type's internal fields, literals naming them, casts and reflection are the package's alone" },
        .{ .id = .X002, .name = "replaced", .kind = .ban, .reads = .replaces, .default = true, .purpose = "a declaration the package's answer stands for, outside a seam" },
        .{ .id = .X003, .name = "bare value", .kind = .hygiene, .reads = .exits, .default = true, .purpose = "a governed type's bare value given straight to arithmetic, a comparison or a narrowing cast" },
    },
    .replaces = .{.{ .rule = .X002, .decl = std.Io.File.sync, .with = syncFile, .why = "durability belongs to syncFile" }},
};
