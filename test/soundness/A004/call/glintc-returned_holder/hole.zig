// A004: Checked's bare value, its holder a call's result, given to a comparison: a finding.
const aegis = @import("aegis");
const C = aegis.int.Checked(u32);
const S = struct {
    c: C,
    fn get(self: *const S) C {
        return self.c;
    }
};
pub fn f(s: *const S) bool {
    return s.get().raw() > 3;
}
