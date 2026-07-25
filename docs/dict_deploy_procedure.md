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

## 本番（ConoHa VPS）への反映手順

**現時点で文書化されていない。** 其の六十五 追記2 T0の調査で、リポジトリ内には`docs/handover_其の十五.md`にConoHaへの言及が1行あるのみで、具体的なデプロイ・環境変数・辞書配置パス等の記録は見つからなかった。`docs/aws_deploy_guide.md`（2026-04-15付）はAWS EC2時代の記録であり、現状のデプロイ先（ConoHa VPS）とは一致しないため、そのまま参照しないこと。

現在のwaka-collectorの実運用がこのMac mini上のローカル実行なのか、ConoHa VPS上の別インスタンスなのか（あるいは両方）も、リポジトリの記述だけでは判断できない。

**したがって、今回（其の六十五）の「かりね」「かりふし」ユーザー辞書対応は、ローカル（Mac mini）実行環境への反映のみを保証範囲とする。** ConoHa VPS側に同様の反映が必要かどうか、必要な場合の手順は、別途人間が判断・実施する未解決事項として残す。

## 未解決事項

- ConoHa VPSが実際にwaka-collectorのデプロイ先として稼働しているか自体が、リポジトリの記述からは確認できない
- ConoHa VPS側の環境で`dict/user.dic`がどう配置・参照されているか（ローカルと同じ`Rails.root.join("dict", "user.dic")`か、別パスか）は不明
- ConoHa VPSへの辞書反映が必要な場合、mecabのインストール方法（Homebrew前提の本手順はLinux環境ではそのまま使えない）を含めて別途手順を整備する必要がある

---

*関連：`docs/phase1a_tabi_report.md`（其の六十五、C1〜C3・T0を含む）、`docs/handover_20260626.md`（旧手順の記載元）、`dict/user_entries.csv`*
