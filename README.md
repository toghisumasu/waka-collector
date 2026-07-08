# 連歌ウェブアプリ（waka-collector × Ollama）

古典和歌の収集システム waka-collector に、ローカル LLM（Ollama / qwen3:8b メンタムさん）を統合し、連歌の付け句生成と式目チェックを実現するウェブアプリケーション。

## 現在の到達点（フェーズ0〜5 完了）

| フェーズ | 内容 | 状態 |
|----------|------|------|
| 0 | 環境確認 | ✅ 完了 |
| 1-2 | 単体スクリプト確認 | ✅ 完了 |
| 3 | Renga モデル追加 | ✅ 完了 |
| 4 | Rails サービス・コントローラ | ✅ 完了 |
| 5 | ビュー・動作確認 | ✅ 完了 |

**動作環境**
- Ruby 3.3.6
- Rails 7.2.3
- PostgreSQL 16.13
- Ollama 0.23.2 / qwen3:8b（GPU オフロード）

**アクセス**
http://192.168.**0.**1:*000/rengas/new

## コア機能

### 付け句生成（RengaGenerator）
- 前句に対する七七の短句を生成
- Ollama API（think:true モード、タイムアウト300秒）
- 去嫌（直前の言葉との重複回避）を指示

### 式目チェック（RengaChecker）
- 字数判定（五七五 / 七七）
- 去嫌・定座（月・花・恋）の確認
- 音分解を breakdown として返す

### 本歌参照候補（planned）
- waka-collector DB との連携
- 古典和歌を参照元として活用

## ファイル構成
app/
├── controllers/rengas_controller.rb      # new / create / show
├── models/renga.rb                       # Renga モデル
├── services/
│   ├── ollama_client.rb                  # Ollama API 通信
│   ├── renga_generator.rb                # 付け句生成プロンプト
│   └── renga_checker.rb                  # 式目チェック
└── views/rengas/
├── new.html.erb                      # 前句入力フォーム
└── show.html.erb                     # 結果表示（音分解付き）
db/migrate/20260607005905_create_rengas.rb  # Renga テーブル

## 開発の進め方

### 現在の知見（プロンプト設計の原則）

1. **情報量と安定性はトレードオフ** — プロンプトを短く保つと 3-4 分で安定動作
2. **否定指示より肯定＋例示** — 「書くな」より「1行で出力する。例：…」が効く
3. **例示は局所的に効く** — すべての難読語を網羅はできない
4. **誤りの層を見分ける** — 字数誤判定の根は「漢字→読み」の変換にある

### 次のフェーズ（手順書2参照）

**フェーズ6：読みの正確化** ← 最優先
- プロンプトで読み変換を強調する（軽い対策）
- または Renga に maeku_yomi / tsugeku_yomi カラムを追加（本質的対策）

**フェーズ7：読み上げ機能（say）**
- macOS `say` コマンドで確定した読みを音声化
- 待ち時間を句の鑑賞時間に変える

**フェーズ8：複数句の連鎖**
- 連歌の本来の流れを実現
- 去嫌・定座を「文脈を持った判定」に進化させる

**フェーズ9：本歌取り（waka-collector DB連携）**
- 古典和歌データを投入
- 季語・歌枕から関連本歌を自動抽出

## リソース

- **開発手順書1**（フェーズ0〜5） — Z:\temp\wakas-web\連歌アプリ開発手順書.docx
- **開発手順書2**（発展フェーズ6〜9） — Z:\temp\wakas-web\連歌アプリ開発手順書2.docx
- **式目ルール**（連歌式目の制定） — Z:\temp\wakas-web\連歌式目の制定

## サーバ起動

```bash
# Mac mini
bundle exec rails server -b 0.0.0.0 -p 3000

# または WSL2 からリモート SSH
ssh macmini
cd /Volumes/externalHDD/projects/waka-collector
bundle exec rails server -b 0.0.0.0 -p 3000
```

## テスト・動作確認

単体スクリプト（~/renga_lab/）で Ollama 通信を確認してからプル。

```bash
# Ollama 通信テスト
ruby ~/renga_lab/test_ollama.rb

# 付け句生成テスト
ruby ~/renga_lab/test_tsugeku.rb

# 式目チェックテスト
ruby ~/renga_lab/test_check.rb
```

## トラブルシューティング

| 症状 | 原因 | 対処 |
|------|------|------|
| タイムアウト | Ollama 未ロード | `curl http://localhost:11434/api/generate -d '{"model":"qwen3:8b","prompt":"テスト","stream":false}'` で再ロード |
| unknown エラー | プロンプトが長すぎる | プロンプトを短く絞る。安定版に戻す |
| 付け句が短い | 出力例が不足 | RengaGenerator の出力例を七七の明確な例に修正 |
| 読みが誤判定 | 漢字→読み変換ミス | フェーズ6で読みカラムの活用を検討 |

## 最後に

連歌はコンピュータの論理と古典文学の美学が出会う場所。プロンプト調整もまた、制約の中で最良を目指す営みです。各フェーズを通じて、メンタムさんとの対話を深めていきましょう。

---

*「なぁなぁメンタム〜」*
