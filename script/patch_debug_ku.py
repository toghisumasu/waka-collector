#!/usr/bin/env python3
path = "/Volumes/externalHDD/projects/waka-collector/app/services/renga_generator.rb"
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()
with open(path + ".bak_debug", "w", encoding="utf-8") as f:
    f.writelines(lines)

for i, line in enumerate(lines):
    if "ku_ms       = morphemes_of(ku, nm)" in line:
        lines.insert(i, '        Rails.logger.info "[RengaGenerator] raw_ku=#{ku.inspect} mora=#{mora rescue \'?\'}"\n')
        # moraはku_msの後なので、ログはku_ms計算後に移動
        # まずku確定直後にrawログを挿入
        lines[i] = '        Rails.logger.info "[RengaGenerator] raw_ku=#{ku.inspect}"\n'
        lines[i+1] = "        ku_ms       = morphemes_of(ku, nm)\n"
        lines.insert(i+2, '        mora        = ku_ms.sum { |m| m[:mora] }\n')
        lines.insert(i+3, '        Rails.logger.info "[RengaGenerator] mora=#{mora} target=#{target_mora}"\n')
        # 元のku_ms行とmora行を削除（ずれた行）
        del lines[i+4]  # 元のku_ms
        del lines[i+4]  # 元のmora
        print(f"デバッグログ追加 OK (行{i+1}付近)")
        break
else:
    print("未検出")

with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
