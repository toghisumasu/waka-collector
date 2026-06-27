#!/usr/bin/env python3
path = "/Volumes/externalHDD/projects/waka-collector/app/services/renga_generator.rb"
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()
with open(path + ".bak_18h", "w", encoding="utf-8") as f:
    f.writelines(lines)

for i, line in enumerate(lines):
    if "if mora == target_mora && !is_echo && !is_rep && !is_sticky" in line:
        lines[i] = "        if (mora - target_mora).abs <= 1 && !is_echo && !is_rep && !is_sticky\n"
        print(f"±1許容 OK (行{i+1})")
        break
else:
    print("未検出")

with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
