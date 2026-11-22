// P009: the callee keeps the slice it loads through the pointer, which points at the caller's
// buffer; the pointer to the local is never kept.
const E = struct {
    next: []u8 = &.{},
    fn take(e: *E, out: *[]u8) void {
        e.next = out.*;
        out.* = out.*[1..];
    }
};
pub fn write(e: *E, buf: []u8) usize {
    var room = buf;
    e.take(&room);
    return buf.len - room.len;
}
