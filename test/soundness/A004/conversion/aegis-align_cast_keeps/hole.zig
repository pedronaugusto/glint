// A scalar's integer read through a pointer cast whose operand is an @alignCast of its
// address: the cast keeps what the pointer points at, the scalar, so its raw integer escapes.
const aegis = @import("aegis");
const Index = aegis.id.Id(struct {}, u16);
pub fn f(i: *const Index) u16 {
    const raw: *const u16 = @ptrCast(@alignCast(i));
    return raw.* + 1;
}
