# waka-collector 引き継ぎ ── 句去の境界を正す
### 其の十五・2026/06/22

> 「五句去と　数えて四句の　間あり　当句を一と　古典は数える」
> ── 全8折の分析を収め、初折裏・二折表を通そうとして、
>    句去の数え年方式という根本バグを発見した。其の十五は、まずそこを直す。

---

## ★ プロジェクトの作業リズム（次のClaudeへ）

セッション開始時に「今日は外出中か帰宅後か」を確認し、作業の粒度を合わせること。

| 外出時（Android/Termius） | 帰宅後（Mac mini直接 or SSH） |
|---|---|
| 上流工程全般（要件定義・設計判断） | 実装全般（コード修正・部分編集） |
| ネット調査・古典資料確認 | 大量入力・複雑な編集 |
| 小さなYAML・スクリプト確認 | verify_*.rb の緑化 |
| 動作確認・テスト実行報告 | コミット・push |

**「viで老眼でも打てる行数」が外出時の実装上限。**

**其の十五開始時の補足:** ConoHaの設定状況を冒頭で確認すること。

---

## 〇、開始時にまず読む（ファイル構成の地図）

### 主要サービスクラスと責務（其の十四完了時点）

| ファイル | 責務 | 状態 |
|---|---|---|
| `app/services/shikimoku_checker.rb` | 式目ガードレール（句去＋句数＋体用） | ⚠️ **句去境界にバグあり（其の十五で修正）** |
| `app/services/bui_dictionary.rb` | 体用フラグ付き部立辞書クラス | ✅ 変更なし |
| `app/data/bui_dictionary.yml` | 部立辞書データ（2語：行く水=体／舟=用） | ✅ 変更なし |
| `app/data/kuzari_rules.yml` | 句去ルール表（値は古典の数値で正しい） | ✅ 変更なし |
| `script/verify_shikimoku.rb` | ShikimokuChecker動作検証 | ⚠️ **試験5がNG（バグ修正で解消予定）** |
| `docs/minase_analysis.md` | 全8折完全版（其の十四でコミット済み） | ✅ **其の十四で全折完備** |

### git HEAD（其の十四完了時点）

```
ad4ec87 (HEAD -> main, origin/main) test: add Test4 for Minase ura 9-22, 22 pass / 0 fail
35a4dc9 docs: update minase_analysis to full 8-fold complete version (100 verses)
3881c53 chore: add seed-pool extraction and hiragana generation verification scripts
```

`git status` は working tree clean（未コミットファイルなし）で其の十四を終了。

**試験5（二折表23〜36句）はNGのまま未コミット。**
修正後にコミットする。

---

## 一、其の十四の総評と其の十五への橋渡し

### 其の十四で達成したこと

1. **`minase_analysis.md` 全8折完全版をコミット（35a4dc9）**
   プロジェクト知識に存在した旧版（初折表のみ）を、全100句・全8折の完全分析版に差し替えた。
   Termux→Mac mini SCP転送、全角スペース0件確認済み。

2. **試験4（初折裏9〜22句）を追加・緑化（ad4ec87）**
   `minase + minase_ura` のchain_1_22で `scan_chain` を実行。
   既存2語辞書（行く水=体／舟=用）のままで句去違反0件を確認。
   「枯れてから足す」が初折裏でも実証された。

3. **試験5（二折表23〜36句）の追加途中で根本バグを発見**
   `pos26: bui=植物 gap= required=5` という違反が辞書ありでも残存。
   調査の結果、**句去の間隔判定が古典の数え方と1句ずれている**ことが判明。
   試験5はNGのまま未コミットで其の十四を終了。

### 発見したバグの詳細

**古典の「五句去」の正しい意味：**
当句を1として遡り、5句目のエリアまで禁止。
つまり差=5（間に4句挟む）で合法。

```
[pos0] 植物A出現
[pos1] 禁止
[pos2] 禁止
[pos3] 禁止
[pos4] 禁止
[pos5] ← ここから解禁（差=5、between=4）
```

**現コードの誤り：**
```ruby
# shikimoku_checker.rb
between = n - j          # 間に挟まる句数（差-1）
next if between >= interval  # interval=5 → between=4 → 4>=5 → False → 違反と誤判定
```

**正しいコード：**
```ruby
next if between >= interval - 1  # 4>=4 → True → 適法
```

**証拠（docs/minase_analysis.md より）：**
- 霞（聳物）53句 ← 50句から差3、between=2、三句去 → **✅ 適法**
  現コードは `2>=3` → False → **誤って違反と判定する**
- 花（植物）25句 ← 20句から差5、between=4、五句去 → **✅ 適法**
  現コードは `4>=5` → False → **誤って違反と判定する**（今回のNG原因）

---

## 二、其の十五で進むこと（優先順位順）

### 最優先：句去境界バグの修正

**別ファイル「手順書_其の十五.md」を参照。** 手順・期待値・注意事項を完全に記載してある。

要点のみ：
1. `shikimoku_checker.rb` の `between >= interval` を `between >= interval - 1` に1行修正
2. `verify_shikimoku.rb` 試験1(1a)の期待値を修正（間2句=適法に変更）
3. `bundle exec ruby script/verify_shikimoku.rb 2>/dev/null` で全緑を確認
4. コミット

### その後：二折裏〜名残折裏への拡張

バグ修正後、同じ手順（Pythonスクリプトでチェーンデータ挿入→scan_chain→偽陽性のみ辞書追加）で二折裏以降を進める。

`docs/minase_analysis.md` に全8折のデータが揃っているので、データ起こし作業は不要。

---

## 三、確定済みの設計方針（其の十五も踏襲）

1. 体用は句去対象外。同一部立でも体と用は各別物。
2. 辞書のデフォルトは体。未登録語は `"体"` 扱い。
3. 偽陽性が出た箇所だけ辞書を編む。全語先回り登録しない。
4. 検査役は外部をCALLしない。ShikimokuCheckerはLLM・MeCab・Rails非依存。
5. 付合の面白さは100%がC層（LLM）。Rubyは式目違反を防ぐ垣根に徹する。
6. 折の検証は `scan_chain(chain, bui_dict:)` に統一。
7. 「文字化け」を見たら、まず `content.count("\u3000")` でバイト確認。
8. **〔其の十四で追加〕句去の数値は古典の数え年方式（当句=1）。`kuzari_rules.yml` の値は正しい。比較式だけが誤っていた。**

---

## 四、次スレッド開始時の手順

```bash
# 1. 環境確認
cd /Volumes/externalHDD/projects/waka-collector
git log --oneline -5      # HEAD が ad4ec87 であることを確認
git status                 # clean であることを確認

# 2. 既存テストの状態確認
bundle exec ruby script/verify_shikimoku.rb 2>/dev/null
# → 22 pass / 1 fail（試験5のみNG）が出れば正常

# 3. ConoHaの状況を確認

# 4. 「手順書_其の十五.md」に従ってバグ修正を実施
#    （shikimoku_checker.rb 1行修正 → 試験1期待値修正 → 全緑確認 → コミット）

# 5. バグ修正後、二折裏（37〜50句）の試験6を追加
```

---

## 五、参考資料（其の十四でコミット済み）

| ファイル | 用途 |
|---|---|
| `docs/minase_analysis.md` | **全8折完全版**（其の十四で更新）。全折のチェーンデータ源 |
| `docs/minase_soron.md` | 水無瀬全100句の構造分析・総論 |
| `docs/minase_tsukeai_roles.md` | 付合の役割分担理論 |
| `docs/minase_sangin_hyakuin.md` | 水無瀬三吟百韻 本文 |

---

## 六、其の十四のClaudeの所見

1. **句去境界バグは発見できたことが成果。** 水無瀬の正解データを正解データとして使ったからこそ顕在化した。机上のテスト（合成ケース）だけでは発見できなかったバグ。

2. **試験5のNGは未コミットのまま終了した。** 試験4（ad4ec87）がcleanなので、次回は「試験5のNGを修正してコミット」という明確なゴールから始められる。中途半端なコミットをしなかったのは正しい判断。

3. **Pythonスクリプトによる挿入手順が確立した。** ヒアドキュメントのEOF問題・assertによる挿入位置確認・`python3 - << 'EOF'` 方式の安定性が今回のセッションで実証された。次回以降は同じパターンで進められる。

4. **Unicode文字コードのミスが2件発生した。** `\u8174\u7d20\u7269`（腴素物）と `\u6642\u5246`（時剆）。Pythonの `\uXXXX` エスケープを使う際は、必ず事前に `chr(0xXXXX)` で確認してから使うべき。

---

*全8折の分析が揃い、初折裏まで式目検証が通った。*
*「五句去と数えて四句の間あり」── 古典の数え年が、現代のインデックス計算と1だけずれていた。*
*其の十五は、その1を直すところから始まる。*

