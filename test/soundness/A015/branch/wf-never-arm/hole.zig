// warp-fast: a switch whose other arm opens a directory: what it returns may be an owner handed over
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
pub const Dir = aegis.own.OwnedIo(Io.Dir, closeDir);
fn closeDir(d: *Io.Dir, io: Io) void {
    d.close(io);
}
pub const Parent = union(enum) {
    owned: Dir,
    lent: Io.Dir,
    closed: Io.Dir,
    pub fn dir(p: *Parent, io: Io) !Io.Dir {
        return switch (p.*) {
            .owned => |*d| d.borrow().*,
            .lent => |d| d,
            .closed => |d| try d.openDir(io, ".", .{}),
        };
    }
};
