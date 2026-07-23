# frozen_string_literal: true

# 其の五十九 D-59-1（c6ac7d5）配線修正の実戦検証。
# ShikimokuChecker自体は試験10・体用辞書ありブロック（verify_shikimoku.rb）で
# 既に正しさが証明済み。ここで確認したいのはそこではなく、RengasController側の
# 配線（build_verse_history・候補hash構築・all_violations呼び出し）が実際に
# :word/:text/:plant_type/bui_dict:を正しく伝搬させ、一座一句物・植物異種区分・
# 体用差別化を本番コードパス上で発火させられるか、という点。
#
# 実行: bin/rails runner script/verify_ichiza_taiyo_wiring.rb
# DB書き込みはトランザクション内で行い、最後にロールバックする（永続化なし）。

require "natto"

total_pass = 0
total_fail = 0

def check(label, got, want)
  ok = (got == want)
  puts "#{ok ? '  OK ' : '✗ NG '} #{label}"
  unless ok
    puts "       期待: #{want.inspect}"
    puts "       実際: #{got.inspect}"
  end
  ok
end

controller = RengasController.new
nm         = Natto::MeCab.new(userdic: RengaGenerator::USER_DIC) rescue Natto::MeCab.new
checker    = ShikimokuChecker.new

# rengas_controller.rb#create と同じ組み立て（本番コードの複製ではなく、
# そこと同一の呼び出し列であることが検証の前提なので、あえて手で並べる）。
def build_candidate(tsugeku, verse_type, nm, bui_dict, season_from_text:)
  word = bui_dict.detect_word(tsugeku, nm)
  {
    bui:        bui_dict.detect_all(tsugeku, nm),
    season:     season_from_text.call(tsugeku),
    verse_type: verse_type,
    word:       word,
    text:       tsugeku,
    plant_type: bui_dict.plant_type(word)
  }
end

season_from_text = ->(text) { controller.send(:season_from_text, text) }

puts "=" * 60
puts "D-59-1 配線検証：一座一句物 / 植物異種区分 / 体用"
puts "=" * 60

ActiveRecord::Base.transaction do
  bui_dict = BuiDictionary.new

  # ── Part A: 一座一句物（ichiza_violations） ──────────────
  # :text はMeCab非依存（tsugekuをそのまま保持するだけ）なので、production
  # dictionaryのままでも配線の有無がそのまま結果に出る、最もクリーンな確認対象。
  puts "-" * 60
  puts "Part A: 一座一句物（鶯の二度出し）"
  puts "-" * 60

  r1 = Renga.create!(maeku: "はるののどけき", tsugeku: "鶯なくねやの朝ぼらけ")
  r2 = Renga.create!(maeku: r1.tsugeku, tsugeku: "山風に散る紅葉かな", previous_renga_id: r1.id)
  r3 = Renga.create!(maeku: r2.tsugeku, tsugeku: "月影ぞすむ夜半の空", previous_renga_id: r2.id)

  history_a = controller.send(:build_verse_history, r3.id, r3.tsugeku, :tanku, nm: nm, bui_dict: bui_dict)
  cand_a    = build_candidate("鶯の声きく春の夕暮れ", :chouku, nm, bui_dict, season_from_text: season_from_text)

  after_a  = checker.ichiza_violations(history_a, cand_a)
  # 旧配線シミュレーション：修正前は candidate[:word]/[:text] が一度も設定されず、
  # cand_text = candidate[:word].to_s が常に "" だったため、include?判定が常にfalseだった。
  history_a_before = history_a.map { |h| h.merge(word: nil).except(:text) }
  cand_a_before     = cand_a.merge(word: nil).except(:text)
  before_a = checker.ichiza_violations(history_a_before, cand_a_before)

  puts "  修正後（本番と同じ呼び出し）: #{after_a.inspect}"
  puts "  修正前シミュレーション　　　: #{before_a.inspect}"
  r = check("修正後：鶯の再出を検出する", after_a.map { |v| v[:type] }, [:ichiza_duplicate])
  total_pass, total_fail = r ? [total_pass + 1, total_fail] : [total_pass, total_fail + 1]
  r = check("修正前（旧配線）：検出できない（バグ再現）", before_a, [])
  total_pass, total_fail = r ? [total_pass + 1, total_fail] : [total_pass, total_fail + 1]

  # ── Part B: 植物異種区分（kuzari cross句去） ──────────────
  # 植物は同種5句去・異種3句去（kuzari_rules.yml）。桜(flower)から2句あけて
  # 柳(tree)を出す構成なら、異種区分が効いていれば適法・効いていなければ違反。
  puts "-" * 60
  puts "Part B: 植物異種区分（桜→柳、間2句）"
  puts "-" * 60

  s1 = Renga.create!(maeku: "はるかすみ", tsugeku: "桜さく庭の面影")
  s2 = Renga.create!(maeku: s1.tsugeku, tsugeku: "鐘の音きこゆ夕まぐれ", previous_renga_id: s1.id)
  s3 = Renga.create!(maeku: s2.tsugeku, tsugeku: "旅の空にも慣れにけり", previous_renga_id: s2.id)

  history_b = controller.send(:build_verse_history, s3.id, s3.tsugeku, :tanku, nm: nm, bui_dict: bui_dict)
  cand_b    = build_candidate("柳ゆれる川辺の道", :chouku, nm, bui_dict, season_from_text: season_from_text)

  after_b = checker.all_violations(history_b, cand_b, bui_dict: bui_dict)
  # 旧配線シミュレーション：修正前は all_violations に bui_dict: が渡っておらず、
  # candidate[:word]/[:plant_type]も常にnilだったため、cross句去が一切選ばれず
  # 常にdefault（同種扱い＝5句去）が適用されていた。
  history_b_before = history_b.map { |h| h.merge(word: nil, plant_type: nil) }
  cand_b_before     = cand_b.merge(word: nil, plant_type: nil)
  before_b = checker.all_violations(history_b_before, cand_b_before)

  puts "  修正後（本番と同じ呼び出し）: #{after_b.inspect}"
  puts "  修正前シミュレーション　　　: #{before_b.inspect}"
  r = check("修正後：異種区分によりcross句去(3)が適用され適法", after_b.select { |v| v[:bui] == "植物" }, [])
  total_pass, total_fail = r ? [total_pass + 1, total_fail] : [total_pass, total_fail + 1]
  r = check("修正前（旧配線）：同種default(5)扱いで誤検出（バグ再現）",
            before_b.select { |v| v[:bui] == "植物" }.map { |v| [v[:bui], v[:required], v[:actual]] },
            [["植物", 5, 2]])
  total_pass, total_fail = r ? [total_pass + 1, total_fail] : [total_pass, total_fail + 1]

  # ── Part C: 体用（taiyo差別化） ────────────────────────────
  # production辞書の taiyo: 用 は舟/船の2語のみで、いずれも「水辺」句去(5)の
  # 判定窓を作るには「行く水」（唯一の体語）が必要だが、MeCabでは「行く」+「水」に
  # 分割され単一トークン一致しない（実測済み）。体用差別化そのものは実データの
  # 制約で実演できないため、ここだけ検証専用の最小辞書（月=体・灯=用、光物）を
  # BuiDictionary.new(path)に注入し、本番と同一のcontroller/checker呼び出し経路で
  # 確認する（辞書データが違うだけで、通すコードパスはPart A/Bと同一）。
  puts "-" * 60
  puts "Part C: 体用差別化（月[体]→灯[用]、光物）"
  puts "-" * 60

  taiyo_dict_path = Rails.root.join("tmp", "verify_taiyo_dict_#{Process.pid}.yml")
  File.write(taiyo_dict_path, <<~YAML)
    ---
    月:
      primary_bui: 光物
      taiyo: 体
    灯:
      primary_bui: 光物
      taiyo: 用
  YAML
  taiyo_dict = BuiDictionary.new(taiyo_dict_path)

  t1 = Renga.create!(maeku: "よもすがら", tsugeku: "旅の空にも慣れにけり")
  t2 = Renga.create!(maeku: t1.tsugeku, tsugeku: "月影ぞすむ夜半の空", previous_renga_id: t1.id)

  history_c = controller.send(:build_verse_history, t2.id, t2.tsugeku, :tanku, nm: nm, bui_dict: taiyo_dict)
  cand_c    = build_candidate("灯ひとつともる軒端かな", :chouku, nm, taiyo_dict, season_from_text: season_from_text)

  after_c = checker.all_violations(history_c, cand_c, bui_dict: taiyo_dict)
  history_c_before = history_c.map { |h| h.merge(word: nil) }
  cand_c_before     = cand_c.merge(word: nil)
  before_c = checker.all_violations(history_c_before, cand_c_before)

  puts "  修正後（本番と同じ呼び出し）: #{after_c.inspect}"
  puts "  修正前シミュレーション　　　: #{before_c.inspect}"
  r = check("修正後：体用が異なるため同一視されず適法", after_c.select { |v| v[:bui] == "光物" }, [])
  total_pass, total_fail = r ? [total_pass + 1, total_fail] : [total_pass, total_fail + 1]
  r = check("修正前（旧配線）：体用無視でpos2直後の再出扱い→違反（バグ再現）",
            before_c.select { |v| v[:bui] == "光物" }.map { |v| [v[:bui], v[:required], v[:actual]] },
            [["光物", 3, 0]])
  total_pass, total_fail = r ? [total_pass + 1, total_fail] : [total_pass, total_fail + 1]

  File.delete(taiyo_dict_path) if File.exist?(taiyo_dict_path)

  puts "=" * 60
  puts "総合：#{total_pass} pass / #{total_fail} fail　（DB書き込みはこの後rollback）"
  puts "=" * 60

  raise ActiveRecord::Rollback
end

puts "（Renga.create!分はロールバック済み・DBへの永続化なし）"
exit(total_fail.zero? ? 0 : 1)
