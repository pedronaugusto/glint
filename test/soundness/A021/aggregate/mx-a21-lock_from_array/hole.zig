// matrix: A021 aggregate: two locks put in an array literal and taken from it by index, both held
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    const locks = [_]*L{ a, b };
    var ga = locks[0].acquire();
    defer ga.deinit();
    var gb = locks[1].acquire();
    defer gb.deinit();
}
