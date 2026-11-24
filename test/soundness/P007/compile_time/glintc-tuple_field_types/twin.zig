// P007: an anytype tuple's field types read off its type, and its elements by index: a tuple
// literal's parts, no pointer (shakedown's FaultIo, review b9).
const std = @import("std");
const Io = std.Io;
const F = struct {
    fn subjectOf(f: *F, comptime name: []const u8, args: anytype) u64 {
        _ = f;
        _ = name;
        const fields = @typeInfo(@TypeOf(args)).@"struct".field_types;
        if (fields.len == 0) return 0;
        if (fields[0] == Io.File) return @intCast(args[0].handle);
        if (fields[0] == []const Io.File) return if (args[0].len > 0) @intCast(args[0][0].handle) else 0;
        return 0;
    }
    noinline fn slow(f: *F, comptime name: []const u8, args: anytype) u64 {
        return f.subjectOf(name, args);
    }
    fn dispatch(userdata: ?*anyopaque, file: Io.File) u64 {
        const f: *F = @ptrCast(@alignCast(userdata));
        return f.slow("fileClose", .{file});
    }
    fn many(userdata: ?*anyopaque, files: []const Io.File) u64 {
        const f: *F = @ptrCast(@alignCast(userdata));
        return f.slow("fileCloseMany", .{files});
    }
};
fn workingDirectory(args: anytype) @TypeOf(args) {
    var local = args;
    inline for (0..args.len) |i| {
        if (@TypeOf(args[i]) == Io.Dir and args[i].handle == Io.Dir.cwd().handle) local[i] = Io.Dir.cwd();
    }
    return local;
}
pub fn entry(u: ?*anyopaque, file: Io.File, files: []const Io.File, d: Io.Dir) u64 {
    _ = workingDirectory(.{ d, 3 });
    return F.dispatch(u, file) + F.many(u, files);
}
