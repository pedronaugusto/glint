// Z005: a result type that does not resolve (a member of what a caller hands) is no type
// glint can show: silent (8d).
pub fn first(items: anytype) @TypeOf(items).Item {
    return items.first();
}
