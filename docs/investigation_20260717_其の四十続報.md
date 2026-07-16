# waka-collector 其の四十・続報 調査報告（Rubyプロセスクラッシュ仮説の検証）

作業日: 2026-07-17
対象: run5（verse_no=72で沈黙停止、前回報告 `docs/investigation_20260717_其の四十冒頭.md`の続き）
性質: **調査のみ。実装・修正は一切行っていない。**
ゲートチェック: `verify_shikimoku.rb` 88 pass / 0 fail（作業前後とも確認、未変更）

## 0. 前回報告からの訂正の確認（調査F）

実機で確認した結果、人間のレビュー指摘（訂正1）は正しいことを確認した。

```
$ ruby -v
ruby 3.3.6 (2024-11-05 revision 75015d4c1f) [arm64-darwin25]
$ ruby -rnet/http -e "h = Net::HTTP.new('localhost'); puts h.open_timeout; puts h.read_timeout"
60
60
```

`OllamaClient`は`read_timeout`のみ明示設定し`open_timeout`には触れていないため、
デフォルトの60秒が適用される。1回の`chat()`呼び出しが理論上ブロックしうる
上限は「open_timeout(60秒、接続確立時のみ) + read_timeout(300秒)」で
最大約360秒（6分）。実際に観測された47分間の空白とは6〜7倍の開きがあり、
**「1回の呼び出しがread_timeoutの射程内で詰まっていた」という説明は
数値的に成立しない**という訂正1の指摘は妥当である。

## 1. 調査D：Rubyプロセスクラッシュの直接証拠【最優先】

### 1-1. クラッシュレポートの有無

`~/Library/Logs/DiagnosticReports/`・`/Library/Logs/DiagnosticReports/`の
いずれにも、2026-07-16の`ruby`または`puma`プロセスに関するクラッシュレポート
（`.crash`/`.ips`）は**存在しない**。同ディレクトリにある唯一の`ruby_*.diag`は
`ruby_2026-07-12-140408_...diag`であり、日付が3日前・無関係。同日の
`JetsamEvent`（OOM強制終了時に生成される記録）も存在しない
（直近のJetsamEventは`2026-07-13-192404`で、これも無関係）。

**「クラッシュレポートが存在しない」こと自体を、依頼書の指示通り明記する。**
macOSは通常、シグナルベースのクラッシュ（SIGSEGV/SIGBUS/SIGILL/SIGABRT等）
があれば`ReportCrash`が確実にレポートを生成する。レポートが存在しないという
事実は、「MeCabネイティブ拡張が生のセグメンテーションフォルトを起こした」
という最も直接的な意味でのクラッシュ仮説には**反する**。

### 1-2. プロセス終了時刻の直接証拠（新発見・最重要）

macOS統一ログを`eventMessage CONTAINS "91002"`（run5を実行していたrubyの
実際のPID）で検索した結果、以下が見つかった：

```
2026-07-16 20:53:46.489 GSSCred[905]     : invalidated because the client process (pid 91002) either cancelled the connection or exited
2026-07-16 20:53:46.489 cfprefsd[924]    : invalidated because the client process (pid 91002) either cancelled the connection or exited
2026-07-16 20:53:46.489 cfprefsd[619]    : invalidated because the client process (pid 91002) either cancelled the connection or exited
2026-07-16 20:53:46.493 mDNSResponder[632]: DNSServiceCreateConnection STOP PID[91002](ruby)
```

これらは複数の独立したOSデーモン（GSSCred・cfprefsd×2・mDNSResponder）が
**同一の4ミリ秒以内**にPID 91002とのXPC接続の消失を検知したことを示す。
これはプロセスが実際に終了（正常終了・異常終了を問わず）した際にOSが
一斉に検知する典型的なシグナルであり、**PID 91002は2026-07-16 20:53:46.489
（±数ms）に終了した**と確定できる。

この時刻は、前回報告で特定したOllamaの`/api/chat`への500応答
（`20:53:46 | 500 | 967.011834ms`、応答完了は20:53:46.4秒台と推定）と
**ほぼ完全に同時**である。

**これは前回報告の枠組みに対する重要な訂正である。** 前回報告は「500応答の
後、次に発行されたはずのchat呼び出しが47分間ハングした」という構成で
整理したが、今回の直接証拠は「500応答を受け取った直後（同一秒内）に
**プロセス自体が終了した**」ことを示している。つまり47分間の空白は
「次の呼び出しがハングし続けた結果」ではなく、**プロセスが即座に消滅した
ことの結果**であり、Ollama側の47分間の沈黙（前回報告§1）は、waka-collector
側のプロセス終了とは別に、Ollama自身（モデルランナー）も同時期に不調に
陥っていたことを示す**独立した並行事象**として整理し直す必要がある。

### 1-3. mDNSクエリの副次的発見（前回報告の誤帰属の訂正）

今回の調査で、PID 91002が2026-07-16 20:50頃から20:53:46まで、約2〜3秒
間隔で継続的に`mDNSResponder`へDNSクエリ（`localhost`宛と推定）を
発行し続けていたことが分かった。この間隔は前回報告で「waka-collector以外の
並行トラフィックと見られる」と記述した、ollama.log上の2秒間隔の
`/api/chat`呼び出し群と一致する。

**前回報告の誤り：** この継続的な`/api/chat`トラフィックを「他アプリ
（kasen-za等）由来の可能性」として記述したが、実際には**waka-collector
自身（PID 91002）が発生源だった**と考えられる。`Net::HTTP.new`は
呼び出しごとに新規インスタンスを生成しており（`OllamaClient`は接続を
使い回さない設計）、`generate_tsugeku`内部の5×5ループでSocratic対話
分岐（モーラng streak・repeat streak）に入ると、外側の観測スクリプトの
attemptとしては1回にしか見えない区間の中で、実際には数十回規模の
`chat()`呼び出しが短時間に連続発行されうる。20:50〜20:53の高頻度
`/api/chat`トラフィックは、verse71→72間（前回報告のid=372→373、
delta 285.3秒）で内部ループが長時間空転していたことの直接証拠であり、
他アプリとの混同ではなかった。

### 1-4. なぜ例外がobserve_production_hyakuin.rb側で捕捉されなかったか

`script/observe_production_hyakuin.rb`の該当箇所（124-127行目、220-239行目）
を確認したところ、`RengaGenerator#generate_tsugeku`の呼び出しは

```ruby
begin
  tsugeku = RengaGenerator.new(...).generate_tsugeku
rescue RuntimeError, Net::ReadTimeout => conn_err
  ...
end
```

という形で、**`RuntimeError`と`Net::ReadTimeout`のみ**を対象にrescueして
いる（`rescue => e`＝`StandardError`全体ではない）。`OllamaClient`の各
メソッドは内部で`rescue => e`（`StandardError`全体）を捕捉して
`raise "文字列"`（＝`RuntimeError`）に正規化しているため、Ollama通信に
起因する典型的なエラー（タイムアウト・接続エラー・JSON解析失敗等）は
すべてこの狭いrescueで捕捉できる設計にはなっている。

**しかし、以下のいずれかに該当する例外はこのrescue網をすり抜け、
かつ外側の`rescue RetryExhausted`（301行目）でも捕捉されず、
スクリプト全体を無言で終了させる：**

- `NoMemoryError`・`SystemStackError`等、`StandardError`の**祖先が異なる**
  例外（`OllamaClient`内の`rescue => e`にも、observe script側の
  `rescue RuntimeError`にも掛からない）
- `RengaGenerator`内部（Ollama通信を経由しない箇所、例：`morphemes_of`・
  `history_repeat?`・その他のRuby処理）で発生した`NoMethodError`・
  `TypeError`・`ArgumentError`等の非`RuntimeError`系`StandardError`
  （`OllamaClient`の`rescue`は通らないため正規化されず、observe script側の
  `rescue RuntimeError`にも掛からない）

いずれの場合も、Rubyの例外機構としては正常に「捕捉されない例外による
プロセス終了」であり、シグナルクラッシュではないため**macOSのクラッシュ
レポートは生成されない**（§1-1の「レポートなし」という事実と矛盾しない）。
またこの種の終了はRubyインタプリタがSTDERRにバックトレースを出力してから
`exit`するのが通常の挙動だが、**tmuxペインのスクロールバックは今回
空であり（前回報告で確認済み）、標準エラー出力を別途ファイルへ
リダイレクトする設定もrun5の起動コマンドには含まれていなかったため、
このバックトレース自体は失われており復元不可能**。どの例外クラスが
実際に投げられたかは、今回のログ資産からはこれ以上特定できない
（未確認事項として明記する）。

## 2. 仮説整理表

| 仮説 | 支持する事実 | 反する事実 | 未確認事項 |
|---|---|---|---|
| **Rubyプロセスクラッシュ（新・本命）** | ①統一ログでPID 91002が2026-07-16 20:53:46.489（±4ms）に終了したことを複数の独立デーモン（GSSCred・cfprefsd×2・mDNSResponder）が同時検知＝直接証拠。②終了タイミングがOllamaの500エラー応答とほぼ完全に一致。③`observe_production_hyakuin.rb`のrescue網は`RuntimeError, Net::ReadTimeout`のみを対象とし、`NoMemoryError`や`RengaGenerator`内部のRuby例外（`NoMethodError`等）はこの網をすり抜けてプロセス全体を無言で終了させうる構造上の欠陥が現物確認できた | クラッシュレポート（.crash/.ips）・JetsamEvent（OOM）がいずれも2026-07-16に存在しない＝「シグナルによる生のセグメンテーションフォルト」または「OSによるOOM強制終了」という狭い意味でのクラッシュは支持されない | プロセスを終了させた具体的な例外クラス・メッセージ・バックトレースは、tmuxスクロールバックが空でstderrの別ログもないため復元不可能。「Ruby VMレベルの未捕捉例外による正常終了」なのか、「人間による手動終了」なのか、その他の要因かは断定できない |
| **Ollamaハング（read_timeout不発火、訂正後）** | 47分間、Ollama自身のリクエストログ・macOS統一ログとも当該プロセスに関する記録が完全に途絶しており、Ollama側（モデルランナー、サブプロセスPIDが91027→93793に変化）も同時期に何らかの不調に陥っていたことは別途支持される | open_timeout(60s)+read_timeout(300s)の理論上限（約6分）と実際の47分間の空白には6〜7倍の開きがあり、「1回の呼び出しが単純にread_timeoutの射程内で詰まっていた」という説明は数値的に成立しない。§1-2の新証拠により、waka-collector側のRubyプロセス自体は500応答直後に終了しており、そもそも「次のchat呼び出しが47分间ブロックされ続けた」という前回報告の前提そのものが再検証を要する | Ollama側の47分間の沈黙が、waka-collectorプロセスの終了と**独立した事象**なのか、それとも同じ根本原因（例：ホスト全体のリソース枯渇）に由来する**相関事象**なのかは未確認 |

## 3. 参考情報（優先順位づけには直接使わないが記録）

### 3-1. 調査E：`chat_with_tools`の使用状況

`app/services/renga_generator.rb`の`generate_tsugeku`は`OllamaClient.chat`
と`OllamaClient.generate`のみを使用しており、`chat_with_tools`は**現在の
生成パスでは一切呼ばれていない**（`grep`で確認：呼び出し箇所は
`script/verify_chat_with_tools.rb`という検証専用スクリプトのみ）。
したがって`chat_with_tools`の構造上のリスク（後述）は**run5のインシデントには
無関係**である。

参考として構造のみ記録する：`chat_with_tools`はループ外で`http`
（`Net::HTTP`インスタンス）を1回だけ生成し、`MAX_TOOL_LOOPS`（5回）まで
同じ`http`オブジェクトで`http.request(req)`を繰り返す。`read_timeout`は
ループ開始前に1回設定されるのみで、各ループの`http.request`呼び出しは
「まだ有効な既存コネクション」を再利用する形になる。理論上、5回のツール
呼び出しがそれぞれタイムアウト直前まで詰まった場合、累積の実効待ち時間は
単純な`read_timeout`の値（デフォルト300秒）よりも大きくなりうる構造で
ある。将来的にこのメソッドを生成パスで使う設計に変更する際は、
ループ全体としてのタイムアウト設計を別途検討する必要がある。

### 3-2. temperatureパラメータの握りつぶし（依頼書§1で既出）

`OllamaClient.generate`内で`body`変数に`temperature`をセットしているが、
実際に送信される`req.body`は別のハッシュリテラルであり、`temperature`は
反映されない。今回の調査対象（run5沈黙停止）とは無関係と確認した
（`RengaGenerator`側の`temperature`引数自体は正しく`generate`に渡されて
いるが、`OllamaClient.generate`内部の未使用変数`body`に格納されるだけで
実際のリクエストに載らない、という`OllamaClient`側のみのバグ）。
**今回は修正しない。**

## 4. 考察：次に何を調べるべきか

### クラッシュ仮説が正しかった場合

最大の障害は「どの例外が投げられたか分からない」ことである。次回観測実行
では、最低限以下を人間の承認を得た上で追加することを提案する（コードは
今回書かない）：

- tmux起動コマンド自体に`2>&1 | tee log/observation_stderr_<tag>.log`相当の
  リダイレクトを追加し、Rubyの未捕捉例外バックトレースを確実に保存する
- `script/observe_production_hyakuin.rb`の`rescue RuntimeError, Net::ReadTimeout`
  を`rescue StandardError`相当に広げるべきかどうかは、
  「本来Rubyバグとして気づくべき例外まで握りつぶしてしまう」トレードオフが
  あるため、安易に広げず、まず「広い`rescue`で一旦ログに落としてから
  `raise`し直す」（ログだけ残して握りつぶさない）形を検討する

### Ollamaハング仮説（の残滓）が正しかった場合

waka-collector側のプロセス終了とは別に、Ollama自身が同時期に47分間
不調だった事実は今回も動かない。次回はOllama側のモデルランナー再起動の
トリガー条件（何が21:41:02の復帰を引き起こしたか）を、Ollamaのソース
または挙動観察で確認する必要がある。ただし、これはwaka-collector本体の
問題ではなくOllama運用の問題である可能性が高く、優先度は
クラッシュ仮説の追跡より低いと考える。

## 5. 調査G：OllamaClientの変更履歴確認

### 5-0. 前提の訂正（重要）

依頼書は「初期導入時（`waka_ollama_handover.md`時点）は`generate(prompt)`メソッドのみの
ごく単純な構成だった（timeout未設定・エラー処理なし）」と前提していたが、以下2点で
リポジトリの実態と食い違うことが確認された。

- `waka_ollama_handover.md`という名前のファイルはリポジトリ内に**存在しない**
  （`docs/`配下の`handover_*`・`waka-collector-handover-v2.md`いずれにも
  `ollama`への言及なし。該当ファイルはこのリポジトリ外の初期プロトタイプ・
  設計メモである可能性があるが今回は確認できず、未確認事項として扱う）
- `app/services/ollama_client.rb`の`git log --follow`による全履歴は**3コミットのみ**
  （下記5-1参照）。最初のコミット（`6c2bbda`, 2026-06-07）の時点で、既に
  `timeout: 300`のキーワード引数と`rescue Net::ReadTimeout` / `rescue => e`
  によるエラー処理が実装済みであり、「timeout未設定・エラー処理なし」という
  単純な状態はgit履歴上**一度も存在しない**

### 5-1. 時系列変更履歴表

| コミット | 日時 | 追加・変更内容 | その時点での考慮漏れ |
|---|---|---|---|
| `6c2bbda` feat: Ollamaサービスクラスを追加 | 2026-06-07 | `generate`メソッドを新規作成。`timeout: 300`キーワード引数・`rescue Net::ReadTimeout`/`rescue => e`によるエラー正規化は**この最初のコミットの時点で既に実装済み**。`think:`はraw text prepend方式（`think ? prompt : "/no_think\n#{prompt}"`）。`open_timeout`には一切触れず（Rubyデフォルト60秒のまま）。HTTPステータスコード検査なし | `open_timeout`未設定・ステータスコード未検査は**設計当初（最初の1行目）から存在**。「機能追加の過程で生じた」のではなく、最初から見落とされていた |
| `866b63c` feat: add dynamic blacklist and seed swap to verify_seed_completion | 2026-06-16 | コミットメッセージは`verify_seed_completion.rb`向けの機能追加のみを謳っているが、**実際には`ollama_client.rb`に3つの変更が同時に紛れ込んでいる**：①`chat_with_tools`メソッド新規追加、②`generate`の`think:`実装をraw text prepend→JSON APIパラメータ（bodyに`think: think`を含める）へ修正、③`generate`に`temperature:`引数を追加（ただしローカル変数`body`にセットするのみで、実際に送信する`req.body`は別のハッシュリテラルとして直書きされており未反映＝temperatureバグの導入コミット） | ③のtemperatureバグは②のthink修正と**同一diffハンク内**で発生。think修正時に`req.body`のハッシュリテラルを書き直す際、既存の`body`変数を使わず新規ハッシュリテラルを直書きしたため`body[:temperature]`の代入が宙に浮いた。コミットメッセージに`ollama_client.rb`への言及が一切なく、意識的なレビューを経ずに紛れ込んだ可能性が高い |
| `6cf1c8c` 其の三十一 Step C-3 bui修正 | 2026-07-04 | `chat`メソッドを新規追加。実装は`generate`・`chat_with_tools`と同一の`rescue Net::ReadTimeout`/`rescue => e`パターンをそのまま複製。ステータスコード未検査・`open_timeout`未設定もそのまま踏襲 | コミットのタイトル・メッセージは「bui:[]リテラル除去」というプロンプト内容の修正であり、`chat`メソッド自体の追加はここでも言及されていない。既存2メソッドのrescue粒度・タイムアウト設計をレビューせずコピーしたことで、最初のコミットの見落とし（open_timeout・ステータスコード未検査）が3メソッド目にも複製された |

該当付近のhandover文書（`docs/handover_20260704_其の三十一.md`）・`docs/architecture_decisions.md`・
`docs/architecture_decisions_追記_其の十九.md`を確認したが、`think`/`chat_with_tools`/
`temperature`/`open_timeout`に関する設計意図の記述は見当たらなかった。これらの実装判断は
D-XX形式の意思決定として文書化されておらず、コードの現物のみが実質的な設計記録になっている。

### 5-2. 判定：「単発の見落とし」か「継ぎ足し型の歪み」か

両方が異なる箇所で併存している、というのが結論である。

- **open_timeout未設定／ステータスコード未検査**：設計当初（最初のコミット）から
  一貫して存在する**単発の見落とし**。以降2回の機能拡張でも見直されず、
  そのまま持ち越された
- **temperatureバグ**：明確に**機能拡張の過程で生じた**もの。しかもその機能拡張は
  コミットメッセージ上は完全に無関係な作業（`verify_seed_completion.rb`の
  動的ブラックリスト機能）として記録されており、`ollama_client.rb`側の変更は
  レビューの目が向きにくい「ついで」の変更だった可能性が高い。依頼書が懸念する
  「継ぎ足し型の機能拡張が構造的に見落としを誘発しやすい」は、**temperatureバグに
  関して明確に支持される**
- **chatメソッドのrescue粒度・タイムアウト設計の複製**：`chat`追加時、
  既存2メソッドの実装をレビュー・見直しせずそのまま複製しており、
  「既存の見落としが機能拡張のたびに複製される」パターンの一例といえる

## 6. 作業ログ

| 日時 | タスク | 結果 | メモ |
|---|---|---|---|
| 2026-07-17 | ゲートチェック | 88 pass / 0 fail、作業前後とも維持 | 作業許可、コード無変更 |
| 2026-07-17 | 調査F: open_timeoutデフォルト値実機確認 | 60秒と確認、訂正1が妥当と確認 | ruby 3.3.6 |
| 2026-07-17 | 調査D: クラッシュレポート確認 | `.crash`/`.ips`/JetsamEventとも2026-07-16分は存在せず | シグナルクラッシュ・OOM Killは支持されない |
| 2026-07-17 | 調査D: 統一ログでPID 91002を追跡 | 20:53:46.489にXPC接続が一斉invalidate＝プロセス終了時刻を確定 | Ollamaの500応答とほぼ同時。前回報告の「47分ハング」前提を訂正 |
| 2026-07-17 | mDNSクエリパターンの再検証 | 20:50〜20:53の高頻度/api/chatはPID 91002自身（内部ループ空転）と判明 | 前回報告の「他アプリ由来」という誤帰属を訂正 |
| 2026-07-17 | observe_production_hyakuin.rbのrescue範囲確認 | `RuntimeError, Net::ReadTimeout`のみ捕捉、非RuntimeError系StandardErrorはすり抜ける構造を確認 | クラッシュ仮説を支持する構造的欠陥 |
| 2026-07-17 | 調査E: chat_with_toolsの使用箇所確認 | generate_tsugekuでは未使用、verify_chat_with_tools.rbのみで使用 | run5とは無関係、参考情報として記録 |
| 2026-07-17 | 調査G: `git log --follow -p`でollama_client.rb全履歴取得 | 全履歴は3コミットのみ（6c2bbda/866b63c/6cf1c8c） | 依頼書前提の`waka_ollama_handover.md`はリポジトリ内に存在せず |
| 2026-07-17 | 調査G: 最初のコミット(6c2bbda)の内容確認 | timeout:300・rescue処理は最初から実装済みと判明 | 「timeout未設定・エラー処理なし」という依頼書前提を訂正 |
| 2026-07-17 | 調査G: 866b63cのdiff確認 | chat_with_tools追加・think修正・temperatureバグ導入が同一コミットに混在、コミットメッセージは無関係な機能を謳う | 継ぎ足し型機能拡張が見落としを誘発した実例として確認 |
| 2026-07-17 | 調査G: 6cf1c8cのdiff確認 | chatメソッド追加、既存rescue/タイムアウト設計をそのまま複製 | 既存の見落としが機能拡張のたびに複製されるパターンを確認 |
| 2026-07-17 | 調査G: handover文書・architecture_decisions突き合わせ | think/chat_with_tools/temperature/open_timeoutに関するD-XX記述なし | 設計意図の文書化なし、コード現物のみが実質的な設計記録 |
