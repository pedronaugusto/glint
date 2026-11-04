// P006 field: names read off a const type, used on that const: its own fields
const S = struct { async: u8 };
pub fn f(s: S) void {
    const X = S;
    const names = @typeInfo(X).@"struct".field_names;
    inline for (names) |name| _ = @field(@as(X, s), name);
}
