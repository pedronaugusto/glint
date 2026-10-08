//! Pure inherited spelling policy; never used as semantic resolution.
pub fn isValidFunctionName(name: []const u8) bool {
    if (name.len == 0) return false;
    // Must start with lowercase letter
    if (name[0] >= 'A' and name[0] <= 'Z') return false;
    // Leading underscore is allowed (private/internal convention)
    if (name[0] == '_') return true;

    // No underscores allowed in camelCase (except leading)
    for (name) |c| {
        if (c == '_') return false;
    }

    return true;
}

pub fn isPascalCase(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] < 'A' or name[0] > 'Z') return false;
    for (name) |c| {
        if (c == '_') return false;
    }
    return true;
}

pub fn isSnakeCase(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '_') return true;
    for (name) |c| {
        if (c >= 'A' and c <= 'Z') return false;
    }
    return true;
}

/// A leading underscore is metadata pretending to be a semantic name.
pub fn hasUnderscorePrefix(name: []const u8) bool {
    if (name.len < 2) return false;
    if (name[0] != '_') return false;
    return true;
}

/// The inherited naming policy, not a semantic type fact.
pub fn acronymIssue(name: []const u8) bool {
    var i: usize = 0;
    while (i < name.len) {
        if (!isUppercase(name[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < name.len and isUppercase(name[i])) i += 1;
        const length = i - start;
        if (length >= 2 and (i == name.len or !isLowercase(name[i]) or length > 2)) return true;
    }
    return false;
}

fn isUppercase(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isLowercase(c: u8) bool {
    return c >= 'a' and c <= 'z';
}
