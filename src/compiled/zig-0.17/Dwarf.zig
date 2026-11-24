//! The DWARF Zig 0.17's self-hosted x86_64 backend writes into an ELF binary, read as untrusted
//! input: the debugging entries glint asks about (declarations, their instances, types, members,
//! locals, parameters, inlined calls) and the line programs' file tables that name their files.
//! Keyed by std.dwarf's constants, Zig's own extensions among them (`ZIG_parent`,
//! `ZIG_comptime_value`, `ZIG_decl_line_relative`): a Zig release changes what this reads only
//! where std.dwarf does, and a reader for it is a directory of its own beside this one. Every
//! count and offset is checked against the bytes it reads; a file that breaks one is refused
//! whole. Lexical blocks are read through: an entry's parent is its nearest entry kept.
const std = @import("std");
const aegis = @import("aegis");
const Tag = std.dwarf.TAG;
const Attribute = std.dwarf.AT;
const Form = std.dwarf.FORM;
const Dwarf = @This();

/// The sections' bytes, owned: names point into them.
sections: Sections,
/// The entries kept, in the order of their offsets in `.debug_info`.
entries: std.MultiArrayList(Entry),
/// Each entry's offset in `.debug_info`, ascending, in order with `entries`: a reference's target
/// is found by it (`at`).
offsets: []const u32,
/// Each compilation unit, in order.
units: []const Unit,
/// How many entries named their line relative to another (`ZIG_decl_line_relative`) or their
/// call's (`ZIG_call_line_relative`): read as offsets from that entry's line (`relative`).
relative_lines: usize,

pub const Error = error{ InvalidDebugInfo, NotElf64, CompressedSection, MissingSection, OutOfMemory };

/// What an entry is, as glint reads it.
pub const Kind = enum(u8) {
    unit,
    module,
    subprogram,
    parameter,
    variable,
    constant,
    comptime_value,
    member,
    structure,
    @"union",
    enumeration,
    enumerator,
    variant_part,
    variant,
    pointer,
    @"const",
    @"volatile",
    typedef,
    array,
    base,
    subroutine,
    inlined,
    /// A declaration whose value is another's: a type alias, a function or namespace alias,
    /// an import (`const std = @import("std")`).
    imported,

    fn of(tag: u64) ?Kind {
        return switch (tag) {
            Tag.compile_unit => .unit,
            Tag.module => .module,
            Tag.subprogram => .subprogram,
            Tag.formal_parameter => .parameter,
            Tag.variable => .variable,
            Tag.constant => .constant,
            Tag.ZIG_comptime_value => .comptime_value,
            Tag.member => .member,
            Tag.structure_type => .structure,
            Tag.union_type => .@"union",
            Tag.enumeration_type => .enumeration,
            Tag.enumerator => .enumerator,
            Tag.variant_part => .variant_part,
            Tag.variant => .variant,
            Tag.pointer_type => .pointer,
            Tag.const_type => .@"const",
            Tag.volatile_type => .@"volatile",
            Tag.typedef => .typedef,
            Tag.array_type => .array,
            Tag.base_type => .base,
            Tag.subroutine_type => .subroutine,
            Tag.inlined_subroutine => .inlined,
            Tag.imported_declaration => .imported,
            else => null,
        };
    }
};

/// No entry: a reference, a parent or a line that is absent.
pub const none = std.math.maxInt(u32);

/// One entry kept. A reference is the target's offset in `.debug_info` (`at` finds its index);
/// a line or column is 1-based, 0 where absent; a file is an index into its unit's `files`.
pub const Entry = struct {
    kind: Kind,
    /// The nearest kept entry enclosing it, by index; `none` for a unit.
    parent: u32,
    unit: u32,
    name: []const u8,
    type: u32 = none,
    /// The container that declares it (`ZIG_parent`).
    zig_parent: u32 = none,
    abstract_origin: u32 = none,
    specification: u32 = none,
    file: u32 = none,
    line: u32 = 0,
    column: u32 = 0,
    call_line: u32 = 0,
    call_column: u32 = 0,
    /// The entry its line is relative to (`ZIG_relative_decl`), where it states one.
    relative_decl: u32 = none,
    /// It has machine code: a function instance compiled (`low_pc`).
    code: bool = false,
    /// A parameter whose value is fixed at compile time (`const_expr`).
    comptime_known: bool = false,
    /// A declaration, defined elsewhere (`declaration`).
    declaration: bool = false,
};

pub const Unit = struct {
    /// The unit's entry, by index.
    entry: u32,
    /// The files its entries name (`decl_file`, `call_file`), by index: a directory joined to a
    /// name, as its line program writes them.
    files: []const []const u8,
};

const Sections = struct {
    info: []const u8,
    abbrev: []const u8,
    str: []const u8,
    line: []const u8,
    line_str: []const u8,
};

/// The DWARF of the ELF binary `bytes`, the caller's input read whole (glint's input seam reads
/// the file; this parses it). `gpa` holds everything the result names, copied out of `bytes`
/// and freed by `deinit`: `bytes` may go once this returns.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) Error!Dwarf {
    var sections = try readSections(gpa, bytes);
    errdefer freeSections(gpa, &sections);
    var dwarf: Dwarf = .{ .sections = sections, .entries = .empty, .offsets = &.{}, .units = &.{}, .relative_lines = 0 };
    errdefer dwarf.entries.deinit(gpa);
    try dwarf.decode(gpa);
    return dwarf;
}

pub fn deinit(dwarf: *Dwarf, gpa: std.mem.Allocator) void {
    for (dwarf.units) |unit| {
        for (unit.files) |file_path| gpa.free(file_path);
        gpa.free(unit.files);
    }
    gpa.free(dwarf.units);
    gpa.free(dwarf.offsets);
    dwarf.entries.deinit(gpa);
    freeSections(gpa, &dwarf.sections);
}

/// The index of the entry at `offset` in `.debug_info`, or null where none kept is there.
pub fn at(dwarf: *const Dwarf, offset: u32) ?u32 {
    if (offset == none) return null;
    const index = std.sort.lowerBound(u32, dwarf.offsets, offset, orderU32);
    if (index >= dwarf.offsets.len or dwarf.offsets[index] != offset) return null;
    return @intCast(index); // safe: offsets has one per entry, and entries are counted in u32
}

fn orderU32(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

/// The path of the file an entry of `unit` names by `index`, or null where its table has none.
pub fn path(dwarf: *const Dwarf, unit: u32, index: u32) ?[]const u8 {
    if (unit >= dwarf.units.len) return null;
    const files = dwarf.units[unit].files;
    return if (index < files.len and files[index].len != 0) files[index] else null;
}

// --- ELF ---------------------------------------------------------------------------------------

const section_compressed = 0x800;

fn readSections(gpa: std.mem.Allocator, bytes: []const u8) Error!Sections {
    if (bytes.len < 64) return error.NotElf64;
    const header = bytes[0..64];
    if (!std.mem.eql(u8, header[0..4], "\x7fELF") or header[4] != 2 or header[5] != 1) return error.NotElf64;
    const shoff = std.mem.readInt(u64, header[0x28..0x30], .little);
    const shentsize = std.mem.readInt(u16, header[0x3a..0x3c], .little);
    const shnum = std.mem.readInt(u16, header[0x3c..0x3e], .little);
    const shstrndx = std.mem.readInt(u16, header[0x3e..0x40], .little);
    if (shentsize < 64 or shnum == 0 or shstrndx >= shnum) return error.InvalidDebugInfo;
    const table_len = std.math.mul(u64, shentsize, shnum) catch return error.InvalidDebugInfo;
    if (shoff > bytes.len or table_len > bytes.len - shoff) return error.InvalidDebugInfo;
    const table = bytes[@intCast(shoff)..][0..@intCast(table_len)]; // safe: within bytes, checked above
    const names = try sectionIn(bytes, table, shentsize, shstrndx);
    var found: [5]?[]u8 = .{ null, null, null, null, null };
    var found_at: [5]u16 = undefined;
    errdefer for (found) |held| if (held) |b| gpa.free(b);
    const wanted = [5][]const u8{ ".debug_info", ".debug_abbrev", ".debug_str", ".debug_line", ".debug_line_str" };
    for (0..shnum) |index| {
        const entry = table[index * shentsize ..][0..64];
        const name_offset = std.mem.readInt(u32, entry[0..4], .little);
        if (name_offset >= names.len) return error.InvalidDebugInfo;
        const name = std.mem.sliceTo(names[name_offset..], 0);
        for (wanted, &found, &found_at) |want, *slot, *slot_at| {
            if (!std.mem.eql(u8, name, want)) continue;
            if (slot.* != null) return error.InvalidDebugInfo;
            slot.* = try gpa.dupe(u8, try sectionIn(bytes, table, shentsize, @intCast(index))); // safe: below shnum, a u16
            slot_at.* = @intCast(index); // safe: below shnum, a u16
        }
    }
    // A relocatable object (`build-obj`) leaves the offsets its DWARF names between sections (a
    // unit's line program, a string) to its relocations: the bytes hold zero, as Zig's
    // self-hosted backend writes them. A linked binary has none to apply.
    for (0..shnum) |index| {
        const entry = table[index * shentsize ..][0..64];
        if (std.mem.readInt(u32, entry[4..8], .little) != section_rela) continue;
        const target = std.mem.readInt(u32, entry[44..48], .little);
        const symbols = std.mem.readInt(u32, entry[40..44], .little);
        for ([_]usize{ 0, 3 }) |slot| {
            const section = found[slot] orelse continue;
            if (target != found_at[slot]) continue;
            if (symbols >= shnum) return error.InvalidDebugInfo;
            const rela = try sectionIn(bytes, table, shentsize, @intCast(index)); // safe: below shnum, a u16
            const symtab = try sectionIn(bytes, table, shentsize, @intCast(symbols)); // safe: below shnum, checked above
            try relocate(section, rela, symtab);
        }
    }
    const info = found[0] orelse return error.MissingSection;
    const abbrev = found[1] orelse return error.MissingSection;
    const line = found[3] orelse return error.MissingSection;
    return .{ .info = info, .abbrev = abbrev, .str = found[2] orelse try gpa.alloc(u8, 0), .line = line, .line_str = found[4] orelse try gpa.alloc(u8, 0) };
}

const section_rela = 4;
const rela_size = 24;
const symbol_size = 24;
const r_x86_64_64 = 1;
const r_x86_64_32 = 10;
const r_x86_64_32s = 11;

/// Applies `rela`'s relocations to `bytes`, each the symbol's value (in `symtab`) plus its
/// addend, written at its offset: x86_64's absolute 64-bit, 32-bit and signed 32-bit ones, the
/// kinds the DWARF's offsets and addresses take. Another kind relocates nothing this reads (a
/// location expression's code address) and is left. A relocation out of `bytes`, of a symbol
/// `symtab` lacks, or whose value does not fit its width refuses the file.
fn relocate(bytes: []u8, rela: []const u8, symtab: []const u8) Error!void {
    if (rela.len % rela_size != 0 or symtab.len % symbol_size != 0) return error.InvalidDebugInfo;
    var next: usize = 0;
    while (next < rela.len) : (next += rela_size) {
        const offset = std.mem.readInt(u64, rela[next..][0..8], .little);
        const info = std.mem.readInt(u64, rela[next + 8 ..][0..8], .little);
        const addend = std.mem.readInt(i64, rela[next + 16 ..][0..8], .little);
        const kind: u32 = @truncate(info); // safe: an ELF64 relocation's type is its info's low 32 bits
        const width: usize = switch (kind) {
            r_x86_64_64 => 8,
            r_x86_64_32, r_x86_64_32s => 4,
            else => continue,
        };
        const symbol = info >> 32;
        if (symbol >= symtab.len / symbol_size) return error.InvalidDebugInfo;
        if (offset > bytes.len or width > bytes.len - offset) return error.InvalidDebugInfo;
        const value_at = @as(usize, @intCast(symbol)) * symbol_size + 8; // safe: below the table's length, checked above
        const symbol_value = std.mem.readInt(u64, symtab[value_at..][0..8], .little);
        const value = @as(i128, symbol_value) + addend;
        const place = bytes[@intCast(offset)..][0..width]; // safe: within bytes, checked above
        switch (kind) {
            r_x86_64_64 => std.mem.writeInt(u64, place[0..8], std.math.cast(u64, value) orelse return error.InvalidDebugInfo, .little),
            r_x86_64_32 => std.mem.writeInt(u32, place[0..4], std.math.cast(u32, value) orelse return error.InvalidDebugInfo, .little),
            else => std.mem.writeInt(i32, place[0..4], std.math.cast(i32, value) orelse return error.InvalidDebugInfo, .little),
        }
    }
}

test "a relocatable object's offsets are its relocations' symbol values plus addends" {
    var bytes: [12]u8 = @splat(0);
    // Symbol 1's value is 0x10: a section symbol's is 0, a function's its offset.
    var symtab: [2 * symbol_size]u8 = @splat(0);
    std.mem.writeInt(u64, symtab[symbol_size + 8 ..][0..8], 0x10, .little);
    var rela: [2 * rela_size]u8 = @splat(0);
    // A 32-bit offset at 0 to symbol 0 plus 0x31 (a line string), a 64-bit address at 4 to symbol 1 plus 2.
    std.mem.writeInt(u64, rela[8..16], r_x86_64_32, .little);
    std.mem.writeInt(i64, rela[16..24], 0x31, .little);
    std.mem.writeInt(u64, rela[rela_size..][0..8], 4, .little);
    std.mem.writeInt(u64, rela[rela_size + 8 ..][0..8], (1 << 32) | r_x86_64_64, .little);
    std.mem.writeInt(i64, rela[rela_size + 16 ..][0..8], 2, .little);
    try relocate(&bytes, &rela, &symtab);
    try std.testing.expectEqual(@as(u32, 0x31), std.mem.readInt(u32, bytes[0..4], .little));
    try std.testing.expectEqual(@as(u64, 0x12), std.mem.readInt(u64, bytes[4..12], .little));
    // One past the bytes, or of a symbol the table lacks, refuses the file.
    std.mem.writeInt(u64, rela[0..8], 9, .little);
    try std.testing.expectError(error.InvalidDebugInfo, relocate(&bytes, &rela, &symtab));
    std.mem.writeInt(u64, rela[0..8], 0, .little);
    std.mem.writeInt(u64, rela[8..16], (2 << 32) | r_x86_64_32, .little);
    try std.testing.expectError(error.InvalidDebugInfo, relocate(&bytes, &rela, &symtab));
}

/// The bytes of section `index` of `table`, within `bytes`.
fn sectionIn(bytes: []const u8, table: []const u8, shentsize: u16, index: u16) Error![]const u8 {
    const entry = table[@as(usize, index) * shentsize ..][0..64];
    const flags = std.mem.readInt(u64, entry[8..16], .little);
    if (flags & section_compressed != 0) return error.CompressedSection;
    const offset = std.mem.readInt(u64, entry[24..32], .little);
    const size = std.mem.readInt(u64, entry[32..40], .little);
    if (offset > bytes.len or size > bytes.len - offset) return error.InvalidDebugInfo;
    return bytes[@intCast(offset)..][0..@intCast(size)]; // safe: within bytes, checked above
}

fn freeSections(gpa: std.mem.Allocator, sections: *Sections) void {
    gpa.free(sections.info);
    gpa.free(sections.abbrev);
    gpa.free(sections.str);
    gpa.free(sections.line);
    gpa.free(sections.line_str);
}

// --- bytes -------------------------------------------------------------------------------------

/// A cursor over one section's bytes; every read checks what is left.
const Cursor = struct {
    bytes: []const u8,
    at: usize,

    fn byte(c: *Cursor) error{InvalidDebugInfo}!u8 {
        if (c.at >= c.bytes.len) return error.InvalidDebugInfo;
        defer c.at += 1;
        return c.bytes[c.at];
    }

    fn fixed(c: *Cursor, comptime T: type) error{InvalidDebugInfo}!T {
        const n = @divExact(@bitSizeOf(T), 8);
        if (c.bytes.len - c.at < n) return error.InvalidDebugInfo;
        defer c.at += n;
        return std.mem.readInt(T, c.bytes[c.at..][0..n], .little);
    }

    fn sized(c: *Cursor, n: u8) error{InvalidDebugInfo}!u64 {
        return switch (n) {
            1 => try c.byte(),
            2 => try c.fixed(u16),
            3 => try c.fixed(u24),
            4 => try c.fixed(u32),
            8 => try c.fixed(u64),
            else => error.InvalidDebugInfo,
        };
    }

    fn skip(c: *Cursor, n: u64) error{InvalidDebugInfo}!void {
        if (n > c.bytes.len - c.at) return error.InvalidDebugInfo;
        c.at += @intCast(n); // safe: at most what is left, checked above
    }

    fn uleb(c: *Cursor) error{InvalidDebugInfo}!u64 {
        var result: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = try c.byte();
            if (shift < 64) result |= @as(u64, b & 0x7f) << @intCast(shift); // safe: below 64
            if (b & 0x80 == 0) return result;
            shift += 7;
            if (shift > 70) return error.InvalidDebugInfo;
        }
    }

    fn sleb(c: *Cursor) error{InvalidDebugInfo}!i64 {
        var result: i64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = try c.byte();
            if (shift < 64) result |= @as(i64, b & 0x7f) << @intCast(shift); // safe: below 64
            shift += 7;
            if (b & 0x80 == 0) {
                if (shift < 64 and b & 0x40 != 0) result |= @as(i64, -1) << @intCast(shift); // safe: below 64
                return result;
            }
            if (shift > 70) return error.InvalidDebugInfo;
        }
    }

    fn cString(c: *Cursor) error{InvalidDebugInfo}![]const u8 {
        const end = std.mem.findScalarPos(u8, c.bytes, c.at, 0) orelse return error.InvalidDebugInfo;
        defer c.at = end + 1;
        return c.bytes[c.at..end];
    }
};

fn stringAt(bytes: []const u8, offset: u64) error{InvalidDebugInfo}![]const u8 {
    if (offset >= bytes.len) return error.InvalidDebugInfo;
    const start: usize = @intCast(offset); // safe: below the section's length, checked above
    const end = std.mem.findScalarPos(u8, bytes, start, 0) orelse return error.InvalidDebugInfo;
    return bytes[start..end];
}

// --- abbreviations -----------------------------------------------------------------------------

const Spec = struct { attribute: u64, form: u64, implicit: i64 };
const Abbrev = struct { tag: u64, children: bool, specs: []const Spec };
const Table = std.AutoHashMapUnmanaged(u64, Abbrev);

/// Caps on what one file may declare: past them it is refused, never read on.
const max_specs = 256;
const max_files = 1 << 20;

fn readTable(arena: std.mem.Allocator, abbrev: []const u8, offset: u64) Error!Table {
    if (offset >= abbrev.len) return error.InvalidDebugInfo;
    var c: Cursor = .{ .bytes = abbrev, .at = @intCast(offset) }; // safe: below the section's length
    var table: Table = .empty;
    while (true) {
        const code = try c.uleb();
        if (code == 0) return table;
        const tag = try c.uleb();
        const children = try c.byte();
        var specs: std.ArrayList(Spec) = .empty;
        while (true) {
            const attribute = try c.uleb();
            const form = try c.uleb();
            const implicit: i64 = if (form == Form.implicit_const) try c.sleb() else 0;
            if (attribute == 0 and form == 0) break;
            if (specs.items.len == max_specs) return error.InvalidDebugInfo;
            try specs.append(arena, .{ .attribute = attribute, .form = form, .implicit = implicit });
        }
        try table.put(arena, code, .{ .tag = tag, .children = children != 0, .specs = specs.items });
    }
}

// --- entries -----------------------------------------------------------------------------------

const Value = union(enum) { none, unsigned: u64, signed: i64, reference: u64, string: []const u8, flag: bool };

const Format = struct { offset_size: u8, address_size: u8, unit_start: u64, version: u16 };

fn readValue(d: *const Dwarf, c: *Cursor, form_in: u64, implicit: i64, format: Format) Error!Value {
    var form = form_in;
    var hops: u8 = 0;
    while (form == Form.indirect) : (hops += 1) {
        if (hops == 8) return error.InvalidDebugInfo;
        form = try c.uleb();
    }
    return switch (form) {
        Form.addr => .{ .unsigned = try c.sized(format.address_size) },
        Form.data1, Form.ref1, Form.flag, Form.strx1, Form.addrx1 => readPlain(form, try c.byte(), format),
        Form.data2, Form.ref2, Form.strx2, Form.addrx2 => readPlain(form, try c.fixed(u16), format),
        Form.strx3, Form.addrx3 => readPlain(form, try c.fixed(u24), format),
        Form.data4, Form.ref4, Form.ref_sup4, Form.strx4, Form.addrx4 => readPlain(form, try c.fixed(u32), format),
        Form.data8, Form.ref8, Form.ref_sig8, Form.ref_sup8 => readPlain(form, try c.fixed(u64), format),
        Form.data16 => blk: {
            try c.skip(16);
            break :blk .none;
        },
        Form.udata, Form.ref_udata, Form.strx, Form.addrx, Form.loclistx, Form.rnglistx => readPlain(form, try c.uleb(), format),
        Form.sdata => .{ .signed = try c.sleb() },
        Form.implicit_const => .{ .signed = implicit },
        Form.flag_present => .{ .flag = true },
        Form.string => .{ .string = try c.cString() },
        Form.strp => .{ .string = try stringAt(d.sections.str, try c.sized(format.offset_size)) },
        Form.line_strp => .{ .string = try stringAt(d.sections.line_str, try c.sized(format.offset_size)) },
        Form.ref_addr => .{ .reference = try c.sized(if (format.version <= 2) format.address_size else format.offset_size) },
        Form.sec_offset, Form.strp_sup, Form.GNU_strp_alt, Form.GNU_ref_alt => .{ .unsigned = try c.sized(format.offset_size) },
        Form.block1 => skipBlock(c, try c.byte()),
        Form.block2 => skipBlock(c, try c.fixed(u16)),
        Form.block4 => skipBlock(c, try c.fixed(u32)),
        Form.block, Form.exprloc => skipBlock(c, try c.uleb()),
        else => error.InvalidDebugInfo,
    };
}

fn readPlain(form: u64, raw: u64, format: Format) Value {
    return switch (form) {
        Form.ref1, Form.ref2, Form.ref4, Form.ref8, Form.ref_udata => .{ .reference = format.unit_start +% raw },
        Form.flag => .{ .flag = raw != 0 },
        // An index into tables this reader does not hold: what it names is not read.
        Form.strx, Form.strx1, Form.strx2, Form.strx3, Form.strx4, Form.ref_sig8, Form.ref_sup4, Form.ref_sup8 => .none,
        else => .{ .unsigned = raw },
    };
}

fn skipBlock(c: *Cursor, n: u64) error{InvalidDebugInfo}!Value {
    try c.skip(n);
    return .none;
}

fn offset32(value: u64) error{InvalidDebugInfo}!u32 {
    return aegis.int.narrow(u32, value) orelse return error.InvalidDebugInfo;
}

fn small(value: Value) error{InvalidDebugInfo}!u32 {
    return switch (value) {
        .unsigned => |v| aegis.int.narrow(u32, v) orelse error.InvalidDebugInfo,
        .signed => |v| if (v < 0) error.InvalidDebugInfo else aegis.int.narrow(u32, @as(u64, @intCast(v))) orelse error.InvalidDebugInfo, // safe: not negative, checked
        else => 0,
    };
}

fn decode(d: *Dwarf, gpa: std.mem.Allocator) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tables: std.AutoHashMapUnmanaged(u64, Table) = .empty;
    var offsets: std.ArrayList(u32) = .empty;
    errdefer offsets.deinit(gpa);
    var units: std.ArrayList(Unit) = .empty;
    errdefer {
        for (units.items) |unit| {
            for (unit.files) |p| gpa.free(p);
            gpa.free(unit.files);
        }
        units.deinit(gpa);
    }
    // Lines relative to another entry, resolved once every entry is read.
    var relative: std.ArrayList(struct { entry: u32, base: u32, delta: i64, call: bool }) = .empty;
    const info = d.sections.info;
    var c: Cursor = .{ .bytes = info, .at = 0 };
    if (info.len >= none) return error.InvalidDebugInfo;
    while (c.at < info.len) {
        const unit_start = c.at;
        var length: u64 = try c.fixed(u32);
        var offset_size: u8 = 4;
        if (length == 0xffff_ffff) {
            length = try c.fixed(u64);
            offset_size = 8;
        }
        if (length > info.len - c.at) return error.InvalidDebugInfo;
        const unit_end = c.at + @as(usize, @intCast(length)); // safe: at most what is left, checked above
        const version = try c.fixed(u16);
        var address_size: u8 = undefined;
        var abbrev_offset: u64 = undefined;
        if (version >= 5) {
            const unit_type = try c.byte();
            address_size = try c.byte();
            abbrev_offset = try c.sized(offset_size);
            switch (unit_type) {
                std.dwarf.UT.compile, std.dwarf.UT.partial => {},
                std.dwarf.UT.skeleton, std.dwarf.UT.split_compile => try c.skip(8),
                std.dwarf.UT.type, std.dwarf.UT.split_type => try c.skip(8 + @as(u64, offset_size)),
                else => return error.InvalidDebugInfo,
            }
        } else if (version >= 2) {
            abbrev_offset = try c.sized(offset_size);
            address_size = try c.byte();
        } else return error.InvalidDebugInfo;
        const format: Format = .{ .offset_size = offset_size, .address_size = address_size, .unit_start = unit_start, .version = version };
        const table = blk: {
            const got = try tables.getOrPut(arena, abbrev_offset);
            if (!got.found_existing) got.value_ptr.* = try readTable(arena, d.sections.abbrev, abbrev_offset);
            break :blk got.value_ptr.*;
        };
        const unit_index = aegis.int.narrow(u32, units.items.len) orelse return error.InvalidDebugInfo;
        // The kept entry enclosing each depth: `none` above the unit.
        var stack: std.ArrayList(u32) = .empty;
        var unit_entry: u32 = none;
        var stmt_list: ?u64 = null;
        var unit_dir: []const u8 = "";
        var unit_c: Cursor = .{ .bytes = info[0..unit_end], .at = c.at };
        while (unit_c.at < unit_end) {
            const die_offset = try offset32(unit_c.at);
            const code = try unit_c.uleb();
            if (code == 0) {
                if (stack.items.len > 0) _ = stack.pop();
                continue;
            }
            const abbrev = table.get(code) orelse return error.InvalidDebugInfo;
            const kind = Kind.of(abbrev.tag);
            var entry: Entry = .{ .kind = kind orelse .unit, .parent = if (stack.items.len > 0) stack.items[stack.items.len - 1] else none, .unit = unit_index, .name = "" };
            var line_relative: ?i64 = null;
            var call_relative: ?i64 = null;
            for (abbrev.specs) |spec| {
                const value = try d.readValue(&unit_c, spec.form, spec.implicit, format);
                if (kind == null) continue;
                switch (spec.attribute) {
                    Attribute.name => if (value == .string) {
                        entry.name = value.string;
                    },
                    Attribute.type => if (value == .reference) {
                        entry.type = try offset32(value.reference);
                    },
                    Attribute.ZIG_parent => if (value == .reference) {
                        entry.zig_parent = try offset32(value.reference);
                    },
                    Attribute.abstract_origin => if (value == .reference) {
                        entry.abstract_origin = try offset32(value.reference);
                    },
                    Attribute.specification => if (value == .reference) {
                        entry.specification = try offset32(value.reference);
                    },
                    Attribute.ZIG_relative_decl => if (value == .reference) {
                        entry.relative_decl = try offset32(value.reference);
                    },
                    Attribute.decl_file => entry.file = if (value == .unsigned) try small(value) else none,
                    Attribute.decl_line => entry.line = try small(value),
                    Attribute.decl_column => entry.column = try small(value),
                    Attribute.call_line => entry.call_line = try small(value),
                    Attribute.call_column => entry.call_column = try small(value),
                    Attribute.ZIG_decl_line_relative => line_relative = signedOf(value),
                    Attribute.ZIG_call_line_relative => call_relative = signedOf(value),
                    Attribute.low_pc => entry.code = value != .none,
                    Attribute.const_expr => entry.comptime_known = value == .flag and value.flag,
                    Attribute.declaration => entry.declaration = value == .flag and value.flag,
                    Attribute.stmt_list => if (kind == .unit and value == .unsigned) {
                        stmt_list = value.unsigned;
                    },
                    Attribute.comp_dir => if (kind == .unit and value == .string) {
                        unit_dir = value.string;
                    },
                    else => {},
                }
            }
            var kept: u32 = none;
            if (kind) |_| {
                kept = aegis.int.narrow(u32, d.entries.len) orelse return error.InvalidDebugInfo;
                try d.entries.append(gpa, entry);
                try offsets.append(gpa, die_offset);
                if (entry.kind == .unit) unit_entry = kept;
                if (line_relative) |delta| try relative.append(arena, .{ .entry = kept, .base = if (entry.relative_decl != none) entry.relative_decl else entry.zig_parent, .delta = delta, .call = false });
                if (call_relative) |delta| try relative.append(arena, .{ .entry = kept, .base = none, .delta = delta, .call = true });
            }
            if (abbrev.children) {
                // A kept entry encloses its children; one not kept (a lexical block) is read through.
                try stack.append(arena, if (kind != null) kept else entry.parent);
            }
        }
        c.at = unit_end;
        if (unit_entry == none) return error.InvalidDebugInfo;
        const files = if (stmt_list) |list| try readFiles(gpa, d.sections, list, offset_size, unit_dir) else try gpa.alloc([]const u8, 0);
        units.append(gpa, .{ .entry = unit_entry, .files = files }) catch |err| {
            for (files) |p| gpa.free(p);
            gpa.free(files);
            return err;
        };
    }
    d.offsets = try offsets.toOwnedSlice(gpa);
    d.units = try units.toOwnedSlice(gpa);
    const lines = d.entries.items(.line);
    const call_lines = d.entries.items(.call_line);
    const parents = d.entries.items(.parent);
    for (relative.items) |r| {
        // A call's line is relative to the function it is inlined into, a declaration's to the
        // one it names or its container.
        const base_index: ?u32 = if (r.call) enclosingFunction(d, parents[r.entry]) else d.at(r.base);
        const base_line: i64 = if (base_index) |b| lines[b] else 0;
        const line = base_line + r.delta;
        if (line <= 0 or line > std.math.maxInt(u32)) continue;
        if (r.call) call_lines[r.entry] = @intCast(line) else lines[r.entry] = @intCast(line); // safe: between 1 and u32's max, checked above
        d.relative_lines += 1;
    }
}

fn signedOf(value: Value) ?i64 {
    return switch (value) {
        .signed => |v| v,
        .unsigned => |v| if (v <= std.math.maxInt(i64)) @intCast(v) else null, // safe: at most i64's max, checked
        else => null,
    };
}

fn enclosingFunction(d: *const Dwarf, start: u32) ?u32 {
    const kinds = d.entries.items(.kind);
    const parents = d.entries.items(.parent);
    var index = start;
    var hops: usize = 0;
    while (index != none and hops < 4096) : (hops += 1) {
        if (kinds[index] == .subprogram or kinds[index] == .inlined) return index;
        index = parents[index];
    }
    return null;
}

// --- line programs' file tables ----------------------------------------------------------------

const LineContent = std.dwarf.LNCT;

/// The file table of the line program at `offset`: index 0 is the unit's own file from
/// DWARF 5, nothing before it.
fn readFiles(gpa: std.mem.Allocator, s: Sections, offset: u64, unit_offset_size: u8, comp_dir: []const u8) Error![]const []const u8 {
    _ = unit_offset_size;
    if (offset >= s.line.len) return error.InvalidDebugInfo;
    var c: Cursor = .{ .bytes = s.line, .at = @intCast(offset) }; // safe: below the section's length
    var length: u64 = try c.fixed(u32);
    var offset_size: u8 = 4;
    if (length == 0xffff_ffff) {
        length = try c.fixed(u64);
        offset_size = 8;
    }
    if (length > s.line.len - c.at) return error.InvalidDebugInfo;
    c.bytes = s.line[0 .. c.at + @as(usize, @intCast(length))]; // safe: at most what is left
    const version = try c.fixed(u16);
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    if (version >= 5) {
        try c.skip(2); // address size, segment selector size
        _ = try c.sized(offset_size); // header length
        try c.skip(4); // minimum instruction length, maximum operations, default is_stmt, line base
        try c.skip(1); // line range
        const opcode_base = try c.byte();
        if (opcode_base == 0) return error.InvalidDebugInfo;
        try c.skip(opcode_base - 1);
        var directories: std.ArrayList([]const u8) = .empty;
        defer directories.deinit(gpa);
        try readEntries(gpa, s, &c, offset_size, &directories, null);
        try readEntries(gpa, s, &c, offset_size, &paths, directories.items);
    } else if (version >= 2) {
        _ = try c.sized(offset_size); // header length
        try c.skip(if (version >= 4) 5 else 4);
        const opcode_base = try c.byte();
        if (opcode_base == 0) return error.InvalidDebugInfo;
        try c.skip(opcode_base - 1);
        var directories: std.ArrayList([]const u8) = .empty;
        defer directories.deinit(gpa);
        try directories.append(gpa, comp_dir);
        while (true) {
            const dir = try c.cString();
            if (dir.len == 0) break;
            if (directories.items.len == max_files) return error.InvalidDebugInfo;
            try directories.append(gpa, dir);
        }
        // DWARF 4 counts its files from 1.
        try paths.append(gpa, try gpa.alloc(u8, 0));
        while (true) {
            const name = try c.cString();
            if (name.len == 0) break;
            const dir = try c.uleb();
            _ = try c.uleb();
            _ = try c.uleb();
            if (paths.items.len == max_files) return error.InvalidDebugInfo;
            const full = try joined(gpa, if (dir < directories.items.len) directories.items[@intCast(dir)] else "", name); // safe: below the list's length
            paths.append(gpa, full) catch |err| {
                gpa.free(full);
                return err;
            };
        }
    } else return error.InvalidDebugInfo;
    return paths.toOwnedSlice(gpa);
}

/// A DWARF 5 entry list: its formats, then its entries. With `directories`, each entry is a
/// file, its path joined to its directory; without, a directory's path, not copied.
fn readEntries(gpa: std.mem.Allocator, s: Sections, c: *Cursor, offset_size: u8, out: *std.ArrayList([]const u8), directories: ?[]const []const u8) Error!void {
    const format_count = try c.byte();
    var formats: [16]struct { content: u64, form: u64 } = undefined;
    if (format_count > formats.len) return error.InvalidDebugInfo;
    for (formats[0..format_count]) |*f| f.* = .{ .content = try c.uleb(), .form = try c.uleb() };
    const count = try c.uleb();
    if (count > max_files) return error.InvalidDebugInfo;
    for (0..@intCast(count)) |_| { // safe: at most max_files
        var name: []const u8 = "";
        var dir_index: u64 = 0;
        for (formats[0..format_count]) |f| {
            const v: Value = switch (f.form) {
                Form.string => .{ .string = try c.cString() },
                Form.line_strp => .{ .string = try stringAt(s.line_str, try c.sized(offset_size)) },
                Form.strp => .{ .string = try stringAt(s.str, try c.sized(offset_size)) },
                Form.udata => .{ .unsigned = try c.uleb() },
                Form.data1 => .{ .unsigned = try c.byte() },
                Form.data2 => .{ .unsigned = try c.fixed(u16) },
                Form.data4 => .{ .unsigned = try c.fixed(u32) },
                Form.data8 => .{ .unsigned = try c.fixed(u64) },
                Form.data16 => blk: {
                    try c.skip(16);
                    break :blk .none;
                },
                Form.block => skipBlock(c, try c.uleb()) catch return error.InvalidDebugInfo,
                else => return error.InvalidDebugInfo,
            };
            switch (f.content) {
                LineContent.path => if (v == .string) {
                    name = v.string;
                },
                LineContent.directory_index => if (v == .unsigned) {
                    dir_index = v.unsigned;
                },
                else => {},
            }
        }
        if (directories) |dirs| {
            // A directory other than the first, relative, is relative to the first: the unit's.
            const dir = if (dir_index < dirs.len) dirs[@intCast(dir_index)] else ""; // safe: below the list's length
            const base = if (dir_index != 0 and dirs.len > 0 and !std.fs.path.isAbsolute(dir)) dirs[0] else "";
            const p = try joinedIn(gpa, base, dir, name);
            out.append(gpa, p) catch |err| {
                gpa.free(p);
                return err;
            };
        } else try out.append(gpa, name);
    }
}

/// `name` in `dir` in `base`, normalized: whichever is absolute starts it.
fn joinedIn(gpa: std.mem.Allocator, base: []const u8, dir: []const u8, name: []const u8) error{OutOfMemory}![]u8 {
    if (std.fs.path.isAbsolute(name)) return std.fs.path.resolveAllocPosix(gpa, &.{name});
    if (base.len == 0) return joined(gpa, dir, name);
    return std.fs.path.resolveAllocPosix(gpa, &.{ base, dir, name });
}

/// `dir` joined to `name`, normalized; `name` alone where it is absolute.
fn joined(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) error{OutOfMemory}![]u8 {
    if (std.fs.path.isAbsolute(name) or dir.len == 0) return std.fs.path.resolveAllocPosix(gpa, &.{name});
    return std.fs.path.resolveAllocPosix(gpa, &.{ dir, name });
}

// --- tests -------------------------------------------------------------------------------------

/// Bytes being built for a test: an ELF file of the sections given.
const Builder = struct {
    bytes: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn deinit(b: *Builder) void {
        b.bytes.deinit(b.gpa);
    }
    fn u(b: *Builder, value: u64) !void {
        var v = value;
        while (true) {
            const low: u8 = @truncate(v & 0x7f); // safe: the low seven bits
            v >>= 7;
            if (v == 0) return b.bytes.append(b.gpa, low);
            try b.bytes.append(b.gpa, low | 0x80);
        }
    }
    fn s(b: *Builder, value: i64) !void {
        var v = value;
        while (true) {
            const low: u8 = @truncate(@as(u64, @bitCast(v)) & 0x7f); // safe: the low seven bits
            v >>= 7;
            const done = (v == 0 and low & 0x40 == 0) or (v == -1 and low & 0x40 != 0);
            if (done) return b.bytes.append(b.gpa, low);
            try b.bytes.append(b.gpa, low | 0x80);
        }
    }
    fn int(b: *Builder, comptime T: type, value: T) !void {
        var buffer: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buffer, value, .little);
        try b.bytes.appendSlice(b.gpa, &buffer);
    }
    fn str(b: *Builder, text: []const u8) !void {
        try b.bytes.appendSlice(b.gpa, text);
        try b.bytes.append(b.gpa, 0);
    }
    fn patch32(b: *Builder, at_offset: usize, value: u32) void {
        std.mem.writeInt(u32, b.bytes.items[at_offset..][0..4], value, .little);
    }
};

/// An ELF file holding a DWARF 5 unit: a file struct `s` (file 0) declaring a struct `List`
/// (line 3) with a member `len` of type `usize`, a method `first` (line 5, ZIG_parent `List`,
/// with code) whose comptime parameter `n` is a `usize` and whose local `x`, inside a lexical
/// block, is a `usize`, and a declaration `width` whose line is `List`'s plus 7; an instance
/// `Box(u32)` (line 9) with a member `value` of type `usize` and a method `get` returning one;
/// a tagged union `Shape` (line 11) whose variant part holds its tag and the fields `circle`
/// and `square`; and `alias`, a declaration of `s` whose value is another's.
fn sample(gpa: std.mem.Allocator) ![]u8 {
    var abbrev: Builder = .{ .gpa = gpa };
    defer abbrev.deinit();
    const Attr = struct { u64, u64 };
    const abbrevs = [_]struct { u64, bool, []const Attr }{
        .{ Tag.compile_unit, true, &.{ .{ Attribute.name, Form.string }, .{ Attribute.stmt_list, Form.sec_offset }, .{ Attribute.comp_dir, Form.string } } },
        .{ Tag.base_type, false, &.{.{ Attribute.name, Form.string }} },
        .{ Tag.structure_type, true, &.{ .{ Attribute.name, Form.string }, .{ Attribute.decl_file, Form.udata } } },
        .{ Tag.structure_type, true, &.{ .{ Attribute.name, Form.string }, .{ Attribute.ZIG_parent, Form.ref4 }, .{ Attribute.decl_line, Form.udata } } },
        .{ Tag.member, false, &.{ .{ Attribute.name, Form.string }, .{ Attribute.type, Form.ref4 } } },
        .{ Tag.subprogram, true, &.{ .{ Attribute.name, Form.string }, .{ Attribute.ZIG_parent, Form.ref4 }, .{ Attribute.decl_line, Form.udata }, .{ Attribute.low_pc, Form.addr } } },
        .{ Tag.formal_parameter, false, &.{ .{ Attribute.name, Form.string }, .{ Attribute.type, Form.ref4 }, .{ Attribute.const_expr, Form.flag_present } } },
        .{ Tag.lexical_block, true, &.{} },
        .{ Tag.variable, false, &.{ .{ Attribute.name, Form.string }, .{ Attribute.type, Form.ref4 } } },
        .{ Tag.constant, false, &.{ .{ Attribute.name, Form.string }, .{ Attribute.ZIG_parent, Form.ref4 }, .{ Attribute.ZIG_relative_decl, Form.ref4 }, .{ Attribute.ZIG_decl_line_relative, Form.sdata } } },
        .{ Tag.subprogram, false, &.{ .{ Attribute.name, Form.string }, .{ Attribute.ZIG_parent, Form.ref4 }, .{ Attribute.type, Form.ref4 } } },
        .{ Tag.union_type, true, &.{ .{ Attribute.name, Form.string }, .{ Attribute.ZIG_parent, Form.ref4 }, .{ Attribute.decl_line, Form.udata } } },
        .{ Tag.variant_part, true, &.{.{ Attribute.discr, Form.ref4 }} },
        .{ Tag.variant, true, &.{.{ Attribute.discr_value, Form.udata }} },
        .{ Tag.imported_declaration, false, &.{ .{ Attribute.name, Form.string }, .{ Attribute.ZIG_parent, Form.ref4 } } },
    };
    for (abbrevs, 1..) |a, code| {
        try abbrev.u(code);
        try abbrev.u(a[0]);
        try abbrev.bytes.append(gpa, @intFromBool(a[1]));
        for (a[2]) |attr| {
            try abbrev.u(attr[0]);
            try abbrev.u(attr[1]);
        }
        try abbrev.u(0);
        try abbrev.u(0);
    }
    try abbrev.u(0);

    var info: Builder = .{ .gpa = gpa };
    defer info.deinit();
    try info.int(u32, 0); // length, patched
    try info.int(u16, 5);
    try info.bytes.append(gpa, std.dwarf.UT.compile);
    try info.bytes.append(gpa, 8);
    try info.int(u32, 0); // abbrev offset
    try info.u(1);
    try info.str("s.zig");
    try info.int(u32, 0); // stmt_list
    try info.str("/pkg");
    const usize_at: u32 = @intCast(info.bytes.items.len); // safe: a test's few bytes
    try info.u(2);
    try info.str("usize");
    const file_at: u32 = @intCast(info.bytes.items.len); // safe: a test's few bytes
    try info.u(3);
    try info.str("s");
    try info.u(0);
    const list_at: u32 = @intCast(info.bytes.items.len); // safe: a test's few bytes
    try info.u(4);
    try info.str("s.List");
    try info.int(u32, file_at);
    try info.u(3);
    try info.u(5);
    try info.str("len");
    try info.int(u32, usize_at);
    try info.u(0); // end of List
    // A type function's instance: Zig names it with its arguments, at the line of the
    // structure the function returns.
    const box_at: u32 = @intCast(info.bytes.items.len); // safe: a test's few bytes
    try info.u(4);
    try info.str("s.Box(u32)");
    try info.int(u32, file_at);
    try info.u(9);
    try info.u(5);
    try info.str("value");
    try info.int(u32, usize_at);
    try info.u(0); // end of Box(u32)
    // Its method, in the instance: what it returns.
    try info.u(11);
    try info.str("get");
    try info.int(u32, box_at);
    try info.int(u32, usize_at);
    // A tagged union: its tag, the discriminant of its variant part, and a field in each variant.
    try info.u(12);
    try info.str("s.Shape");
    try info.int(u32, file_at);
    try info.u(11);
    const part_at: u32 = @intCast(info.bytes.items.len); // safe: a test's few bytes
    try info.u(13);
    try info.int(u32, part_at + 5); // the tag, the part's first child: its code and reference before it
    try info.u(5);
    try info.str("tag");
    try info.int(u32, usize_at);
    for ([_][]const u8{ "circle", "square" }, 0..) |field, value| {
        try info.u(14);
        try info.u(value);
        try info.u(5);
        try info.str(field);
        try info.int(u32, usize_at);
        try info.u(0); // end of the variant
    }
    try info.u(0); // end of the variant part
    try info.u(0); // end of Shape
    try info.u(6);
    try info.str("first");
    try info.int(u32, list_at);
    try info.u(5);
    try info.int(u64, 0x1000);
    try info.u(7);
    try info.str("n");
    try info.int(u32, usize_at);
    try info.u(8); // lexical block
    try info.u(9);
    try info.str("x");
    try info.int(u32, usize_at);
    try info.u(0); // end of block
    try info.u(0); // end of first
    try info.u(10);
    try info.str("width");
    try info.int(u32, file_at);
    try info.int(u32, list_at);
    try info.s(7);
    // An alias: Zig names the declaration and its container, its value another's.
    try info.u(15);
    try info.str("alias");
    try info.int(u32, file_at);
    try info.u(0); // end of s
    try info.u(0); // end of unit
    info.patch32(0, @intCast(info.bytes.items.len - 4)); // safe: a test's few bytes

    var line: Builder = .{ .gpa = gpa };
    defer line.deinit();
    try line.int(u32, 0); // length, patched
    try line.int(u16, 5);
    try line.bytes.append(gpa, 8);
    try line.bytes.append(gpa, 0);
    try line.int(u32, 0); // header length, unread
    try line.bytes.appendSlice(gpa, &.{ 1, 1, 1, 0xfb, 14, 13 });
    try line.bytes.appendSlice(gpa, &.{ 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1 });
    try line.bytes.append(gpa, 1); // directory formats
    try line.u(LineContent.path);
    try line.u(Form.string);
    try line.u(2);
    try line.str("/pkg");
    try line.str("src");
    try line.bytes.append(gpa, 2); // file formats
    try line.u(LineContent.path);
    try line.u(Form.string);
    try line.u(LineContent.directory_index);
    try line.u(Form.udata);
    try line.u(2);
    try line.str("s.zig");
    try line.u(1);
    try line.str("other.zig");
    try line.u(0);
    line.patch32(0, @intCast(line.bytes.items.len - 4)); // safe: a test's few bytes

    const names = "\x00.shstrtab\x00.debug_info\x00.debug_abbrev\x00.debug_line\x00";
    const contents = [_]struct { u32, []const u8 }{ .{ 1, names }, .{ 11, info.bytes.items }, .{ 23, abbrev.bytes.items }, .{ 37, line.bytes.items } };
    var elf: Builder = .{ .gpa = gpa };
    defer elf.deinit();
    try elf.bytes.appendSlice(gpa, &.{ 0x7f, 'E', 'L', 'F', 2, 1, 1, 0 });
    try elf.bytes.appendNTimes(gpa, 0, 64 - 8);
    var placed: [contents.len]u64 = undefined;
    for (contents, &placed) |content, *offset| {
        offset.* = elf.bytes.items.len;
        try elf.bytes.appendSlice(gpa, content[1]);
    }
    const shoff = elf.bytes.items.len;
    try elf.bytes.appendNTimes(gpa, 0, 64); // the null section
    for (contents, placed) |content, offset| {
        try elf.int(u32, content[0]);
        try elf.bytes.appendNTimes(gpa, 0, 20);
        try elf.int(u64, offset);
        try elf.int(u64, content[1].len);
        try elf.bytes.appendNTimes(gpa, 0, 24);
    }
    std.mem.writeInt(u64, elf.bytes.items[0x28..0x30], shoff, .little);
    std.mem.writeInt(u16, elf.bytes.items[0x3a..0x3c], 64, .little);
    std.mem.writeInt(u16, elf.bytes.items[0x3c..0x3e], contents.len + 1, .little);
    std.mem.writeInt(u16, elf.bytes.items[0x3e..0x40], 1, .little);
    return elf.bytes.toOwnedSlice(gpa);
}

fn readBytes(bytes: []const u8) Error!Dwarf {
    return parse(std.testing.allocator, bytes);
}

fn find(d: *const Dwarf, name: []const u8) ?u32 {
    for (d.entries.items(.name), 0..) |n, index| if (std.mem.eql(u8, n, name)) return @intCast(index); // safe: entries are counted in u32
    return null;
}

test "an ELF's DWARF: declarations, their container, members, parameters, a block's local read through, a relative line and the file table" {
    const gpa = std.testing.allocator;
    const bytes = try sample(gpa);
    defer gpa.free(bytes);
    var d = try readBytes(bytes);
    defer d.deinit(gpa);
    const e = d.entries.slice();
    const list = find(&d, "s.List").?;
    const first = find(&d, "first").?;
    try std.testing.expectEqual(Kind.structure, e.items(.kind)[list]);
    try std.testing.expectEqual(@as(u32, 3), e.items(.line)[list]);
    try std.testing.expectEqual(list, d.at(e.items(.zig_parent)[first]).?);
    try std.testing.expect(e.items(.code)[first]);
    const len = find(&d, "len").?;
    try std.testing.expectEqual(list, e.items(.parent)[len]);
    try std.testing.expectEqualStrings("usize", e.items(.name)[d.at(e.items(.type)[len]).?]);
    const n = find(&d, "n").?;
    try std.testing.expect(e.items(.comptime_known)[n]);
    try std.testing.expectEqual(first, e.items(.parent)[n]);
    // The block is not kept: its local's parent is the function.
    try std.testing.expectEqual(first, e.items(.parent)[find(&d, "x").?]);
    const width = find(&d, "width").?;
    try std.testing.expectEqual(@as(u32, 10), e.items(.line)[width]);
    try std.testing.expectEqual(@as(usize, 1), d.relative_lines);
    const file = find(&d, "s").?;
    try std.testing.expectEqualStrings("/pkg/src/s.zig", d.path(e.items(.unit)[file], e.items(.file)[file]).?);
    try std.testing.expectEqualStrings("/pkg/other.zig", d.path(0, 1).?);
    try std.testing.expectEqual(@as(?[]const u8, null), d.path(0, 2));
}

test "a file cut anywhere, or not ELF, is refused whole" {
    const gpa = std.testing.allocator;
    const bytes = try sample(gpa);
    defer gpa.free(bytes);
    try std.testing.expectError(error.NotElf64, readBytes(bytes[0..32]));
    var cut: usize = 64;
    while (cut < bytes.len) : (cut += 7) {
        if (readBytes(bytes[0..cut])) |got| {
            var d = got;
            d.deinit(gpa);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

/// The test sample, for the index's tests (`Compiled.zig`).
pub const sampleForTests = sample;
/// A test's bytes read through a file, for the index's tests.
pub const readBytesForTests = readBytes;
