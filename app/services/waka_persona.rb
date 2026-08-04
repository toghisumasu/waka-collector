# frozen_string_literal: true

# 其の七十四: StepwiseWakaGenerator Step1（自由詠み）へ「誰が・どこから・
# どんな境遇で詠んでいるか」というペルソナ（視座）を注入し、抽象的な
# 形容詞に逃げず身体感覚に基づいた密度の高い描写を引き出すための
# ペルソナ定義・選択ロジック。
module WakaPersona
  NEGATIVE_INSTRUCTION =
    "客観的な状況説明や「寂しい」「美しい」などの形容詞だけに頼らず、" \
    "色・光・音・肌触りといった主体の身体感覚で描写すること。"

  # 其の七十七 D-77-2: 視座の与え方を「完成した詩句」から「視線の向きと
  # 感覚チャネル」へ改める。
  #
  # 背景: 其の七十六 Phase Aの診断で、gaze_path（例「足元に萌え出づる若草の露」）
  # がそのまま和歌として使える名詞句であったため、qwen3:8bが創作ではなく
  # 転記を選び、Step1出力9件中6件が一字一句同じ句で始まっていた。しかも
  # その出力が次句の前句になるとmaeku_echo?違反となり、詠み直しても同じ
  # ペルソナ・同じgaze_pathなので脱出できずnilに落ちていた（報告書6-1・6-3）。
  #
  # 対策: プロンプトへコピー可能な語句を一切置かず、「どの距離帯を見るか」と
  # 「どの感覚で捉えるか」だけを渡し、何を見つけるかはモデルに委ねる。
  # 距離帯はペルソナに依らず共通で、人物固有の具体性はstance（立ち位置）が担う。
  #
  # また、従来は3つの距離帯すべてを「丁寧に描写」させており、31音の目標と
  # 両立しない過剰制約になっていた（201音/67音の長文と7音の断片に二極化）。
  # 1回の詠みでは1つの距離帯のみを指定する。
  GAZE_ZONES = [
    { key: :near,   label: "手元・身近",     cue: "あなたの手や肌が触れているもの",     sense: "手触り・重み・温度" },
    { key: :middle, label: "目の前",         cue: "視界の中で動いているもの",           sense: "音・色・移ろい" },
    { key: :far,    label: "遠く",           cue: "顔を上げた先に広がっているもの",     sense: "光・かすみ・奥行き" }
  ].freeze

  # gaze_pathは其の七十四方式（gaze_mode: :literal）専用の遺産データ。
  # 既定の:abstract方式では参照されない。効果比較のために残している。
  PERSONAS = {
    youth: {
      name:      "前途ある若者",
      stance:    "野辺に立つ若者",
      gaze_path: %w[足元に萌え出づる若草の露 目の前を吹き抜ける風のそよぎ 空の彼方に広がる霞や雲],
      keywords:  %w[若草 春 花 未来 明日 望み 夢 光 風 朝]
    },
    hermit: {
      name:      "世を捨てた庵の主",
      stance:    "山深き草庵の軒端に座す隠者",
      gaze_path: %w[手にした冷たい茶碗や経机の木目 軒端に落ちる雫や苔むした庭石 谷間にたなびく霧や遠い山の稜線],
      keywords:  %w[草庵 閑居 世を捨て 隠れ家 苔 雫 山里 独り 静けさ]
    },
    woman: {
      name:      "日々を営む女",
      stance:    "格子窓のそばで手仕事をする女",
      gaze_path: %w[指先に触れる糸や布の質感 格子窓越しに差し込む光の筋 庭先を渡る風や遠くの物音],
      keywords:  %w[格子 袖 閨 針仕事 日々 家 灯 衣 庭]
    }
  }.freeze

  # persona_key: nil（自動選択：前句キーワード一致→なければランダム） /
  #              :random（常にランダム） / :youth / :hermit / :woman
  def self.resolve(persona_key, maeku)
    case persona_key
    when nil
      best_match(maeku) || PERSONAS.values.sample
    when :random
      PERSONAS.values.sample
    when *PERSONAS.keys
      PERSONAS.fetch(persona_key)
    else
      raise ArgumentError, "unknown persona: #{persona_key.inspect}"
    end
  end

  # 視座の距離帯を1つ返す。zone_key未指定なら毎回ランダムに選ぶ。Step1の
  # 詠み直し（MAX_CONTENT_RETRIES）ごとに再抽選されるため、ペルソナが同じでも
  # 別の距離帯へ移って詠み直せる。
  def self.resolve_zone(zone_key = nil)
    return GAZE_ZONES.sample if zone_key.nil?

    GAZE_ZONES.find { |z| z[:key] == zone_key } ||
      raise(ArgumentError, "unknown gaze zone: #{zone_key.inspect}")
  end

  # 前句に含まれるキーワード数が最も多いペルソナを返す（簡易解析）。
  # 一致するキーワードが一つも無ければnil。
  def self.best_match(maeku)
    return nil if maeku.nil? || maeku.strip.empty?

    scored = PERSONAS.map { |_, persona| [persona, persona[:keywords].count { |w| maeku.include?(w) }] }
    best   = scored.max_by { |_, score| score }
    best && best[1] > 0 ? best[0] : nil
  end
end
