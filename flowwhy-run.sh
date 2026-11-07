#!/bin/bash
# flowwhy-run.sh BIN OUT: BIN's A003 "unsupported flow facts" sites (with the instrumented WHY trail)
# over every family clone's src and relic's src; one line per site: package, file, start, detail.
P=/Users/gusto/work/tycho/.wt/main; C=$P/postsubmit/clones; S=/Users/gusto/work/tycho/.wt/glint-b/scratch
L=/Users/gusto/.local/share/bay/zig/0.17.0/lib; : > "$2"
pick() { python3 -I -c "
import json,sys
d=json.load(sys.stdin)
for x in d['coverage']:
  if x.get('rule')=='A003' and 'flow facts' in x.get('detail',''): print(sys.argv[1], x.get('source',''), x.get('start'), x.get('detail',''), sep='\t')
" "$1"; }
for r in $(/bin/ls "$C"); do
  [ -d "$C/$r/src" ] || continue
  a=$(/bin/ls -d "$C/$r"/zig-pkg/aegis-*/src/root.zig 2>/dev/null | head -1); [ "$r" = aegis ] && a="$C/aegis/src/root.zig"
  mods=(); [ -n "$a" ] && mods=(--module "aegis=$a")
  (cd "$C/$r" && HEAVY_MEM_GB=24 bash "$P/heavy.sh" "$1" --only A003 --zig-lib-path "$L" "${mods[@]}" --format json $(find src -name '*.zig' | sort) 2>/dev/null | pick "$r") >> "$2"
done
R=/Users/gusto/work/tycho/.wt/relic-road-b/ports/relic; M=$(cat $S/relic-mods2.txt)
(cd $R && HEAVY_MEM_GB=24 bash "$P/heavy.sh" "$1" --only A003 --zig-lib-path $L $M --format json $(find src -name "*.zig") 2>/dev/null | pick relic) >> "$2"
cut -f1 "$2" | sort | uniq -c | sort -rn
