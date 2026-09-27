# frozen_string_literal: true

# 依頼書M-3: 前句・付句間の語彙オーバーラップ率を計算し、bonsai2-waka等で
# 頻発する「部分的な前句エコー」を検出する。
#
# 閾値の根拠: 水無瀬三吟99組の実測（script/measure_minase_distance.rb）で
# 観測された非重複率の最小値0.888889（pair37、共有語「おも」1語/和集合9語）。
# これは「実践で許容された最大重複率」＝1.0-0.888889=0.111111であり、
# これを超える重複は水無瀬三吟のどの付合にも見られなかった（M-4で確定）。
#
# 内容語抽出はVerseTextAnalysis#morphemes_ofを再利用する（RengaGenerator/
# StepwiseWakaGeneratorが既にincludeしているモジュール）。M-2の
# script/analyze_compare_models.rbと同じ品詞フィルタ・Jaccard式だが、
# MeCab解析はRengaGenerator側で構築済みのTaggerインスタンス（nm）を
# 再利用し、新規にインスタンス化しない。
module OverlapGuard
  extend VerseTextAnalysis

  THRESHOLD = 0.111 # 水無瀬三吟99組の実測最大重複率（pair37由来）

  CONTENT_POS = %w[名詞 動詞 形容詞 副詞].freeze

  # 前句・付句間の内容語Jaccard重複率を返す（0.0=完全非重複〜1.0=完全一致）。
  def self.overlap_rate(maeku_text, tsukeku_text, nm)
    a = content_words(maeku_text, nm)
    b = content_words(tsukeku_text, nm)
    union = (a | b).uniq
    return 0.0 if union.empty?

    shared = (a & b).uniq
    shared.size.to_f / union.size
  end

  # 重複率がTHRESHOLDを超える場合にtrue（部分的な前句エコーと判定）。
  def self.partial_echo?(maeku_text, tsukeku_text, nm)
    overlap_rate(maeku_text, tsukeku_text, nm) > THRESHOLD
  end

  def self.content_words(text, nm)
    morphemes_of(text, nm).select { |m| CONTENT_POS.include?(m[:feature].split(",").first) }.map { |m| m[:surface] }
  end
  private_class_method :content_words
end
