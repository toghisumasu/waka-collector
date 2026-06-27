#!/usr/bin/env python3
path = "/Volumes/externalHDD/projects/waka-collector/app/services/renga_generator.rb"
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()
with open(path + ".bak_18f", "w", encoding="utf-8") as f:
    f.writelines(lines)

# build_full_prompt内の「例：#{example[:after]}」を句種別の完全な例示に変える
for i, line in enumerate(lines):
    if '      #{feedback_line}例：#{example[:after]}' in line:
        lines[i] = (
            '      #{feedback_line}'
            '例（七七14音）：おもかげにしてこいしきものを\n'
            if False else
            '      #{feedback_line}例：#{ @verse_type == :chouku ? "はるかすみたちてゆくへもしらぬかな" : "おもかげにしてこいしきものを" }\n'
        )
        print(f"変更 OK (行{i+1})")
        break
else:
    print("未検出")

with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
print("完了")
