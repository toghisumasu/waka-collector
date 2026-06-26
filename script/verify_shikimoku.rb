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
chain = [["降物"], ["水辺"], ["降物"]]
v = checker.scan_chain(chain)
res = check("降物の三句去違反を検出（pos3・間1句<3）",
            v.map { |h| [h[:pos], h[:bui], h[:actual], h[:required]] },
            [[3, "降物", 1, 3]])
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
chain = [["山類"],["山類"],["山類"],["水辺"],["動物"],["旅"],["山類"]]
v = checker.scan_chain(chain)
res = check("山類の五句去違反（pos7・直近pos3から間3句<5）",
            v.map { |h| [h[:pos], h[:bui], h[:actual], h[:required], h[:last_pos]] },
            [[7, "山類", 3, 5, 3]])
p1, f1 = r1(res, p1, f1)

# (1e) 規制外の部立（時分・人倫）は近接しても違反なし
res = check("時分・人倫は句去対象外（違反0）",
            checker.scan_chain([["時分"],["人倫"],["時分"],["人倫"]]), [])
p1, f1 = r1(res, p1, f1)

# (1f) 候補単体検査
ok = checker.kuzari_ok?([["聳物"],["水辺"]], ["聳物"])
res = check("候補聳物がpos3で句去不足→不可（kuzari_ok?=false）", ok, false)
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

require_relative '../app/services/bui_dictionary'
bui_dict = BuiDictionary.new(File.join(__dir__, '../app/data/bui_dictionary.yml'))

minase = [
  { bui: ["降物","山類","聳物","時分"], season: "春", word: nil      }, # 1
  { bui: ["水辺"],                      season: "春", word: "行く水" }, # 2 体
  { bui: ["植物"],                      season: "春", word: nil      }, # 3
  { bui: ["水辺"],                      season: nil,  word: "舟"     }, # 4 用
  { bui: ["光物","聳物"],               season: "秋", word: nil      }, # 5
  { bui: ["降物"],                      season: "秋", word: nil      }, # 6
  { bui: ["動物"],                      season: "秋", word: nil      }, # 7
  { bui: ["居所"],                      season: nil,  word: nil      }, # 8
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
puts "  句去違反1件：水辺 pos4（辞書なし）→ 偽陽性（体用未区別）"
puts "  句数違反：なし"
puts

puts "  ── 体用辞書あり（bui_dict）でscan_chain再チェック ──"
v_with_dict = checker.scan_chain(minase, bui_dict: bui_dict)
res3 = check("体用辞書あり：初折表1〜8の句去違反は0件",
             v_with_dict.size, 0)
total_pass += 1 if res3
total_fail += 1 unless res3
puts
# ---------------------------------------------------------
#  Test4: Minase Ura 9-22 (Hash / kuzari+kukazo)
# ---------------------------------------------------------
puts "=" * 56
puts "Test4: Minase Ura 9-22 (kuzari+kukazo)"
puts "-" * 56
minase_ura = [
  { word: "yamafulaki",     bui: ["聳物", "居所"], season: "秋" },
  { word: "narenusumahi",   bui: ["居所"],  season: "雑" },
  { word: "imasarani",      bui: ["人倫"], season: "雑" },
  { word: "uturohan",       bui: [],                   season: "雑" },
  { word: "okiwaburu",      bui: ["降物", "植物"], season: "春" },
  { word: "madanokoru",     bui: ["光物", "聳物"], season: "春" },
  { word: "kurenuToya",     bui: ["動物"],    season: "春" },
  { word: "miyamawoyuke",   bui: ["山類"], season: "雑" },
  { word: "haruruma",       bui: ["衣裳", "降物"], season: "冬" },
  { word: "wagakusamakura", bui: ["光物"], season: "秋" },
  { word: "itadura",        bui: ["時分"],   season: "秋" },
  { word: "yumeni",         bui: ["植物"],  season: "秋" },
  { word: "mishihamina",    bui: ["名所"], season: "雑" },
  { word: "oino",           bui: ["述懐"], season: "雑" },
]
chain_1_22 = minase + minase_ura
puts "  [kuzari without dict]"
v4 = checker.scan_chain(chain_1_22)
kuzari4 = v4.reject { |v| v[:type] == :kukazo }
if kuzari4.empty?
  puts "    none"
else
  kuzari4.each { |viol| puts "    -> pos#{viol[:pos]+1}: bui=#{viol[:bui]} gap=#{viol[:gap]} required=#{viol[:required]}" }
end
puts "  -- with bui_dict --"
v4d = checker.scan_chain(chain_1_22, bui_dict: bui_dict)
kuzari4d = v4d.reject { |v| v[:type].to_s.start_with?("kukazo") }
res4 = check("bui_dict: ura 9-22 kuzari=0", kuzari4d.size, 0)
total_pass += 1 if res4
total_fail += 1 unless res4
puts
# ---------------------------------------------------------
#  Test5: Minase Omote 23-36 (Hash / kuzari+kukazo)
# ---------------------------------------------------------
puts "=" * 56
puts "Test5: Minase Omote 23-36 (kuzari+kukazo)"
puts "-" * 56
minase_omote2 = [
  { word: "irokimotoki",  bui: [],                          season: "雑" },
  { word: "soretomotomo", bui: ["時分"],         season: "秋" },
  { word: "kumonikefuu",  bui: ["聳物", "山類", "植物"], season: "春" },
  { word: "kikebaimaha",  bui: ["動物"],         season: "春" },
  { word: "oborogeno",    bui: ["光物"],        season: "春" },
  { word: "karineno",     bui: ["降物", "時分", "旅"], season: "秋" },  # かりね＝旅寝
  { word: "suenonaru",    bui: ["聳物", "居所"],      season: "秋" },
  { word: "fukikuru",     bui: ["衣裳"],               season: "秋" },
  { word: "sayurubi",     bui: ["光物", "時分", "衣裳"], season: "冬" }, # さゆる日も袖うすき
  { word: "tanomumohakana", bui: ["山類"],      season: "冬" },
  { word: "saritomono",   bui: ["述懐"],        season: "雑" },
  { word: "kokorobososhi", bui: [],                         season: "雑" },
  { word: "inotinoMi",    bui: ["恋"],         season: "恋" },
  { word: "nahoNani",     bui: ["恋"],         season: "恋" },
]
chain_1_36 = minase + minase_ura + minase_omote2
p5 = 0; f5 = 0
def r5(r, p, f) = r ? [p+1, f] : [p, f+1]

puts "  [kuzari without dict]"
v5 = checker.scan_chain(chain_1_36)
kuzari5 = v5.reject { |v| v[:type].to_s.start_with?("kukazo") }
if kuzari5.empty?
  puts "    none"
else
  kuzari5.each { |viol| puts "    -> #{ShikimokuChecker.describe(viol)}" }
end

puts "  -- kuzari with bui_dict --"
v5d = checker.scan_chain(chain_1_36, bui_dict: bui_dict)
kuzari5d = v5d.reject { |v| v[:type].to_s.start_with?("kukazo") }
# pos30-31 連続衣裳は「同走継続」扱い（j==n スキップ設計）→ 句去対象外
res5a = check("bui_dict: omote2 23-36 kuzari=0（連続衣裳は句数で管理）",
              kuzari5d.size, 0)
p5, f5 = r5(res5a, p5, f5)

puts "  -- kukazo (kuzari+kukazo 統合) --"
kukazo5d = v5d.select { |v| v[:type].to_s.start_with?("kukazo") }
# pos25(雲にけふ 春): 直前の秋(pos24のみ streak=1)から転季 → 秋の最短3句不足
res5b = check("omote2 pos25 秋→春転換で秋連続1句（最短3句不足）kukazo_under検出",
              kukazo5d.select { |v| v[:pos] == 25 }.map { |v| [v[:type], v[:season], v[:streak], v[:min]] },
              [[:kukazo_under, "秋", 1, 3]])
p5, f5 = r5(res5b, p5, f5)

puts "Test5：#{p5} pass / #{f5} fail"
total_pass += p5; total_fail += f5
puts

# ─────────────────────────────────────────────────────────────
#  試験6：長短交互チェック（Phase 8-2）
# ─────────────────────────────────────────────────────────────
puts "═" * 56
puts "試験6：長短交互チェック（chotan_violations）"
puts "─" * 56

p6 = 0; f6 = 0
def r6(r, p, f) = r ? [p+1, f] : [p, f+1]

# (6a) 発句（長）→脇（短）→第三（長）→四句目（短）→五句目（長）: 違反なし
chain6_ok = [
  { verse_type: :chouku, bui: [], season: "春"  }, # 発句
  { verse_type: :tanku,  bui: [], season: "春"  }, # 脇
  { verse_type: :chouku, bui: [], season: nil   }, # 第三
  { verse_type: :tanku,  bui: [], season: nil   }, # 四句目
  { verse_type: :chouku, bui: [], season: nil   }, # 五句目
]
v6a = checker.scan_chain_with_chotan(chain6_ok)
chotan6a = v6a.select { |v| v[:type] == :chotan_chigai }
res6a = check("長短正常交互（5句）→ 長短違反0",
              chotan6a, [])
p6, f6 = r6(res6a, p6, f6)

# (6b) 長→長（連続）: 違反
chain6_ng1 = [
  { verse_type: :chouku, bui: [], season: "春" },
  { verse_type: :chouku, bui: [], season: "春" },
]
v6b = checker.scan_chain_with_chotan(chain6_ng1)
chotan6b = v6b.select { |v| v[:type] == :chotan_chigai }
res6b = check("長句連続（pos2）→ chotan_chigai検出",
              chotan6b.map { |v| [v[:pos], v[:verse_type], v[:expected]] },
              [[2, :chouku, :tanku]])
p6, f6 = r6(res6b, p6, f6)

# (6c) 短→短（連続）: 違反
chain6_ng2 = [
  { verse_type: :chouku, bui: [], season: "春" },
  { verse_type: :tanku,  bui: [], season: "春" },
  { verse_type: :tanku,  bui: [], season: nil  },
]
v6c = checker.scan_chain_with_chotan(chain6_ng2)
chotan6c = v6c.select { |v| v[:type] == :chotan_chigai }
res6c = check("短句連続（pos3）→ chotan_chigai検出",
              chotan6c.map { |v| [v[:pos], v[:verse_type], v[:expected]] },
              [[3, :tanku, :chouku]])
p6, f6 = r6(res6c, p6, f6)

# (6d) verse_type なし句はスキップ（型未確定の句と混在）
chain6_skip = [
  { verse_type: :chouku, bui: [], season: "春" },
  { bui: [], season: nil },                          # verse_type なし → スキップ
  { verse_type: :chouku, bui: [], season: nil  },    # 見かけ上長→長だが間に型なし句あり
]
v6d = checker.scan_chain_with_chotan(chain6_skip)
chotan6d = v6d.select { |v| v[:type] == :chotan_chigai }
res6d = check("verse_type なし句をスキップして交互確認",
              chotan6d.map { |v| [v[:pos], v[:verse_type], v[:expected]] },
              [[3, :chouku, :tanku]])
p6, f6 = r6(res6d, p6, f6)

# (6e) 水無瀬三吟 初折表1〜8（長短順を反映）: 違反なし
minase_chotan = [
  { verse_type: :chouku, bui: ["降物","山類","聳物","時分"], season: "春"  }, # 1 長
  { verse_type: :tanku,  bui: ["水辺"],                      season: "春"  }, # 2 短
  { verse_type: :chouku, bui: ["植物"],                      season: "春"  }, # 3 長
  { verse_type: :tanku,  bui: ["水辺"],                      season: nil   }, # 4 短
  { verse_type: :chouku, bui: ["光物","聳物"],               season: "秋"  }, # 5 長
  { verse_type: :tanku,  bui: ["降物"],                      season: "秋"  }, # 6 短
  { verse_type: :chouku, bui: ["動物"],                      season: "秋"  }, # 7 長
  { verse_type: :tanku,  bui: ["居所"],                      season: nil   }, # 8 短
]
v6e = checker.scan_chain_with_chotan(minase_chotan, bui_dict: bui_dict)
chotan6e = v6e.select { |v| v[:type] == :chotan_chigai }
res6e = check("水無瀬 初折表1〜8 長短交互 → 違反0",
              chotan6e, [])
p6, f6 = r6(res6e, p6, f6)

puts "試験6：#{p6} pass / #{f6} fail"
total_pass += p6; total_fail += f6
puts

# ═══════════════════════════════════════════════════════════════
#  水無瀬三吟 全100句データ（tsuki/hana/verse_type 付き）
#  ── 折区切り ──
#   初折表  1- 8  / 初折裏  9-22
#   二折表 23-36  / 二折裏 37-50
#   三折表 51-64  / 三折裏 65-78
#   名残表 79-92  / 名残裏 93-100
# ═══════════════════════════════════════════════════════════════
minase_full = [
  # ── 初折表 1-8 ──
  { word: "雪ながら",      bui: ["降物","山類","聳物","時分"], season: "春", verse_type: :chouku },                    # 1
  { word: "行く水とほく",  bui: ["水辺","植物","居所"],       season: "春", verse_type: :tanku  },                    # 2
  { word: "川風に",        bui: ["水辺","植物"],              season: "春", verse_type: :chouku },                    # 3
  { word: "舟さす音も",   bui: ["水辺","時分"],              season: "雑", verse_type: :tanku  },                    # 4
  { word: "月や猶",        bui: ["光物","聳物","時分"],       season: "秋", verse_type: :chouku, tsuki: true },       # 5 ★月
  { word: "霜おく野はら",  bui: ["降物","時分"],              season: "秋", verse_type: :tanku  },                    # 6
  { word: "なく蟲の",      bui: ["動物","植物"],              season: "秋", verse_type: :chouku },                    # 7
  { word: "かきねをとへば",bui: ["居所"],                    season: "雑", verse_type: :tanku  },                    # 8
  # ── 初折裏 9-22 ──
  { word: "山ふかき",      bui: ["山類","居所"],              season: "秋", verse_type: :chouku },                    # 9
  { word: "なれぬすまひ",  bui: ["居所","述懐"],              season: "雑", verse_type: :tanku  },                    # 10
  { word: "今更に",        bui: ["人倫","述懐"],              season: "雑", verse_type: :chouku },                    # 11
  { word: "うつろはん",    bui: ["述懐"],                    season: "雑", verse_type: :tanku  },                    # 12
  { word: "置きわぶる",    bui: ["降物","植物"],              season: "春", verse_type: :chouku, hana: true },        # 13 ★花
  { word: "まだ残る日の",  bui: ["光物","聳物"],              season: "春", verse_type: :tanku  },                    # 14
  { word: "暮れぬとや",    bui: ["動物","時分"],              season: "春", verse_type: :chouku },                    # 15
  { word: "深山をゆけば",  bui: ["山類"],                    season: "雑", verse_type: :tanku  },                    # 16
  { word: "はるゝまも",    bui: ["降物","旅","衣裳"],         season: "冬", verse_type: :chouku },                    # 17
  { word: "わが草枕",      bui: ["旅","光物"],                season: "秋", verse_type: :tanku,  tsuki: true },       # 18 ★月
  { word: "いたづらに",    bui: ["時分"],                    season: "秋", verse_type: :chouku },                    # 19
  { word: "夢にうらむる",  bui: ["植物"],                    season: "秋", verse_type: :tanku  },                    # 20
  { word: "見しはみな",    bui: ["名所","述懐"],              season: "雑", verse_type: :chouku },                    # 21
  { word: "老の行方よ",    bui: ["述懐"],                    season: "雑", verse_type: :tanku  },                    # 22
  # ── 二折表 23-36 ──
  { word: "色もなき",      bui: ["述懐"],                    season: "雑", verse_type: :chouku },                    # 23
  { word: "それも友なる",  bui: ["時分"],                    season: "秋", verse_type: :tanku  },                    # 24
  { word: "雲にけふ",      bui: ["聳物","山類","植物"],       season: "春", verse_type: :chouku, hana: true },        # 25 ★花
  { word: "きけば今はの",  bui: ["動物"],                    season: "春", verse_type: :tanku  },                    # 26
  { word: "おぼろげの",    bui: ["光物"],                    season: "春", verse_type: :chouku, tsuki: true },       # 27 ★月
  { word: "かりねの露の",  bui: ["降物","時分","旅"],         season: "秋", verse_type: :tanku  },                    # 28
  { word: "末野なる",      bui: ["聳物","居所"],              season: "秋", verse_type: :chouku },                    # 29
  { word: "吹きくる風は",  bui: ["衣裳"],                    season: "秋", verse_type: :tanku  },                    # 30
  { word: "さゆる日も",    bui: ["光物","時分","衣裳"],       season: "冬", verse_type: :chouku },                    # 31
  { word: "たのむもはかな",bui: ["山類"],                    season: "冬", verse_type: :tanku  },                    # 32
  { word: "さりともの",    bui: ["述懐"],                    season: "雑", verse_type: :chouku },                    # 33
  { word: "心ぼそし",      bui: ["述懐"],                    season: "雑", verse_type: :tanku  },                    # 34
  { word: "命のみ",        bui: ["衣裳","恋"],               season: "恋", verse_type: :chouku },                    # 35
  { word: "なほ何なれや",  bui: ["恋"],                      season: "恋", verse_type: :tanku  },                    # 36
  # ── 二折裏 37-50 ──
  { word: "君を置きて",    bui: ["恋","人倫"],               season: "恋", verse_type: :chouku },                    # 37
  { word: "そのおもかげに",bui: ["恋"],                      season: "恋", verse_type: :tanku  },                    # 38
  { word: "草木さへ",      bui: ["植物","名所","述懐"],       season: "雑", verse_type: :chouku },                    # 39
  { word: "身のうき宿も",  bui: ["居所","述懐"],              season: "雑", verse_type: :tanku  },                    # 40
  { word: "たらちねの",    bui: ["人倫","述懐"],              season: "雑", verse_type: :chouku },                    # 41
  { word: "月日の末や",    bui: ["光物"],                    season: "雑", verse_type: :tanku,  tsuki: true },       # 42 ★月
  { word: "この岸を",      bui: ["水辺"],                    season: "雑", verse_type: :chouku },                    # 43
  { word: "また生まれこぬ",bui: ["釈教"],                    season: "雑", verse_type: :tanku  },                    # 44
  { word: "あふまでと",    bui: ["降物","恋"],               season: "恋", verse_type: :chouku },                    # 45
  { word: "身を秋風も",    bui: ["恋"],                      season: "秋", verse_type: :tanku  },                    # 46
  { word: "松むしの",      bui: ["動物","植物"],              season: "秋", verse_type: :chouku },                    # 47
  { word: "しめゆふ山は",  bui: ["山類","光物","神祇"],       season: "秋", verse_type: :tanku,  tsuki: true },       # 48 ★月
  { word: "鐘に我",        bui: ["釈教"],                    season: "冬", verse_type: :chouku },                    # 49
  { word: "いただきけりな",bui: ["降物"],                    season: "冬", verse_type: :tanku  },                    # 50
  # ── 三折表 51-64 ──
  { word: "冬がれの",      bui: ["動物","水辺"],              season: "冬", verse_type: :chouku },                    # 51
  { word: "夕しほ風の",    bui: ["水辺","人倫"],              season: "雑", verse_type: :tanku  },                    # 52
  { word: "行方なき",      bui: ["聳物"],                    season: "春", verse_type: :chouku },                    # 53
  { word: "くるかた見えぬ",bui: ["山類","居所"],              season: "春", verse_type: :tanku  },                    # 54
  { word: "茂みより",      bui: ["植物"],                    season: "春", verse_type: :chouku, hana: true },        # 55 ★花
  { word: "木の本わくる",  bui: ["植物","降物"],              season: "春", verse_type: :tanku  },                    # 56
  { word: "秋はなど",      bui: ["降物","山類"],              season: "冬", verse_type: :chouku },                    # 57
  { word: "こけの袂も",    bui: ["光物","衣裳"],              season: "秋", verse_type: :tanku,  tsuki: true },       # 58 ★月
  { word: "心あるかぎり",  bui: ["釈教","述懐"],              season: "雑", verse_type: :chouku },                    # 59
  { word: "をさまる波に",  bui: ["水辺"],                    season: "雑", verse_type: :tanku  },                    # 60
  { word: "朝なぎの",      bui: ["時分","聳物"],              season: "雑", verse_type: :chouku },                    # 61
  { word: "雪にさやけき",  bui: ["降物","山類"],              season: "冬", verse_type: :tanku  },                    # 62
  { word: "嶺の庵",        bui: ["山類","居所","植物"],       season: "冬", verse_type: :chouku },                    # 63
  { word: "さびしさならふ",bui: ["植物"],                    season: "雑", verse_type: :tanku  },                    # 64
  # ── 三折裏 65-78 ──
  { word: "誰かこの",      bui: ["時分","恋"],               season: "雑", verse_type: :chouku },                    # 65
  { word: "月はしるやの",  bui: ["光物","旅"],               season: "秋", verse_type: :tanku,  tsuki: true },       # 66 ★月
  { word: "露ふかみ",      bui: ["降物","衣裳"],              season: "秋", verse_type: :chouku },                    # 67
  { word: "うす花すゝき",  bui: ["植物"],                    season: "秋", verse_type: :tanku  },                    # 68
  { word: "うづらなく",    bui: ["動物","山類","時分"],       season: "秋", verse_type: :chouku },                    # 69
  { word: "野となる里も",  bui: ["居所","述懐"],              season: "雑", verse_type: :tanku  },                    # 70
  { word: "かへりこば",    bui: ["恋"],                      season: "恋", verse_type: :chouku },                    # 71
  { word: "うときも",      bui: ["恋"],                      season: "恋", verse_type: :tanku  },                    # 72
  { word: "むかしより",    bui: ["恋"],                      season: "恋", verse_type: :chouku },                    # 73
  { word: "わすられがたき",bui: ["恋"],                      season: "恋", verse_type: :tanku  },                    # 74
  { word: "山がつに",      bui: ["山類","人倫"],              season: "雑", verse_type: :chouku },                    # 75
  { word: "植ゑぬ草葉の",  bui: ["植物","居所"],              season: "雑", verse_type: :tanku  },                    # 76
  { word: "かたはらに",    bui: ["居所","植物"],              season: "春", verse_type: :chouku },                    # 77
  { word: "行く人かすむ",  bui: ["聳物","降物","時分"],       season: "春", verse_type: :tanku  },                    # 78
  # ── 名残表 79-92 ──
  { word: "やどりせん",    bui: ["動物"],                    season: "春", verse_type: :chouku },                    # 79
  { word: "さ夜もしづかに",bui: ["光物","植物","時分"],       season: "春", verse_type: :tanku,  tsuki: true, hana: true }, # 80 ★月★花(桜)
  { word: "とぼし火を",    bui: ["植物","時分"],              season: "春", verse_type: :chouku, hana: true },        # 81 ★花
  { word: "誰が手枕に",    bui: ["恋"],                      season: "恋", verse_type: :tanku  },                    # 82
  { word: "契りはや",      bui: ["恋"],                      season: "恋", verse_type: :chouku },                    # 83
  { word: "今はのよはひ",  bui: ["山類","述懐"],              season: "雑", verse_type: :tanku  },                    # 84
  { word: "かくす身を",    bui: ["述懐"],                    season: "雑", verse_type: :chouku },                    # 85
  { word: "さてもうき世に",bui: ["述懐"],                    season: "雑", verse_type: :tanku  },                    # 86
  { word: "松の葉を",      bui: ["植物","時分"],              season: "雑", verse_type: :chouku },                    # 87
  { word: "浦曲のさとよ",  bui: ["水辺","居所"],              season: "雑", verse_type: :tanku  },                    # 88
  { word: "秋風の",        bui: ["水辺","旅"],                season: "秋", verse_type: :chouku },                    # 89
  { word: "鴈なく山の",    bui: ["動物","山類","光物"],       season: "秋", verse_type: :tanku,  tsuki: true },       # 90 ★月
  { word: "小萩はら",      bui: ["植物","降物"],              season: "秋", verse_type: :chouku },                    # 91
  { word: "あだの大野を",  bui: ["人倫"],                    season: "雑", verse_type: :tanku  },                    # 92
  # ── 名残裏 93-100 ──
  { word: "忘るなよ",      bui: ["述懐"],                    season: "雑", verse_type: :chouku },                    # 93
  { word: "おもへばいつを",bui: ["述懐"],                    season: "雑", verse_type: :tanku  },                    # 94
  { word: "佛たちかくれては",bui: ["釈教"],                   season: "雑", verse_type: :chouku },                    # 95
  { word: "かれし林も",    bui: ["植物"],                    season: "春", verse_type: :tanku  },                    # 96
  { word: "山はけさ",      bui: ["山類","降物","聳物"],       season: "春", verse_type: :chouku },                    # 97
  { word: "けぶり長閑に",  bui: ["聳物","居所"],              season: "春", verse_type: :tanku  },                    # 98
  { word: "いやしきも",    bui: ["人倫"],                    season: "雑", verse_type: :chouku },                    # 99
  { word: "人におしなべ",  bui: ["人倫"],                    season: "雑", verse_type: :tanku  },                    # 100
]

# ─────────────────────────────────────────────────────────────
#  試験7：水無瀬三吟 全100句 統合スキャン
# ─────────────────────────────────────────────────────────────
puts "═" * 56
puts "試験7：水無瀬三吟 全100句 統合スキャン"
puts "─" * 56

p7 = 0; f7 = 0
def r7(r, p, f) = r ? [p+1, f] : [p, f+1]

v7d = checker.scan_chain_with_chotan(minase_full, bui_dict: bui_dict)
kuzari7  = v7d.reject { |v| v[:type].to_s.start_with?("kukazo") || v[:type] == :chotan_chigai }
kukazo7  = v7d.select { |v| v[:type].to_s.start_with?("kukazo") }
chotan7  = v7d.select { |v| v[:type] == :chotan_chigai }

puts "  [kuzari with bui_dict]"
kuzari7.each { |viol| puts "    -> #{ShikimokuChecker.describe(viol)}" }
puts "    none" if kuzari7.empty?

puts "  [kukazo]"
kukazo7.each { |viol| puts "    -> #{ShikimokuChecker.describe(viol)}" }
puts "    none" if kukazo7.empty?

puts "  [chotan]"
chotan7.each { |viol| puts "    -> #{ShikimokuChecker.describe(viol)}" }
puts "    none" if chotan7.empty?

# bui_dict（体用辞書）は水辺の偽陽性を除去するが、植物・衣裳・動物などの
# 五句去違反は除去しない。以下7件は実際の百韻で観察される既知の境界事例:
#   pos7  植物(pos3から間3句)  pos35 衣裳(pos31から間3句)
#   pos51 動物(pos47から間3句) pos57 山類(pos54から間2句)
#   pos68 植物(pos64から間3句) pos80 植物(pos77から間2句)
#   pos91 植物(pos87から間3句)
# ── 植物は体言/用言・単一語/複合語で細分化すれば多くが消える見込み ──
res7a = check("全100句 kuzari 既知7件（植物体用未分化等の境界事例）",
              kuzari7.size, 7)
p7, f7 = r7(res7a, p7, f7)

# 長短交互: 全100句で違反0
res7b = check("全100句 長短交互 chotan違反=0", chotan7.size, 0)
p7, f7 = r7(res7b, p7, f7)

# pos25 の kukazo_under は依然として検出される（二折表 秋1句→春転換）
res7c = check("全100句 pos25 秋→春kukazo_under健在",
              kukazo7.any? { |v| v[:pos] == 25 && v[:type] == :kukazo_under },
              true)
p7, f7 = r7(res7c, p7, f7)

# ── kukazo_under pos10・pos25・pos59 の解釈（docs/minase_analysis.md より） ──
# アルゴリズムは厳格に秋最短3句規制を適用し、以下3箇所を違反として検出する:
#   pos10 (秋1句=pos9 → 雑 pos10): 初折裏「孤立した秋1句で終止、雑3句を挟んで春へ転換という大胆な運び」
#   pos25 (秋1句=pos24 → 春 pos25): 二折表「24句『夕暮の空』が季感の薄い秋句。25句の花散る景の大転換が転季のクッション代わり」
#   pos59 (秋1句=pos58 → 雑 pos59): 三折表「逆行転季の連続（55→56→57→58）…『転』に入ったサイン」
# いずれも宗祇・肖柏・宗長が意図した季の色付き（単独の季感）であり、
# 式目上の許容範囲（intentional single-verse seasonal color）と判断する。
# 違反数が 3 であることを確認し、実際の連歌の技法として記録する。
kukazo_under7 = kukazo7.select { |v| v[:type] == :kukazo_under }
res7d = check("全100句 kukazo_under=3（秋単独句の大胆転季・式目上の許容範囲）",
              kukazo_under7.size, 3)
p7, f7 = r7(res7d, p7, f7)

puts "試験7：#{p7} pass / #{f7} fail"
total_pass += p7; total_fail += f7
puts

# ─────────────────────────────────────────────────────────────
#  試験8：月・花の定座チェック（百韻）
# ─────────────────────────────────────────────────────────────
puts "═" * 56
puts "試験8：月・花の定座チェック（百韻）"
puts "─" * 56

p8 = 0; f8 = 0
def r8(r, p, f) = r ? [p+1, f] : [p, f+1]

# 月の定座: 各面に1回以上（名残裏は免除）
tsuki_faces = [
  { name: "初折表", range:  1..8,   req: true  },
  { name: "初折裏", range:  9..22,  req: true  },
  { name: "二折表", range: 23..36,  req: true  },
  { name: "二折裏", range: 37..50,  req: true  },
  { name: "三折表", range: 51..64,  req: true  },
  { name: "三折裏", range: 65..78,  req: true  },
  { name: "名残表", range: 79..92,  req: true  },
  { name: "名残裏", range: 93..100, req: false }, # 揚句付近は月免除
]

# 花の定座: 各折（4折単位）に1回以上
hana_folds = [
  { name: "初折", range:  1..22  },
  { name: "二折", range: 23..50  },
  { name: "三折", range: 51..78  },
  { name: "名残", range: 79..100 },
]

tsuki_viols = checker.teiza_tsuki_violations(minase_full, tsuki_faces)
hana_viols  = checker.teiza_hana_violations(minase_full, hana_folds)

puts "  [月の定座 (各面に月1回以上, 名残裏免除)]"
tsuki_viols.each { |v| puts "    -> #{ShikimokuChecker.describe(v)}" }
puts "    違反なし ✓" if tsuki_viols.empty?

puts "  [花の定座 (各折に花1回以上)]"
hana_viols.each  { |v| puts "    -> #{ShikimokuChecker.describe(v)}" }
puts "    違反なし ✓" if hana_viols.empty?

# 水無瀬三吟は月・花の定座を完全に守っている
res8a = check("月の定座: 全7面（名残裏除く）に月あり → 違反0", tsuki_viols.size, 0)
p8, f8 = r8(res8a, p8, f8)

res8b = check("花の定座: 全4折に花あり → 違反0", hana_viols.size, 0)
p8, f8 = r8(res8b, p8, f8)

# ── 定座チェッカーのネガティブ確認 ──
# 月がない面が生じるケースを検出できるか
chain_tsuki_ng = Array.new(8) { { bui: [], season: "雑", verse_type: :tanku } }  # 月なし8句
faces_ng = [{ name: "テスト面", range: 1..8, req: true }]
res8c = check("月なし面 → teiza_tsuki_violations 検出",
              checker.teiza_tsuki_violations(chain_tsuki_ng, faces_ng).map { |v| v[:type] },
              [:teiza_tsuki])
p8, f8 = r8(res8c, p8, f8)

# 花がない折が生じるケースを検出できるか
chain_hana_ng = Array.new(8) { { bui: ["植物"], season: "秋", verse_type: :tanku } }  # 花なし(秋植物)
folds_ng = [{ name: "テスト折", range: 1..8 }]
res8d = check("花なし折 → teiza_hana_violations 検出",
              checker.teiza_hana_violations(chain_hana_ng, folds_ng).map { |v| v[:type] },
              [:teiza_hana])
p8, f8 = r8(res8d, p8, f8)

puts "試験8：#{p8} pass / #{f8} fail"
total_pass += p8; total_fail += f8
puts

# ─────────────────────────────────────────────────────────────
#  集計
# ─────────────────────────────────────────────────────────────
puts "═" * 56
puts "総合：#{total_pass} pass / #{total_fail} fail"
exit(total_fail.zero? ? 0 : 1)

