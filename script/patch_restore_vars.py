#!/usr/bin/env python3
path = "/Volumes/externalHDD/projects/waka-collector/app/services/renga_generator.rb"
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()
with open(path + ".bak_rv", "w", encoding="utf-8") as f:
    f.writelines(lines)

for i, line in enumerate(lines):
    if 'mora=#{mora} target=#{target_mora}' in line:
        lines.insert(i+1, '        is_echo     = ECHO_AFTERS.include?(ku)\n')
        lines.insert(i+2, '        is_rep      = (ku == seed[:yomi])\n')
        print(f"変数復元 OK (行{i+2},{i+3}に追加)")
        break
else:
    print("対象行未検出")

with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
