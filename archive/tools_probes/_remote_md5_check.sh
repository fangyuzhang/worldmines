export HOME=/root
cd /root/minesweeper
for f in core/hint_solver.gd core/proof_log.gd core/board.gd core/clue_engine.gd core/rule_registry.gd core/rule_oracle.gd core/rule_builder.gd core/difficulty.gd core/reasoning_step.gd demo/mods/o5_xiemai/entry.gd tools/verify_batch.gd; do
  md5sum "$f" 2>/dev/null
done
echo MD5_DONE
