# waka-collector 其の十五 ── 句去境界バグ修正 手順書

**作成日:** 2026-06-22  
**目的:** `shikimoku_checker.rb` の句去間隔判定が1句分厳しすぎるバグを修正し、全試験を緑にする

---

## ★ 作業前ゲート（必ず最初に実行）

```bash
cd /Volumes/externalHDD/projects/waka-collector
git log --oneline -5
# HEAD = ad4ec87 であることを確認

git status
# working tree clean であることを確認

bundle exec ruby script/verify_shikimoku.rb 2>/dev/null
# 22 pass / 1 fail（試験5のみNG）が出ることを確認
# これが出なければ何かがおかしい。作業を止めて状況を確認する
```

---

## バグの概要

### 発見した事実

連歌式目の「五句去」は**古典の数え年方式**（当句を1として遡る）で定義されている。

```
1句目に植物A → 6句目に植物Bを出してよい（差=5、間に4句挟む）
```

**文献根拠:** 応安新式・至宝抄における「当句を1とする数え方」

### コードの誤り

`app/services/shikimoku_checker.rb` の `kuzari_violations` メソッド：

```ruby
between = n - j          # 間に挟まる句数
next if between >= interval  # 現在の比較
```

`kuzari_rules.yml` の値（三句去=3、五句去=5）は古典の数値そのままなので、
正しい比較は：

```ruby
next if between >= interval - 1  # 修正後
```

### 証拠となる正解データ

`docs/minase_analysis.md` より：

| 語 | 部立 | 句去 | 出現句 | 直前出現 | 差 | between | 判定 |
|:--|:--|:--|:--|:--|:--|:--|:--|
| 霞（53句） | 聳物 | 三句去 | 53 | 50 | 3 | 2 | ✅ 適法 |
| 花（25句） | 植物 | 五句去 | 25 | 20 | 5 | 4 | ✅ 適法 |

現コードでは霞(between=2, interval=3): `2>=3` → False → **誤って違反と判定**

---

## 修正手順

### Step 1: shikimoku_checker.rb の修正

```bash
grep -n "between >= interval" app/services/shikimoku_checker.rb
```

該当行を確認後：

```bash
python3 - << 'EOF'
target = "app/services/shikimoku_checker.rb"
with open(target, encoding="utf-8") as f:
    content = f.read()

old = "next if between >= interval\n"
new = "next if between >= interval - 1  # 古典の数え年方式: 差=interval で合法\n"
assert content.count(old) == 1, f"置換対象が{content.count(old)}件（1件のみ想定）"
content = content.replace(old, new)
with open(target, "w", encoding="utf-8") as f:
    f.write(content)
print("done")
EOF
```

### Step 2: verify_shikimoku.rb 試験1の期待値修正

試験1(1a)「降物の三句去違反を検出（pos4・間2句<3）」は、
修正後は「間2句（差3）= 適法」になるため**テストケースの設計を変える**必要がある。

現在の(1a):
```ruby
chain = [["降物"], ["水辺"], ["植物"], ["降物"]]
# 期待値: [[4, "降物", 2, 3]]  ← 違反として検出
```

修正後の(1a)は「間1句（差2）で三句去違反」に変更する：
```ruby
chain = [["降物"], ["水辺"], ["降物"]]  # 差=2, between=1 → 違反
# 期待値: [[3, "降物", 1, 3]]
```

新たに(1a')として「間2句（差3）= 適法」を追加：
```ruby
chain = [["降物"], ["水辺"], ["植物"], ["降物"]]  # 差=3, between=2 → 適法
# 期待値: []（違反なし）
```

```bash
grep -n "間2句\|pos4.*降物\|降物.*2.*3" script/verify_shikimoku.rb
```

該当行番号を確認して行番号スライスで修正する。

### Step 3: 全試験を実行して確認

```bash
bundle exec ruby script/verify_shikimoku.rb 2>/dev/null
# 目標: 23 pass / 0 fail（試験5のNG解消 + 試験1の新ケース追加）
```

試験5のNG（植物・五句去の偽陽性）が解消されるはず。
もし他に新たなNGが出た場合は、各違反の `between` と `interval` を確認し、
正解データ（`docs/minase_analysis.md`）と照合して判断する。

### Step 4: コミット

```bash
git add app/services/shikimoku_checker.rb script/verify_shikimoku.rb
git commit -m "fix: correct kuzari interval comparison (off-by-one in classical counting)"
git push
```

---

## 修正後に期待される動作

| ケース | before | after |
|:--|:--|:--|
| 三句去・between=1（差2） | 違反✅ | 違反✅ |
| 三句去・between=2（差3） | **違反❌（誤）** | 適法✅ |
| 三句去・between=3（差4） | 適法✅ | 適法✅ |
| 五句去・between=3（差4） | 違反✅ | 違反✅ |
| 五句去・between=4（差5） | **違反❌（誤）** | 適法✅ |
| 五句去・between=5（差6） | 適法✅ | 適法✅ |

---

## 注意事項

- `j == n` のスキップ（直前句の除外）は打越チェックと分離する意図的設計。**触らない**
- `kuzari_rules.yml` の数値は古典そのままで正しい。**変更しない**
- 修正は `shikimoku_checker.rb` の1行と `verify_shikimoku.rb` の試験1だけ
- 影響範囲が広いので、試験を一つずつ緑にしてから次に進む

