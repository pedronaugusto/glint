// warp-fast: the same switch whose other arm never returns (aegis.assert.never), as `unreachable`
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
    closed,
    pub fn dir(p: *Parent) Io.Dir {
        return switch (p.*) {
            .owned => |*d| d.borrow().*,
            .lent => |d| d,
            .closed => aegis.assert.never("closed"),
        };
    }
};
