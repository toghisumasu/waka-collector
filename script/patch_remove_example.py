#!/usr/bin/env python3
path = "/Volumes/externalHDD/projects/waka-collector/app/services/renga_generator.rb"
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()
with open(path + ".bak_18g", "w", encoding="utf-8") as f:
    f.writelines(lines)

for i, line in enumerate(lines):
    if '@verse_type == :chouku ? "はるかすみたちてゆくへもしらぬかな"' in line:
        lines[i] = ""
        print(f"例示行を削除 OK (行{i+1})")
        break
else:
    print("未検出")

with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
