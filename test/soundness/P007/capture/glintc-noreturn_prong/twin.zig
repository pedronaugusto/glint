// P007: fields of a switch's value whose other prong is a block that never completes: the
// block gives no value, and the fields are the capture's (conduit's supervisor, review b9).
const std = @import("std");
const builtin = @import("builtin");
const Prepared = struct { signals: i32, children: i32 };
const Preparation = union(enum) { ready: Prepared, failed: u16 };
fn prepare() Preparation {
    return .{ .ready = .{ .signals = 3, .children = -1 } };
}
fn prepareFreeBsd() Preparation {
    return .{ .failed = 1 };
}
fn close(fd: i32) void {
    _ = fd;
}
pub fn run() void {
    const prepared = switch (if (comptime builtin.target.os.tag == .linux) prepare() else prepareFreeBsd()) {
        .ready => |prepared| prepared,
        .failed => |errno| {
            _ = errno;
            std.process.exit(127);
        },
    };
    close(prepared.signals);
    if (prepared.children >= 0) close(prepared.children);
}
