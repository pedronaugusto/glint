// A004: Checked's bare value, its holder a call's result, handed on whole: none.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
const S = struct {
    c: C,
    fn get(self: *const S) C {
        return self.c;
    }
};
pub fn f(s: *const S) u32 {
    return s.get().raw();
}
