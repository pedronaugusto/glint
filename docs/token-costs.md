# Token recovery costs

The standard-tokenizer API is implemented and the frozen family facts match exactly. The
corpus speed requirement remains open: this candidate is faster for the tiny input, but
slower across the family. These measurements do not authorize advancing Gantry's dependency.

The baseline is published Gantry `42b0db74234827b95f28ce95a59afee80e66d4bd`, its independent
Zig recovery using the byte lexer. Both providers perform import/member recovery and lazy
production/test/dead classification, not merely tokenization. No AST, ZIR, semantic mapping,
IO or corpus loading occurs inside timing. Both receive the same preloaded zero-sentinel
source and create/destroy one arena per file. The std tokenizer is the only lexical engine
in the candidate. Public observer token storage is absent from ordinary graph recovery.

Recorded on 2026-10-09, Apple M3 Max, aarch64 macOS (Darwin 25.2.0), Zig 0.17.0,
`-Ofast`, native CPU, one process. The host also runs other family work; rows retain all
outliers. Twenty pairs alternate which provider runs first. Ratios are the median of each
pair's candidate/baseline ratio; latency columns are separate medians, not a selected best run.

| Workload | Baseline median | Glint median | Paired ratio |
|---|---:|---:|---:|
| 61-byte input, two facts, 2,000 repetitions per pair | 438 ns/file | 399 ns/file | 0.911 |
| 1,528 files, 23,078,900 bytes, 74,752 facts | 79.74 ms/pass | 92.24 ms/pass | 1.155 |

Untimed counting uses the same arena owner and records requested backing allocations, not
RSS or the operating system's physical memory. Live requested bytes return to zero after
every file for both providers.

| Workload | Baseline allocations / peak bytes | Glint allocations / peak bytes |
|---|---:|---:|
| Tiny | 1 / 1,992 | 2 / 948 |
| Corpus | 3,407 / 14,255,980 | 3,404 / 8,554,204 |

Identical stripped standalone drivers are 256,576 bytes (baseline) and 256,568 bytes (Glint).
This is native executable file size, not a general package-size claim. The memory reduction
and tiny-input speed do not erase the corpus regression. A 16-byte compressed token record
made recovery slower; the candidate instead keeps 24-byte private records with std token
tags, decoded slices and bracket links. Temporary short-stream tokens use a bounded stack
buffer with arena fallback. All returned facts still borrow source or the caller's arena.

## Reproduction

[The corpus pins](../bench/token-corpus.json) identify nineteen published snapshots; no active
worker checkout contributes files. The parity driver compares every literal import/member
spelling, byte offset, test kind and dead flag, and every unsupported import offset. The
baseline's literal form, empty scope and language flags are also checked. This proves source
recovery parity, not Gantry graph/resolution parity, which belongs to the second batch.

Download snapshots into this repository's ignored `.analysis` scratch directory. Keep the
baseline isolated: its tiny bridge must reside beside its root-relative imports. There is
no vendored rival implementation in this package.

```sh
mkdir -p .analysis/gantry-baseline .analysis/published-corpus
gh api repos/pedronaugusto/gantry/tarball/42b0db74234827b95f28ce95a59afee80e66d4bd > .analysis/baseline.tar.gz
tar -xzf .analysis/baseline.tar.gz --strip-components=1 -C .analysis/gantry-baseline
cp bench/token-baseline.zig .analysis/gantry-baseline/src/token-baseline.zig
jq -r '.[] | [.repo, .sha] | @tsv' bench/token-corpus.json |
while read -r repo sha; do
    mkdir -p ".analysis/published-corpus/$repo"
    gh api "repos/pedronaugusto/$repo/tarball/$sha" > ".analysis/$repo.tar.gz"
    tar -xzf ".analysis/$repo.tar.gz" --strip-components=1 -C ".analysis/published-corpus/$repo"
done
jq -r '.[].repo' bench/token-corpus.json |
while read -r repo; do
    rg --files --hidden --no-ignore -g '*.zig' ".analysis/published-corpus/$repo" | LC_ALL=C sort
done > .analysis/published-manifest.txt
zig build-exe -Ofast --dep glint_token --dep baseline \
    -Mroot=bench/token-paired.zig -Mglint_token=src/Token.zig \
    -Mbaseline=.analysis/gantry-baseline/src/token-baseline.zig -femit-bin=.analysis/token-paired
.analysis/token-paired
.analysis/token-paired .analysis/published-manifest.txt
zig build-exe -Ofast -fstrip --dep facts -Mroot=bench/token-size.zig \
    -Mfacts=src/Token.zig -femit-bin=.analysis/token-size
zig build-exe -Ofast -fstrip --dep facts -Mroot=bench/token-size.zig \
    -Mfacts=.analysis/gantry-baseline/src/token-baseline.zig -femit-bin=.analysis/baseline-size
wc -c .analysis/token-size .analysis/baseline-size
```

Use Zig 0.17.0 for all commands. Raw alternating durations are retained in
[the result rows](../bench/token-results.csv), beside the driver. The corpus manifest ordering
must be held identical for both providers in any new measurement. Further recovery work or
an explicit owner decision on the performance constraint is needed before this batch lands.
