// A018 in a build script: an error's name the build panics with goes to the developer's
// terminal, whatever the panic's writer holds through what does not resolve.
const std = @import("std");
pub fn build(b: *std.Build) void {
    const sources = listSources(b) catch |err| std.debug.panic("src/ could not be listed: {t}", .{err});
    const exe = b.addExecutable(.{ .name = "tool", .root_module = b.createModule(.{ .root_source_file = b.path("tool.zig"), .target = b.graph.host }) });
    const run = b.addRunArtifact(exe);
    for (sources) |source| run.addFileArg(source);
    b.getInstallStep().dependOn(&run.step);
}
fn listSources(b: *std.Build) ![]const std.Build.LazyPath {
    const io = b.graph.io;
    var dir = try b.root.openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(b.allocator);
    defer walker.deinit();
    var list: std.ArrayList(std.Build.LazyPath) = .empty;
    while (try walker.next(io)) |entry| try list.append(b.allocator, b.path(b.fmt("src/{s}", .{entry.path})));
    return list.items;
}
