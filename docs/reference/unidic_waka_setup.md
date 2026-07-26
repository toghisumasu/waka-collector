# UniDic和歌版 セットアップ手順（WakaUnidicAnalyzer用）

作成日：2026-07-26（其の六十九）

`app/services/waka_unidic_analyzer.rb`が参照するUniDic和歌版の入手・展開・環境変数設定の手順。既存の`ku_validator.rb`（IPA辞書＋`dict/user.dic`）とは完全に独立しており、本設定を行わなくても既存機能には一切影響しない。

## ライセンス

- **UniDic和歌版 ver.2025.12**：Creative Commons 表示 - 非営利 - 継承 4.0 国際（CC BY-NC-SA 4.0）
- 提供元：国立国語研究所「通時コーパス」プロジェクト（実装：小木曽智信）
- **非営利限定**。waka-collectorを将来営利利用する場合は配布元への事前相談が必要（本手順の対象外）。
- この理由により、辞書本体・派生物（コンパイル済みユーザー辞書等）はリポジトリにコミットしない。

## 入手・展開

1. `https://clrd.ninjal.ac.jp/unidic_archive/2512/unidic-waka-v202512.zip` から取得（約914MB）。
2. リポジトリ外の永続ディレクトリ、または`tmp/`配下（既存`.gitignore`の`/tmp/*`規則でカバー済み）に展開する。展開後は約1.8GB。
3. 展開先に`sys.dic` / `matrix.bin` / `char.bin` / `dicrc` / `unk.dic` / `unk.def` / `feature.def` / `README.md`が含まれることを確認する。

このMac miniでは`tmp/unidic-waka/`に展開済み（其の六十八Phase0調査で使用したものと同一）。

## 環境変数

| 変数名 | 内容 | 必須 |
|---|---|---|
| `WAKA_UNIDIC_DICDIR` | UniDic和歌版の展開先ディレクトリ | 必須（未設定時は`WakaUnidicAnalyzer.available?`が`false`を返し、サービスは無効化される） |
| `WAKA_UNIDIC_USERDIC` | UniDic用ユーザー辞書（コンパイル済み`.dic`）のパス | 任意 |

例（このMac miniでの開発時）：

```sh
export WAKA_UNIDIC_DICDIR="$(pwd)/tmp/unidic-waka"
```

## 素性列の構造（重要）

UniDic和歌版の素性（`node.feature.split(",")`）はIPA辞書と列数・列の意味が異なる。このMac mini上の実際の辞書ビルドで実測した値：

| 用途 | 列番号 | 実測例（「紅葉」） |
|---|:--:|---|
| 品詞（大分類） | 0 | 名詞 |
| 語彙素読み（lForm） | 6 | モミジ |
| 語彙素（lemma） | 7 | 紅葉 |
| 発音形（pron） | 9 | モミジ |
| 発音形基本形（pronBase） | 11 | モミジ |
| 総列数 | - | 29 |

`lForm`は辞書見出し語（終止形）の読みであり、活用語の実際の活用形の読みではない（例：「けり」と「ける」で`lForm`が同じ値になりうる）。表層の発音を見たい場合は`pron`を使うこと。`WakaUnidicAnalyzer`はこの4つを含む`Morpheme`構造体（`surface / pos / lform / lemma / pron / pron_base`）を返す。

列数がここに記載した29と異なるビルドを読み込んだ場合、`WakaUnidicAnalyzer`は暗黙に誤った列を読まず、`WakaUnidicAnalyzer::UnsupportedFeatureFormatError`を送出する。

## ユーザー辞書との併用について（其の六十九で試行・未実現）

`WakaUnidicAnalyzer`は`WAKA_UNIDIC_USERDIC`が設定されていれば`-u`オプションを付与する配線までは実装済みだが、**実際に動作するUniDic用ユーザー辞書ファイルの作成には至っていない。**

`dict/user_entries.csv`（IPA辞書のフィールド構成を前提にコンパイル済み）はUniDicのシステム辞書とは列構成・コストIDの体系が異なるため、そのままでは互換性がない。UniDic用に別途コンパイルを試みたが、`mecab-dict-index -a`（POS名からコスト・接続IDを自動推定するモード）が要求する`left-id.def`・`right-id.def`等のモデルファイルが、この解析用配布物（`tmp/unidic-waka/`）には含まれておらず失敗した。natto経由で既存語の接続ID（lcAttr/rcAttr相当）を取得する手段もなかったため、IDを数値で明示指定する代替手段も断念した。

UniDic用ユーザー辞書が必要な場合は、モデルファイル一式を含む別の構築用パッケージの入手、または他の対策が必要。今後のPhase 0調査候補。

## 関連資料

- `docs/phase0_unidic_koshabun_report.md`（其の六十八Phase0調査報告）
- `docs/依頼書_其の六十九_UniDic並行運用基盤実装.md`（本実装の依頼書）
- `docs/reference/natto_jisho_tsukaikata.md`（natto/ユーザー辞書の基本的な使い方）
- `app/services/waka_unidic_analyzer.rb`
