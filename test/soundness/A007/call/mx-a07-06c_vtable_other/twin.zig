// matrix A007: a call through Io's vtable to what is no synchronization.
const std = @import("std");
pub fn poll(io: std.Io) std.Io.Cancelable!void {
    try io.vtable.checkCancel(io.userdata);
}
