#!/usr/bin/env python3
import sys
path = "/Volumes/externalHDD/projects/waka-collector/app/services/renga_generator.rb"
with open(path, "r", encoding="utf-8") as f:
    src = f.read()
with open(path + ".bak_18", "w", encoding="utf-8") as f:
    f.write(src)
print("バックアップ: " + path + ".bak_18")

errors = []
def rep(src, old, new, label):
    if old not in src:
        errors.append(label + ": 未検出"); return src
    if src.count(old) > 1:
        errors.append(label + ": 複数検出"); return src
    print(label + " OK"); return src.replace(old, new, 1)

# 変更1: ループ前に制約変数を追加・hints行を削除
src = rep(src,
    "    5.times do\n"
    "      seed         = pool.sample\n"
    "      hints        = extract_hints(seed)\n"
    "      feedback     = nil\n"
    "      wrong_streak = 0",
    "    target_mora     = (@verse_type == :chouku) ? 17 : 14\n"
    "    season_label    = @constraints.dig(:season_hint, :current) || SEASON_JP[m_season] || \"雑\"\n"
    "    forbidden_bui   = @constraints[:forbidden_bui] || []\n"
    "    forbidden_label = forbidden_bui.any? ? forbidden_bui.join(\"・\") : nil\n"
    "\n"
    "    5.times do\n"
    "      seed         = pool.sample\n"
    "      feedback     = nil\n"
    "      wrong_streak = 0",
    "変更1")

# 変更2: プロンプト呼び出し変更
src = rep(src,
    "        prompt      = build_after_prompt(seed, example, feedback, hints, m_nature)",
    "        prompt      = build_full_prompt(seed, example, feedback, season_label, forbidden_label)",
    "変更2")

# 変更3: タイムアウト延長
src = rep(src,
    "        raw         = OllamaClient.generate(prompt, timeout: 120, think: false, temperature: temperature)",
    "        raw         = OllamaClient.generate(prompt, timeout: 180, think: false, temperature: temperature)",
    "変更3")

# 変更4: target_mora の内側定義を削除
src = rep(src,
    "        target_mora = (@verse_type == :chouku) ? 5 : 7\n",
    "",
    "変更4")

# 変更5: result_ku 連結組み立てを ku 一本化
src = rep(src,
    "        if mora == target_mora && !has_kanji && !is_echo && !is_rep && !is_sticky && !is_maeku_repeat\n"
    "          if @verse_type == :chouku\n"
    "            deco = DECORATION_POOL.sample\n"
    "            result_ku = \"#{deco}#{seed[:surface]}#{ku}\"\n"
    "          else\n"
    "            result_ku = \"#{seed[:surface]}#{ku}\"\n"
    "          end\n"
    "          used_afters << ku\n"
    "          break\n"
    "        end",
    "        if mora == target_mora && !has_kanji && !is_echo && !is_rep && !is_sticky\n"
    "          result_ku = ku\n"
    "          used_afters << ku\n"
    "          break\n"
    "        end",
    "変更5")

# 変更6: feedback のモーラ閾値を target_mora に変更
src = rep(src,
    "          message = mora > 7 ? \"もっと短く\" : mora < 7 ? \"もっと長く\" : \"別の言葉で\"",
    "          message = mora > target_mora ? \"もっと短く\" : mora < target_mora ? \"もっと長く\" : \"別の言葉で\"",
    "変更6")

# 変更7: build_after_prompt メソッドを build_full_prompt に全置換
idx = src.find("  def build_after_prompt(")
if idx < 0:
    errors.append("変更7: build_after_prompt 未検出")
else:
    new_method = (
        "  def build_full_prompt(seed, example, feedback, season_label, forbidden_label)\n"
        "    kinshi        = forbidden_label ? \"禁:#{forbidden_label}\\n\" : \"\"\n"
        "    feedback_line = feedback ? \"やり直し:前回\u300c#{feedback[:ku]}\u300dは#{feedback[:issue]}\u3002#{feedback[:message]}\\n\" : \"\"\n"
        "    target_desc   = (@verse_type == :chouku) ? \"\u4e94\u4e03\u4e94\uff0817\u97f3\uff09\" : \"\u4e03\u4e03\uff0814\u97f3\uff09\"\n"
        "\n"
        "    <<~PROMPT\n"
        "      \u9023\u6b4c\u5e2b\u3068\u3057\u3066\u524d\u53e5\u306b\u4ed8\u3051\u53e5\u3092\u8a60\u3081\u3002\n"
        "      \u524d\u53e5\uff1a#{@maeku}\n"
        "      \u5b63\uff1a#{season_label}\n"
        "      #{kinshi}\u8d77\u70b9\uff1a#{seed[:surface]}\n"
        "      #{target_desc}\u3067\u3072\u3089\u304c\u306a\u306e\u307f\u4e00\u884c\u3002\n"
        "      #{feedback_line}\u4f8b\uff1a#{example[:after]}\n"
        "      \u4ed8\u3051\u53e5\uff1a\n"
        "    PROMPT\n"
        "  end\n"
        "end\n"
    )
    src = src[:idx] + new_method
    print("変更7 OK")

if errors:
    print("\nエラー（ファイル未更新）:")
    for e in errors: print("  - " + e)
    sys.exit(1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print("\n完了。確認:")
print("  grep -n 'build_full_prompt\\|target_mora\\|forbidden_label' app/services/renga_generator.rb | head -20")
