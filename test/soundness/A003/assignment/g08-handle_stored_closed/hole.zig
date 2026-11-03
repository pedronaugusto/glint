// glint-b: A003 assignment (a std handle stored, then closed): the local is closed twice after its copy is stored, so it must flag or stay undecided
const std = @import("std");
const Io = std.Io;
const Job = struct { file: Io.File };
pub fn f(job: *Job, dir: Io.Dir, io: Io) !void {
    const fresh = try dir.openFile(io, "build.zig", .{});
    job.file = fresh;
    fresh.close(io);
    fresh.close(io);
}
