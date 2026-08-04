# frozen_string_literal: true

# 其の七十三: 其の七十二の一発生成方式（:waka_extraction）は「文脈継承」
# 「前句非重複」「31音厳守」を1回のプロンプトで同時に要求しており、qwen3:8b
# では3条件を同時に満たす確率が低かった。生成を4ステップに分割し、LLMには
# 「自由な文脈生成（Step1）」と「形式への書き換え（Step3）」という単純な
# タスクだけを与える。式目・内容面のチェック（Step2）と機械抽出（Step4）は
# Ruby側で行い、モデルへの重い書き換え依頼はStep2を通過した候補に限定する。
#
#   Step1   自由詠み    … 音数制約なしで前句に連なる和歌をLLMに詠ませる
#   Step1.5 音数調整    … Step1出力が長すぎ/短すぎる場合、核心への凝縮または
#                         遠景の追加で31音前後に近づける推敲を挟む
#   Step2   内容判定    … 前句エコー・既出表現・禁じ手の語をRuby側でチェック
#   Step3   形式整形    … Step2通過後のテキストを31音に書き換えさせる
#   Step4   機械抽出    … 31音のテキストから必要な短句/長句をextract_mora_segmentで切り出す
#
# RengaGenerator#generate_tsugekuからconstraints[:generation_strategy] == :waka_extraction
# の場合に委譲される。pool（filter_pool済み）・nm（MeCabインスタンス）・bui_dictは
# 呼び出し側で構築済みのものを注入する。
#
# 其の七十四: constraints[:persona]（:youth/:hermit/:woman/:random/未指定）で
# Step1に注入するペルソナ（視座）を指定できる。詳細はWakaPersonaを参照。
#
# 其の七十五: ペルソナ注入後、Step1の出力音数が両極端（201音の詞書風長文、
# 14音の閉塞した手元描写など）に振れる実地事例が確認された。一発のプロンプトで
# 31音ぴったりに収めようとするとモデルの創造性を殺すため、Step1とStep3の間に
# 音数に応じた動的推敲（Step1.5）を挟み、収束するまで（上限付きで）繰り返す。
#
# 其の七十七: 各ステップの入出力をJSONLへ恒久記録する（StepwiseStepLogger）。
# 記録専用であり、生成ロジックには影響しない。
class StepwiseWakaGenerator
  include VerseTextAnalysis
  include StepwiseStepLogger

  MAX_DRAFT_ATTEMPTS   = 5 # Step1やり直し（新しいseedで最初から）
  MAX_CONTENT_RETRIES  = 3 # Step1→Step2内容チェックの往復（同じseed）
  MAX_REWRITE_ATTEMPTS = 5 # Step3→Step4整形・抽出の往復（同じfree_text）

  # 其の七十五 D-75-1: Step1.5（音数調整）の往復上限と、長すぎ/短すぎの
  # 判定閾値。Step1の目標は「三十一音程度（三十〜三十五音前後）」なので、
  # 閾値はそれより外側に余裕を持たせ、実地確認済みの極端な事例
  # （201音・14音）を包含する範囲で設定する。
  MAX_LENGTH_ADJUST_ATTEMPTS      = 3
  FREE_VERSE_MORA_LONG_THRESHOLD  = 50 # これを超えたら核心の情景に絞る推敲を指示
  FREE_VERSE_MORA_SHORT_THRESHOLD = 25 # これを下回ったら遠景を加える推敲を指示

  # 其の七十二 D-72-4: 目標モーラ数（五・七・五・七・七＝31音）と許容誤差。
  # extract_mora_segmentが偶然non-nilを返しても、総モーラ数が31から
  # 大きく外れていると句境界と無関係な断片になることが実地確認で判明したため、
  # 誤差±2音を超える場合は成功扱いにしない。
  WAKA_TOTAL_MORA           = 31
  WAKA_TOTAL_MORA_TOLERANCE = 2

  attr_reader :used_seed_waka_id

  def initialize(maeku, verse_type, constraints:, pool:, nm:, bui_dict:)
    @maeku         = maeku
    @verse_type    = verse_type
    @constraints   = constraints
    @verse_history = constraints[:verse_history] || []
    @pool          = pool
    @nm            = nm
    @bui_dict      = bui_dict
    @persona_key   = constraints[:persona]
    # 其の七十七 D-77-2: :abstract（既定、視座カテゴリのみ）/ :literal（其の七十四方式、比較用）
    @gaze_mode     = constraints[:gaze_mode] || :abstract
  end

  def generate
    MAX_DRAFT_ATTEMPTS.times do |draft_i|
      seed      = @pool.sample
      persona   = WakaPersona.resolve(@persona_key, @maeku)
      # 其の七十七 D-77-1: ログ相関用。記録専用で生成ロジックからは参照しない。
      @draft_attempt   = draft_i + 1
      @current_seed    = seed
      @current_persona = persona
      free_text = generate_free_verse(seed, persona)
      next if free_text.nil? # Step1〜2の往復を使い切った→新しいseed・ペルソナへ

      free_text = adjust_free_verse_length(free_text)
      ku = rewrite_and_extract(free_text)
      if ku
        @used_seed_waka_id = seed[:waka_id]
        return ku
      end
    end
    nil
  end

  private

  # Step1（自由詠み） ⇄ Step2（内容判定）の往復。ペルソナはこの往復の間は
  # 固定し、outer draft attempt（generateの5回ループ）ごとに再選択する。
  def generate_free_verse(seed, persona)
    feedback = nil
    MAX_CONTENT_RETRIES.times do |retry_i|
      season_label = season_label_for(seed)
      # 詠み直しごとに距離帯を再抽選する（同じペルソナのまま別の情景へ移れる）。
      zone         = @gaze_mode == :literal ? nil : WakaPersona.resolve_zone(@constraints[:gaze_zone])
      prompt       = build_free_verse_prompt(seed, feedback, season_label, persona, zone)
      log_extra    = { content_retry: retry_i + 1, season_label: season_label,
                       gaze_mode: @gaze_mode, gaze_zone: zone && zone[:key],
                       feedback_issue: feedback && feedback[:issue] }
      free_text    = log_step("step1", prompt: prompt, extra: log_extra) do
        first_line(OllamaClient.generate(prompt, timeout: 180, think: false, temperature: 0.6))
      end

      violation = content_violation(free_text)
      log_step_verdict("step2", text: free_text, issue: violation && violation[:issue], extra: log_extra)
      return free_text if violation.nil?

      feedback = violation.merge(ku: free_text)
    end
    nil
  end

  # Step1.5（音数調整）: Step2通過後のfree_textの総モーラ数が両極端な場合、
  # 核心への凝縮（長すぎ）または遠景の追加（短すぎ）を指示する推敲を挟む。
  # 適正範囲（FREE_VERSE_MORA_SHORT_THRESHOLD〜FREE_VERSE_MORA_LONG_THRESHOLD）に
  # 収まるか、上限回数に達するまで繰り返す（収束しなくてもfree_textは返す。
  # 最終的な31音への精密な書き換えはStep3が担うため、ここでは大きな振れ幅の
  # 補正に留める）。
  def adjust_free_verse_length(free_text)
    text = free_text
    MAX_LENGTH_ADJUST_ATTEMPTS.times do |adjust_i|
      total_mora = total_mora_of(text)
      direction  =
        if total_mora > FREE_VERSE_MORA_LONG_THRESHOLD
          :condense
        elsif total_mora < FREE_VERSE_MORA_SHORT_THRESHOLD
          :expand
        end
      # 発動率（其の七十六 6-5）を集計できるよう、スキップも1行記録する。
      if direction.nil?
        log_step_verdict("step1.5", text: text, extra: { adjust_attempt: adjust_i + 1, direction: "skip" })
        return text
      end

      prompt = build_length_adjust_prompt(text, direction)
      text   = log_step("step1.5", prompt: prompt, input_text: text,
                        extra: { adjust_attempt: adjust_i + 1, direction: direction }) do
        first_line(OllamaClient.generate(prompt, timeout: 180, think: false, temperature: 0.5))
      end
    end
    text
  end

  def total_mora_of(text)
    morphemes_of(text, @nm).sum { |m| m[:mora] }
  end

  # Step3（31音への書き換え） ⇄ Step4（機械抽出）の往復
  def rewrite_and_extract(free_text)
    feedback = nil
    MAX_REWRITE_ATTEMPTS.times do |rewrite_i|
      prompt    = build_mora_rewrite_prompt(free_text, feedback)
      log_extra = { rewrite_attempt: rewrite_i + 1, feedback_issue: feedback && feedback[:issue] }
      mora_text = log_step("step3", prompt: prompt, input_text: free_text, extra: log_extra) do
        first_line(OllamaClient.generate(prompt, timeout: 180, think: false, temperature: 0.5))
      end

      # 其の七十六 未検証事項1（Step3失敗理由の内訳が不明）をここで埋める。
      seg, failure = extract_and_validate(mora_text)
      log_step_verdict("step4", text: mora_text, issue: failure && failure[:issue],
                       extra: log_extra.merge(extracted: seg && seg[:surface]))
      return seg[:surface] if seg

      feedback = failure.merge(ku: mora_text)
    end
    nil
  end

  # Step2: 内容判定（LLM呼び出しなし）。前句エコー・一巻内の既出表現・
  # forbidden_buiの語を検出した場合、Step1への詠み直し理由として返す。
  # 季語の必須化（季節ヒントの語が本文に無ければ違反、とする）は挙動変更の
  # 影響が読みにくいため今回は含めない（プロンプト側の指示止まり）。
  def content_violation(free_text)
    if maeku_echo?(free_text)
      return { issue: "前句エコー", message: "前句をそのまま繰り返さず、新しい言葉で詠み直してください" }
    end

    if history_repeat?(free_text)
      return { issue: "既出", message: "この一巻で既に詠まれた表現に近いため、別の言葉で詠み直してください" }
    end

    forbidden_bui = @constraints[:forbidden_bui] || []
    if forbidden_bui.any?
      hit = @bui_dict.detect_all(free_text, @nm) & forbidden_bui
      return { issue: "禁じ手（#{hit.join('・')}）", message: "その部立の語を避けて詠み直してください" } if hit.any?
    end

    nil
  end

  # Step4: 機械抽出。其の七十二 D-72-4（総モーラ数許容誤差）・D-72-5（前句エコー
  # 再検出）のガードをそのまま踏襲する（Step3の書き換えでも同じ問題が再発し得るため）。
  def extract_and_validate(mora_text)
    ms         = morphemes_of(mora_text, @nm)
    total_mora = ms.sum { |m| m[:mora] }
    skip, take = waka_extraction_bounds
    seg        = extract_mora_segment(ms, skip, take)

    echoes = maeku_echo?(mora_text) || (seg && maeku_echo?(seg[:surface]))
    over   = !waka_total_mora_within_tolerance?(total_mora)
    seg    = nil if echoes || over

    return [seg, nil] if seg

    failure =
      if echoes
        { issue: "前句エコー", message: "前句をそのまま繰り返さず、新しい言葉で三十一音に書き換えてください" }
      elsif over
        { issue: "#{total_mora}音（三十一音から#{WAKA_TOTAL_MORA_TOLERANCE}音超逸脱）",
          message: "五・七・五・七・七、計三十一音を超えず、かつ短すぎないよう書き換えてください" }
      else
        { issue: "区切り不一致", message: "五・七・五・七・七の音数の区切りで書き換えてください" }
      end
    [nil, failure]
  end

  # chouku（長句・五七五＝17音）は先頭17音、tanku（短句・七七＝14音）は
  # 17音スキップして残り14音を、31音の和歌テキストから切り出す。
  def waka_extraction_bounds
    @verse_type == :chouku ? [0, 17] : [17, 14]
  end

  def waka_total_mora_within_tolerance?(total_mora)
    (total_mora - WAKA_TOTAL_MORA).abs <= WAKA_TOTAL_MORA_TOLERANCE
  end

  def season_label_for(seed)
    season_hint = @constraints[:season_hint]
    if season_hint && season_hint[:must_switch]
      seed[:season] || "雑"
    else
      season_hint&.dig(:current) || RengaGenerator::SEASON_JP[maeku_season] || "雑"
    end
  end

  def maeku_season
    RengaGenerator::SEASON_WORDS.find { |_, words| words.any? { |w| @maeku.include?(w) } }&.first
  end

  # forbidden_bui（禁じ手）の注記行・季語指定/季の情趣を詠ませる行を返す。
  # RengaGenerator#directive_linesと同等ロジック（静的データはRengaGenerator::の定数を参照）。
  def directive_lines(season_label)
    forbidden_bui = @constraints[:forbidden_bui] || []
    kinshi = if forbidden_bui.any?
      desc = forbidden_bui.map { |b| RengaGenerator::BUI_EXAMPLE_WORDS[b] || b }.join("・")
      "禁：#{desc}の語は避けること。\n"
    else
      ""
    end
    kigo_words = kigo_hint(season_label)
    kigo_line  = if kigo_words.any?
      "季語「#{kigo_words.join('・')}」のいずれかを必ず詠み込むこと。\n"
    elsif season_label != "雑"
      "#{season_label}の情趣を詠むこと。\n"
    else
      ""
    end
    [kigo_line, kinshi]
  end

  def kigo_hint(season_label)
    season_key = RengaGenerator::SEASON_JP.invert[season_label]
    return [] unless season_key
    forbidden_bui = @constraints[:forbidden_bui] || []
    candidates = RengaGenerator::SEASON_WORDS[season_key].reject do |w|
      bui = RengaGenerator::KIGO_BUI[w]
      bui && forbidden_bui.include?(bui)
    end
    candidates.reject { |w| @maeku.include?(w) }.shuffle.first(2)
  end

  # 其の七十三 D-73-1: 音数制約を外しただけでは、モデルが7〜25音程度の
  # 短いフレーズで終わらせてしまい、Step3で31音まで伸ばしきれない問題が
  # 実地確認で判明。「三十一音程度・短いフレーズで終わらせない」という
  # 下限の目安を明示する。
  # 其の七十四: 抽象的・平板な描写に留まりがちな傾向への対策として、
  # 「誰が・どこから詠むか」というペルソナ（WakaPersona）を注入する。
  # 其の七十七 D-77-2: 視座の与え方はgaze_blockへ切り出した（既定は距離帯1つのみを
  # 渡す:abstract方式。手元→目の前→遠景を一度に指示する其の七十四方式は:literal）。
  def build_free_verse_prompt(seed, feedback, season_label, persona, zone = nil)
    feedback_note      = feedback ? "※前回の「#{feedback[:ku]}」は#{feedback[:issue]}でした。#{feedback[:message]}\n" : ""
    kigo_line, kinshi = directive_lines(season_label)

    <<~PROMPT
      あなたは連歌の宗匠です。
      これから、次のペルソナになりきって前句に情趣で連なる和歌を一首、自由に詠んでください。

      【ペルソナ】
      #{persona[:name]}。#{persona[:stance]}という立ち位置です。

      #{gaze_block(persona, zone)}
      【描写の注意】
      #{WakaPersona::NEGATIVE_INSTRUCTION}

      三十一音程度（目安として三十〜三十五音前後）を目指し、短いフレーズだけで終わらせないこと。
      前句の言葉をそのまま和歌に含めてはいけません。連想語だけを単独で出力してはいけません。
      #{kigo_line}#{kinshi}#{feedback_note}
      前句：#{@maeku}
      連想：#{seed[:surface]}
      季節：#{season_label}

      和歌の本文だけを一行で出力してください。説明や前置きは不要です。
      和歌：
    PROMPT
  end

  # 其の七十七 D-77-2: 視座ブロック。既定（:abstract）は距離帯と感覚チャネルのみを
  # 渡し、何を見つけるかはモデルに委ねる。プロンプト中にコピー可能な完成句を
  # 置かないことが目的なので、ここに具体的な景物の語を書き足してはならない。
  # :literalは其の七十四方式（gaze_pathの直接埋め込み）で、効果比較専用。
  def gaze_block(persona, zone)
    if @gaze_mode == :literal
      <<~BLOCK
        【視座の移動】
        次の順で視線を移し、それぞれを丁寧に描写すること。
        一、手元・身近：#{persona[:gaze_path][0]}
        二、目の前の対象：#{persona[:gaze_path][1]}
        三、遠くの景色：#{persona[:gaze_path][2]}
      BLOCK
    else
      zone ||= WakaPersona.resolve_zone
      <<~BLOCK
        【視座】
        今回は「#{zone[:label]}」だけに目を向けて詠むこと。
        #{zone[:cue]}を、その立ち位置に立ったあなた自身が見つけること。
        何を見つけるかはあなたが決めてよい。#{zone[:sense]}で捉えること。
      BLOCK
    end
  end

  # 其の七十三 D-73-2: フィードバック文言を書き換え対象の直後（和歌：free_text
  # の次の行）に置くと、モデルがフィードバック文をそのまま出力に複写してしまう
  # （前回の書き換え「X」は7音…といった文言ごと出力に混入する）ことが
  # 実地確認で判明。フィードバックを指示ブロック側（対象テキストより前）に
  # 移し、対象テキストと出力形式指示を見出し（【】）で明確に区切ることで
  # 「テキストの続きとして指示文を複写する」誤りを防ぐ。
  def build_mora_rewrite_prompt(free_text, feedback)
    feedback_note = feedback ? "※前回の書き換え「#{feedback[:ku]}」は#{feedback[:issue]}でした。#{feedback[:message]}\n" : ""

    <<~PROMPT
      以下の和歌の意味や情景のニュアンスを保ったまま、五・七・五・七・七（合計三十一音）の形に書き換えてください。
      三十一音を超えないこと。短すぎるのも誤りです。区切り記号（／や・など）は使わず、一続きの文として書くこと。
      #{feedback_note}
      【書き換え対象】
      #{free_text}

      【出力形式】
      書き換えた和歌だけを一行で出力してください。見出し・説明・前置き・引用符は不要です。
      書き換え：
    PROMPT
  end

  # Step1.5用プロンプト。direction: :condense（長すぎ）/ :expand（短すぎ）
  def build_length_adjust_prompt(text, direction)
    instruction =
      case direction
      when :condense
        "描いた情景の中から「一番残したい核心の情景」に焦点を絞り、余分な状況説明を削ぎ落として、" \
        "三十一音前後の密度の高い和歌へ要約・凝縮してください。"
      when :expand
        "手元の描写に留まっています。ふっと顔を上げて見上げた遠くの情景（空、光、風、市井の気配など）を加え、" \
        "手元の静けさと遠くの広がり（対比）を意識して三十一音の和歌へ押し広げてください。"
      end

    <<~PROMPT
      以下の和歌の下書きを推敲してください。
      #{instruction}

      【下書き】
      #{text}

      【出力形式】
      推敲した和歌だけを一行で出力してください。見出し・説明・前置き・引用符は不要です。
      推敲：
    PROMPT
  end
end
