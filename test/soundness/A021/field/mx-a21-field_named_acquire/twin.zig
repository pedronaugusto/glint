// matrix: A021 field: the lock taken through @field naming acquire, released before the second is taken
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    var ga = @field(L, "acquire")(a);
    ga.deinit();
    var gb = b.acquire();
    defer gb.deinit();
}
