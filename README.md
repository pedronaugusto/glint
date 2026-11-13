# glint

glint is a linter for Zig. It reads source with Zig's own parser and lowering, resolves what each reference
names, and reports two kinds of rule:
- a **ban**: a construct is not used outside a declared seam, and every site is a finding;
- **hygiene**: dead code, unused imports, naming, length, deprecations, reported only where glint is certain.

A run ends in findings, reports, or a run error that says what glint could not read and how to fix it. There
is no "undecided" result, and glint does not prove a program safe. A package can declare its own rules: aegis
does, so a program that imports aegis is checked against going around it.

## Install

Requires Zig 0.17. Fetch with `zig fetch --save git+https://github.com/pedronaugusto/glint`. To use it as a
library, take the `glint` module through `b.dependency`. To run the command line:

```sh
git clone https://github.com/pedronaugusto/glint.git
cd glint
zig build -Doptimize=safe
./zig-out/bin/glint src/main.zig
```

## Stability

glint is 0.x and tracks Zig 0.17.x. A breaking change comes only in a minor release (0.8 to 0.9), with a
CHANGELOG entry saying what changed and what to write instead; a patch release never breaks. A configuration
naming a rule 0.8 removed is refused with its replacement, or with "remove it" where it has none.

## Usage

```sh
glint src/main.zig src/other.zig            # the default rules
glint --reviewed src/main.zig               # every rule not off by default
glint --only Z026 --only D001 src/main.zig  # just these rules
glint --config glint.json --files-from list.txt
glint --format json src/main.zig            # text, json or sarif
```

Inputs are explicit files, or a newline-separated `--files-from` list. Relative imports are followed within
the input directories. `--module NAME=FILE` maps a named module, `--package NAME=DIR` names the package a
directory holds, and `--zig-lib-path DIR` finds std. An import no mapping names is a run error that says how to
map it. `glint --help` lists every option.

Exit 0 means a completed run with no findings, 1 findings, and 2 a run error or a failure (arguments, input,
output, tool or cancellation).

A single site is answered by one comment that gives its reason, naming one rule or several:

```zig
// glint-ignore: Z026 -- the cache is advisory; a failed write leaves the old entry
cache.store(key, value) catch {};
```

A whole file or directory is answered by a seam in the project's configuration (the path or glob, its rules, a
reason), and `test_inputs` names the inputs read as test code. Every suppression and every seam is counted in
the report. `glint --fix` (preflight's `zig build fix`) rewrites 0.7's `// aegis:` escapes and `// unreachable:`
reasons into `glint-ignore`, and replaces a call a package's rule bans with the answer it names as a drop-in.

## Design

[docs/design.md](docs/design.md) holds every rule's claim and its closed list of constructs, the removed-rule
table, the package vocabulary, the configuration, run errors, and what glint does not claim.

## Scope

- **Bans**: discarded errors (Z026), project-declared bans (P006), operations Zig leaves unchecked (P007:
  unsafe builtins and casts, `extern`, `asm`, many-item pointer arithmetic, `std.c`, `std.os.linux`,
  `std.os.windows`), and every rule a package declares as a ban (aegis's A001, A007, A008, A009, A011, A013,
  A015, and A012 and A021 where selected).
  Off by default: an unwrap that can trap (P010), `undefined` outside a test (P011), leftover debugging (P012).
- **Hygiene**: naming, syntax the next Zig refuses (Z003, Z034), line and function length, deprecated calls,
  private types in public signatures, unused imports, dead declarations, an assertion of `a and b`, debug
  prints, identifying integers of one type that may stand for one another (P008), a pointer into the frame
  returned (P009), and the breadth rules Z035-Z056 (same operands, constant conditions, narrow arithmetic
  widened, large stack arrays, NaN and inexact float comparisons, and more).
- **Not in scope**: proving that a program cannot panic, tracking input or overflow, or the lifetime of a
  pointer. Those belong to ReleaseSafe, to aegis's types, and to each package's fuzzing and testing allocator.
  glint never runs the checked project's build or its comptime code.

MIT. See [LICENSE](LICENSE).
