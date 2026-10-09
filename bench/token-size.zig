//! Identical standalone size driver for either fact provider.
const std = @import("std");
const facts = @import("facts");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.ExpectedSourcePath;
    const source = try std.Io.Dir.cwd().readFileAllocOptions(init.io, args[1], a, .unlimited, .of(u8), 0);
    var scratch = std.heap.ArenaAllocator.init(init.gpa);
    defer scratch.deinit();
    const count = if (comptime @hasDecl(facts, "scanSentinel")) (try facts.scanSentinel(scratch.allocator(), source, null)).imports.len else (try facts.recover(scratch.allocator(), source)).specs.len;
    var buffer: [128]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buffer);
    try out.interface.print("imports={d}\n", .{count});
    try out.interface.flush();
}
