# waka-collector テスト計画書

## 1. テストの目的

このドキュメントは waka-collector アプリケーションのテスト方針・計画・手順をまとめたものです。
テストを書く目的は以下の3点です。

- **品質保証：** コードが期待通りに動くことを確認する
- **回帰防止：** 機能追加や修正時に既存機能を壊していないことを確認する
- **仕様の文書化：** テストコードそのものがアプリの仕様書になる

---

## 2. テスト環境

| 項目 | 内容 |
|---|---|
| テストフレームワーク | RSpec |
| テストデータ生成 | factory_bot |
| テスト用DB | PostgreSQL（waka_collector_test） |
| 実行コマンド | `bundle exec rspec` |

---

## 3. テストの種類と役割

### 3.1 モデルスペック（`spec/models/`）

**目的：** モデルのビジネスロジック（バリデーション・メソッド）が正しく動作するかを確認する。

**着眼点：**
- バリデーションが正しく機能しているか
- 有効なデータは保存できるか
- 無効なデータは拒否されるか
- モデルのメソッドが期待した値を返すか

**注意事項：**
- `build` を使いDBに保存せずテストする（高速）
- DB保存が必要な場合のみ `create` を使う
- 境界値（空文字・nil・最大文字数）を意識したテストケースを書く

### 3.2 リクエストスペック（`spec/requests/`）

**目的：** HTTPリクエストからレスポンスまでの一連の流れ（コントローラの動作）を確認する。

**着眼点：**
- 各アクションが正しいHTTPステータスコードを返すか
- データの登録・更新・削除が正しく行われるか
- バリデーションエラー時に登録されないか
- リダイレクト先は正しいか

**注意事項：**
- `create(:waka)` でDBにデータを作成してからテストする
- `change(Waka, :count).by(1)` でDB件数の変化を確認する
- 正常系（成功）と異常系（失敗）の両方をテストする

### 3.3 ビュースペック（`spec/views/`）※今後実装予定

**目的：** ビューが正しいHTMLを生成するかを確認する。

**着眼点：**
- 必要な要素（テキスト・リンク・フォーム）が表示されているか
- エラーメッセージが正しく表示されるか

### 3.4 ヘルパースペック（`spec/helpers/`）※今後実装予定

**目的：** ヘルパーメソッドの動作を確認する。

---

## 4. テスト実装手順

### 4.1 事前準備

```bash
# テスト用DBの確認
bundle exec rails db:migrate RAILS_ENV=test

# factory_botの設定確認（spec/rails_helper.rb）
# 以下が含まれていること
config.include FactoryBot::Syntax::Methods
```

### 4.2 factoryの定義（`spec/factories/wakas.rb`）

```ruby
FactoryBot.define do
  factory :waka do
    upper_phrase { '春はあけぼの やうやう白く なりゆく山ぎは' }
    lower_phrase { 'すこしあかりて 紫だちたる雲の' }
    author { '清少納言' }
    source { '枕草子' }
    era { '平安' }
    notes { 'テストデータ' }
  end
end
```

**着眼点：** factoryは「有効なデータの基本形」を定義する。テスト内で一部だけ上書きして使う。

### 4.3 モデルスペックの実装（`spec/models/waka_spec.rb`）

```ruby
require 'rails_helper'

RSpec.describe Waka, type: :model do
  describe 'バリデーション' do
    it '上の句と下の句があれば有効' do
      waka = build(:waka)
      expect(waka).to be_valid
    end

    it '上の句がなければ無効' do
      waka = build(:waka, upper_phrase: '')
      expect(waka).not_to be_valid
    end

    it '下の句がなければ無効' do
      waka = build(:waka, lower_phrase: '')
      expect(waka).not_to be_valid
    end
  end
end
```

**各テストの目的：**

| テスト名 | 目的 | 着眼点 |
|---|---|---|
| 上の句と下の句があれば有効 | 正常系の確認 | factoryのデフォルトデータで有効になること |
| 上の句がなければ無効 | 異常系の確認 | presenceバリデーションが機能すること |
| 下の句がなければ無効 | 異常系の確認 | presenceバリデーションが機能すること |

### 4.4 リクエストスペックの実装（`spec/requests/wakas_spec.rb`）

```ruby
require 'rails_helper'

RSpec.describe "Wakas", type: :request do
  describe "GET /wakas" do
    it "一覧ページが表示される" do
      get wakas_path
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /wakas/new" do
    it "新規登録ページが表示される" do
      get new_waka_path
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /wakas/:id" do
    it "詳細ページが表示される" do
      waka = create(:waka)
      get waka_path(waka)
      expect(response).to have_http_status(:success)
    end
  end

  describe "POST /wakas" do
    it "有効なデータで和歌を登録できる" do
      expect {
        post wakas_path, params: { waka: attributes_for(:waka) }
      }.to change(Waka, :count).by(1)
    end

    it "無効なデータでは登録できない" do
      expect {
        post wakas_path, params: { waka: attributes_for(:waka, upper_phrase: '') }
      }.not_to change(Waka, :count)
    end
  end
end
```

**各テストの目的：**

| テスト名 | 目的 | 着眼点 |
|---|---|---|
| 一覧ページが表示される | indexアクションの正常動作 | HTTPステータス200が返ること |
| 新規登録ページが表示される | newアクションの正常動作 | HTTPステータス200が返ること |
| 詳細ページが表示される | showアクションの正常動作 | 既存データを作成してから取得できること |
| 有効なデータで和歌を登録できる | createアクションの正常系 | DBの件数が1件増えること |
| 無効なデータでは登録できない | createアクションの異常系 | DBの件数が変化しないこと |

---

## 5. テスト実行手順

### 5.1 全テスト実行

```bash
bundle exec rspec
```

### 5.2 特定ファイルのみ実行

```bash
# モデルスペックのみ
bundle exec rspec spec/models/waka_spec.rb

# リクエストスペックのみ
bundle exec rspec spec/requests/wakas_spec.rb
```

### 5.3 特定のテストのみ実行

```bash
# 行番号を指定
bundle exec rspec spec/models/waka_spec.rb:5
```

### 5.4 結果の見方

```
...        # .(ドット) = テスト成功
F          # F = テスト失敗
*          # * = pending（未実装）

3 examples, 0 failures        # 全成功
3 examples, 1 failure         # 1件失敗
3 examples, 0 failures, 1 pending  # 1件未実装
```

---

## 6. テスト全体を通した注意事項

### 6.1 テストの独立性

各テストは独立して動作すること。あるテストの結果が別のテストに影響しないように、`config.use_transactional_fixtures = true` により各テスト後にDBがロールバックされる。

### 6.2 build と create の使い分け

| メソッド | DB保存 | 用途 |
|---|---|---|
| `build(:waka)` | しない | バリデーションのテスト（高速） |
| `create(:waka)` | する | 取得・更新・削除のテスト |
| `attributes_for(:waka)` | しない | パラメータのハッシュが必要なとき |

**原則：** DBアクセスは最小限にする。`build` で済む場合は `build` を使う。

### 6.3 正常系と異常系の両方をテストする

正常系（成功するケース）だけでなく、異常系（失敗するケース）も必ずテストする。バリデーションのテストでは「有効なデータ」と「無効なデータ」の両方を書く。

### 6.4 テストの命名規則

テスト名は日本語でも英語でも良いが、**何をテストしているかが一目で分かる名前**をつける。

```ruby
# 良い例
it '上の句がなければ無効'
it '有効なデータで和歌を登録できる'

# 悪い例
it 'test1'
it 'バリデーションテスト'
```

### 6.5 テストが失敗したときの対処

1. エラーメッセージを読む
2. 失敗した行を確認する
3. `binding.pry` や `puts` でデバッグする
4. モデルやコントローラの実装を見直す

テストが失敗するのは「テストが悪い」か「実装が悪い」かのどちらかです。エラーメッセージを丁寧に読む習慣をつけることが大切です。

### 6.6 継続的なテスト追加

機能を追加するたびにテストも追加する。テストなしでコードを増やし続けると、後から書くのが困難になる。**機能実装と同時にテストを書く習慣**をつける。

---

## 7. 今後追加すべきテスト

| 対象 | 内容 | 優先度 |
|---|---|---|
| リクエストスペック | edit/updateアクション | 高 |
| リクエストスペック | destroyアクション | 高 |
| リクエストスペック | 検索機能 | 中 |
| モデルスペック | 検索スコープ（将来実装時） | 中 |
| ビュースペック | エラーメッセージの表示 | 低 |
