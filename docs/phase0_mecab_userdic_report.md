# Phase 0 報告書：Natto::MeCab ユーザー辞書読み込み確認（其の六十七）

対象依頼書：依頼書「其の六十七　Natto::MeCab ユーザー辞書読み込み確認 Phase 0」
実施日：2026-07-25
実施環境：Mac mini（`/Volumes/externalHDD/projects/waka-collector`）

ゲート確認：`bundle exec ruby script/verify_shikimoku.rb` → **113 pass / 0 fail**

---

## T1　`mecabrc` の確認

```
$ mecab-config --sysconfdir
/opt/homebrew/etc

$ cat /opt/homebrew/etc/mecabrc
dicdir = /opt/homebrew/lib/mecab/dic/ipadic
```

`mecabrc`（Homebrew版、`/opt/homebrew/etc/mecabrc`）には `dicdir` の指定のみがあり、
**`userdic` 行は存在しない**。

→ 依頼書の (a)/(b) の分岐について、**(b)（mecabrcにユーザー辞書指定なし）が事実**であると判明。
自動読み込みの余地はない。

## T2　ユーザー辞書ファイルの実体確認

`dict/user_entries.csv`（9行、コメントなし）：

```
紅葉,1285,1285,-3000,名詞,一般,*,*,*,*,紅葉,モミジ,モミジ
東風,1285,1285,-3000,名詞,一般,*,*,*,*,東風,コチ,コチ
時雨,1285,1285,-3000,名詞,一般,*,*,*,*,時雨,シグレ,シグレ
妙高,1288,1288,-3000,名詞,固有名詞,地域,一般,*,*,妙高,ミョウコウ,ミョウコウ
春雨,1285,1285,-3000,名詞,一般,*,*,*,*,春雨,ハルサメ,ハルサメ
五月雨,1285,1285,-3000,名詞,一般,*,*,*,*,五月雨,サミダレ,サミダレ
若菜,1285,1285,-3000,名詞,一般,*,*,*,*,若菜,ワカナ,ワカナ
かりね,1285,1285,-3000,名詞,一般,*,*,*,*,かりね,カリネ,カリネ
かりふし,1285,1285,-3000,名詞,一般,*,*,*,*,かりふし,カリフシ,カリフシ
```

コンパイル済み辞書 `dict/user.dic` はプロジェクト内に実在する
（`/Volumes/externalHDD/projects/waka-collector/dict/user.dic`）。

`mecabrc` に `userdic` 行が無いため、比較対象となる「mecabrcが指すパス」は存在しない。
`dict/user.dic` はアプリ側コードが明示的にパス指定して読み込む専用ファイルであり、
システムのMeCab設定とは独立している。

なお、システム内の他プロジェクト（`kasen-za`）にも同名の `dict/user.dic` が存在するが、
これは別プロジェクトの独立したファイルであり、waka-collectorの `mecabrc` 経由読み込みとは無関係。

## T3　本番コードでの `Natto::MeCab.new` 呼び出し確認

`app/` 配下（`.bak_*` 系の非本番ファイルを除く）での呼び出し箇所：

| ファイル | 行 | 呼び出し |
|:--|:--|:--|
| `app/services/renga_generator.rb` | 226 | `Natto::MeCab.new(userdic: USER_DIC)` |
| `app/services/renga_generator.rb` | 229 | `Natto::MeCab.new`（rescue節、フォールバック） |
| `app/controllers/rengas_controller.rb` | 187 | `Natto::MeCab.new(userdic: RengaGenerator::USER_DIC)` |
| `app/controllers/rengas_controller.rb` | 190 | `Natto::MeCab.new`（rescue節、フォールバック） |
| `app/services/ku_validator.rb` | 42, 57 | `Natto::MeCab.new(userdic: USER_DIC)`（フォールバックなし） |

いずれも `build_mecab` メソッドの実装は同一パターン：

```ruby
def build_mecab
  Natto::MeCab.new(userdic: USER_DIC)
rescue => e
  Rails.logger.warn "ユーザー辞書なし: #{e.message}"
  Natto::MeCab.new
end
```

`USER_DIC = Rails.root.join("dict", "user.dic").to_s`（`renga_generator.rb:6`、`ku_validator.rb:6`）。

`app/services/bui_dictionary.rb` 自体は `Natto::MeCab.new` を呼ばず、
呼び出し側（`renga_generator.rb`／`rengas_controller.rb`）が構築した `nm` インスタンスを
引数として受け取る設計（コメント: 「nmは呼び出し側で構築済みのNatto::MeCabインスタンス」）。

**本番コードは通常経路で `userdic: USER_DIC` を明示指定しており、
無引数呼び出しは `dict/user.dic` の読み込みに失敗した場合のみのフォールバックである。**
これは其の六十六のスクリプトが行った「無引数呼び出し（フォールバックではなく唯一の呼び出し）」
とは条件が異なる。

## T4　実地確認

`dict/user_entries.csv` に実在する語「紅葉」（登録読み: モミジ）で比較した。

```
=== A: Natto::MeCab.new (no args) ===
紅葉    名詞,サ変接続,*,*,*,*,紅葉,コウヨウ,コーヨー

=== B: Natto::MeCab.new(userdic: dict/user.dic) ===
userdic_path exists?: true
紅葉    名詞,一般,*,*,*,*,紅葉,モミジ,モミジ
```

A（無引数）は標準辞書の読み「コウヨウ」（音読み・サ変接続）を返し、
B（`userdic:` 明示指定）はユーザー辞書由来の読み「モミジ」（名詞・一般）を返した。

→ **無引数の `Natto::MeCab.new` ではユーザー辞書は反映されない**ことを実地で確認した。
T1の`mecabrc`調査結果（userdic指定なし）と整合する。

## T5　結論

1. **其の六十六 T1の「ユーザー辞書なし」という前提は事実だった。**
   `mecabrc` に `userdic` 指定がなく（T1）、無引数の `Natto::MeCab.new` では
   実地確認でもユーザー辞書が反映されないこと（T4）を確認した。
   依頼書が懸念した (a)（mecabrc経由の自動読み込み）は成立しない。

2. **本番コードの通常呼び出しは、其の六十六のスクリプトと条件が異なる。**
   `renga_generator.rb`・`rengas_controller.rb`・`ku_validator.rb` はいずれも
   `userdic: USER_DIC` を明示指定する呼び出しを主経路としており（無引数呼び出しは
   辞書読み込み失敗時のフォールバックのみ）、其の六十六のスクリプトが検証した
   「ユーザー辞書なし」の条件は、本番の通常経路とは一致しない。

3. **ただし、この相違は「逢ふ」「おもひ」「消え帰り」のNG判定には影響しない。**
   `dict/user_entries.csv`（T2）の登録語は「紅葉・東風・時雨・妙高・春雨・五月雨・
   若菜・かりね・かりふし」の9語のみであり、恋の候補語（逢ふ・おもひ・消え帰り等）は
   一切含まれていない。したがって、本番と同じ `userdic: USER_DIC` 付きで再検証しても、
   これら3語のトークン化結果（NG）は変わらない。

   **結論：其の六十六 T1の「逢ふ」「おもひ」「消え帰り」NG判定はそのまま有効。**
   前提の記述（「ユーザー辞書なし」）は本番の通常経路の条件とは技術的に異なっていたが、
   結果に影響する相違ではなかった。依頼書が懸念した「より強い（かつ異なる意味を持つ）
   結果への読み替え」は不要である。

4. **一般的な注意点として記録に残す価値がある事実：**
   本番コードのフォールバック（`dict/user.dic` 読み込み失敗時に無引数へ自動的に
   切り替わる）は例外を握りつぶしログ出力のみで継続する設計であり、
   辞書ファイルの破損・パス変更等が起きた場合に検出しにくい。
   これは本依頼のスコープ外（動作変更の提案）だが、事実として記録する。

---

*関連：`docs/phase0_koi_hojo_signal_report.md`（其の六十六）、
`dict/user_entries.csv`、`app/services/renga_generator.rb`、
`app/controllers/rengas_controller.rb`、`app/services/ku_validator.rb`*
