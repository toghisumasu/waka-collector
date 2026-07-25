# MeCabユーザー辞書 反映手順

作成日：2026-07-25（其の六十五 追記2 T3）

`dict/user_entries.csv`（MeCabユーザー辞書のソース）を変更した際、`dict/user.dic`（コンパイル済みバイナリ）にどう反映するかの手順。`docs/handover_20260626.md`に埋め込まれていた記述を独立した手順書として整理・転記したもの。

## 対象

- `RengaGenerator::USER_DIC`（= `Rails.root.join("dict", "user.dic")`）を参照する箇所すべて：`RengasController#create`（Web本番経路）、`RengaGenerator`、`KuValidator`、`script/`配下の各種観測・検証スクリプト
- `dict/user.dic`が読み込みに失敗した場合、`RengasController#build_mecab`は`rescue`でユーザー辞書無しの素のMeCabにフォールバックする（警告ログ出力）。反映漏れは即エラーにはならず、検出漏れという形で静かに劣化するため注意。

## ローカル（Mac mini）での反映手順

**承認ゲート（本依頼・其の六十五で新設）：** `dict/user_entries.csv`の変更は`app/data/*.yml`と同様、差分提示と人間の承認を経てから適用すること（D-33-1相当のゲート。詳細は`docs/phase1a_tabi_report.md`第8章C3参照）。

1. `dict/user_entries.csv`に1行追加する。形式は既存行に合わせる：

   ```
   語,左文脈ID,右文脈ID,コスト,品詞,品詞細分類1,品詞細分類2,品詞細分類3,活用型,活用形,原形,読み,発音
   ```

   既存語は`1285,1285,-3000`（一般名詞）または`1288,1288,-3000`（固有名詞・地域、例：妙高）を使っている。新規語が一般名詞であれば`1285,1285,-3000`を踏襲する。

2. `mecab-dict-index`で`dict/user.dic`を再コンパイルする。**`dict/build.sh`のようなラッパースクリプトは存在しない**ため、以下を直接実行する（このMac mini・Homebrew版mecabでのパス）：

   ```sh
   /opt/homebrew/Cellar/mecab/0.996/libexec/mecab/mecab-dict-index \
     -d /opt/homebrew/lib/mecab/dic/ipadic \
     -u dict/user.dic \
     -f utf-8 -t utf-8 dict/user_entries.csv
   ```

   - `mecab-dict-index`のパスはHomebrewのmecabバージョンによって変わりうる（`brew list mecab`または`find /opt/homebrew -iname mecab-dict-index`で確認）。
   - ipadic本体のパスは`mecab-config --dicdir`で確認できる（このMac miniでは`/opt/homebrew/lib/mecab/dic`、その下の`ipadic`ディレクトリを指定する）。
   - `docs/handover_20260626.md`にはLinux想定のパス（`/usr/lib/mecab/mecab-dict-index`・`/var/lib/mecab/dic/ipadic`）が書かれているが、**このMac mini環境ではHomebrewパスを使う**（其の六十五で確認・本手順に反映済み）。

3. 再コンパイル後、`bundle exec ruby script/verify_shikimoku.rb`を実行し、既存の回帰テスト（試験15：ユーザー辞書語のトークン化・bui検出確認）が0 failのままであることを確認する。

4. `dict/user.dic`はバイナリだが、既存の運用（commit `7c4d876`）に倣いリポジトリにコミットする（`.gitignore`に`dict/`関連の除外設定は無いことを確認済み）。

## 本番環境への反映手順

**waka-collectorが本番環境にデプロイされているかどうか自体が未確認である。** 其の六十五 追記2 T0の調査でリポジトリ内を検索したところ、`docs/handover_其の十五.md`に「ConoHa」への言及が1行あったが、これは別プロジェクト（栄養計画アプリ`eiyokeikaku_app`）のデプロイ手順書に関するものであり、waka-collectorのデプロイ先を示す記録ではないことが人間側の確認で判明した（当初「ConoHa VPSへ移行済み」という前提で調査していたが、この前提自体が誤りだった）。

`docs/aws_deploy_guide.md`（2026-04-15付）にはAWS EC2へのデプロイ記録があるが、**これが現在も有効か、waka-collectorが今どこかにデプロイされているのかは、リポジトリの記述だけでは確認できない**（現状との整合性は未確認。EC2時代の記録として現状と不一致と断定するものではない）。ローカル（Mac mini）以外に実際に稼働している環境があるのかどうか自体、未確認のまま残る。

**したがって、今回（其の六十五）の「かりね」「かりふし」ユーザー辞書対応は、現時点ではローカル（Mac mini development環境）での反映のみを保証範囲とする。** 本番環境（の有無を含め）への反映が必要かどうか、必要な場合の手順は、別途人間が確認・判断する未解決事項として残す。

## 未解決事項

- waka-collectorが本番環境にデプロイされているかどうか自体が未確認（ローカルMac mini上でのみ動作している可能性もある）
- デプロイされている場合、そこでの環境（OS・mecabのインストール方法・`dict/user.dic`の配置パス等）がこのMac mini（Homebrew版mecab）と同じ前提で反映できるかは未確認
- `docs/aws_deploy_guide.md`の内容が現状と整合するかどうかも未確認（2026-04-15付の記録という以上のことは分からない）

---

*関連：`docs/phase1a_tabi_report.md`（其の六十五、C1〜C3・T0を含む）、`docs/handover_20260626.md`（旧手順の記載元）、`dict/user_entries.csv`*
