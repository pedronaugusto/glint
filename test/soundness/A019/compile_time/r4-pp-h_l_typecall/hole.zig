// review 4: pp/h_l_typecall.zig
const std = @import("std");
const Conn = struct { id: u32, node: std.DoublyLinkedList.Node = .{} };
const Other = struct { node: std.DoublyLinkedList.Node = .{}, tag: u8 };
const Pool = struct {
    free: std.DoublyLinkedList = .{},
    fn put(p: *Pool, c: *Conn) void {
        p.free.append(&c.node);
    }
    fn take(p: *Pool) ?*Conn {
        const n = p.free.popFirst() orelse return null;
        return @fieldParentPtr("node", n);
    }
};
pub fn run(p: *Pool, c: *Conn, o: *Other) u32 {
    p.put(c);
    std.DoublyLinkedList.append(&p.free, &o.node);
    var total: u32 = 0;
    while (p.take()) |got| total += got.id;
    return total;
}
