# waka-collector 其の四十冒頭 調査報告（run5沈黙停止の原因調査）

作業日: 2026-07-17
対象: 其の三十九 run5（`log/observation_sono39_run5_20260716.jsonl`、verse_no=72で停止）
性質: **調査のみ。実装・修正は一切行っていない。**
ゲートチェック: `verify_shikimoku.rb` 88 pass / 0 fail（作業前に確認済み、未変更）

## 0. 調査方法についての前置き（重要な前提の訂正）

依頼書は「jsonlログの最終行と直前行のタイムスタンプを突き合わせる」ことを
最初の手順として指定していたが、**`log/observation_sono39_run5_20260716.jsonl`
の各行にはタイムスタンプフィールドが存在しない**（`log_line`関数はverse_no/
attempt/text/violations等のみを書き出しており、時刻を記録していない）。

そのため、以下の代替手段で時刻を復元した：

1. `rengas`テーブルの`created_at`カラム（`observation_batch: "sono39_run5_20260716"`
   で絞り込み）— 各verseの保存時刻が秒単位で正確に残っている
2. `log/development.log`の`[RengaGenerator] attempt:`/`total:`ログ行（時刻プレフィックス
   なしだが、行の出現順序とDBの`created_at`を突き合わせて相対位置を特定）
3. Ollama自体のリクエストログ`/opt/homebrew/var/log/ollama.log`（`[GIN]`行、
   JST・秒単位、全リクエストの応答時間とステータスコードを記録）
4. macOS統一ログ（`log show`。ollamaプロセスのPIDごとの活動記録）

この代替手段により、依頼書が想定していたよりはるかに高精度（秒単位、かつ
Ollama側の生リクエスト単位）で時刻を特定できた。

## 1. 確定した事実（時系列）

DB（`Renga.where(observation_batch: "sono39_run5_20260716")`）より、run5は
72件のRengaレコードを作成して停止：

- 最初の保存: id=307, 2026-07-16 11:20:52 UTC（20:20:52 JST）
- 最後の保存: id=378, 2026-07-16 11:53:42 UTC（**20:53:42 JST**、verse_no=72）
- 以降、DBにも`log/observation_sono39_run5_20260716.jsonl`にも一切の追記なし

verse間の保存間隔（delta）は序盤1〜5秒程度だったが、後半にかけて拡大した
（id=358で250.1秒、id=373で285.3秒）。**ただし**`development.log`の
`[RengaGenerator] attempt:`（個々のOllama `generate()`呼び出しの所要時間を
実測しているログ）を見ると、実行終盤でも個々のOllama呼び出し自体は
1〜2秒台で応答しており遅くなっていない。つまり**verseあたりの所要時間が
伸びていたのは個々のOllama応答が遅くなったからではなく、再試行回数
（内部5×5ループ・forced_zatsuエスカレーション）が増えたため**であることが
確認できた。

`development.log`の最終行（ファイル全体の末尾、20952行目）は
`[RengaGenerator] attempt: 1.298437s`であり、その直後に来るはずの
`[RengaGenerator] total:`行が存在しない。これはverse_no=73の
`generate_tsugeku`呼び出しが**内部の25回ループを完走せずに停止した**
ことを直接示す。

同時刻帯のOllama自身のリクエストログ（`/opt/homebrew/var/log/ollama.log`）：

```
20:53:42 200  983ms   POST /api/generate
20:53:44 200  1.331s  POST /api/generate   ← development.logの2件のattempt:と対応
20:53:45 200  1.297s  POST /api/generate
20:53:46 500  967ms   POST /api/chat       ← ここでエラー応答
（以降、次のログ行まで完全な空白）
21:41:02 200  19.8µs  HEAD /
21:41:02 200  7.4µs   GET  /api/ps
```

**20:53:46から21:41:02までの約47分間、Ollamaのリクエストログには一切の
記録がない。** この間、waka-collectorの観測スクリプト以外にも本機で稼働中の
他アプリ（`kasen-za`:3002、`eiyokeikaku_app`:3001）由来と見られる`/api/chat`
呼び出しが20:40〜20:53の間ほぼ2秒間隔で継続的に記録されていたが、これも
20:53:46で**同時に**途絶えている。これは偶然の一致というより、Ollama側
（モデルランナー・GPU/Metalバックエンド）が20:53:46前後に全リクエストを
処理不能な状態に陥ったことを示唆する。

macOS統一ログ（`log show --predicate 'process == "ollama"'`）でも、
`ollama`プロセスに紐づくサブプロセスPIDが20:20台では`91027`だったのに対し、
21:41:02台では`93793`に変わっており、かつその間の約47分間は`ollama`
プロセスに関する統一ログの記録が完全に存在しない（通常であれば
アイドル状態でも何らかのシステムフレームワーク呼び出しが記録される）。
これはOllamaのモデルランナー（qwen3:8bを実行するサブプロセス）が
一度クラッシュ・停止し、しばらく再起動されなかったことと整合する。

tmuxセッション`sono39_observe_run5`は本調査時点（2026-07-17 05:33 JST、
インシデントから約9時間後）でも残存していたが、ペインは空のシェル
プロンプトのみでスクロールバック履歴もなく、対応するrubyプロセスは
既に存在しなかった（`ps aux`で確認）。**プロセスが自然終了したのか、
誰かが手動で中断したのかは判別できなかった**（未確認事項として扱う）。

## 2. 仮説別の整理

### 仮説A：Ollamaハング

| 項目 | 内容 |
|---|---|
| 支持する事実 | ①Ollamaリクエストログが20:53:46〜21:41:02の約47分間完全に途絶（waka-collector以外の並行トラフィックも同時に途絶）。②同時間帯にollamaのサブプロセスPIDが変化（91027→93793）＝ランナー再起動を示唆。③20:53:46に`/api/chat`が**HTTPステータス500**で応答（Ollama内部でエラー発生を示す一次証拠）。④`OllamaClient.chat`はHTTPステータスコードを一切検査していないため（`ollama_client.rb`）、500応答のJSONボディに`"message"`キーが無ければ`nil`を返し、例外にならず静かに空文字列の付句として扱われる（＝この1回自体はハングの原因ではなく、正常に「エラー応答」として処理された） |
| 反する事実 | `OllamaClient`の`read_timeout`は`generate`が180秒・`chat`が300秒で明示的に設定されており、Net::HTTPの`read_timeout`はソケットの`select()`ベースの実装（Rubyの`Timeout`監視スレッド方式ではない）のため、GVL競合やGCの影響を受けにくく、理論上はバイトが届かない状態が続けば必ず発火するはずである。500エラー応答自体は約1秒で返っており、少なくともこの1リクエストはハングしていない |
| 未確認事項 | 500エラー直後、mora_error_streakの条件によりRengaGeneratorが即座に次のOllama呼び出し（Socratic分岐の`chat()`、timeout:300）を発行したはずだが、development.logにもollama.logにもこの「次の呼び出し」に対応する記録が一切ない。この呼び出しがOllama側で本当に無応答（バイトゼロ）のまま47分間ブロックされたのか、それとも別の理由（後述）でRuby側がOllamaへの呼び出しに到達する前に停止したのかは未確認。read_timeout=300秒が実際に発火しなかった理由（Rubyプロセス側の問題か、Ollama側が到達不能で永久に待ち続けたのか）も未確定 |

### 仮説B：MeCabネイティブメモリ蓄積

| 項目 | 内容 |
|---|---|
| 支持する事実 | natto gem本体（`vendor/bundle/.../natto-1.2.0/lib/natto/natto.rb:436`）は確かに`ObjectSpace.define_finalizer`でネイティブリソース解放をGCに委ねている。これは依頼書の前提通り。`RengaGenerator#generate_tsugeku`は**verseごとに1回**`build_mecab`（＝新規`Natto::MeCab.new`）を呼んでおり、72verse実行で72個のMeCabインスタンスが生成された（GCで即座に解放される保証はない） |
| 反する事実 | 依頼書が前提としていた「`BuiDictionary#detect_all`が呼び出しのたびに新規Natto::MeCabインスタンスを生成している」という記述は**現在のコードでは事実と異なる**。`app/services/bui_dictionary.rb:40`の`detect_all(text, nm)`は引数`nm`（呼び出し側で構築済みのインスタンス）をそのまま使い回しており、内部でMeCabインスタンスを新規生成していない。つまり「attemptのたびに」ではなく「verseのたびに」1個という、依頼書の想定より2桁小さい生成頻度である（既に其の三十九終盤の確認内容が正しかったことの再確認）。また、development.logの個々のOllama呼び出し時間が終盤でも劣化していないことは、CPU/メモリ圧迫によるスローダウンの直接証拠としては弱い（Ollama呼び出し区間はGC一時停止の影響を受けにくい） |
| 未確認事項 | 72個のMeCabインスタンスが実際にGCで解放されていたか、プロセスのRSSがどう推移したかは今回計測しておらず（run5実行中の計装がなかったため）不明。仮にRSSが継続的に増加していたとしても、それがOSレベルのスワップ/スラッシングを引き起こしてRuby自身のシステムコール（select等）のスケジューリングを遅延させるほどの規模だったかは未検証 |

### 仮説C：D-19-5（句数ngの頻度・影響度）

run5のjsonl（117行、うちseed行1・attempt116）を集計：

| 指標 | 値 |
|---|---|
| 句数ng attempt数 | 23 / 116（19.8%） |
| 句数ngを最低1回経験したverse | 9 / 72（12.5%） |
| forced_zatsuエスカレーション発生verse | 3 / 72（4.2%）：verse 34・52・67 |
| verse 34の内訳 | 5回とも「句数:秋」ng→forced_zatsu×2→forced_zatsu_mora_ng（**純粋にD-19-5由来**） |
| verse 52の内訳 | 生成失敗3回＋句数:春ng1回→forced_zatsu×2→forced_zatsu_mora_ng（**D-19-5が一部関与**） |
| verse 67の内訳 | 生成失敗5回→forced_zatsu_create（**D-19-5とは無関係**） |
| 違反カテゴリ内訳（全attempt） | 句数23件／生成失敗23件／句去4件（句数と生成失敗が同数で主要因） |

| 項目 | 内容 |
|---|---|
| 支持する事実 | forced_zatsu発動3件中1.5件（34は完全、52は部分）がD-19-5（句数ng）に起因。1件のエスカレーションはverseあたりのOllama呼び出しを1回→6〜8回（jsonl記録ベース）に増加させており、句数ngの頻発が呼び出し回数を押し上げる構造は run5 の中でも実際に観測された |
| 反する事実 | **run5が最終的に沈黙停止したverse_no=73の直前（verse 71・72）には句数ngもforced_zatsuも発生していない**（verse71は生成失敗→リトライで通常成立、verse72は1回で成立）。development.logの分析（§1）から、verse73の停止はモーラ数不一致streak（generate()の`else`分岐が2回連続でモーラng）がSocratic分岐（timeout:300のchat）に切り替わった直後に起きたと特定でき、これは句数ng（D-19-5）ではなくモーラng streakが引き金である。**したがって、run5という個別インシデントの直接原因としてはD-19-5は支持されない** |
| 未確認事項 | jsonlの「attempt」はobserve_production_hyakuin.rb側の外側リトライ（MAX_RETRY=5）単位であり、`generate_tsugeku`内部の5×5＝最大25回のOllama呼び出しは1つの「attempt」として集約されている。したがって実際のOllama呼び出し総数は116件よりかなり多いと推定されるが、内部ループの呼び出し回数はログに残っておらず正確な倍率は不明 |

## 3. 3仮説の相互関係についての考察

今回のrun5沈黙停止という**個別インシデント**に限定して言えば、一次原因は
仮説Aの範疇（Ollama側の応答不能）である可能性が最も高い。具体的な連鎖は
以下のように再構成できる：

1. verse73処理中、生成された付句が2回連続でモーラ数不一致となり
   （D-19-5＝句数ngではない）、`mora_error_streak>=2`の条件でSocratic
   対話分岐（`OllamaClient.chat`、timeout:300）に切り替わった
2. この切り替わり後の最初の`chat`呼び出しで、Ollamaから**HTTPステータス500**
   が約1秒で返った（Ollama内部で何らかのエラーが発生したことを示す）。
   `OllamaClient.chat`はステータスコードを見ておらず、レスポンスボディに
   `"message"`キーがなければ静かに`nil`を返す実装のため、この時点では
   例外は発生していない
3. モーラng（空文字列）として処理が続行され、streak条件により**次の**
   `chat`呼び出しが即座に発行された。この呼び出し以降、development.logにも
   ollama.logにも一切の記録が残っていない
4. Ollama自身のプロセス（サブプロセスPIDの変化・統一ログの完全な空白から
   推測するに、モデルランナーがクラッシュ後しばらく再起動されなかった）が
   実質的に無応答状態に陥り、Rubyプロセスは`read_timeout=300`のはずの
   `chat`呼び出しの中で（本来なら5分で例外になるはずが）応答なく停止した
   まま、少なくとも本調査時点まで復帰しなかった

この連鎖が事実なら、**仮説Aが一次原因、かつ「read_timeoutが機能しなかった
理由」こそが真に未解決の中核**である。依頼書が提示した「ストリーミング
チャンク単位でのread_timeoutリセット」仮説は、本コードベースが
全呼び出しで`stream: false`を使っている（`ollama_client.rb`）ため
**前提が成立しない**ことが確認できた＝この経路は棄却してよい。

仮説B（MeCabネイティブメモリ）は、依頼書が想定した「attemptごとに新規
生成」という設計は現在のコードには存在せず（verseごとに1回のみ）、
run5個別インシデントの直接的な引き金だったという証拠も得られなかった。
ただし「verseごとに1個、GC非保証で蓄積する」という縮小版のリスクは
コード上否定できず、100句・数百句規模の長時間実行では依然として
無視できない可能性がある（今回は反証ではなく「規模が想定より小さい」
という訂正）。

仮説C（D-19-5）は、run5全体を通じて実在する負荷要因（3/72verseで
forced_zatsu発動、うち1.5件がD-19-5起因）ではあるが、**run5が沈黙停止した
その瞬間の直接原因ではない**。「句数ng頻発→forced_zatsu→Ollama呼び出し
増加→仮説A/Bの発生確率上昇」という因果の輪自体は否定しないが、今回の
停止点だけを見るとモーラng streakという別経路からSocratic分岐に入っており、
D-19-5を経由していない。D-19-5はOllama呼び出し回数を押し上げる**複数ある
経路のうちの1つ**として位置づけるのが正確である。

## 4. 次回計装の設計案（コードのみ提示・未適用）

### 4-1. wall-clockウォッチドッグ（仮説A用）

観測スクリプトとは別プロセスで動かす想定。実装は容易（既存の`jsonl`の
mtimeを使う）が、**§1で判明した通りjsonl自体は各行にタイムスタンプが
ないため、mtime監視だけでは「いつから」止まっているかしか分からない
点に注意**。行内容とOllama側ログの突き合わせは引き続き必要。

```ruby
#!/usr/bin/env ruby
# script/watchdog_observation.rb（設計案・未適用）
# 使い方: ruby script/watchdog_observation.rb log/observation_sono39_xxx.jsonl [stall_seconds=120]
path          = ARGV[0]
stall_seconds = (ARGV[1] || 120).to_i

last_mtime = File.mtime(path)
loop do
  sleep 10
  current_mtime = File.mtime(path)
  if current_mtime == last_mtime && (Time.now - current_mtime) > stall_seconds
    stamp = Time.now.strftime("%Y%m%d_%H%M%S")
    dump_path = "log/watchdog_dump_#{stamp}.txt"
    File.open(dump_path, "w") do |f|
      f.puts "=== stall detected at #{Time.now} (last write: #{current_mtime}) ==="
      f.puts "--- ps (rails/ruby) ---"
      f.puts `ps aux | grep -E "ruby|puma" | grep -v grep`
      f.puts "--- ps (ollama) ---"
      f.puts `ps aux | grep ollama | grep -v grep`
      f.puts "--- ollama ps (loaded models) ---"
      f.puts `ollama ps 2>&1`
      f.puts "--- tail ollama.log ---"
      f.puts `tail -n 50 /opt/homebrew/var/log/ollama.log`
      f.puts "--- tail development.log ---"
      f.puts `tail -n 50 log/development.log`
    end
    puts "stall dump written to #{dump_path}"
    # 誤検知の繰り返しダンプを避けるため、last_mtimeを更新して次回まで待つ
    last_mtime = current_mtime
  else
    last_mtime = current_mtime
  end
end
```

適用判断（人間承認）が必要な点：ダンプ間隔・stall_secondsの閾値
（180秒のgenerate timeoutより短いと誤検知しやすい）、常駐させる場所
（別tmuxペイン推奨）。

### 4-2. RSS / GC.stat計装（仮説B用）

`script/observe_production_hyakuin.rb`のverseループ内、DB保存直後に
1行追記する形を想定（既存の`log_line`と同じファイルに追加フィールドを
持たせるか、別ファイルに分離するかは要相談）。

```ruby
# 其の四十案：verse保存直後に追加する計装（未適用）
GC.start # 計測前に明示的にGCを走らせ「GC後もなお残っている」量を見る
gc_stat = GC.stat
rss_kb  = `ps -o rss= -p #{Process.pid}`.to_i
log_line(log_file, {
  verse_no: verse_no,
  instrumentation: {
    rss_kb: rss_kb,
    heap_live_slots: gc_stat[:heap_live_slots],
    total_allocated_objects: gc_stat[:total_allocated_objects],
    major_gc_count: gc_stat[:major_gc_count],
    minor_gc_count: gc_stat[:minor_gc_count]
  }
})
```

注意点：`GC.start`を毎verse挿入すると本来のタイミング（GCが起きない
状況の再現）を歪める。まず**GC.startなしでRSSの生の推移**を見て、
増加傾向が確認できた場合にのみ「GC.start後も残るか」の切り分けに
進むべき。人間承認前に、まずGC.startなし版から始めることを推奨。

## 5. 作業ログ

| 日時 | タスク | 結果 | メモ |
|---|---|---|---|
| 2026-07-17 | ゲートチェック | 88 pass / 0 fail、clean、コミット履歴一致 | 作業許可 |
| 2026-07-17 | jsonlタイムスタンプ不在の発見 | 依頼書前提の手順が実行不可と判明 | DB created_at・development.log・ollama.logで代替 |
| 2026-07-17 | DB created_atによるverse別時刻確定 | 72件、最終id=378 @11:53:42 UTC(20:53:42 JST) | delta分析で終盤の遅延化を確認 |
| 2026-07-17 | development.log突き合わせ | 最終行が`[RengaGenerator] attempt:`で終了、`total:`欠落 | verse73内部ループが未完走のまま停止と特定 |
| 2026-07-17 | ollama.log解析 | 20:53:46に/api/chatが500応答、以降47分間ログ完全途絶 | 仮説Aの直接的支持材料 |
| 2026-07-17 | macOS統一ログ確認 | ollamaサブプロセスPIDが91027→93793に変化、空白期間中は記録皆無 | ランナークラッシュ・再起動を示唆 |
| 2026-07-17 | tmuxセッション確認 | `sono39_observe_run5`残存も空プロンプト、rubyプロセスは消滅 | 自然終了か手動中断かは未確認 |
| 2026-07-17 | BuiDictionary/natto gemコード確認 | detect_allはnm使い回し、finalizerはnatto gem側に実在 | 仮説Bの前提を一部訂正（規模が想定より小） |
| 2026-07-16 | OllamaClient実装確認 | 全呼び出しstream:false、ステータスコード未検査、open_timeout未設定 | チャンクreset仮説を棄却 |
| 2026-07-17 | run5 jsonl定量分析 | 句数ng 19.8%、forced_zatsu発動3/72verse、うち1.5件がD-19-5起因 | run5停止点自体はD-19-5非経由と判明 |
