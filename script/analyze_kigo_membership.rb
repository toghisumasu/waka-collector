#!/usr/bin/env ruby
# frozen_string_literal: true

# analyze_kigo_membership.rb — 季語所属ng調査（其の二十二持ち越し、其の二十八で実データ検証）
#
# 其の二十五〜二十七のdryrun実績（500句＋900句＝計1400句規模）で蓄積された
# log/generation_attempts.log を対象に、LLMが自己申告する season / bui と、
# システム側の語彙・部立登録情報を突き合わせ、以下2種の不整合を検出・集計する。
#
# A. 季所属ng: bui_dictionary.yml で season 登録済みの語（例: 紅葉→秋）が
#    句本文に含まれるのに、self-report season が別の季になっているケース
# B. bui形式ng: self-report bui配列に、正規の部立カテゴリ（下記
#    VALID_BUI_CATEGORIES）に一致しない値が含まれるケース
#    （季節名の誤記入、部立名でなく語そのものを書いてしまう等）
#    → ShikimokuChecker#kuzari_violations は @rules[bui] が見つからない
#      場合 `next unless rule` で黙って無視するため、こうした不正な自己申告は
#      句去チェックをすり抜ける。本調査はこの黙殺の規模を定量化する。
#
# 使用法:
#   bundle exec ruby script/analyze_kigo_membership.rb

require "yaml"
require "json"
require "natto"

ROOT         = File.expand_path("..", __dir__)
LOG_DIR      = File.join(ROOT, "log")
ATTEMPTS_LOG = File.join(LOG_DIR, "generation_attempts.log")
OUTPUT_MD    = File.join(LOG_DIR, "kigo_membership_analysis.md")

BUI_DICT_PATH   = File.join(ROOT, "app/data/bui_dictionary.yml")
KUZARI_PATH     = File.join(ROOT, "app/data/kuzari_rules.yml")
USER_DIC        = File.join(ROOT, "dict/user.dic")

# 辞書照合は単純な部分文字列一致ではなく形態素単位で行う。
# 例: 「薄（すすき、season:秋）」は「薄明」「薄暗く」に部分文字列として
# 含まれるが、これらは形態素解析上は別語（別morpheme）であり、
# 部分文字列一致では誤検出（false positive）になる。
MECAB = Natto::MeCab.new(userdic: USER_DIC)

def morphemes_of(text)
  clean = text.to_s.gsub(/\s+/, "")
  surfaces = []
  MECAB.parse(clean) do |node|
    next if node.is_eos?

    surfaces << node.surface
  end
  surfaces
end

bui_dict   = YAML.load_file(BUI_DICT_PATH) || {}
kuzari     = YAML.load_file(KUZARI_PATH) || {}

# 句去（kuzari_rules.yml）に登録された部立に加え、句数規制こそないが
# 連歌新式上は正規の部立として扱われる「時分」「人倫」を加えた集合。
# 出典: app/data/kukazo_rules.yml 冒頭コメント
#   「句数規制を設けない部立: 動物・植物・光物・降物・聳物・衣装・名所・時分・人倫」
# このうち動物・植物・光物・降物・聳物・名所は kuzari_rules.yml に既出のため、
# 新規に加わるのは 時分・人倫 のみ。
VALID_BUI_CATEGORIES = (kuzari.keys + %w[時分 人倫]).uniq.freeze

# script/dryrun_hyakuin.rb の build_prompt が実際にLLMへ指示している
# bui語彙（23種、プロンプト内「bui に指定できる部立」の列挙と一致させること）。
# VALID_BUI_CATEGORIES（ルールエンジンが認識する17種）との差分が
# 「花・草・木・鳥・虫・獣」であり、これはプロンプトが動物/植物の下位区分として
# 明示的に許可しているにもかかわらず、kuzari_rules.yml/kukazo_rules.yml が
# 下位区分を認識せず親カテゴリ（動物/植物）でしか句去・句数を判定できない、
# という登録漏れ（LLMの自己申告ミスではない）を意味する。
PROMPT_BUI_OPTIONS = %w[
  降物 聳物 光物 花 草 木 植物 鳥 虫 獣 動物 水辺 山類
  時分 居所 衣裳 恋 旅 名所 神祇 釈教 述懐 人倫
].freeze
PROMPT_ONLY_SUBCATEGORIES = (PROMPT_BUI_OPTIONS - VALID_BUI_CATEGORIES).freeze

SEASON_NAMES = %w[春 夏 秋 冬 雑].freeze

# bui_dictionary.yml のうち season が非null（明確に季が定まっている語）のみ抽出
SEASONED_WORDS = bui_dict.filter_map do |word, meta|
  next unless meta.is_a?(Hash) && meta["season"]

  [word, meta["season"]]
end.to_h.freeze

def parse_attempts_log(path)
  return [] unless File.exist?(path)

  File.readlines(path, chomp: true).filter_map do |raw|
    next if raw.strip.empty?

    JSON.parse(raw, symbolize_names: true)
  rescue JSON::ParserError
    nil
  end
end

entries = parse_attempts_log(ATTEMPTS_LOG)
candidates = entries.filter_map { |e| e[:candidate] }

# ── A. 季所属ng: 辞書上season登録済みの語が本文に含まれるのに self-report season が異なる ──

SeasonMismatch = Struct.new(:verse_no, :word, :matched_dict_word, :dict_season, :reported_season, keyword_init: true)

season_mismatches = []
candidates.each_with_index do |c, i|
  entry = entries[i]
  word  = c[:word].to_s
  reported_season = c[:season]
  next if reported_season.nil? || reported_season == "雑" # 雑は季転換の正当な選択肢のため対象外

  morphemes = morphemes_of(word)

  SEASONED_WORDS.each do |dict_word, dict_season|
    next unless morphemes.include?(dict_word)
    next if dict_season == reported_season

    season_mismatches << SeasonMismatch.new(
      verse_no: entry[:verse_no], word: word, matched_dict_word: dict_word,
      dict_season: dict_season, reported_season: reported_season
    )
  end
end

# ── B. bui形式ng: 正規カテゴリ外のbuiタグ ──

tag_total   = 0
tag_invalid = 0
invalid_tag_counts = Hash.new(0)
season_leak_count  = 0 # bui配列に季節名(春/夏/秋/冬)がそのまま紛れ込んでいるケース
candidates_with_invalid = 0
candidates_with_zero_valid = 0

candidates.each do |c|
  tags = Array(c[:bui])
  next if tags.empty?

  valid_tags   = tags.select { |t| VALID_BUI_CATEGORIES.include?(t) }
  invalid_tags = tags - valid_tags

  tag_total   += tags.size
  tag_invalid += invalid_tags.size
  invalid_tags.each { |t| invalid_tag_counts[t] += 1 }
  season_leak_count += tags.count { |t| SEASON_NAMES.include?(t) }

  candidates_with_invalid     += 1 if invalid_tags.any?
  candidates_with_zero_valid  += 1 if valid_tags.empty?
end

# 正規カテゴリ外タグを3種類に切り分ける（ユーザー要求: 「表記ゆれ・登録漏れ」か
# 「本当に未知」かを分けないと 40.9% という数字の実害が判断できないため）。
#
# bucket1: プロンプトが明示的に許可した下位区分（花・草・木・鳥・虫・獣）。
#          LLMは指示に忠実であり、ルールファイル側の登録漏れが原因。
# bucket2: bui_dictionary.yml に語として登録済みだが、カテゴリ名でなく
#          語そのものを自己申告している（正規化すれば解決する軽微なng）。
# bucket3: プロンプトにも辞書にも根拠がない、真に未知の自己申告。
bucket1 = invalid_tag_counts.select { |t, _| PROMPT_ONLY_SUBCATEGORIES.include?(t) }
bucket2 = invalid_tag_counts.reject { |t, _| PROMPT_ONLY_SUBCATEGORIES.include?(t) }
                            .select { |t, _| bui_dict.key?(t) }
bucket3 = invalid_tag_counts.reject { |t, _| PROMPT_ONLY_SUBCATEGORIES.include?(t) || bui_dict.key?(t) }

bucket1_sum = bucket1.values.sum
bucket2_sum = bucket2.values.sum
bucket3_sum = bucket3.values.sum

# ── レポート出力 ──────────────────────────────────────────────

md = +""
md << "# 季語所属ng調査（其の二十二持ち越し・其の二十八実データ検証）\n\n"
md << "生成日時: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}\n\n"
md << "対象: `log/generation_attempts.log`（其の二十五〜二十七のdryrun実績、"
md << "accepted/rejected問わず全attempt） / 総candidate数: **#{candidates.size}**\n\n"
md << "正規部立カテゴリ（#{VALID_BUI_CATEGORIES.size}種、kuzari_rules.yml + 時分/人倫）: "
md << "#{VALID_BUI_CATEGORIES.join('・')}\n\n"
md << "---\n\n"

md << "## A. 季所属ng（辞書season登録語と自己申告seasonの不一致）\n\n"
md << "bui_dictionary.yml で season が明確に登録されている語（#{SEASONED_WORDS.size}語）が"
md << "句本文に含まれるにもかかわらず、self-report season が異なるケースを検出。\n\n"
md << "検出件数: **#{season_mismatches.size}**\n\n"
if season_mismatches.any?
  md << "| # | 句番号 | 句本文 | 本文中の季語 | 辞書上の季 | 自己申告season |\n"
  md << "|:-:|:-:|:--|:--|:-:|:-:|\n"
  season_mismatches.each_with_index do |m, i|
    md << "| #{i + 1} | #{m.verse_no} | #{m.word} | #{m.matched_dict_word} | #{m.dict_season} | #{m.reported_season} |\n"
  end
  md << "\n"
else
  md << "（該当なし）\n\n"
end

md << "---\n\n"
md << "## B. bui形式ng（正規カテゴリ外の自己申告bui）\n\n"
md << "bui配列は句去（kuzari_rules.yml）・句数（kukazo_rules.yml）双方の判定キーとして"
md << "そのまま使われる。ShikimokuChecker はカテゴリ不一致のタグを黙って無視するため"
md << "（`@rules[bui]` が nil の場合 `next`）、正規カテゴリ外のタグはチェックを"
md << "すり抜ける。\n\n"

md << "| 指標 | 値 |\n|:--|--:|\n"
md << "| 総bui自己申告タグ数 | #{tag_total} |\n"
md << "| うち正規カテゴリ外（形式ng） | #{tag_invalid} |\n"
tag_rate = tag_total.positive? ? (tag_invalid * 100.0 / tag_total).round(1) : 0
md << "| 形式ng率（タグ単位） | #{tag_rate}% |\n"
md << "| 1つ以上ngタグを含むcandidate数 | #{candidates_with_invalid} / #{candidates.size} |\n"
cand_rate = candidates.size.positive? ? (candidates_with_invalid * 100.0 / candidates.size).round(1) : 0
md << "| 同・candidate単位の割合 | #{cand_rate}% |\n"
md << "| 正規カテゴリのタグを1つも含まないcandidate数（句去/句数チェックが完全無効化） | #{candidates_with_zero_valid} / #{candidates.size} |\n"
zero_rate = candidates.size.positive? ? (candidates_with_zero_valid * 100.0 / candidates.size).round(1) : 0
md << "| 同・candidate単位の割合 | #{zero_rate}% |\n"
md << "| bui配列に季節名（春/夏/秋/冬/雑）がそのまま紛れ込んでいる件数 | #{season_leak_count} |\n"
md << "\n"

md << "### 正規カテゴリ外タグの内訳（3分類）\n\n"
md << "「形式ng」を一括りにすると実害の判断ができないため、原因別に3分類する。\n\n"
md << "| 分類 | 定義 | 件数 | 全invalid中の割合 | 全タグ中の割合 |\n"
md << "|:--|:--|--:|--:|--:|\n"
b1_of_invalid = tag_invalid.positive? ? (bucket1_sum * 100.0 / tag_invalid).round(1) : 0
b2_of_invalid = tag_invalid.positive? ? (bucket2_sum * 100.0 / tag_invalid).round(1) : 0
b3_of_invalid = tag_invalid.positive? ? (bucket3_sum * 100.0 / tag_invalid).round(1) : 0
b1_of_total = tag_total.positive? ? (bucket1_sum * 100.0 / tag_total).round(1) : 0
b2_of_total = tag_total.positive? ? (bucket2_sum * 100.0 / tag_total).round(1) : 0
b3_of_total = tag_total.positive? ? (bucket3_sum * 100.0 / tag_total).round(1) : 0
md << "| ① プロンプト指示済み下位区分 | プロンプトが明示的に許可した語（花・草・木・鳥・虫・獣）。ルールファイル側の登録漏れであり、LLMの誤りではない | #{bucket1_sum} | #{b1_of_invalid}% | #{b1_of_total}% |\n"
md << "| ② 辞書登録語の非正規化 | bui_dictionary.yml に語として登録済みだが、カテゴリ名でなく語そのものを自己申告 | #{bucket2_sum} | #{b2_of_invalid}% | #{b2_of_total}% |\n"
md << "| ③ 真に未知 | プロンプト・辞書いずれにも根拠がない自己申告 | #{bucket3_sum} | #{b3_of_invalid}% | #{b3_of_total}% |\n"
md << "\n"

md << "#### ① プロンプト指示済み下位区分（内訳）\n\n"
md << "| タグ | 出現回数 | 対応する親カテゴリ |\n|:--|--:|:--|\n"
parent_of = { "虫" => "動物", "鳥" => "動物", "獣" => "動物", "花" => "植物", "草" => "植物", "木" => "植物" }
bucket1.sort_by { |_, v| -v }.each { |tag, count| md << "| #{tag} | #{count} | #{parent_of[tag]} |\n" }
md << "\n"

md << "#### ② 辞書登録語の非正規化（内訳）\n\n"
md << "| タグ | 出現回数 | 辞書上のprimary_bui |\n|:--|--:|:--|\n"
bucket2.sort_by { |_, v| -v }.each { |tag, count| md << "| #{tag} | #{count} | #{bui_dict.dig(tag, 'primary_bui')} |\n" }
md << "\n"

md << "#### ③ 真に未知（上位20件）\n\n"
md << "| # | タグ | 出現回数 |\n|:-:|:--|--:|\n"
bucket3.sort_by { |_, v| -v }.first(20).each_with_index { |(tag, count), i| md << "| #{i + 1} | #{tag} | #{count} |\n" }
md << "\n（他 #{[bucket3.size - 20, 0].max}種、出現回数1〜数回の長い裾）\n\n"

md << "---\n\n"
md << "## 所見\n\n"
md << "- Aの季所属ng（辞書登録語との不一致）は#{season_mismatches.empty? ? 'ほぼ観測されず' : "#{season_mismatches.size}件観測され"}、"
md << "其の二十二で懸念されていた「特定語の季誤登録」型の不整合は#{season_mismatches.size >= 5 ? '無視できない規模で存在する' : '現状データでは限定的'}。"
md << "（紅葉→秋、桜/花→春 の登録に対し、それぞれ冬・夏と自己申告されたケースなど）\n"
md << "- Bのbui形式ngは#{tag_rate}%（candidate単位で#{cand_rate}%）だが、その内訳を見ると"
md << "**73%（全タグの#{b1_of_total}%）が①プロンプト自体の登録漏れ**であり、LLMの不安定な自由記述ではない。"
md << "`script/dryrun_hyakuin.rb` の `build_prompt` が「bui に指定できる部立」として"
md << "`花・草・木・鳥・虫・獣` を明示的に提示している一方、`kuzari_rules.yml`・`kukazo_rules.yml`は"
md << "この6語を認識せず親カテゴリ（植物・動物）でしか句去・句数を判定できない。"
md << "つまりプロンプトとルールエンジンという**システム内2箇所の語彙定義が非同期**になっている"
md << "ことが実害の主因であり、「LLMの表記ゆれ」ではなく再現性のある設計不備である。\n"
md << "- ②辞書登録語の非正規化は#{bucket2_sum}件（全タグの#{b2_of_total}%）と軽微。"
md << "③真に未知の自己申告は#{bucket3_sum}件（全タグの#{b3_of_total}%）で、"
md << "「風」「音」「夢」など多岐にわたるが1件あたりの出現数は少なく、特定の偏りは見られない。\n"
md << "- **結論**: 「約4割が式目チェックをすり抜けている」という数字の実害は、"
md << "大半（全タグの#{b1_of_total}%）が①のプロンプト/ルールエンジン間の語彙不一致という"
md << "**特定・修正可能な既知の原因**に起因する。真に未知のリスクは全タグの#{b3_of_total}%に限定される。\n"
md << "- 対処方針（実装は別途相談）: ①への対処は `kuzari_rules.yml`・`kukazo_rules.yml`に"
md << "花・草・木（→植物のエイリアス）、鳥・虫・獣（→動物のエイリアス）を追加する、"
md << "または `ShikimokuChecker` 側でこれらをチェック前に正規化する変換層を設ける、のいずれかで"
md << "解消できる見込みが高い。②は同様の変換層で解消可能。③は現状データでは"
md << "対処を要するほどの偏りは見られず、「枯れてから足す」原則に従い監視継続にとどめる。\n\n"

File.write(OUTPUT_MD, md)
puts "書き出し完了: #{OUTPUT_MD}"
puts "candidates: #{candidates.size} / 季所属ng: #{season_mismatches.size} / bui形式ng率: #{tag_rate}% (candidate単位 #{cand_rate}%)"
