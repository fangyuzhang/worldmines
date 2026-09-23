export HOME=/root
f=/root/.local/share/godot/app_userdata/wm_server/batch_o5x/issues.jsonl
grep '"t":"unit_done"' $f | python3 -c "
import sys, json
for line in sys.stdin:
    d = json.loads(line)
    print('side=%s per_tier=%s | made=%s tried=%s tier_empty=%s empty=%s proof=%s dup=%s sim=%s full_stall=%s | by_tier=%s | %.0fs' % (
        d.get('side'), d.get('per_tier'), d.get('made'), d.get('tried'),
        d.get('tier_empty'), d.get('empty'), d.get('proof_fail'), d.get('dup'), d.get('similar'),
        d.get('full_stall'), d.get('by_tier'), d.get('cost_s', 0)))
"
echo UD_FULL_DONE
