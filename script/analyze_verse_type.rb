# frozen_string_literal: true
# 依頼書M-6: 句種別（月を含む句・花を含む句・挙句・平句）の切り直し集計
#
# 実行: bundle exec ruby script/analyze_verse_type.rb
# 入力: tmp/hyakuin_compare_verses.csv（M-5の出力。これだけを読む。MeCab・Ollama・DBは使わない）
# 出力: 標準出力の表 / tmp/verse_type_breakdown.csv（コミットしない）
# 優劣の判断はしない。1 run = 1回走行（n=1）、句種別に切ると母数は各10句前後なので大きな差だけを見ること。
#
# ── 句種別の定義（本文 text に語が含まれるかの簡易判定。式目上の「定座」とは別物）──
# ・月を含む句: text に MOON_WORDS のいずれかを含む
# ・花を含む句: text に HANA_WORDS のいずれかを含む（「菜の花」「花びら」等も含まれる。月と重なる句は両方に数える）
# ・挙句: verse_no == AGEKU_VERSE_NO
# ・平句: 上記のいずれにも当たらない句
# 4種別は重複しうるので、種別のn合計は99句と一致しない。RC-2の検算は「和集合＝99句」＋重複数の内訳で行う。
# ・対象は2〜100句目の99句（1句目は固定の発句のため、M-5のCSVに含まれない）。季の分布もこの99句で数える
#   （M-5表Aは発句込み100句）ので、M-5の季の数とは1句分ずれる。
# ・水無瀬の「恋」は別欄、「雑＋恋」も併記（生成側の雑との比較は「雑＋恋」で行う）。
# ・所要秒は観察ログの時刻差。2句目はモデルロードを含むため、2句目を含む値と除いた値を併記（水無瀬は該当なし）。

require "csv"

IN_PATH  = File.expand_path("../tmp/hyakuin_compare_verses.csv", __dir__)
OUT_PATH = File.expand_path("../tmp/verse_type_breakdown.csv", __dir__)

MOON_WORDS = %w[月].freeze
HANA_WORDS = %w[花 桜 櫻].freeze
AGEKU_VERSE_NO = 100
EXPECTED_VERSES = 99

RUN_LABELS = ["水無瀬三吟（人手注釈・参考）", "bonsai2-waka（0929）", "qwen3:14b（0929）"].freeze
MINASE = RUN_LABELS.first
TYPES = %w[月を含む句 花を含む句 挙句 平句].freeze
SEASONS = %w[春 夏 秋 冬 雑 恋].freeze

def moon?(v) = MOON_WORDS.any? { |w| v[:text].include?(w) }
def hana?(v) = HANA_WORDS.any? { |w| v[:text].include?(w) }
def ageku?(v) = v[:no] == AGEKU_VERSE_NO

def types_of(v)
  t = []
  t << "月を含む句" if moon?(v)
  t << "花を含む句" if hana?(v)
  t << "挙句" if ageku?(v)
  t << "平句" if t.empty?
  t
end

def mean(a) = a.empty? ? nil : a.sum.to_f / a.size
def median(a)
  return nil if a.empty?
  s = a.sort
  s.size.odd? ? s[s.size / 2] : (s[s.size / 2 - 1] + s[s.size / 2]) / 2.0
end
def fmt(x, d = 1) = x.nil? ? "-" : (x.is_a?(Float) ? format("%.#{d}f", x) : x.to_s)
def frac(k, n) = n.zero? ? "-" : "#{k}/#{n}（#{format('%.0f', 100.0 * k / n)}%）"

abort "入力がありません: #{IN_PATH}（M-5のscript/analyze_hyakuin_compare.rbを先に実行）" unless File.exist?(IN_PATH)

table = CSV.read(IN_PATH, headers: true)
verses_by_run = RUN_LABELS.to_h do |label|
  rows = table.select { |r| r["run"] == label }.map do |r|
    { no: r["verse_no"].to_i, text: r["text"].to_s, season: r["season"].to_s, status: r["status"].to_s,
      aux: r["classical_aux"] == "true", overlap: r["overlap_rate"].to_f,
      attempts: r["internal_attempts"].to_s.empty? ? nil : r["internal_attempts"].to_i,
      seconds: r["seconds"].to_s.empty? ? nil : r["seconds"].to_f }
  end
  abort "#{label}: #{rows.size}句（#{EXPECTED_VERSES}句必要）" unless rows.size == EXPECTED_VERSES && rows.map { |v| v[:no] }.sort == (2..100).to_a
  [label, rows.sort_by { |v| v[:no] }]
end

results = []
verses_by_run.each do |label, verses|
  TYPES.each do |type|
    vs = verses.select { |v| types_of(v).include?(type) }
    sc = SEASONS.to_h { |s| [s, vs.count { |v| v[:season] == s }] }
    secs_incl = vs.filter_map { |v| v[:seconds] }
    secs_excl = vs.reject { |v| v[:no] == 2 }.filter_map { |v| v[:seconds] }
    att = vs.filter_map { |v| v[:attempts] }
    results << {
      run: label, type: type, n: vs.size, seasons: sc,
      aux_k: vs.count { |v| v[:aux] }, overlap_k: vs.count { |v| v[:overlap] > 0 },
      forced_k: vs.count { |v| v[:status] == "FORCED" },
      attempts_mean: mean(att), sec_mean_incl: mean(secs_incl), sec_median_incl: median(secs_incl),
      sec_mean_excl: mean(secs_excl), sec_median_excl: median(secs_excl), n_excl: secs_excl.size,
      verse_nos: vs.map { |v| v[:no] }
    }
  end
end

CSV.open(OUT_PATH, "w") do |csv|
  csv << %w[run type n 春 夏 秋 冬 雑 恋 雑＋恋 classical_aux_n classical_aux_pct attempts_mean sec_mean_incl_v2 sec_median_incl_v2
            sec_mean_excl_v2 sec_median_excl_v2 overlap_pos_n overlap_pos_pct forced_n verse_nos]
  results.each do |r|
    s = r[:seasons]
    pct = ->(k) { r[:n].zero? ? nil : (100.0 * k / r[:n]).round(1) }
    csv << [r[:run], r[:type], r[:n], *%w[春 夏 秋 冬 雑 恋].map { |k| s[k] }, s["雑"] + s["恋"],
            r[:aux_k], pct.(r[:aux_k]), r[:attempts_mean]&.round(2), r[:sec_mean_incl]&.round(1), r[:sec_median_incl]&.round(1),
            r[:sec_mean_excl]&.round(1), r[:sec_median_excl]&.round(1), r[:overlap_k], pct.(r[:overlap_k]), r[:forced_k],
            r[:verse_nos].join(" ")]
  end
end

puts "入力: #{IN_PATH}（3 run × #{EXPECTED_VERSES}句）"
puts "出力: #{OUT_PATH}"
puts "定義: 月を含む句=text に「#{MOON_WORDS.join('」「')}」 / 花を含む句=「#{HANA_WORDS.join('」「')}」 / 挙句=verse_no #{AGEKU_VERSE_NO} / 平句=いずれにも当たらない句（簡易判定・定座とは別物）"
puts "注意: 種別ごとのnは各10句前後。大きな差だけを見る。季は2〜100句目の99句で集計（M-5表Aは発句込み100句）。"

puts "\n## 句種別 × run（n併記）"
puts "| run | 種別 | n | 春 | 夏 | 秋 | 冬 | 雑 | 恋 | 雑＋恋 | 文語助動詞を含む句 | 内部試行平均 | 前句と共有（overlap>0） | FORCED |"
puts "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
results.each do |r|
  s = r[:seasons]
  puts "| #{r[:run]} | #{r[:type]} | #{r[:n]} | #{s['春']} | #{s['夏']} | #{s['秋']} | #{s['冬']} | #{s['雑']} | #{r[:run] == MINASE ? s['恋'] : '-'} | #{s['雑'] + s['恋']} | " \
       "#{frac(r[:aux_k], r[:n])} | #{fmt(r[:attempts_mean])} | #{frac(r[:overlap_k], r[:n])} | #{r[:run] == MINASE ? '-' : r[:forced_k]} |"
end

puts "\n## 所要秒（観察ログの時刻差。水無瀬は該当なし）"
puts "| run | 種別 | n | 平均/中央値（2句目含む） | n（2句目除く） | 平均/中央値（2句目除く） |"
puts "|---|---|---:|---:|---:|---:|"
results.reject { |r| r[:run] == MINASE }.each do |r|
  puts "| #{r[:run]} | #{r[:type]} | #{r[:n]} | #{fmt(r[:sec_mean_incl], 0)}/#{fmt(r[:sec_median_incl], 0)} | #{r[:n_excl]} | #{fmt(r[:sec_mean_excl], 0)}/#{fmt(r[:sec_median_excl], 0)} |"
end

puts "\n## 検算（RC-2）"
verses_by_run.each do |label, verses|
  sets = TYPES.to_h { |t| [t, verses.select { |v| types_of(v).include?(t) }.map { |v| v[:no] }] }
  union = sets.values.flatten.uniq.size
  sum_n = sets.values.sum(&:size)
  moon_hana = (sets["月を含む句"] & sets["花を含む句"]).size
  moon_ageku = (sets["月を含む句"] & sets["挙句"]).size
  hana_ageku = (sets["花を含む句"] & sets["挙句"]).size
  ok = union == EXPECTED_VERSES && sum_n - moon_hana - moon_ageku - hana_ageku + (sets["月を含む句"] & sets["花を含む句"] & sets["挙句"]).size == EXPECTED_VERSES
  puts "#{label}: 種別n合計=#{sum_n} 和集合=#{union}/#{EXPECTED_VERSES} 重複（月∩花=#{moon_hana} 月∩挙句=#{moon_ageku} 花∩挙句=#{hana_ageku}） #{ok ? 'PASS' : 'FAIL'}"
end

puts "\n## 該当句の句番号（月を含む句・花を含む句・挙句）"
results.reject { |r| r[:type] == "平句" }.each { |r| puts "- #{r[:run]} #{r[:type]}: #{r[:verse_nos].empty? ? 'なし' : r[:verse_nos].join(' ')}" }
