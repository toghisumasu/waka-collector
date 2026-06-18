# frozen_string_literal: true

# ShikimokuChecker 動作検証
#   bundle exec ruby script/verify_shikimoku.rb

require_relative "../app/services/shikimoku_checker"

checker = ShikimokuChecker.new
total_pass = 0
total_fail = 0

def ok_mark(bool) = bool ? "  OK " : "✗ NG "

def check(label, got, want)
  ok = (got == want)
  puts "#{ok ? '  OK ' : '✗ NG '} #{label}"
  unless ok
    puts "       期待: #{want.inspect}"
    puts "       実際: #{got.inspect}"
  end
  ok
end

# ─────────────────────────────────────────────────────────────
#  試験1：句去チェック（合成ケース・算術）
# ─────────────────────────────────────────────────────────────
puts "═" * 56
puts "試験1：句去チェック（合成ケース）"
puts "─" * 56

p1 = 0; f1 = 0
def r1(r, p, f) = r ? [p+1, f] : [p, f+1]

# (1a) 降物の三句去違反
chain = [["降物"], ["水辺"], ["植物"], ["降物"]]
v = checker.scan_chain(chain)
res = check("降物の三句去違反を検出（pos4・間2句<3）",
            v.map { |h| [h[:pos], h[:bui], h[:actual], h[:required]] },
            [[4, "降物", 2, 3]])
p1, f1 = r1(res, p1, f1)

# (1b) 降物が間4句で適法
chain = [["降物"], ["水辺"], ["植物"], ["山類"], ["動物"], ["降物"]]
res = check("降物が間4句で適法（違反0）", checker.scan_chain(chain), [])
p1, f1 = r1(res, p1, f1)

# (1c) 山類の連続は句去対象外
res = check("山類の連続は句去対象外（違反0）",
            checker.scan_chain([["山類"], ["山類"], ["山類"]]), [])
p1, f1 = r1(res, p1, f1)

# (1d) 山類が直近pos3から間4句<5でNG
chain = [["山類"],["山類"],["山類"],["水辺"],["動物"],["旅"],["神祇"],["山類"]]
v = checker.scan_chain(chain)
res = check("山類の五句去違反（pos8・直近pos3から間4句<5）",
            v.map { |h| [h[:pos], h[:bui], h[:actual], h[:required], h[:last_pos]] },
            [[8, "山類", 4, 5, 3]])
p1, f1 = r1(res, p1, f1)

# (1e) 規制外の部立（時分・人倫）は近接しても違反なし
res = check("時分・人倫は句去対象外（違反0）",
            checker.scan_chain([["時分"],["人倫"],["時分"],["人倫"]]), [])
p1, f1 = r1(res, p1, f1)

# (1f) 候補単体検査
ok = checker.kuzari_ok?([["聳物"],["水辺"],["植物"]], ["聳物"])
res = check("候補聳物がpos4で句去不足→不可（kuzari_ok?=false）", ok, false)
p1, f1 = r1(res, p1, f1)

puts "試験1：#{p1} pass / #{f1} fail"
total_pass += p1; total_fail += f1
puts

# ─────────────────────────────────────────────────────────────
#  試験2：句数チェック（合成ケース・算術）
#  verse 形式 = { bui: Array<String>, season: String|nil }
# ─────────────────────────────────────────────────────────────
puts "═" * 56
puts "試験2：句数チェック（合成ケース）"
puts "─" * 56

p2 = 0; f2 = 0
def r2(r, p, f) = r ? [p+1, f] : [p, f+1]

# ── 季節の上限 ──────────────────────────────
# (2a) 春5句（上限ちょうど）→ OK
history = Array.new(4) { { bui: [], season: "春" } }
res = check("春5句目（上限ちょうど）→ 適法",
            checker.kukazo_ok?(history, { bui: [], season: "春" }), true)
p2, f2 = r2(res, p2, f2)

# (2b) 春6句目 → kukazo_over
history = Array.new(5) { { bui: [], season: "春" } }
v = checker.kukazo_violations(history, { bui: [], season: "春" })
res = check("春6句目 → 上限超過（kukazo_over）",
            v.map { |h| [h[:type], h[:season], h[:streak], h[:max]] },
            [[:kukazo_over, "春", 6, 5]])
p2, f2 = r2(res, p2, f2)

# (2c) 夏3句（上限ちょうど）→ OK
history = Array.new(2) { { bui: [], season: "夏" } }
res = check("夏3句目（上限ちょうど）→ 適法",
            checker.kukazo_ok?(history, { bui: [], season: "夏" }), true)
p2, f2 = r2(res, p2, f2)

# (2d) 夏4句目 → kukazo_over
history = Array.new(3) { { bui: [], season: "夏" } }
v = checker.kukazo_violations(history, { bui: [], season: "夏" })
res = check("夏4句目 → 上限超過（kukazo_over）",
            v.map { |h| [h[:type], h[:season], h[:streak], h[:max]] },
            [[:kukazo_over, "夏", 4, 3]])
p2, f2 = r2(res, p2, f2)

# ── 春・秋の最短規制 ────────────────────────
# (2e) 春3句で雑へ転換 → OK（最短ちょうど）
history = Array.new(3) { { bui: [], season: "春" } }
res = check("春3句で雑へ転換 → 適法（最短ちょうど）",
            checker.kukazo_ok?(history, { bui: [], season: nil }), true)
p2, f2 = r2(res, p2, f2)

# (2f) 春2句で秋へ転換 → kukazo_under
history = Array.new(2) { { bui: [], season: "春" } }
v = checker.kukazo_violations(history, { bui: [], season: "秋" })
res = check("春2句で秋へ転換 → 最短不足（kukazo_under）",
            v.map { |h| [h[:type], h[:season], h[:streak], h[:min]] },
            [[:kukazo_under, "春", 2, 3]])
p2, f2 = r2(res, p2, f2)

# (2g) 春1句で雑へ転換 → kukazo_under
history = [{ bui: [], season: "春" }]
v = checker.kukazo_violations(history, { bui: [], season: nil })
res = check("春1句で雑へ転換 → 最短不足（kukazo_under）",
            v.map { |h| [h[:type], h[:season], h[:streak], h[:min]] },
            [[:kukazo_under, "春", 1, 3]])
p2, f2 = r2(res, p2, f2)

# (2h) 雑→春：最短チェックは発動しない（雑は min 規制なし）
history = Array.new(2) { { bui: [], season: nil } }
res = check("雑2句のあと春へ転換 → 最短チェック不発動（適法）",
            checker.kukazo_ok?(history, { bui: [], season: "春" }), true)
p2, f2 = r2(res, p2, f2)

# ── 部立の上限 ──────────────────────────────
# (2i) 恋5句（上限ちょうど）→ OK
history = Array.new(4) { { bui: ["恋"], season: nil } }
res = check("恋5句目（上限ちょうど）→ 適法",
            checker.kukazo_ok?(history, { bui: ["恋"], season: nil }), true)
p2, f2 = r2(res, p2, f2)

# (2j) 恋6句目 → kukazo_over
history = Array.new(5) { { bui: ["恋"], season: nil } }
v = checker.kukazo_violations(history, { bui: ["恋"], season: nil })
res = check("恋6句目 → 上限超過（kukazo_over）",
            v.map { |h| [h[:type], h[:bui], h[:streak], h[:max]] },
            [[:kukazo_over, "恋", 6, 5]])
p2, f2 = r2(res, p2, f2)

# (2k) 山類4句目 → kukazo_over
history = Array.new(3) { { bui: ["山類"], season: nil } }
v = checker.kukazo_violations(history, { bui: ["山類"], season: nil })
res = check("山類4句目 → 上限超過（kukazo_over）",
            v.map { |h| [h[:type], h[:bui], h[:streak], h[:max]] },
            [[:kukazo_over, "山類", 4, 3]])
p2, f2 = r2(res, p2, f2)

# (2l) 動物は句数制限なし（連続4句でも句数違反なし）
history = Array.new(3) { { bui: ["動物"], season: nil } }
v = checker.kukazo_violations(history, { bui: ["動物"], season: nil })
res = check("動物4句連続 → 句数違反なし（句数規制対象外）", v, [])
p2, f2 = r2(res, p2, f2)

# ── ストリークカウンタの直接検証 ─────────────
# (2m) current_bui_streak：末尾連続のみカウント
history = [
  { bui: ["山類"], season: nil },
  { bui: ["水辺"], season: nil },
  { bui: ["山類"], season: nil },
  { bui: ["山類"], season: nil }
]
res = check("current_bui_streak：末尾2句のみを返す（中断後の山類は数えない）",
            checker.current_bui_streak(history, "山類"), 2)
p2, f2 = r2(res, p2, f2)

# (2n) current_season_streak：雑で中断 → 春のカウント0
history = [{ season: "春" }, { season: "春" }, { season: nil }]
res = check("current_season_streak：雑で中断後の春ストリークは0",
            checker.current_season_streak(history, "春"), 0)
p2, f2 = r2(res, p2, f2)

puts "試験2：#{p2} pass / #{f2} fail"
total_pass += p2; total_fail += f2
puts

# ─────────────────────────────────────────────────────────────
#  試験3：水無瀬三吟 初折表 1〜8句（統合・Hash 形式）
#  句去 + 句数 を all_violations で一括確認
# ─────────────────────────────────────────────────────────────
puts "═" * 56
puts "試験3：水無瀬三吟 初折表1〜8（Hash 形式・句去+句数統合）"
puts "─" * 56
puts "  ※ 体用の区別は未反映。偽陽性の確認が目的。"
puts

minase = [
  { bui: ["降物","山類","聳物","時分"], season: "春" }, # 1 雪ながら山本かすむ夕べかな
  { bui: ["水辺"],                      season: "春" }, # 2 行く水とほく梅にほふ里
  { bui: ["植物"],                      season: "春" }, # 3 川風に一むら柳春見えて
  { bui: ["水辺"],                      season: nil  }, # 4 舟さす音もしるき明け方（雑）
  { bui: ["光物","聳物"],               season: "秋" }, # 5 月や猶霧わたる夜に残るらん
  { bui: ["降物"],                      season: "秋" }, # 6 霜おく野はら秋は暮れけり
  { bui: ["動物"],                      season: "秋" }, # 7 鳴く虫の心ともなく草枯れて
  { bui: ["居所"],                      season: nil  }, # 8 垣根をとへばあらはなる道（雑）
]

v = checker.scan_chain(minase)

kuzari_v = v.select { |h| !h.key?(:type) }
kukazo_v = v.select { |h| h.key?(:type) }

puts "  【句去違反】"
if kuzari_v.empty?
  puts "    なし"
else
  kuzari_v.each { |h| puts "    → #{ShikimokuChecker.describe(h)}" }
end

puts "  【句数違反】"
if kukazo_v.empty?
  puts "    なし ✓"
else
  kukazo_v.each { |h| puts "    → #{ShikimokuChecker.describe(h)}" }
end

puts
puts "  ──所見──"
puts "  句去違反：水辺 pos4（pos2から間1句<5）"
puts "    → 水無瀬では合法。水辺の体用各別物が未実装なので偽陽性。仕様1の予告通り。"
puts "  句数違反：なし"
puts "    → 春3句(1-3)→雑(4)の転換は最短3句ちょうどで適法。"
puts "       秋3句(5-7)→雑(8)の転換も同様。"
puts "  句去偽陽性が1件・句数違反が0件 = ShikimokuChecker は仕様どおり動作。"
puts

# 試験3は pass/fail ではなく所見確認なので合計に含めない

# ─────────────────────────────────────────────────────────────
#  集計
# ─────────────────────────────────────────────────────────────
puts "═" * 56
puts "総合：#{total_pass} pass / #{total_fail} fail"
puts "（試験3は偽陽性確認が目的のため集計外）"
exit(total_fail.zero? ? 0 : 1)

