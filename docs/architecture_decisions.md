# waka-collector 設計判断記録

**位置づけ:** 「なぜそう作ったか」を残す生きた仕様書。  
引き継ぎ文書とは別に、設計判断が生まれるたびにここに追記する。  
**更新:** 新しい判断は上に追記する（最新が先頭）。

---

## 2026-06-26 次句制約システム（其の十七）

### next_constraints の設計

**場所:** `app/services/shikimoku_checker.rb`

**なぜ ShikimokuChecker に置いたか**  
句去・句数のルール（`@rules` / `@kukazo_rules`）を既に保持しているクラスが
制約の計算責任を持つのが自然。RengaGenerator や Controller は「受け取るだけ」にする。

**返却する3キーの根拠**

| キー | 根拠 |
|:---|:---|
| `verse_type` | 長短交互は式目（chotan）で決まる。Controller の KuValidator 判定と二重化するが、式目の根拠はこちらに一本化すべき |
| `forbidden_bui` | 句去ルールから「次句に出すと違反になる部立」を逆算。between < interval - 1 の条件 |
| `season_hint` | kukazo_rules の min/max から継続・転季の義務を判定。LLM に渡すのではなくシード選択に使う |

**意図的にスキープしたもの**
- 植物の cross-interval（花↔木 の異種三句去）: シードに plant_type がなく偽陽性を生む
- 恋の deep count: season_hint には含めない。観測されたら追加
- bui_dict による体用フラグ: compute_forbidden_bui では未使用。事後チェックに任せる

---

### filter_pool の優先順位設計

**場所:** `app/services/renga_generator.rb`

```
1. must_switch（転季義務）→ 現季のシードを除外
2. must_continue（継続義務）→ 現季のシードのみ選択
3. フォールバック → 前句の季語からの推定（従来の挙動）
```

**なぜ従来フォールバックを残したか**  
`previous_renga_id` がない初句（発句への付け）では history が薄く、
ShikimokuChecker の判定が効かない。その場合は前句季語推定が適切。

---

### forbidden_bui が現在未使用な理由

**場所:** `app/services/renga_generator.rb` → `build_seed_pool`

シードの構造に `bui:` フィールドがない。  
```ruby
# 現在
{ surface: "...", yomi: "...", season: "秋", position: "四句" }

# 必要な形（未実装）
{ surface: "...", yomi: "...", season: "秋", bui: ["植物"], position: "四句" }
```

`BuiDictionary` で `surface` を部立判定してタグ付けすれば有効化できる。  
**着手条件:** シード選択で偽陽性（禁止部立を持つシードが選ばれる）が観測されてから。

---

### build_verse_history の verse_type 推定

**場所:** `app/controllers/rengas_controller.rb`

チェーン内の各句の `verse_type` を「現在の前句 maeku_type から逆算」で埋める。
DB に `verse_type` を保存していないため近似的な推定。

```ruby
offset = chain.size - i   # 末尾から何句前か
vtype  = offset.odd? ? maeku_type : (maeku_type == :chouku ? :tanku : :chouku)
```

**将来の改善案:** Renga テーブルに `verse_type` カラムを追加して正確な値を保存する。

---

## 2026-06-26 折末・折立ルール（Phase 8-3）

**場所:** `docs/phase83_design_memo.md`

水無瀬三吟（宗祇・1488）の実データで折境界7箇所を確認した結果、
折跨ぎで恋・述懐・冬・春が平然と継続している事実を確認。  
折跨ぎ制限（折跨ぎの禁）は紹巴以降（1587〜）の現象であり、
水無瀬版には適用されない。

**判断:** 折末・折立ロジックは実装しない。式目バージョンの「器」（ディレクトリ構造）だけ将来のために示す。

---

## 2026-06-26 植物の体用細分化（其の十六）

**場所:** `app/data/kuzari_rules.yml` / `app/services/shikimoku_checker.rb`

```yaml
植物:
  default: 5   # 同種（花↔花 等）
  cross:   3   # 異種（花↔草 等）
```

**根拠:** 水無瀬三吟で kuzari 違反7件のうち植物4件が「花・草・木の異種」で合法と判明。  
残存3件（衣裳・動物・山類）は「枯れてから足す」で保留中。

---

## 2026-06-22 off-by-one 修正（其の十五）

**場所:** `app/services/shikimoku_checker.rb` 77行目

```ruby
# 修正前（誤）
next if between >= interval

# 修正後（正）
next if between >= interval - 1  # 候補句を history に含めないため between は間隔より1少ない
```

**根拠:** `between = n - j`（n=history.size, j=1-indexed直前出現位置）は
句番号の差より常に1少ない。Test1 は偶然相殺されていたため同時修正が必要だった。

---

## 設計の大原則（変えないもの）

| 原則 | 内容 |
|:---|:---|
| 枯れてから足す | 偽陽性・偽陰性が観測されるまで辞書エントリを追加しない |
| 骨法は Ruby、即興はメンタムさん | 式目判定・制約計算は Ruby。付合の詩的飛躍だけ LLM に任せる |
| ShikimokuChecker は純粋関数 | Rails・MeCab・Ollama 非依存。history を受け取り結果を返すだけ |
| 正解データは水無瀬三吟 | 実装の検証は必ず minase_analysis.md / minase_sangin_hyakuin.md と照合する |
| j == n スキップは意図的設計 | 打越チェックと句去チェックの分離。バグではない |
