#!/usr/bin/env python3
import sys
path = "/Volumes/externalHDD/projects/waka-collector/app/services/renga_generator.rb"
with open(path, "r", encoding="utf-8") as f:
    src = f.read()
with open(path + ".bak_18d", "w", encoding="utf-8") as f:
    f.write(src)
print("バックアップ: " + path + ".bak_18d")

errors = []
def rep(src, old, new, label):
    if old not in src:
        errors.append(label + ": 未検出"); return src
    if src.count(old) > 1:
        errors.append(label + ": 複数検出"); return src
    print(label + " OK"); return src.replace(old, new, 1)

# 変更1: mora計算をMeCab経由に、has_kanji廃止
src = rep(src,
    "        mora        = count_mora_from_kana(ku)\n"
    "        has_kanji   = ku.match?(/[^\\u3040-\\u309F\\u3099-\\u309C\\s]/)\n",
    "        ku_ms       = morphemes_of(ku, nm)\n"
    "        mora        = ku_ms.sum { |m| m[:mora] }\n",
    "変更1")

# 変更2: 条件からhas_kanji削除
src = rep(src,
    "        if mora == target_mora && !has_kanji && !is_echo && !is_rep && !is_sticky\n",
    "        if mora == target_mora && !is_echo && !is_rep && !is_sticky\n",
    "変更2")

# 変更3: issue行からhas_kanji・is_maeku_repeat削除（元のテキストから直接置換）
src = rep(src,
    "          issue   = has_kanji ? \"\u6f22\u5b57\u6df7\u5165\" : is_echo ? \"echo\" : is_rep ? \"\u9f36\u9f61\u8fd4\u3057\" : is_sticky ? \"\u56fa\u7740\" : is_maeku_repeat ? \"\u524d\u53e5\u91cd\u8907\" : \"#{mora}\u97f3\"",
    "          issue   = is_echo ? \"echo\" : is_rep ? \"\u9f36\u9f61\u8fd4\u3057\" : is_sticky ? \"\u56fa\u7740\" : \"#{mora}\u97f3\"",
    "変更3")

# 変更4: build_full_prompt を短歌完成型プロンプトに改良
idx = src.find("  def build_full_prompt(")
if idx < 0:
    errors.append("変更4: build_full_prompt 未検出")
else:
    new_method = (
        "  def build_full_prompt(seed, example, feedback, season_label, forbidden_label)\n"
        "    kinshi        = forbidden_label ? \"\u7981:\u300c#{forbidden_label}\u300d\u306e\u8a9e\u306f\u907f\u3051\u308b\u3053\u3068\u3002\\n\" : \"\"\n"
        "    feedback_line = feedback ? \"\u524d\u56de\u300c#{feedback[:ku]}\u300d\u306f#{feedback[:issue]}\u3002#{feedback[:message]}\\n\" : \"\"\n"
        "    target_desc   = (@verse_type == :chouku) ? \"\u4e94\u4e03\u4e94\uff0817\u97f3\uff09\" : \"\u4e03\u4e03\uff0814\u97f3\uff09\"\n"
        "\n"
        "    <<~PROMPT\n"
        "      \u524d\u306e\u53e5\u3068\u5408\u308f\u305b\u3066\u77ed\u6b4c\u4e00\u9996\u306b\u306a\u308b\u3088\u3046\u306a\u7d9a\u304d\u3092\u4f5c\u308c\u3002\n"
        "      \u524d\u53e5\uff1a#{@maeku}\n"
        "      \u9023\u60f3\uff1a#{seed[:surface]}\n"
        "      \u5b63\u7bc0\uff1a#{season_label}\n"
        "      #{kinshi}#{target_desc}\u3092\u4e00\u884c\u3060\u3051\u51fa\u529b\u305b\u3088\u3002\u8aac\u660e\u4e0d\u8981\u3002\n"
        "      #{feedback_line}\u4f8b\uff1a#{example[:after]}\n"
        "      \u7d9a\u304d\uff1a\n"
        "    PROMPT\n"
        "  end\n"
        "end\n"
    )
    src = src[:idx] + new_method
    print("変更4 OK")

if errors:
    print("\nエラー（ファイル未更新）:")
    for e in errors: print("  - " + e)
    sys.exit(1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print("\n完了。確認:")
print("  sed -n '75,100p' app/services/renga_generator.rb")
