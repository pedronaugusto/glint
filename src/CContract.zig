//! A019's contracts for functions outside the program that write through a pointer they are
//! given: which parameters each writes, and for which results, as the system's own header or
//! documentation states it. A function is found by its external symbol (every `extern fn` of
//! that symbol, std's or the program's, is the one the linker binds), or for std's own system
//! calls, by declaration. A function in no entry writes nothing that A019 can see: what is
//! handed to it is read there.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Governed = @import("Governed.zig");
const Ast = std.zig.Ast;

/// The results on which the parameters are written.
pub const Success = union(enum) {
    /// 0; anything else (-1 with `errno`, an `NTSTATUS` or `HRESULT` other than success) writes
    /// nothing.
    zero,
    /// Not 0: a Windows `BOOL` that is not `FALSE`.
    nonzero,
    /// Greater than 0: `waitpid` of one process, which answers its id.
    positive,
    /// The size the call was given at that parameter: a `proc_pidinfo` that filled the buffer.
    size: usize,
    /// A count of 0 or more: the parameter is written for that many of its elements, a prefix
    /// `buf[0..n]` reads (-1 on failure is no count: converting it stops a safe build).
    count,
    /// `errno(result)` is `.SUCCESS`: std's raw Linux calls, which answer a `usize`.
    errno,
    /// The length of all it was given: one of std's counts that filled what it was handed
    /// (`readSliceShort`), its result tested against that length.
    length,
};

/// The errno decoder whose `.SUCCESS` shows a call did not fail.
pub const Errno = enum {
    /// None does: the result is the error number itself (`posix_spawn`), a status, a `BOOL`, a
    /// process id, or a size; `errno(result)` is `.SUCCESS` also where it failed.
    none,
    /// std's `c.errno` or `posix.errno`: the C library's calls that answer -1 on failure.
    c,
    /// std's `os.linux.errno`: std's raw Linux calls, which answer the negated error number.
    linux,
};

pub const Entry = struct {
    /// The external symbol, or with `std`, the path of std's declaration.
    name: []const u8,
    std: bool = false,
    /// The parameters written, by position (0 first).
    writes: []const usize,
    /// For each of `writes`, what it points at as the header declares it, named as std names it:
    /// a primitive (`c_int`), std's declaration (`c.Stat`), or `[n]T`, with `|` between the
    /// names it may be spelled by. A count's is its element's. A local handed whole is written
    /// whole only where its own type is one of these: the call writes that type's size at the
    /// local's address, whatever the program's own `extern` says it points at. A `size` entry's
    /// is "", its size given.
    types: []const []const u8,
    success: Success,
    errno: Errno = .none,
};

/// Each from the header or the documentation of the function it names.
pub const entries = [_]Entry{
    // <unistd.h> read: the number of bytes read into buf, or -1.
    .{ .name = "read", .writes = &.{1}, .types = &.{"u8"}, .success = .count, .errno = .c },
    // <sys/socket.h> recvfrom: the length of the message received into buf, or -1.
    .{ .name = "recvfrom", .writes = &.{1}, .types = &.{"u8"}, .success = .count, .errno = .c },
    // <sys/wait.h> waitpid: the process id whose status it stored, 0 under WNOHANG with none
    // ready, or -1; `status` is written only for a process answered.
    .{ .name = "waitpid", .writes = &.{1}, .types = &.{"c_int"}, .success = .positive },
    // <sys/resource.h> getrlimit: 0, the limits stored; or -1.
    .{ .name = "getrlimit", .writes = &.{1}, .types = &.{"c.rlimit"}, .success = .zero, .errno = .c },
    // <signal.h> sigaction: 0, the previous action stored in oact; or -1.
    .{ .name = "sigaction", .writes = &.{2}, .types = &.{"c.Sigaction"}, .success = .zero, .errno = .c },
    // <sys/stat.h> fstat, fstatat: 0, the status stored in buf; or -1. Darwin's 64-bit inode
    // symbols name the same calls.
    .{ .name = "fstat", .writes = &.{1}, .types = &.{"c.Stat"}, .success = .zero, .errno = .c },
    .{ .name = "fstat$INODE64", .writes = &.{1}, .types = &.{"c.Stat"}, .success = .zero, .errno = .c },
    .{ .name = "fstatat", .writes = &.{2}, .types = &.{"c.Stat"}, .success = .zero, .errno = .c },
    .{ .name = "fstatat$INODE64", .writes = &.{2}, .types = &.{"c.Stat"}, .success = .zero, .errno = .c },
    // <time.h> clock_gettime: 0, the time stored in tp; or -1.
    .{ .name = "clock_gettime", .writes = &.{1}, .types = &.{"c.timespec"}, .success = .zero, .errno = .c },
    // <sys/event.h> kevent64: the number of events placed in eventlist, or -1.
    .{ .name = "kevent64", .writes = &.{3}, .types = &.{"c.kevent64_s"}, .success = .count, .errno = .c },
    // <spawn.h> posix_spawn: 0, the child's id stored in pid; an error number otherwise.
    .{ .name = "posix_spawn", .writes = &.{0}, .types = &.{"c.pid_t|c_int"}, .success = .zero },
    // <spawn.h> the initializers: 0, the object initialized; an error number otherwise.
    .{ .name = "posix_spawn_file_actions_init", .writes = &.{0}, .types = &.{"c.posix_spawn_file_actions_t"}, .success = .zero },
    .{ .name = "posix_spawnattr_init", .writes = &.{0}, .types = &.{"c.posix_spawnattr_t"}, .success = .zero },
    // <libproc.h> proc_pidinfo: the bytes it filled, the buffer's whole size when it answered.
    .{ .name = "proc_pidinfo", .writes = &.{3}, .types = &.{""}, .success = .{ .size = 4 } },
    // <libproc.h> proc_pidpath: the length of the path placed in buffer, 0 or less on failure.
    .{ .name = "proc_pidpath", .writes = &.{1}, .types = &.{"u8"}, .success = .count },
    // <libproc.h> proc_listchildpids, proc_listpgrppids: the number of ids placed in buffer, or
    // less than 0.
    .{ .name = "proc_listchildpids", .writes = &.{1}, .types = &.{"c.pid_t|c_int"}, .success = .count },
    .{ .name = "proc_listpgrppids", .writes = &.{1}, .types = &.{"c.pid_t|c_int"}, .success = .count },
    // <processthreadsapi.h> GetExitCodeProcess: nonzero, the code stored in lpExitCode.
    .{ .name = "GetExitCodeProcess", .writes = &.{1}, .types = &.{"os.windows.DWORD|u32"}, .success = .nonzero },
    // <handleapi.h> DuplicateHandle: nonzero, the duplicate stored in lpTargetHandle.
    .{ .name = "DuplicateHandle", .writes = &.{3}, .types = &.{"os.windows.HANDLE"}, .success = .nonzero },
    // <namedpipeapi.h> CreatePipe: nonzero, both handles stored.
    .{ .name = "CreatePipe", .writes = &.{ 0, 1 }, .types = &.{ "os.windows.HANDLE", "os.windows.HANDLE" }, .success = .nonzero },
    // <consoleapi.h> GetConsoleMode: nonzero, the mode stored.
    .{ .name = "GetConsoleMode", .writes = &.{1}, .types = &.{"os.windows.DWORD|u32"}, .success = .nonzero },
    // <processthreadsapi.h> CreateProcessW: nonzero, lpProcessInformation filled.
    .{ .name = "CreateProcessW", .writes = &.{9}, .types = &.{"os.windows.PROCESS.INFORMATION"}, .success = .nonzero },
    // ntdll's NtOpenFile and NtCreateNamedPipeFile: STATUS_SUCCESS (0), the handle and the I/O
    // status block stored.
    .{ .name = "NtOpenFile", .writes = &.{ 0, 3 }, .types = &.{ "os.windows.HANDLE", "os.windows.IO_STATUS_BLOCK" }, .success = .zero },
    .{ .name = "NtCreateNamedPipeFile", .writes = &.{ 0, 3 }, .types = &.{ "os.windows.HANDLE", "os.windows.IO_STATUS_BLOCK" }, .success = .zero },
    // std's raw Linux calls: an errno of SUCCESS, the result stored (statx's buffer, both
    // socket descriptors); getdents64 the number of bytes of entries placed in dirp.
    .{ .name = "os.linux.statx", .std = true, .writes = &.{4}, .types = &.{"os.linux.Statx"}, .success = .errno, .errno = .linux },
    .{ .name = "os.linux.socketpair", .std = true, .writes = &.{3}, .types = &.{"[2]os.linux.fd_t|[2]i32"}, .success = .errno, .errno = .linux },
    .{ .name = "os.linux.getdents64", .std = true, .writes = &.{1}, .types = &.{"u8"}, .success = .count, .errno = .linux },
};

/// The entry for `decl` that writes its parameter `index`.
pub fn find(c: *Context, decl: Facts.Decl, index: usize) Context.Error!?*const Entry {
    const symbol = externSymbol(c, decl);
    for (&entries) |*entry| {
        if (std.mem.findScalar(usize, entry.writes, index) == null) continue;
        if (!entry.std) {
            if (symbol) |name| if (std.mem.eql(u8, name, entry.name)) return entry;
            continue;
        }
        for ((try Governed.declarations(c, "std", entry.name)) orelse &.{}) |found| {
            const origin = (try c.facts.origin(found)) orelse found;
            if (std.meta.eql(origin, decl)) return entry;
        }
    }
    return null;
}

/// The symbol an `extern fn` declaration binds: its name, or its spelled `@"…"` one.
fn externSymbol(c: *Context, decl: Facts.Decl) ?[]const u8 {
    const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    if (record.kind != .function) return null;
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, record.node) orelse return null;
    const token = proto.extern_export_inline_token orelse return null;
    if (tree.tokenTag(token) != .keyword_extern) return null;
    const name = proto.name_token orelse return null;
    const spelled = tree.tokenSlice(name);
    if (spelled.len >= 3 and spelled[0] == '@' and spelled[1] == '"') return spelled[2 .. spelled.len - 1];
    return spelled;
}
