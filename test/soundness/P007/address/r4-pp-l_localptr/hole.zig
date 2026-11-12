// review 4: pp/l_localptr.zig
const std = @import("std");
const Conn = struct { id: u32, node: std.DoublyLinkedList.Node = .{} };
const Other = struct { node: std.DoublyLinkedList.Node = .{}, tag: u8 };
const Pool = struct {
    free: std.DoublyLinkedList = .{},
    fn sum(p: *Pool, o: *Other) u32 {
        var total: u32 = 0;
        var it = p.free.first;
        const alias = &it;
        alias.* = &o.node;
        while (it) |n| : (it = n.next) {
            const c: *Conn = @fieldParentPtr("node", n);
            total += c.id;
        }
        return total;
    }
};
pub fn run(p: *Pool, c: *Conn, o: *Other) u32 {
    p.free.append(&c.node);
    return p.sum(o);
}
