// Z052 twin: the same done the way the rule leaves
const S = struct { f: u8 };
pub fn fieldType() type {
    const x: S = undefined;
    return @TypeOf(x.f);
}
