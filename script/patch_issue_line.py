#!/usr/bin/env python3
path = "/Volumes/externalHDD/projects/waka-collector/app/services/renga_generator.rb"
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

found = False
for i, line in enumerate(lines):
    if "has_kanji" in line and "is_maeku_repeat" in line and "issue" in line:
        print(f"対象行 {i+1}: {line.rstrip()}")
        lines[i] = '          issue   = is_echo ? "echo" : is_rep ? "鸚鵡返し" : is_sticky ? "固着" : "#{mora}音"\n'
        found = True
        print("変更3 OK")
        break

if not found:
    print("未検出: has_kanji + is_maeku_repeat + issue の行が見つかりません")
else:
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    print("書き込み完了")
