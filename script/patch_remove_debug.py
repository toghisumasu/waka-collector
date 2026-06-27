#!/usr/bin/env python3
path = "/Volumes/externalHDD/projects/waka-collector/app/services/renga_generator.rb"
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()
with open(path + ".bak_nodebug", "w", encoding="utf-8") as f:
    f.writelines(lines)

new_lines = [l for l in lines if
    'raw_ku=' not in l and
    'mora=#{mora} target=' not in l and
    'Rails.logger.info "[RengaGenerator] raw_ku' not in l]

with open(path, "w", encoding="utf-8") as f:
    f.writelines(new_lines)
print(f"削除行数: {len(lines) - len(new_lines)}")
