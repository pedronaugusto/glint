// review 4: pp/l_singly.zig
const std = @import("std");
const Conn = struct { id: u32, node: std.SinglyLinkedList.Node = .{} };
const Other = struct { node: std.SinglyLinkedList.Node = .{}, tag: u8 };
const Pool = struct {
    free: std.SinglyLinkedList = .{},
    busy: std.SinglyLinkedList = .{},
    fn take(p: *Pool) ?*Conn {
        const n = p.free.popFirst() orelse return null;
        return @fieldParentPtr("node", n);
    }
};
pub fn run(p: *Pool, c: *Conn, o: *Other) u32 {
    p.free.prepend(&c.node);
    p.busy.prepend(&o.node);
    c.node.next = p.busy.first;
    var total: u32 = 0;
    while (p.take()) |got| total += got.id;
    return total;
}
