export HOME=/root
cd /root/minesweeper
for f in core/rng_service.gd core/puzzle_generator.gd core/level_generator.gd core/mod_api.gd; do
  echo "=== $f ==="
  ls -la --time-style='+%m-%d %H:%M' $f | awk '{print $6, $7, $8}'
  file $f | cut -d: -f2
  wc -c $f | awk '{print "bytes="$1}'
  md5sum $f
done
echo QUALIFY_DONE
