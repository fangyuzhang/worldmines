export HOME=/root
for p in $(pgrep -f batch_all_variants); do
  echo "PID $p:"
  tr '\0' ' ' < /proc/$p/cmdline
  echo
done
echo CMD_DONE
