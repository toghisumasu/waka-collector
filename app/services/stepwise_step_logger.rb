# frozen_string_literal: true

# 其の七十七 D-77-1: StepwiseWakaGeneratorの各ステップの入出力を恒久的に
# JSONLへ記録する。
#
# 背景: 其の七十六 Phase Aでは、Step1（自由詠み）の応答テキストを記録して
# いなかったため、「ペルソナgaze_pathの丸写し」「seed語の単独出力」といった
# 失敗要因の特定を、走行後の再現診断スクリプト（script/diag_step1_outputs.rb）
# に頼らざるを得なかった。また Step3 は653回呼ばれて成功5回だったが、
# 失敗理由（前句エコー／音数逸脱／区切り不一致）の内訳がログに残らず
# 未検証事項として残った。プロンプト改善の効果測定には入出力の実記録が
# 前提となるため、観測スクリプト側の一時計装（OllamaClientのprepend）ではなく
# 本体側の常設ログとして持つ。
#
# 記録対象:
#   step1   / step1.5 / step3 … LLM呼び出し（プロンプト・出力・音数・所要秒数）
#   step2   / step4            … Ruby側判定の結果（違反理由。LLM呼び出しなし）
#
# 出力: log/stepwise_steps_<YYYYMMDD>.jsonl（1レコード＝1行）
#   ファイル名の日付はTime.now（システムローカル＝JST）を使う。既存の
#   observation_*.jsonlはTime.zone.now（UTC）で日付がずれる既知の問題が
#   あるため、ここでは踏襲しない。突合はファイル名ではなく行内の
#   batch / verse_no フィールドで行う。
#
# 相関キー: constraints[:log_context] に {batch:, verse_no:, attempt:} を
#   渡すと各行に記録され、既存の observation_*.jsonl と突合できる。省略可
#   （Web経路など指定がなければ当該フィールドはnullになる）。
#   full_prompt: true を渡した場合のみプロンプト全文も記録する（既定では
#   prompt_digestのみ。プロンプト改変の前後を識別するのが目的で、全文は
#   1走行あたり約1000行×2KBになるため診断時のみ）。
#
# 方針: 計装は生成を止めてはならない。書き込み失敗・モーラ計算失敗はすべて
#   飲み込み、Rails.loggerへ警告を出すだけに留める。
module StepwiseStepLogger
  # LLM呼び出しを1回ラップし、入出力・所要秒数を1行記録してブロックの戻り値を返す。
  # ブロックが例外を投げた場合も失敗として記録した上で、例外はそのまま伝播させる
  # （リトライ・タイムアウトの判断は呼び出し側の責務）。
  def log_step(step, prompt:, input_text: nil, extra: {})
    started = Time.now
    output  = nil
    failure = nil
    begin
      output = yield
    rescue StandardError => e
      failure = "#{e.class}: #{e.message}"
      raise
    ensure
      append_step_record(
        step: step, prompt: prompt, input_text: input_text, output: output,
        failure: failure, elapsed: (Time.now - started).round(3), extra: extra
      )
    end
  end

  # Ruby側判定（Step2内容判定・Step4機械抽出）の結果を1行記録する。
  # issueがnilなら通過、非nilなら弾かれた理由。
  def log_step_verdict(step, text:, issue: nil, extra: {})
    append_step_record(
      step: step, prompt: nil, input_text: text, output: nil,
      failure: nil, elapsed: nil, extra: extra.merge(verdict: issue || "ok", issue: issue)
    )
  end

  private

  def append_step_record(step:, prompt:, input_text:, output:, failure:, elapsed:, extra:)
    ctx = step_log_context
    core = {
      ts:            Time.now.iso8601(3),
      batch:         ctx[:batch],
      verse_no:      ctx[:verse_no],
      attempt:       ctx[:attempt],
      maeku:         @maeku,
      verse_type:    @verse_type,
      step:          step,
      draft_attempt: @draft_attempt,
      persona:       @current_persona && @current_persona[:name],
      seed:          @current_seed && @current_seed[:surface],
      seed_waka_id:  @current_seed && @current_seed[:waka_id],
      prompt_digest: prompt && Digest::SHA256.hexdigest(prompt)[0, 12],
      input_text:    input_text,
      input_mora:    input_text && safe_mora_of(input_text),
      output:        output,
      output_mora:   output && safe_mora_of(output),
      elapsed_sec:   elapsed,
      failure:       failure
    }
    path = step_log_path
    return if path.nil?

    record = core.merge(extra.except(*core.keys))
    record[:prompt] = prompt if ctx[:full_prompt] && prompt

    File.open(path, "a") { |f| f.puts(record.to_json) }
  rescue StandardError => e
    Rails.logger.warn "[StepwiseStepLogger] 記録に失敗しました（生成は継続します）: #{e.class}: #{e.message}"
  end

  def step_log_context
    @constraints[:log_context] || {}
  end

  # テスト環境では既定の出力先を持たない（nil＝記録しない）。specがStep1.5などを
  # 直接叩くたびに実ログへ混入し、走行データの集計を汚すため。記録内容そのものを
  # 検証するspecは、このメソッドをstubして一時ディレクトリへ差し替える。
  def step_log_path
    return nil if Rails.env.test?

    Rails.root.join("log", "stepwise_steps_#{Time.now.strftime('%Y%m%d')}.jsonl")
  end

  # モーラ計算はMeCab解析を伴うため、@nm未設定（spec等）や解析失敗では
  # nilを返して記録自体は続行する。
  def safe_mora_of(text)
    return nil if @nm.nil? || text.to_s.empty?

    total_mora_of(text)
  rescue StandardError
    nil
  end
end
