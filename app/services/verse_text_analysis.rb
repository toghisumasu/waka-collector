# frozen_string_literal: true

# 其の七十三: RengaGenerator（:direct方式）とStepwiseWakaGenerator（:waka_extraction方式）の
# 両方が必要とする、@maeku/@verse_historyとMeCabインスタンスにのみ依存する
# 純粋なテキスト解析メソッド群。両クラスでincludeして使う。
module VerseTextAnalysis
  YOUON = %w[ゃ ゅ ょ].freeze

  def first_line(raw, maeku: nil)
    lines = raw.to_s.strip.lines.map(&:strip).reject(&:empty?)
    maeku_stripped = maeku&.strip
    lines.each do |line|
      next if maeku_stripped && line == maeku_stripped
      return line
    end
    ""
  end

  def mora_from_yomi(yomi)
    yomi.tr("ァ-ヴー", "ぁ-ゔー").chars.reject { |c| YOUON.include?(c) }.size
  end

  def morphemes_of(text, nm)
    result = []
    nm.parse(text.gsub(/[\s　]+/, "")) do |node|
      next if node.is_eos?
      f    = node.feature.split(",")
      yomi = f[7] || node.surface
      result << { surface: node.surface, yomi: yomi,
                  mora: mora_from_yomi(yomi), feature: node.feature }
    end
    result
  end

  # tolerance: 0（既定）で従来どおり「ちょうど skip/take 音」の形態素境界のみ許容。
  # 其の八十四 案1: :waka_extraction の Step4 は tolerance: 1 を渡し、十七音めに
  # 形態素境界が無い和歌（区切り不一致で全棄却されていた 29%）を ±1音の
  # 近傍境界で切り出せるようにする。:direct（seed pool 構築）は引数を渡さない
  # ため挙動不変。
  def extract_mora_segment(morphemes, skip_mora, take_mora, tolerance: 0)
    start_idx = 0
    if skip_mora > 0
      b = boundary_index_near(morphemes, skip_mora, tolerance)
      return nil if b.nil?
      start_idx = b + 1
    end
    remaining = morphemes[start_idx..]
    return nil if remaining.nil? || remaining.empty?
    e = boundary_index_near(remaining, take_mora, tolerance)
    return nil if e.nil?
    phrase = remaining[0..e]
    {
      surface:    phrase.map { |x| x[:surface] }.join,
      yomi:       phrase.map { |x| x[:yomi].tr("ァ-ヴー", "ぁ-ゔー") }.join,
      last_morph: phrase.last,
      morphemes:  phrase
    }
  end

  # 累積モーラが target に最も近い形態素境界の添字を返す。
  # tolerance=0 なら「ちょうど target」の境界のみ（従来と完全一致）。
  # 候補が複数あれば target との差が小さい方（同点なら手前）を優先する。
  def boundary_index_near(morphemes, target, tolerance)
    acc = 0
    best_idx = nil
    best_diff = nil
    morphemes.each_with_index do |m, i|
      acc += m[:mora]
      diff = (acc - target).abs
      if diff <= tolerance && (best_diff.nil? || diff < best_diff)
        best_idx  = i
        best_diff = diff
      end
      break if acc >= target + tolerance
    end
    best_idx
  end

  # 其の三十六: 一巻の履歴（verse_history、tsugeku本文の配列）との
  # 完全一致・類似検知。distance 0 = 完全一致、
  # distance <= max(文字数×0.3, 3) = 類似（一語違い相当）。
  # script/dryrun_hyakuin.rbで検証済みの実装をそのまま移植している。
  def levenshtein(a, b)
    return b.length if a.empty?
    return a.length if b.empty?

    costs = Array(0..b.length)
    a.each_char.with_index do |ca, i|
      costs[0] = i + 1
      nw = i
      b.each_char.with_index do |cb, j|
        cur = costs[j + 1]
        costs[j + 1] = ca == cb ? nw : ([costs[j], costs[j + 1], nw].min + 1)
        nw = cur
      end
    end
    costs[b.length]
  end

  def history_repeat?(word)
    return false if @verse_history.empty?
    return false if word.nil? || word.strip.empty?

    best_dist = nil
    @verse_history.each do |past|
      next if past.nil? || past.strip.empty?
      d = levenshtein(word, past)
      best_dist = d if best_dist.nil? || d < best_dist
      break if best_dist.zero?
    end
    return false if best_dist.nil?

    threshold = [(word.length * 0.3).ceil, 3].max
    best_dist <= threshold
  end

  # 其の七十二 D-72-5: 「前句をそのまま複写してはいけません」という
  # プロンプト指示を無視し、前句を複写する「前句エコー」への対策。
  # 完全一致・部分一致（textが前句を含む）・冒頭の高い前方一致
  # （levenshtein距離が閾値以内、history_repeat?と同じ閾値式）のいずれかで検出する。
  def maeku_echo?(text)
    return false if text.nil? || text.strip.empty?
    return false if @maeku.nil? || @maeku.strip.empty?
    return true if text.include?(@maeku)

    prefix = text[0, @maeku.length]
    return false if prefix.nil? || prefix.empty?

    threshold = [(@maeku.length * 0.3).ceil, 3].max
    levenshtein(prefix, @maeku) <= threshold
  end
end
