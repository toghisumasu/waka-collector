#!/usr/bin/env python3
path = "/Volumes/externalHDD/projects/waka-collector/app/services/renga_generator.rb"
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()
with open(path + ".bak_18e", "w", encoding="utf-8") as f:
    f.writelines(lines)

errors = []

# 変更1: mora計算をMeCab経由に（has_kanji廃止）行番号で特定
for i, line in enumerate(lines):
    if "count_mora_from_kana(ku)" in line:
        if i+1 < len(lines) and "has_kanji" in lines[i+1]:
            lines[i]   = "        ku_ms       = morphemes_of(ku, nm)\n"
            lines[i+1] = "        mora        = ku_ms.sum { |m| m[:mora] }\n"
            print(f"変更1 OK (行{i+1},{i+2})")
            break
else:
    errors.append("変更1: 未検出")

# 変更2: !has_kanji を条件から削除
for i, line in enumerate(lines):
    if "mora == target_mora" in line and "has_kanji" in line:
        lines[i] = "        if mora == target_mora && !is_echo && !is_rep && !is_sticky\n"
        print(f"変更2 OK (行{i+1})")
        break
else:
    errors.append("変更2: 未検出")

# 変更4: build_full_prompt を短歌完成型に置換
for i, line in enumerate(lines):
    if "  def build_full_prompt(" in line:
        new_method = [
            "  def build_full_prompt(seed, example, feedback, season_label, forbidden_label)\n",
            "    kinshi        = forbidden_label ? \"\u7981\uff1a\u300c#{forbidden_label}\u300d\u306e\u8a9e\u306f\u907f\u3051\u308b\u3053\u3068\u3002\\n\" : \"\"\n",
            "    feedback_line = feedback ? \"\u524d\u56de\u300c#{feedback[:ku]}\u300d\u306f#{feedback[:issue]}\u3002#{feedback[:message]}\\n\" : \"\"\n",
            "    target_desc   = (@verse_type == :chouku) ? \"\u4e94\u4e03\u4e94\uff0817\u97f3\uff09\" : \"\u4e03\u4e03\uff0814\u97f3\uff09\"\n",
            "\n",
            "    <<~PROMPT\n",
            "      \u524d\u306e\u53e5\u3068\u5408\u308f\u305b\u3066\u77ed\u6b4c\u4e00\u9996\u306b\u306a\u308b\u3088\u3046\u306a\u7d9a\u304d\u3092\u4f5c\u308c\u3002\n",
            "      \u524d\u53e5\uff1a#{@maeku}\n",
            "      \u9023\u60f3\uff1a#{seed[:surface]}\n",
            "      \u5b63\u7bc0\uff1a#{season_label}\n",
            "      #{kinshi}#{target_desc}\u3092\u4e00\u884c\u3060\u3051\u51fa\u529b\u305b\u3088\u3002\u8aac\u660e\u4e0d\u8981\u3002\n",
            "      #{feedback_line}\u4f8b\uff1a#{example[:after]}\n",
            "      \u7d9a\u304d\uff1a\n",
            "    PROMPT\n",
            "  end\n",
            "end\n",
        ]
        lines = lines[:i] + new_method
        print(f"変更4 OK (行{i+1}\u4ee5\u964d\u7f6e\u63db)")
        break
else:
    errors.append("変更4: 未検出")

if errors:
    print("\nエラー（ファイル未更新）:")
    for e in errors: print("  - " + e)
else:
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    print("\n完了。確認:")
    print("  grep -n 'has_kanji\\|ku_ms\\|短歌一首\\|連想' app/services/renga_generator.rb")
