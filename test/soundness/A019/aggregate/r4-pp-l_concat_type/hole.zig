// review 4: pp/l_concat_type.zig
const std = @import("std");
const Conn = struct { id: u32, node: std.DoublyLinkedList.Node = .{} };
const Other = struct { node: std.DoublyLinkedList.Node = .{}, tag: u8 };
const Pool = struct {
    free: std.DoublyLinkedList = .{},
    busy: std.DoublyLinkedList = .{},
    fn take(p: *Pool) ?*Conn {
        const n = p.free.popFirst() orelse return null;
        return @fieldParentPtr("node", n);
    }
};
pub fn run(p: *Pool, c: *Conn, o: *Other) u32 {
    p.free.append(&c.node);
    p.busy.append(&o.node);
    std.DoublyLinkedList.concatByMoving(&p.free, &p.busy);
    var total: u32 = 0;
    while (p.take()) |got| total += got.id;
    return total;
}
