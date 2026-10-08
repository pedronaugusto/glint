//! Pure inherited spelling policy; never used as semantic resolution.
const std = @import("std");
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

/// Returns true if the identifier has an underscore prefix (but not just `_` or `__`).
pub fn hasUnderscorePrefix(name: []const u8) bool {
    if (name.len < 2) return false;
    if (name[0] != '_') return false;
    // Allow `__` double-underscore prefix (e.g., `__builtin`)
    if (name[1] == '_') return false;
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

fn toLowercase(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

/// Words that are considered redundant in identifier names per the Zig style guide.
const redundant_words = [_][]const u8{
    "Value",
    "Data",
    "Context",
    "Manager",
    "State",
    "utils",
    "misc",
    "Util",
    "Utils",
    "Misc",
};

/// Checks if a name contains a redundant word and returns it if found.
pub fn findRedundantWord(name: []const u8) ?[]const u8 {
    // Check if the name contains any redundant word as a complete word boundary
    for (redundant_words) |word| {
        if (containsWordBoundary(name, word)) {
            return word;
        }
    }
    return null;
}

/// Returns true if name contains word at a word boundary (start, end, or camelCase boundary).
fn containsWordBoundary(name: []const u8, word: []const u8) bool {
    if (word.len > name.len) return false;

    // Check if name equals word exactly
    if (std.mem.eql(u8, name, word)) return true;

    // Check if name starts with word followed by uppercase or end
    if (std.mem.startsWith(u8, name, word)) {
        if (word.len == name.len) return true;
        const next = name[word.len];
        // Word boundary: followed by uppercase (camelCase) or non-alpha
        if (isUppercase(next) or (!isLowercase(next) and !isUppercase(next))) return true;
    }

    // Check if name ends with word preceded by lowercase
    if (std.mem.endsWith(u8, name, word) and name.len > word.len) {
        const prev = name[name.len - word.len - 1];
        if (isLowercase(prev)) return true;
    }

    // Check for word in middle with camelCase boundaries
    var i: usize = 1;
    while (i + word.len <= name.len) {
        if (std.mem.startsWith(u8, name[i..], word)) {
            const prev = name[i - 1];
            // Must be preceded by lowercase (camelCase boundary)
            if (isLowercase(prev)) {
                if (i + word.len == name.len) return true;
                const next = name[i + word.len];
                // Must be followed by uppercase or non-alpha
                if (isUppercase(next) or (!isLowercase(next) and !isUppercase(next))) return true;
            }
        }
        i += 1;
    }

    return false;
}
