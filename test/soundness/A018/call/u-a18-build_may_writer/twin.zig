// A018 in a build script: an error's name given to the build's own calls, which may hold a
// writer only through what does not resolve, reaches no peer.
const std = @import("std");
pub fn build(b: *std.Build) void {
    explain(b, error.Missing);
}
fn explain(b: *std.Build, err: anyerror) void {
    const text = b.fmt("failed: {s}", .{@errorName(err)});
    _ = b.addSystemCommand(&.{ "echo", text });
}
