// matrix: A021 field: the second lock taken through @field naming acquire, while the first guard is held
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    var ga = a.acquire();
    defer ga.deinit();
    var gb = @field(L, "acquire")(b);
    defer gb.deinit();
}
