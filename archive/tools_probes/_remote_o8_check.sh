#!/bin/bash
export HOME=/root
B=/root/.local/share/godot/app_userdata/wm_server/batch_o8
echo "o8: json=$(find $B -name '*.json' | wc -l) intro=$(find $B -name 'intro_*.json' | wc -l) easy=$(find $B -name 'easy_*.json' | wc -l) normal=$(find $B -name 'normal_*.json' | wc -l) hard=$(find $B -name 'hard_*.json' | wc -l)"
ps -eo etime,cmd | grep batch_all_variants | grep -v grep | head -1
echo O8CHECK_DONE
