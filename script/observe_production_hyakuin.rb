# frozen_string_literal: true

# observe_production_hyakuin.rb — 其の三十九：本番コードパスによる百韻観測
#
# 使用法:
#   bundle exec rails runner script/observe_production_hyakuin.rb              # 100句
#   bundle exec rails runner script/observe_production_hyakuin.rb 5            # スモークテスト（5句）
#   bundle exec rails runner script/observe_production_hyakuin.rb 100 run2     # ログ/observation_batchにrun2タグを付与
#
# RengasController#createが呼んでいるのと同じ順序でRengaGenerator→KuValidator→
# ShikimokuCheckerを直接呼び出す薄いラッパー。コントローラ自体は経由しないが、
# 履歴構築ロジック（fetch_verse_history/build_verse_history/build_mecab/
# season_from_text）はコントローラの private メソッドをそのまま再利用し、
# 本番と全く同じ計算になるようにする（ロジックの二重実装によるズレを避けるため）。
#
# 其の三十九・追記（forced_zatsu）:
# ShikimokuCheckerは前句・付句の隣接ペアしか見ず連鎖全体の履歴を見ないため
# （D-19-5の既知の設計限界）、同じ前句に対する試行がMAX_RETRY回とも失敗する
# （原因は生成失敗・モーラng・shikimoku ngのいずれでもよい）と通常の再試行では
# 解消しないケースが実害として観測された。この場合はRengaGenerator（本体・
# 無改修）への再試行を諦め、観測スクリプト側から直接OllamaClient.chatを呼んで
# 雑（無季）句を強制生成するレスキュー経路に切り替え、スクリプト自体は停止せず
# 次句へ進む（verse_no単位の試行ループ全体をrescue RetryExhaustedで包む方式。
# 追記2：当初はshikimoku ng連続回数のみをトリガーにしていたが、原因が
# 試行ごとに変わる（例：4回shikimoku ng→5回目だけ生成失敗）とstreakが
# 途切れて発火しないケースが判明したため、原因を問わない方式に修正した）。
# 追記3：OllamaClient経由の接続タイムアウト（RuntimeError／Net::ReadTimeout）
# もRetryExhaustedと同様にrescue対象へ追加し、forced_zatsu側の再試行でも
# 同じ例外を捕捉する（単発の一時的タイムアウトで全体がクラッシュしないように
# するため。Ollama自体が本当に落ちている場合はforced_zatsu側も全滅するので、
# その時は無理に空句を保存せず人間に報告する）。
#
# 出力: log/observation_sono39_<タグ_><実行日>.jsonl（試行ごとのJSON Lines）＋標準出力サマリー

require "json"

TOTAL_VERSES = (ARGV[0].presence || 100).to_i
RUN_TAG      = ARGV[1].presence
TAG_SUFFIX   = RUN_TAG ? "#{RUN_TAG}_" : ""

MAX_RETRY                  = 5   # script/dryrun_hyakuin.rbのMAX_RETRYと同じ閾値。この回数だけ試行してすべて失敗したらforced_zatsuへ切り替える
FORCED_ZATSU_MORA_RETRY    = 3   # forced_zatsu候補のモーラ再試行上限（無限ループ防止の安全弁）
TOTAL_ATTEMPT_CAP          = 500 # 総試行回数の安全弁（100句×平均5試行想定の余裕値、無限ループ防止）

RUN_DATE   = Time.zone.now.strftime("%Y%m%d")
BATCH_NAME = "sono39_#{TAG_SUFFIX}#{RUN_DATE}"
LOG_PATH   = Rails.root.join("log", "observation_sono39_#{TAG_SUFFIX}#{RUN_DATE}.jsonl")

# controllerの本体ロジックは変更禁止だが、履歴構築の private メソッドは
# 観測の忠実性のためそのまま呼び出す（新しいインスタンスを作るだけで
# リクエスト/レスポンスには依存しない）。
controller = RengasController.new

log_file = File.open(LOG_PATH, "a")

def log_line(file, hash)
  file.puts(hash.to_json)
  file.flush
end

def violation_category(v)
  case v[:type]
  when :ichiza_duplicate            then "一座一句物"
  when :chotan_chigai               then "長短交互"
  when :kukazo_over, :kukazo_under  then "句数"
  when :teiza_tsuki, :teiza_hana    then "定座"
  else "句去" # :type キーなし＝句去（ShikimokuChecker.describeの後方互換分岐と同じ判定）
  end
end

def violation_detail(v)
  case v[:type]
  when :ichiza_duplicate then v[:word]
  when :chotan_chigai    then "#{v[:verse_type]}→#{v[:expected]}"
  when :kukazo_over      then (v[:season] || v[:bui]).to_s
  when :kukazo_under     then v[:season].to_s
  when :teiza_tsuki, :teiza_hana then v[:fold].to_s
  else v[:bui].to_s
  end
end

def violation_label(v)
  "#{violation_category(v)}:#{violation_detail(v)}"
end

# 其の三十九・追記: forced_zatsuレスキュー用のSocratic対話メッセージ。
# RengaGenerator#socratic_mora_messagesの雑分岐・script/dryrun_hyakuin.rbの
# 其の二十七救済文言と同じ構成（自己認識→概念確認→詠み直し）を、観測スクリプト
# 側で独立に組み立てる（RengaGenerator本体は一切呼ばない＝無改修を維持するため）。
def forced_zatsu_messages(maeku, target_mora, trigger_labels, threshold)
  reasons = trigger_labels.any? ? trigger_labels.uniq.join("、") : "同じ問題の繰り返し"
  [
    { role: "user", content: "あなたはいま、同じ前句に対して#{threshold}回試みても句が定まりません" \
                              "（原因：#{reasons}）。行き詰まっていることを認識してください。" },
    { role: "assistant", content: "はい、行き詰まっています。同じ前句に対して同じような問題を繰り返しており、" \
                                   "局面を打開する必要があります。" },
    { role: "user", content: "連歌では、季語（春・夏・秋・冬の語）を使う句と、季語を使わない" \
                              "「雑（ぞう）」の句があります。雑の句は季節に縛られず自由に詠めます。" \
                              "局面打開には雑の句が有効なことがあります。理解できましたか？" },
    { role: "assistant", content: "はい、理解しました。雑の句とは季語を含まない句で、季節に縛られず" \
                                   "詠むことができます。" },
    { role: "user", content: "では局面打開のため、雑の句として全く新しい言葉で#{target_mora}音の" \
                              "付け句を詠んでください。\n前句：#{maeku}\n" \
                              "#{target_mora}音を一行だけ出力してください。説明不要。" }
  ]
end

# forced_zatsu候補をFORCED_ZATSU_MORA_RETRY回まで生成し、モーラngが解消した
# 時点（または上限到達時）の結果までを配列で返す（ログ出力・保存は呼び出し側）。
# OllamaClient由来の接続エラー（RuntimeError／Net::ReadTimeout）もここで
# 捕捉し、テキスト空・result:ngの候補として扱う（次のsub_retryへ進むだけで
# 例外を外へ漏らさない）。全sub_retryが接続エラーで尽きた場合は呼び出し側で
# text.blank?を見て「forced_zatsuも含めて全滅」と判断する。
def forced_zatsu_candidates(maeku, target_vt, trigger_labels, threshold, max_sub_retry)
  target_mora = (target_vt == :chouku) ? 17 : 14
  results = []
  max_sub_retry.times do
    begin
      raw  = OllamaClient.chat(forced_zatsu_messages(maeku, target_mora, trigger_labels, threshold),
                                think: false, timeout: 300)
    rescue RuntimeError, Net::ReadTimeout => conn_err
      results << { text: "", mora_check: { result: "ng", mora: 0, message: "接続エラー: #{conn_err.message}" },
                    connection_error: true }
      next
    end
    text = raw.to_s.strip.lines.map(&:strip).reject(&:empty?).first.to_s
    mora_check = text.blank? ? { result: "ng", mora: 0, message: "句が生成されませんでした" } :
                                 KuValidator.new(text, type: target_vt).validate
    results << { text: text, mora_check: mora_check }
    break if mora_check[:result] != "ng"
  end
  results
end

class RetryExhausted < StandardError; end

nm       = controller.send(:build_mecab)
bui_dict = BuiDictionary.new

# 発句選定：dryrun_hyakuin.rbは既知の古典句（東風ふかば…）を固定HAKKUとして
# 使うが、こちらは本番DB（Waka）からランダムに選ぶ。KuValidatorでngな
# （形態素2未満・音数が17/14から2音以上ずれる）候補は発句として不適切なので
# 引き直す。
hakku_waka = nil
hakku_text = nil
20.times do
  candidate_waka  = Waka.where.not(upper_phrase_text: [nil, ""]).order(Arel.sql("RANDOM()")).first
  candidate_text  = candidate_waka.upper_phrase_text.strip
  candidate_mora  = KuValidator.new(candidate_text).count_mora
  candidate_type  = KuValidator.nearest_verse_type(candidate_mora)
  check           = KuValidator.new(candidate_text, type: candidate_type).validate
  next if check[:result] == "ng"

  hakku_waka = candidate_waka
  hakku_text = candidate_text
  break
end
raise "発句として使えるWakaが見つかりませんでした（20回試行）" unless hakku_text

log_line(log_file, {
  verse_no: 0, attempt: 0, text: hakku_text, waka_id: hakku_waka.id,
  mora_result: "ok", shikimoku_result: nil, violations: [], action: "seed"
})

puts "=" * 60
puts "其の三十九 本番コードパス観測開始（目標#{TOTAL_VERSES}句#{RUN_TAG ? "、タグ=#{RUN_TAG}" : ""}）"
puts "発句: #{hakku_text}（Waka##{hakku_waka.id}）"
puts "ログ: #{LOG_PATH}"
puts "=" * 60

maeku                  = hakku_text
previous_renga_id      = nil
total_attempts         = 0
total_ng                = 0
violation_counts        = Hash.new(0)
forced_zatsu_creates    = 0
forced_zatsu_mora_ng_ct = 0

catch(:attempt_cap_reached) do
  (1..TOTAL_VERSES).each do |verse_no|
    maeku_mora      = KuValidator.new(maeku).count_mora
    maeku_type      = KuValidator.nearest_verse_type(maeku_mora)
    next_verse_type = (maeku_type == :chouku) ? :tanku : :chouku

    # 本番同様、前句（maeku）自体のモーラチェック。生成した付句は
    # RengaGenerator内部でmora差<=1のみ許容するため通常はok/warningになるが、
    # 万一（全attempt失敗などで）ngな文字列が混入した場合は連鎖破綻として
    # 即座に人間へ報告する。
    maeku_check = KuValidator.new(maeku, type: maeku_type).validate
    if maeku_check[:result] == "ng"
      log_line(log_file, {
        verse_no: verse_no, attempt: 0, text: maeku, mora_result: "ng",
        shikimoku_result: nil, violations: [], action: "abort_maeku_ng"
      })
      raise "verse_no=#{verse_no}: 前句「#{maeku}」がKuValidatorでngのため中断（連鎖破綻の可能性）"
    end

    trigger_labels = []
    attempt_no      = 0
    final_text       = nil
    final_action      = nil

    begin
      MAX_RETRY.times do |i|
        attempt_no = i + 1
        total_attempts += 1
        throw :attempt_cap_reached if total_attempts > TOTAL_ATTEMPT_CAP

        verse_history = controller.send(:fetch_verse_history, previous_renga_id)
        begin
          tsugeku = RengaGenerator.new(
            maeku, [], next_verse_type,
            constraints: { verse_history: verse_history }
          ).generate_tsugeku
        rescue RuntimeError, Net::ReadTimeout => conn_err
          # RengasController#createと同じ例外クラス（OllamaClient側はNet::ReadTimeout
          # を含め全てRuntimeErrorに正規化して再raiseする）。単発の一時的タイムアウト
          # の可能性があるため、他の失敗種別と同様にMAX_RETRY内では単に再試行する。
          total_ng += 1
          label = "接続タイムアウト:#{conn_err.message}"
          trigger_labels << label
          action = (attempt_no == MAX_RETRY) ? "exhausted" : "retry"
          log_line(log_file, {
            verse_no: verse_no, attempt: attempt_no, text: "", mora_result: nil,
            shikimoku_result: nil, violations: [label], action: action
          })
          raise RetryExhausted, "Ollama接続エラーが解消しませんでした（#{conn_err.message}）" if attempt_no == MAX_RETRY
          next
        end

        if tsugeku.blank?
          total_ng += 1
          trigger_labels << "生成失敗"
          action = (attempt_no == MAX_RETRY) ? "exhausted" : "retry"
          log_line(log_file, {
            verse_no: verse_no, attempt: attempt_no, text: tsugeku.to_s, mora_result: "ng",
            shikimoku_result: nil, violations: ["生成失敗"], action: action
          })
          raise RetryExhausted, "句が生成できませんでした" if attempt_no == MAX_RETRY
          next
        end

        mora_check = KuValidator.new(tsugeku, type: next_verse_type).validate
        if mora_check[:result] == "ng"
          total_ng += 1
          label = "モーラng(#{mora_check[:mora]}音)"
          trigger_labels << label
          action = (attempt_no == MAX_RETRY) ? "exhausted" : "retry"
          log_line(log_file, {
            verse_no: verse_no, attempt: attempt_no, text: tsugeku, mora_result: "ng",
            shikimoku_result: nil, violations: [label], action: action
          })
          raise RetryExhausted, "モーラ判定ngが解消しませんでした" if attempt_no == MAX_RETRY
          next
        end

        candidate = {
          bui:        bui_dict.detect_all(tsugeku, nm),
          season:     controller.send(:season_from_text, tsugeku),
          verse_type: next_verse_type
        }
        history = controller.send(:build_verse_history, previous_renga_id, maeku, maeku_type, nm: nm, bui_dict: bui_dict)

        checker    = ShikimokuChecker.new
        violations = checker.all_violations(history, candidate)
        violations += checker.ichiza_violations(history, candidate)
        violations += checker.chotan_violations(history, candidate)

        if violations.any?
          total_ng += 1
          labels = violations.map { |v| violation_label(v) }
          violations.each { |v| violation_counts[violation_category(v)] += 1 }
          trigger_labels.concat(labels)
          action = (attempt_no == MAX_RETRY) ? "exhausted" : "retry"
          log_line(log_file, {
            verse_no: verse_no, attempt: attempt_no, text: tsugeku, mora_result: mora_check[:result],
            shikimoku_result: "ng", violations: labels, action: action
          })
          raise RetryExhausted, "式目ngが解消しませんでした" if attempt_no == MAX_RETRY
          next
        end

        final_text  = tsugeku
        final_action = "create"
        log_line(log_file, {
          verse_no: verse_no, attempt: attempt_no, text: tsugeku, mora_result: mora_check[:result],
          shikimoku_result: "ok", violations: [], action: "create"
        })
        break
      end
    rescue RetryExhausted => e
      # 其の三十九・追記2: MAX_RETRY回の試行がすべて失敗した場合、原因（生成失敗・
      # モーラng・shikimoku ngのいずれか、または混在）を問わずforced_zatsuへ
      # 切り替える。verse_no単位の試行ループ全体をrescueすることで、例えば
      # 「4回shikimoku ng→5回目だけ生成失敗」のように原因が試行ごとに変わって
      # 特定の失敗種別のstreakが閾値に届かないケースでも確実に発火する。
      puts "  #{verse_no}句目: #{e.message}（#{MAX_RETRY}回試行）→ forced_zatsuへエスカレーション"
      fz_results = forced_zatsu_candidates(
        maeku, next_verse_type, trigger_labels, MAX_RETRY, FORCED_ZATSU_MORA_RETRY
      )
      fz_results.each_with_index do |r, idx|
        total_attempts += 1
        attempt_no      += 1
        throw :attempt_cap_reached if total_attempts > TOTAL_ATTEMPT_CAP

        is_last = (idx == fz_results.size - 1)
        total_ng += 1 if r[:mora_check][:result] == "ng"

        fz_action =
          if !is_last
            "forced_zatsu"
          elsif r[:mora_check][:result] == "ng"
            "forced_zatsu_mora_ng"
          else
            "forced_zatsu_create"
          end

        log_violations = trigger_labels.uniq
        log_violations += [r[:mora_check][:message]] if r[:connection_error]

        log_line(log_file, {
          verse_no: verse_no, attempt: attempt_no, text: r[:text],
          mora_result: r[:mora_check][:result], shikimoku_result: "skipped",
          violations: log_violations, action: fz_action
        })

        next unless is_last

        final_text  = r[:text]
        final_action = fz_action
        forced_zatsu_creates    += 1 if fz_action == "forced_zatsu_create"
        forced_zatsu_mora_ng_ct += 1 if fz_action == "forced_zatsu_mora_ng"
      end
    end

    if final_text.blank?
      # forced_zatsu側もOllama接続エラー等で全滅し、有効な句が一つも得られな
      # かったケース。空句をRenga.create!するのは観測データを汚すだけなので、
      # 無理に保存せずここで人間に報告する（Ollamaの実際の稼働状況を確認する
      # 必要がある、真の障害の可能性）。
      raise "verse_no=#{verse_no}: forced_zatsuを含め#{MAX_RETRY + FORCED_ZATSU_MORA_RETRY}回の試行すべてで" \
            "有効な句を得られませんでした（直前の原因: #{trigger_labels.last}）"
    end

    style_result =
      if final_action == "create"
        { "result" => "ok", "issues" => [], "breakdown" => [] }
      else
        { "result" => final_action, "issues" => trigger_labels.uniq, "breakdown" => [] }
      end

    renga = Renga.create!(
      maeku:              maeku,
      tsugeku:            final_text,
      maeku_author:       "観測スクリプト",
      tsugeku_author:     "メンタムさん",
      generated_by_model: OllamaClient::MODEL,
      style_check_result: style_result,
      honka_reference:    [],
      previous_renga_id:  previous_renga_id,
      observation_batch:  BATCH_NAME
    )

    puts "  #{verse_no}/#{TOTAL_VERSES}句目 #{final_action}（attempt#{attempt_no}）: #{final_text}"

    previous_renga_id = renga.id
    maeku              = final_text
  end
end

log_file.close

puts "=" * 60
puts "観測完了"
puts "総試行回数: #{total_attempts}"
puts "総ng回数:   #{total_ng}"
ng_rate = total_attempts.positive? ? (total_ng.to_f / total_attempts * 100).round(1) : 0.0
puts "ng率:       #{ng_rate}%"
puts "forced_zatsu採用: #{forced_zatsu_creates}句（うちモーラng許容: #{forced_zatsu_mora_ng_ct}句）"
puts "-" * 60
puts "違反種別の内訳（降順）:"
violation_counts.sort_by { |_, count| -count }.each do |category, count|
  puts "  #{category}: #{count}件"
end
puts "=" * 60
