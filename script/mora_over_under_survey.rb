# frozen_string_literal: true
#
# モーラ過不足率調査（Phase 0・read-only）
# 依頼書 2026-09-08「モーラ過不足率調査」
#
# 使い方:
#   bin/rails runner script/mora_over_under_survey.rb
#
# 本番VPS では renga_verses（インタラクティブ成立句）に成立句が揃ってから
# （目安: 数週間運用後）実行する。ローカルでは observation_batch 分のみ集計される。
#
# 判定:
#   実測モーラ数（KuValidator#count_mora）を句種の目標音数と比較
#     ピタリ   = 実測 == 目標
#     字余り   = 実測 >  目標
#     字足らず = 実測 <  目標
#   長句(chouku)=17音 / 短句(tanku)=14音
#
# read-only: SELECT のみ。INSERT/UPDATE/DELETE/DDL は一切行わない。

TARGET = { chouku: 17, tanku: 14 }.freeze

def norm_type(t)
  t.to_s.start_with?("cho") ? :chouku : :tanku
end

def classify(mora, target)
  return :pitari if mora == target
  mora > target ? :over : :under
end

def mora_of(text)
  KuValidator.new(text).count_mora
end

def print_block(label, rows) # rows: array of [mora, target]
  c = { pitari: 0, over: 0, under: 0 }
  rows.each { |mora, target| c[classify(mora, target)] += 1 }
  n = rows.size
  fmt = ->(k) { format("%d件 (%.1f%%)", c[k], n.zero? ? 0.0 : c[k] * 100.0 / n) }
  puts "【#{label}】"
  puts "  ピタリ:    #{fmt.call(:pitari)}"
  puts "  字余り:    #{fmt.call(:over)}"
  puts "  字足らず:  #{fmt.call(:under)}"
  puts "  合計:      #{n}件"
  puts
end

renga_count_before      = Renga.count
rengaverse_count_before  = RengaVerse.count

# ============================================================
# 集計1: renga_verses（インタラクティブ成立句）
# ============================================================
puts "=== インタラクティブ成立句（renga_verses）==="
verses = RengaVerse.all.to_a

if verses.empty?
  puts "（renga_verses に成立句が 0 件。集計対象なし）"
  puts
else
  maeku_rows   = []
  tsugeku_rows = []

  verses.each do |v|
    # 前句: maeku_type（無ければ tsugeku_type の逆）から目標を決める
    if v.maeku.present?
      mtype = if v.maeku_type.present?
                norm_type(v.maeku_type)
              else
                norm_type(v.tsugeku_type) == :chouku ? :tanku : :chouku
              end
      maeku_rows << [mora_of(v.maeku), TARGET[mtype]]
    end

    # 付句: tsugeku_type（null:false）から目標を決める
    ttype = norm_type(v.tsugeku_type)
    tsugeku_rows << [mora_of(v.tsugeku), TARGET[ttype]]
  end

  print_block("前句（maeku）",   maeku_rows)
  print_block("付句（tsugeku）", tsugeku_rows)
end

# ============================================================
# 集計2: rengas（自動生成パイプライン）
# ============================================================
# 依頼書 literal は status:"done" だが、旧観測パイプラインは status カラム後付けで
# 全行 "pending" のまま。tsugeku が埋まっている行を成立とみなして集計する。
puts "=== 自動生成パイプライン（observation_batch）==="

obs        = Renga.where.not(observation_batch: nil)
literal_n  = obs.where(status: "done").where.not(tsugeku: [nil, ""]).count
rows       = obs.where.not(tsugeku: [nil, ""]).to_a

puts "（参考）依頼書 literal 条件 status=\"done\": #{literal_n} 件"
puts "（実集計）status 不問・tsugeku 非空: #{rows.size} 件"
puts

maeku_rows   = []
tsugeku_rows = []
skipped      = 0

rows.each do |r|
  next if r.maeku.blank?
  maeku_mora   = mora_of(r.maeku)
  maeku_type   = KuValidator.nearest_verse_type(maeku_mora)
  tsugeku_type = (maeku_type == :chouku) ? :tanku : :chouku
  maeku_rows   << [maeku_mora, TARGET[maeku_type]]
  tsugeku_rows << [mora_of(r.tsugeku), TARGET[tsugeku_type]]
rescue => e
  skipped += 1
  warn "skip renga##{r.id}: #{e.class} #{e.message}"
end

print_block("付句（tsugeku）", tsugeku_rows)
puts "（参考）"
print_block("前句（maeku）", maeku_rows)
puts "skipped: #{skipped} 件" if skipped.positive?

# batch 別内訳（世代差の確認用）
puts "--- batch 別（付句 tsugeku）---"
rows.group_by(&:observation_batch).sort.each do |batch, rs|
  c = { pitari: 0, over: 0, under: 0 }
  rs.each do |r|
    next if r.maeku.blank?
    mt = KuValidator.nearest_verse_type(mora_of(r.maeku))
    tt = (mt == :chouku) ? :tanku : :chouku
    c[classify(mora_of(r.tsugeku), TARGET[tt])] += 1
  end
  n = rs.size
  puts format("  %-46s n=%-4d ピタリ%5.1f%%  字余り%5.1f%%  字足らず%5.1f%%",
              batch, n,
              c[:pitari] * 100.0 / n, c[:over] * 100.0 / n, c[:under] * 100.0 / n)
end
puts

# ============================================================
# read-only 確認
# ============================================================
puts "=== read-only 確認 ==="
puts "Renga.count:      #{renga_count_before} -> #{Renga.count}"
puts "RengaVerse.count: #{rengaverse_count_before} -> #{RengaVerse.count}"
puts "（このスクリプトは SELECT のみ。書き込みなし）"
