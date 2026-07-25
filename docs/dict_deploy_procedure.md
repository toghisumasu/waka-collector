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

**waka-collectorは現時点では未デプロイであり、ローカルMac miniでのみ動作している（人間による確認、2026-07-25）。** 其の六十五 追記2 T0の調査時点では「本番環境にデプロイされているかどうか自体が未確認」としていたが、その後の確認で「未デプロイ」という事実が判明した。`docs/handover_其の十五.md`の「ConoHa」への言及は別プロジェクト（栄養計画アプリ`eiyokeikaku_app`）のデプロイ手順書に関するものであり、waka-collectorとは無関係だった（当初「ConoHa VPSへ移行済み」という前提で調査していたが、この前提自体が誤りだったことも確認済み）。`docs/aws_deploy_guide.md`（2026-04-15付）のAWS EC2記録も、現状のwaka-collector運用とは対応していない。

**将来的にConoHa VPSへのデプロイを想定している。** 同VPS上には既に`keiba-web`・`eiyokeikaku_app`が同居運用されており、waka-collectorを追加する際は同様のマルチアプリ運用（ポート分離・Nginx別server block・nftables開放・systemd化等）を踏まえる想定である。

参考資料として`docs/eiyokeikaku_conoha_deploy_procedure_v1.0.docx`（栄養計画アプリのConoHa VPSデプロイ手順書）を配置している。これは他プロジェクト（eiyokeikaku_app）の手順書であり、waka-collector自身のデプロイ記録ではないが、同一VPSへの将来デプロイ時にそのまま参考になるノウハウが含まれる：

- Unixソケット接続のPeer認証回避（`database.yml`に`host: 127.0.0.1`を明示する必要）
- `bin/rails server`がPuma設定の`bind`を無視し`0.0.0.0`で待受してしまう問題（`bundle exec puma -C config/puma.rb`を直接使う）
- 非標準ポートでのCSRF Origin不一致（Nginxの`proxy_set_header Host`に`$http_host`を使う必要、`$host`ではポート番号が欠落する）
- ホスト側nftablesとConoHaセキュリティグループの二重ファイアウォール（両方の開放が必要）
- 複数アプリ同居時のポート分離・Nginx server block分離・systemdサービス個別化

**したがって、今回（其の六十五）の「かりね」「かりふし」ユーザー辞書対応は、現時点ではローカル（Mac mini development環境）での反映のみを保証範囲とする。** 将来waka-collectorをConoHa VPSへデプロイする際は、上記の参考資料を踏まえつつ、本ドキュメントのローカル反映手順（Homebrew版mecab前提）をLinux環境（Debian、上記docx記載のOS）向けに読み替える必要がある点に注意する。

## 未解決事項

- waka-collectorのConoHa VPSへの具体的なデプロイ計画（時期・ポート番号・ドメイン等）は本ドキュメント作成時点では未確定
- デプロイ先のLinux環境（Debian等）でのmecab導入方法・`mecab-dict-index`のパス・`dict/user.dic`の配置は、Homebrew前提の本手順とは異なるため、実際のデプロイ時に別途手順を整備する必要がある
- `docs/eiyokeikaku_conoha_deploy_procedure_v1.0.docx`はeiyokeikaku_app固有の設定（DBロール名・systemdサービス名・ポート番号等）を含むため、waka-collector用にそのまま流用はできない。ノウハウ（落とし穴の回避策）の参考として読むこと

---

*関連：`docs/phase1a_tabi_report.md`（其の六十五、C1〜C3・T0を含む）、`docs/handover_20260626.md`（旧手順の記載元）、`dict/user_entries.csv`、`docs/eiyokeikaku_conoha_deploy_procedure_v1.0.docx`（参考：他プロジェクトのConoHa VPSデプロイ手順書）*
