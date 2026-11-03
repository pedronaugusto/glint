// glint-b: A003 assignment (a std handle stored, then closed): the store copies the handle and the local closes it once, which is no second cleanup; whether the job's copy is closed again is not known here, so it stays undecided (open), never a finding
const std = @import("std");
const Io = std.Io;
const Job = struct { file: Io.File };
pub fn f(job: *Job, dir: Io.Dir, io: Io) !void {
    const fresh = try dir.openFile(io, "build.zig", .{});
    job.file = fresh;
    fresh.close(io);
}
