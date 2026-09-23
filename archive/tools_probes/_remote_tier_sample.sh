export HOME=/root
f=/root/.local/share/godot/app_userdata/wm_server/batch_o5x/issues.jsonl
echo '=== tier_empty 完整样本（side=8 第一条）==='
grep '"t":"tier_empty"' $f | grep '"side":8' | head -1
echo '=== tier_empty 完整样本（side=9 第一条）==='
grep '"t":"tier_empty"' $f | grep '"side":9' | head -1
echo '=== o5x unit_done 全列表（简版）==='
grep '"t":"unit_done"' $f | python3 -c "
import sys, json
for line in sys.stdin:
    d = json.loads(line)
    bt = d.get('by_tier', {})
    print('side=%s per_tier=%s made=%s tried=%s attempts=%s full_stall=%s by_tier=%s cost=%.0fs' % (
        d.get('side'), d.get('per_tier'), d.get('made'), d.get('tried'), d.get('attempts'),
        d.get('full_stall'), bt, d.get('cost_s', 0)))
"
echo TIER_SAMPLE_DONE
