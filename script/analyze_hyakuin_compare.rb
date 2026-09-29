# frozen_string_literal: true
# 依頼書M-5 Phase1: 百韻走行の機械集計（bonsai2-waka × qwen3:14b、参考行に水無瀬三吟・0925の2本）
#
# 実行: bin/rails runner script/analyze_hyakuin_compare.rb
#   RUN_KEYS=bonsai2,0925a,0925b  で対象runを絞れる（既定は全run。未完走のrunは中断する）
# 出力: tmp/hyakuin_compare_verses.csv（句単位）/ tmp/hyakuin_compare_summary.csv（run別・折別、縦持ち）/ 標準出力の表
# app/・OverlapGuard・辞書は変更しない。Ollamaは呼ばない（ログとMeCab・BuiDictionaryのみ）。優劣の判定はしない。
#
# ── 定義（表の読み方） ──────────────────────────────────────────
# ・対象句: 生成側は2〜100句目（1句目は固定の発句）。ペアは前句1〜99→付句2〜100の99組。折は前句の句番で割り当てる
#   （build_minase_scoresheet.rbのFOLD_MAPと同じ）。水無瀬は句1〜100・99組。
# ・overlap_rate: OverlapGuard.overlap_rate（前句⇄付句の内容語ジャッカード重複率、0.0=独立〜1.0=同一。品詞は名詞・動詞・形容詞・
#   副詞、表層形）。build_minase_scoresheet.rbの「非重複率」とは逆向きなので注意。全runで観察ログの本文から再計算する。
# ・bui: 各句の本文から現行のBuiDictionary（115語）で再検出（ログ記録値は使わない）。bui_distance_auto=前句・付句のbui集合の
#   Jaccard距離。どちらかが空集合ならN/A（平均から除外、N/A率・有効ペア数を併記）。水無瀬のみ人手注釈bui（hand）も併記。
# ・季: 観察ログ4列目（空欄=雑）を発句込み100句で集計。水無瀬は人手注釈の季列。水無瀬の「恋」は別欄、「雑＋恋」も併記
#   （生成側の雑との比較は「雑＋恋」で行う）。
# ・C 内部試行: jsonlの1行=1試行。外側呼出=1句内でinternal_attemptが増えない箇所（1に戻る）で区切った回数。
#   「外側リトライ句」=外側呼出が2回以上の句。所要秒=観察ログの時刻差（n句目−n-1句目）。2句目はモデルロードを含むため
#   「2句目含む(99句)」と「2句目除く(98句)」を併記。0925はOverlapGuard導入前でpartial_echoの記録なし（"-"）。
# ・D 語彙: 内容語=IPADIC品詞が名詞・動詞・形容詞（副詞は含めない）で、品詞細分類1が「非自立・代名詞・数・接尾」のものを除き、
#   原形（原形が"*"なら表層形）で数える。延べ=出現総数、異なり=種類数。対象は2〜100句目。「前句と共有する句」は
#   overlap_rate>0の句（OverlapGuard定義＝表層形・副詞込み）の割合。
# ・E 文語助動詞: IPADIC品詞が助動詞で原形がCLASSICAL_AUXにある形態素を1つ以上含む句の割合（簡易指標・参考値）。
# ────────────────────────────────────────────────────────────

require "csv"
require "json"
require "natto"
require "time"

LOG_DIR = Rails.root.join("log")
OUT_VERSES  = Rails.root.join("tmp", "hyakuin_compare_verses.csv")
OUT_SUMMARY = Rails.root.join("tmp", "hyakuin_compare_summary.csv")

RUN_DEFS = [
  { key: "bonsai2", label: "bonsai2-waka（0929）", log: "observe_rg_20260929_bonsai2_final.log",
    jsonl_dates: %w[20260928 20260929], guard: true },
  { key: "qwen14b", label: "qwen3:14b（0929）", log: "observe_rg_20260929_qwen14b_final.log",
    jsonl_dates: %w[20260929 20260930], guard: true },
  { key: "0925a", label: "0925（モデル記録なし、14bとされる）[observe_rg_20260925.log]", log: "observe_rg_20260925.log",
    jsonl_dates: %w[20260925 20260926], guard: false },
  { key: "0925b", label: "0925（モデル記録なし、14bとされる）[observe_rg_20260925_3_complete.log]", log: "observe_rg_20260925_3_complete.log",
    jsonl_dates: %w[20260924 20260925], guard: false }
].freeze
MINASE_LABEL = "水無瀬三吟（人手注釈・参考）"

FOLD_MAP = [
  { range: (1..8),   ori: "初折表" },
  { range: (9..22),  ori: "初折裏" },
  { range: (23..36), ori: "二折表" },
  { range: (37..50), ori: "二折裏" },
  { range: (51..64), ori: "三折表" },
  { range: (65..78), ori: "三折裏" },
  { range: (79..92), ori: "名残折表" },
  { range: (93..99), ori: "名残折裏" }
].freeze
ORI_NAMES = FOLD_MAP.map { |f| f[:ori] }.freeze
def fold_of(maeku_no) = (FOLD_MAP.find { |f| f[:range].include?(maeku_no) } || {})[:ori] || "不明"

# 水無瀬の人手注釈buiの目標値（docs/distance evaluation design.md §5.2、build_minase_scoresheet.rbと同じ）
HAND_TARGET = { "初折表" => 0.750, "初折裏" => 0.792, "二折表" => 0.833, "二折裏" => 0.887,
                "三折表" => 0.875, "三折裏" => 0.714, "名残折表" => 0.750, "名残折裏" => 0.679 }.freeze

CLASSICAL_AUX = %w[けり らむ けむ べし ぬ つ たり なり ず まし らし めり じ む き り].freeze
CONTENT_POS_D = %w[名詞 動詞 形容詞].freeze
EXCLUDE_SUB1_D = %w[非自立 代名詞 数 接尾].freeze
REASONS = %w[mora_mismatch empty echo partial_echo content_violation].freeze

# M-3 Phase 2報告（bonsai2）の再現基準（RC-3）
RC3_EXPECT = { forced: 3, seasons: { "春" => 15, "夏" => 5, "秋" => 56, "冬" => 8, "雑" => 16 },
               attempts: 1236, partial_echo: 78, outer_calls: { 1 => 62, 2 => 28, 3 => 3, 4 => 3, 5 => 3 } }.freeze

NM = begin
  Natto::MeCab.new(userdic: RengaGenerator::USER_DIC)
rescue StandardError
  Natto::MeCab.new
end
BUI = BuiDictionary.new

# ── 共通ヘルパ ──
def sanitize(t) = t.to_s.gsub(/[、\s　]/, "")
def mean(a) = a.empty? ? nil : a.sum.to_f / a.size
def median(a)
  return nil if a.empty?
  s = a.sort
  s.size.odd? ? s[s.size / 2] : (s[s.size / 2 - 1] + s[s.size / 2]) / 2.0
end
def fmt(x, d = 3) = x.nil? ? "-" : (x.is_a?(Float) ? format("%.#{d}f", x) : x.to_s)
def pct(n, d) = d.zero? ? nil : (100.0 * n / d)
def jaccard_distance(a, b)
  return 1.0 if a.empty? && b.empty?
  1.0 - (a & b).size.to_f / (a | b).size
end

def content_tokens(text)
  out = []
  NM.parse(text.to_s.gsub(/[\s　]+/, "")) do |node|
    next if node.is_eos?
    f = node.feature.split(",")
    next unless CONTENT_POS_D.include?(f[0])
    next if EXCLUDE_SUB1_D.include?(f[1])
    out << ((f[6].nil? || f[6] == "*") ? node.surface : f[6])
  end
  out
end

def classical_aux_hits(text)
  hits = []
  NM.parse(text.to_s.gsub(/[\s　]+/, "")) do |node|
    next if node.is_eos?
    f = node.feature.split(",")
    next unless f[0] == "助動詞"
    base = (f[6].nil? || f[6] == "*") ? node.surface : f[6]
    hits << base if CLASSICAL_AUX.include?(base)
  end
  hits
end

# ── 観察ログ・jsonl ──
LOG_RE = /\A\[(.+?)\] (\d{3}) \| (.*?) \| (.*?) \| (.*?) \| (.*?) \| (.*?) \| (.*)\z/

def parse_log(path)
  File.readlines(path, chomp: true).filter_map do |l|
    m = LOG_RE.match(l) or next
    { no: m[2].to_i, time: Time.parse(m[1]), season: m[5].strip.empty? ? "雑" : m[5].strip,
      forced: m[7].start_with?("FORCED"), text: m[8] }
  end
end

def load_jsonl_rows(dates)
  dates.flat_map do |d|
    p = LOG_DIR.join("renga_internal_observe_rg_#{d}.jsonl")
    File.exist?(p) ? File.readlines(p).map { |l| JSON.parse(l) } : []
  end
end

# 同一ファイルに複数runが追記されるため、verse_noが減る箇所でrunを区切る。
def split_segments(rows)
  segs = [[]]
  prev = nil
  rows.each do |r|
    segs << [] if prev && r["verse_no"] < prev
    segs.last << r
    prev = r["verse_no"]
  end
  segs.reject(&:empty?)
end

# 観察ログの本文と一致する句数が最大のセグメントをそのrunのjsonlとして採用する。
def pick_segment(segments, log_verses)
  scored = segments.map do |seg|
    by = seg.group_by { |r| r["verse_no"] }
    hit = log_verses.count { |v| v[:no] >= 2 && (by[v[:no]] || []).any? { |r| sanitize(r["first_line_result"]) == sanitize(v[:text]) } }
    [hit, seg]
  end
  scored.max_by.with_index { |(hit, _), i| [hit, i] }
end

# ── ペア指標 ──
def pair_rows(texts, guard_nm: NM)
  bui = texts.transform_values { |t| BUI.detect_all(t, NM) }
  (2..100).map do |n|
    maeku = texts[n - 1]
    text  = texts[n]
    mb = bui[n - 1]
    tb = bui[n]
    na = mb.empty? || tb.empty?
    { no: n, ori: fold_of(n - 1), maeku: maeku, text: text,
      overlap_rate: OverlapGuard.overlap_rate(maeku, text, guard_nm),
      maeku_bui: mb, bui: tb, bui_na: na,
      bui_distance: na ? nil : jaccard_distance(mb, tb) }
  end
end

# ── 入力の読み込み ──
selected = (ENV["RUN_KEYS"] ? ENV["RUN_KEYS"].split(",").map(&:strip) : RUN_DEFS.map { |r| r[:key] })
runs = []

RUN_DEFS.select { |d| selected.include?(d[:key]) }.each do |d|
  log = parse_log(LOG_DIR.join(d[:log]))
  abort "#{d[:label]}: 観察ログが#{log.size}行（100行必要。未完走の可能性）" unless log.map { |v| v[:no] } == (1..100).to_a
  segs = split_segments(load_jsonl_rows(d[:jsonl_dates]))
  hit, seg = pick_segment(segs, log)
  abort "#{d[:label]}: jsonlのセグメントと本文が一致しない（一致#{hit}/99）" unless hit == 99
  runs << d.merge(verses: log, texts: log.to_h { |v| [v[:no], v[:text]] }, jsonl: seg, jsonl_hit: hit)
end

# 水無瀬三吟（docs/minase_sangin_hyakuin.md）
minase = []
File.foreach(Rails.root.join("docs", "minase_sangin_hyakuin.md")) do |line|
  next unless line.start_with?("|")
  c = line.split("|").map(&:strip)
  next unless c[1] =~ /\A\d+\z/ && c[1].to_i.between?(1, 100) && %w[長 短].include?(c[2])
  hand = (c[6] || "").split("・").map { |b| b.gsub(/（[^）]*）/, "").strip }.reject(&:empty?)
  minase << { no: c[1].to_i, text: c[4], season: c[5], bui_hand: hand }
end
minase.sort_by! { |v| v[:no] }
abort "水無瀬三吟が#{minase.size}句（100句必要）" unless minase.map { |v| v[:no] } == (1..100).to_a

# ── 集計 ──
verse_rows = []    # 句単位CSV
summary = []       # [run, scope, metric, value]
tables = {}        # 標準出力用

def add(summary, run, scope, metric, value) = summary << [run, scope, metric, value.is_a?(Float) ? value.round(6) : value]

def pair_summary(summary, run, pairs, hand: nil)
  scopes = [["全体", pairs]] + ORI_NAMES.map { |o| [o, pairs.select { |p| p[:ori] == o }] }
  scopes.map do |scope, ps|
    valid = ps.reject { |p| p[:bui_na] }
    row = { scope: scope, n: ps.size, overlap: mean(ps.map { |p| p[:overlap_rate] }),
            valid: valid.size, na_rate: pct(ps.size - valid.size, ps.size),
            bui: mean(valid.map { |p| p[:bui_distance] }) }
    add(summary, run, scope, "B_pairs", ps.size)
    add(summary, run, scope, "B_mean_overlap_rate", row[:overlap])
    add(summary, run, scope, "B_bui_valid_pairs", valid.size)
    add(summary, run, scope, "B_bui_na_rate_pct", row[:na_rate])
    add(summary, run, scope, "B_mean_bui_distance_auto", row[:bui])
    if hand
      hp = ps.map { |p| hand[p[:no] - 2] }
      row[:hand] = mean(hp)
      row[:target] = HAND_TARGET[scope]
      add(summary, run, scope, "B_mean_bui_distance_hand", row[:hand])
      add(summary, run, scope, "B_hand_target", row[:target]) if row[:target]
    end
    row
  end
end

def season_row(summary, run, counts, has_koi)
  base = %w[春 夏 秋 冬 雑].to_h { |s| [s, counts[s]] }
  base["恋"] = has_koi ? counts["恋"] : nil
  base["雑＋恋"] = counts["雑"] + counts["恋"]
  base.each { |k, v| add(summary, run, "全体", "A_season_#{k}", v) }
  base
end

def vocab_rows(summary, run, texts_2_100, pairs)
  toks = texts_2_100.flat_map { |t| content_tokens(t) }
  tally = toks.tally.sort_by { |w, c| [-c, w] }
  top10 = tally.first(10).map { |w, c| "#{w}:#{c}" }.join(" ")
  shared = pairs.count { |p| p[:overlap_rate] > 0 }
  aux_verses = texts_2_100.map { |t| classical_aux_hits(t) }
  aux_tally = aux_verses.flatten.tally.sort_by { |w, c| [-c, w] }.map { |w, c| "#{w}:#{c}" }.join(" ")
  d = { total: toks.size, unique: tally.size, top10: top10, shared: shared, shared_pct: pct(shared, pairs.size),
        aux_verses: aux_verses.count { |h| !h.empty? }, aux_pct: pct(aux_verses.count { |h| !h.empty? }, aux_verses.size), aux_tally: aux_tally }
  add(summary, run, "全体", "D_content_words_total", d[:total])
  add(summary, run, "全体", "D_content_words_unique", d[:unique])
  add(summary, run, "全体", "D_top10", d[:top10])
  add(summary, run, "全体", "D_verses_sharing_with_maeku", d[:shared])
  add(summary, run, "全体", "D_verses_sharing_with_maeku_pct", d[:shared_pct])
  add(summary, run, "全体", "E_classical_aux_verses", d[:aux_verses])
  add(summary, run, "全体", "E_classical_aux_pct", d[:aux_pct])
  add(summary, run, "全体", "E_classical_aux_hits", d[:aux_tally])
  [d, aux_verses]
end

# 水無瀬
m_texts = minase.to_h { |v| [v[:no], v[:text]] }
m_pairs = pair_rows(m_texts)
m_hand = (0..98).map { |i| jaccard_distance(minase[i][:bui_hand], minase[i + 1][:bui_hand]) }
tables[MINASE_LABEL] = { pairs: pair_summary(summary, MINASE_LABEL, m_pairs, hand: m_hand) }
m_counts = Hash.new(0).tap { |h| %w[春 夏 秋 冬 雑 恋].each { |s| h[s] = 0 }; minase.each { |v| h[v[:season]] += 1 } }
tables[MINASE_LABEL][:season] = season_row(summary, MINASE_LABEL, m_counts, true)
m_vocab, m_aux = vocab_rows(summary, MINASE_LABEL, (2..100).map { |n| m_texts[n] }, m_pairs)
tables[MINASE_LABEL][:vocab] = m_vocab
m_pairs.each_with_index do |p, i|
  verse_rows << [MINASE_LABEL, p[:no], p[:ori], minase[p[:no] - 1][:season], "", p[:maeku], p[:text], p[:overlap_rate].round(6),
                 p[:maeku_bui].join("・"), p[:bui].join("・"), p[:bui_distance]&.round(6), p[:bui_na], nil, nil, nil, nil, !m_aux[i].empty?]
end
m_max = m_pairs.map { |p| p[:overlap_rate] }.max

# 生成run
runs.each do |r|
  label = r[:label]
  t = { }
  pairs = pair_rows(r[:texts])
  t[:pairs] = pair_summary(summary, label, pairs)

  counts = Hash.new(0).tap { |h| %w[春 夏 秋 冬 雑 恋].each { |s| h[s] = 0 }; r[:verses].each { |v| h[v[:season]] += 1 } }
  t[:season] = season_row(summary, label, counts, false)
  forced = r[:verses].count { |v| v[:forced] }
  add(summary, label, "全体", "A_forced", forced)

  # C: 内部試行
  rows = r[:jsonl]
  by_verse = rows.group_by { |x| x["verse_no"] }
  reasons = rows.map { |x| x["rejection_reason"] }.tally
  total = rows.size
  outer = by_verse.transform_values do |vr|
    prev = nil
    vr.count { |x| c = prev.nil? || x["internal_attempt"] <= prev; prev = x["internal_attempt"]; c }
  end
  outer_dist = outer.values.tally.sort.to_h
  pe_verses = by_verse.count { |_, vr| vr.any? { |x| x["rejection_reason"] == "partial_echo" } }
  times = r[:verses].each_cons(2).map { |a, b| [b[:no], b[:time] - a[:time]] }.to_h
  secs_all = times.values
  secs_ex2 = times.reject { |n, _| n == 2 }.values
  c = { total: total, per_verse: mean(by_verse.values.map(&:size)), reasons: reasons, outer_verses: outer.count { |_, v| v >= 2 },
        outer_dist: outer_dist, pe_verses: pe_verses,
        med_all: median(secs_all), mean_all: mean(secs_all), med_ex2: median(secs_ex2), mean_ex2: mean(secs_ex2), sec2: times[2] }
  add(summary, label, "全体", "C_internal_attempts_total", total)
  add(summary, label, "全体", "C_internal_attempts_per_verse_mean", c[:per_verse])
  REASONS.each do |k|
    n = reasons[k].to_i
    na = (k == "partial_echo" && !r[:guard])
    add(summary, label, "全体", "C_#{k}_count", na ? "-" : n)
    add(summary, label, "全体", "C_#{k}_pct", na ? "-" : pct(n, total))
  end
  add(summary, label, "全体", "C_accepted_count", reasons[nil].to_i)
  add(summary, label, "全体", "C_accepted_pct", pct(reasons[nil].to_i, total))
  add(summary, label, "全体", "C_verses_with_outer_retry", c[:outer_verses])
  add(summary, label, "全体", "C_outer_calls_distribution", outer_dist.map { |k, v| "#{k}回:#{v}句" }.join(" "))
  add(summary, label, "全体", "C_verses_with_partial_echo", r[:guard] ? pe_verses : "-")
  add(summary, label, "全体", "C_seconds_median_incl_verse2", c[:med_all])
  add(summary, label, "全体", "C_seconds_mean_incl_verse2", c[:mean_all])
  add(summary, label, "全体", "C_seconds_median_excl_verse2", c[:med_ex2])
  add(summary, label, "全体", "C_seconds_mean_excl_verse2", c[:mean_ex2])
  add(summary, label, "全体", "C_seconds_verse2", c[:sec2])
  t[:c] = c

  d, aux = vocab_rows(summary, label, (2..100).map { |n| r[:texts][n] }, pairs)
  t[:vocab] = d
  t[:forced] = forced
  tables[label] = t

  pairs.each_with_index do |p, i|
    vr = by_verse[p[:no]] || []
    verse_rows << [label, p[:no], p[:ori], r[:verses][p[:no] - 1][:season], r[:verses][p[:no] - 1][:forced] ? "FORCED" : "OK",
                   p[:maeku], p[:text], p[:overlap_rate].round(6), p[:maeku_bui].join("・"), p[:bui].join("・"),
                   p[:bui_distance]&.round(6), p[:bui_na], vr.size, outer[p[:no]],
                   r[:guard] ? vr.count { |x| x["rejection_reason"] == "partial_echo" } : nil,
                   times[p[:no]]&.round(1), !aux[i].empty?]
  end
end

# ── ファイル出力 ──
verse_headers = %w[run verse_no ori season status maeku_text text overlap_rate maeku_bui_auto bui_auto bui_distance_auto bui_na
                   internal_attempts outer_calls partial_echo_count seconds classical_aux]
CSV.open(OUT_VERSES, "w") { |csv| csv << verse_headers; verse_rows.each { |r| csv << r } }
CSV.open(OUT_SUMMARY, "w") { |csv| csv << %w[run scope metric value]; summary.each { |r| csv << r } }

# ── 標準出力 ──
labels = [MINASE_LABEL] + runs.map { |r| r[:label] }
puts "出力: #{OUT_VERSES}（#{verse_rows.size}行） / #{OUT_SUMMARY}（#{summary.size}行）"
runs.each { |r| puts "読込: #{r[:label]}  句数=#{r[:verses].size}  jsonl試行行数=#{r[:jsonl].size}（本文一致 #{r[:jsonl_hit]}/99）" }
puts "読込: #{MINASE_LABEL}  句数=#{minase.size}"

puts "\n## A 式目・季（発句込み100句）"
puts "| run | FORCED | 春 | 夏 | 秋 | 冬 | 雑 | 恋 | 雑＋恋 |"
puts "|---|---:|---:|---:|---:|---:|---:|---:|---:|"
labels.each do |l|
  s = tables[l][:season]
  puts "| #{l} | #{l == MINASE_LABEL ? '-' : tables[l][:forced]} | #{s['春']} | #{s['夏']} | #{s['秋']} | #{s['冬']} | #{s['雑']} | #{fmt(s['恋'])} | #{s['雑＋恋']} |"
end

puts "\n## B 距離（折別。overlap_rate=重複率の平均、bui_auto=N/A除外平均。水無瀬はhand平均と目標値も併記）"
labels.each do |l|
  puts "\n### #{l}"
  puts(l == MINASE_LABEL ? "| 折 | 組数 | overlap_rate平均 | bui_auto有効/組(N/A率%) | bui_auto平均 | bui_hand平均 | hand目標 |" :
                           "| 折 | 組数 | overlap_rate平均 | bui_auto有効/組(N/A率%) | bui_auto平均 |")
  puts(l == MINASE_LABEL ? "|---|---:|---:|---:|---:|---:|---:|" : "|---|---:|---:|---:|---:|")
  tables[l][:pairs].each do |p|
    base = "| #{p[:scope]} | #{p[:n]} | #{fmt(p[:overlap])} | #{p[:valid]}/#{p[:n]}（#{fmt(p[:na_rate], 1)}） | #{fmt(p[:bui])} |"
    puts(l == MINASE_LABEL ? "#{base} #{fmt(p[:hand])} | #{fmt(p[:target])} |" : base)
  end
end

puts "\n## C コスト"
puts "| run | 内部試行計 | 1句あたり試行 | mora_mismatch% | empty% | echo% | partial_echo% | content_violation% | 採用% | 外側リトライ句 | partial_echo句 | 秒中央(2句目含)/平均 | 秒中央(除く)/平均 | 2句目秒 |"
puts "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
runs.each do |r|
  c = tables[r[:label]][:c]
  pc = ->(k) { (k == "partial_echo" && !r[:guard]) ? "-" : fmt(pct(c[:reasons][k].to_i, c[:total]), 1) }
  puts "| #{r[:label]} | #{c[:total]} | #{fmt(c[:per_verse], 1)} | #{pc.('mora_mismatch')} | #{pc.('empty')} | #{pc.('echo')} | #{pc.('partial_echo')} | #{pc.('content_violation')} | #{fmt(pct(c[:reasons][nil].to_i, c[:total]), 1)} | #{c[:outer_verses]}（#{c[:outer_dist].map { |k, v| "#{k}回:#{v}" }.join(' ')}） | #{r[:guard] ? c[:pe_verses] : '-'} | #{fmt(c[:med_all], 0)}/#{fmt(c[:mean_all], 0)} | #{fmt(c[:med_ex2], 0)}/#{fmt(c[:mean_ex2], 0)} | #{fmt(c[:sec2], 0)} |"
end

puts "\n## D 語彙の偏り / E 文語助動詞（2〜100句目）"
puts "| run | 内容語延べ | 異なり | 前句と共有する句 | 文語助動詞を含む句 | 出現上位10語 |"
puts "|---|---:|---:|---:|---:|---|"
labels.each do |l|
  d = tables[l][:vocab]
  puts "| #{l} | #{d[:total]} | #{d[:unique]} | #{d[:shared]}/99（#{fmt(d[:shared_pct], 1)}%） | #{d[:aux_verses]}/99（#{fmt(d[:aux_pct], 1)}%） | #{d[:top10]} |"
end
puts "\n文語助動詞の内訳（原形:回数）"
labels.each { |l| puts "- #{l}: #{tables[l][:vocab][:aux_tally].empty? ? 'なし' : tables[l][:vocab][:aux_tally]}" }

puts "\n## 検算"
puts "水無瀬99組 OverlapGuard.overlap_rate 最大=#{fmt(m_max, 6)}（期待 0.111111＝pair37、OverlapGuard::THRESHOLD=#{OverlapGuard::THRESHOLD}）"
hand_ok = tables[MINASE_LABEL][:pairs].drop(1).all? { |p| (p[:hand] - p[:target]).abs <= 0.001 }
puts "水無瀬 bui_hand折別平均 vs 目標値（±0.001）: #{hand_ok ? 'PASS（8折一致）' : 'FAIL'}"
if (b = runs.find { |r| r[:key] == "bonsai2" })
  t = tables[b[:label]]
  checks = {
    "FORCED" => [t[:forced], RC3_EXPECT[:forced]],
    "季節分布" => [%w[春 夏 秋 冬 雑].to_h { |s| [s, t[:season][s]] }, RC3_EXPECT[:seasons]],
    "内部試行総数" => [t[:c][:total], RC3_EXPECT[:attempts]],
    "partial_echo件数" => [t[:c][:reasons]["partial_echo"].to_i, RC3_EXPECT[:partial_echo]],
    "外側呼出/句の分布" => [t[:c][:outer_dist], RC3_EXPECT[:outer_calls]]
  }
  puts "RC-3（bonsai2 × M-3 Phase 2報告値）:"
  checks.each { |k, (got, exp)| puts "  #{k}: 実測=#{got} 期待=#{exp} #{got == exp ? 'PASS' : 'FAIL'}" }
  puts "  RC-3総合: #{checks.values.all? { |g, e| g == e } ? 'PASS' : 'FAIL'}"
end
