# frozen_string_literal: true

require "natto"

# 平野連歌会向けVPSデプロイ（方式B'）: RengasController#create（同期）に
# インラインで書かれていた生成ロジック（RengaGenerator呼び出し〜式目最終検証）を
# GenerateRengaJobから呼べる形に切り出したもの。ロジック自体は其の三十八以来の
# 実装をそのまま移設しており、挙動は変更していない。
class RengaGenerationService
  include SeasonHintLogger

  Result = Struct.new(:tsugeku, :tsugeku_author, :generated_by_model,
                       :style_check_result, :honka_reference, keyword_init: true)

  class ShikimokuNg < StandardError
    attr_reader :issues

    def initialize(issues)
      @issues = issues
      super("式目違反: #{issues.join('、')}")
    end
  end

  def initialize(maeku:, previous_renga_id:, verse_type:, honka_ids: [])
    @maeku             = maeku
    @previous_renga_id = previous_renga_id
    @verse_type        = verse_type.to_sym
    @honka_ids         = honka_ids
  end

  def call
    maeku_mora = KuValidator.new(@maeku).count_mora
    maeku_type = KuValidator.nearest_verse_type(maeku_mora)

    honkas = @honka_ids.any? ? Waka.where(id: @honka_ids) : []

    # 其の三十八 D-38-1: RengaChecker（LLM式目チェック）からShikimokuChecker
    # （Ruby決定論的チェック）へ置換。bui情報源はBuiDictionary確定値に限定（D-36-1）。
    nm       = build_mecab
    bui_dict = BuiDictionary.new
    history  = build_verse_history(@previous_renga_id, @maeku, maeku_type, nm: nm, bui_dict: bui_dict)
    checker  = ShikimokuChecker.new

    # 其の四十四 D-44-1: next_constraints（forbidden_bui/season_hint）を生成前に
    # RengaGeneratorへ渡し、事後棄却だけでなく生成段階から式目違反を避けるよう誘導する。
    next_constraints = checker.next_constraints(history)
    log_season_hint(next_constraints, verse_no: history.size + 1)

    generator = RengaGenerator.new(
      @maeku, honkas, @verse_type,
      constraints: {
        verse_history: fetch_verse_history(@previous_renga_id),
        forbidden_bui: next_constraints[:forbidden_bui],
        season_hint:   next_constraints[:season_hint],
        used_waka_ids: fetch_used_waka_ids(@previous_renga_id),
        forbidden_nanaku_words: next_constraints[:forbidden_nanaku_words]
      }
    )
    tsugeku = generator.generate_tsugeku

    tsugeku_word = bui_dict.detect_word(tsugeku, nm)
    candidate = {
      bui:        bui_dict.detect_all(tsugeku, nm),
      season:     season_from_text(tsugeku, nm: nm),
      verse_type: @verse_type,
      word:       tsugeku_word,
      text:       tsugeku,
      plant_type: bui_dict.plant_type(tsugeku_word)
    }

    violations = checker.all_violations(history, candidate, bui_dict: bui_dict)
    violations += checker.ichiza_violations(history, candidate)
    violations += checker.chotan_violations(history, candidate)

    if violations.any?
      issues = violations.map { |v| ShikimokuChecker.describe(v) }
      Rails.logger.warn "[RengaGenerationService] shikimoku ng: tsugeku=#{tsugeku.inspect} issues=#{issues.inspect}"
      raise ShikimokuNg, issues
    end

    Result.new(
      tsugeku:            tsugeku,
      tsugeku_author:     "メンタムさん",
      generated_by_model: OllamaClient::MODEL,
      style_check_result: { "result" => "ok", "issues" => [], "breakdown" => [] },
      honka_reference:    (@honka_ids + [generator.used_seed_waka_id]).compact.uniq
    )
  end

  private

  # 其の三十七: fetch_verse_history（逆戻り検知用、其の三十六）と
  # build_verse_history（式目チェーン用、フェーズ8未接続）が、それぞれ独自に
  # previous_renga_idチェーンを取得していた重複を解消する共通サブルーチン。
  # 再帰CTEで1クエリ（N+1なし）、古い句が先頭・直近の句が末尾の順で
  # id/tsugeku/previous_renga_idの行（Hash）を返す。
  # limit指定時はbuild_verse_historyのchain.size<9相当（直近limit件のみ）に絞る。
  def fetch_verse_chain(previous_renga_id, limit: nil)
    return [] if previous_renga_id.blank?

    depth_guard = limit ? "WHERE verse_chain.depth + 1 < #{limit.to_i}" : ""

    sql = Renga.sanitize_sql_array([<<~SQL, previous_renga_id])
      WITH RECURSIVE verse_chain AS (
        SELECT id, tsugeku, previous_renga_id, honka_reference, 0 AS depth
        FROM rengas
        WHERE id = ?
        UNION ALL
        SELECT r.id, r.tsugeku, r.previous_renga_id, r.honka_reference, verse_chain.depth + 1
        FROM rengas r
        INNER JOIN verse_chain ON r.id = verse_chain.previous_renga_id
        #{depth_guard}
      )
      SELECT id, tsugeku, previous_renga_id, honka_reference FROM verse_chain ORDER BY depth DESC
    SQL

    Renga.connection.select_all(sql).to_a
  end

  # 其の三十六 案C: 逆戻り検知に使うtsugeku本文のみ、履歴の深さを制限せず取得。
  def fetch_verse_history(previous_renga_id)
    fetch_verse_chain(previous_renga_id).map { |row| row["tsugeku"] }
  end

  # 其の七十二: 使用済みオミット機能。一巻内でこれまで連想元（honka_reference、
  # 自動サンプリング分・ユーザー選択分の両方）として使われた和歌のwaka_idを
  # 集め、RengaGenerator#filter_poolで除外するための集合として渡す。
  # honka_referenceはjsonb列だがselect_all経由ではJSON文字列で返るためparseする。
  def fetch_used_waka_ids(previous_renga_id)
    fetch_verse_chain(previous_renga_id).each_with_object([]) do |row, ids|
      raw = row["honka_reference"]
      next if raw.blank?
      ids.concat(Array(JSON.parse(raw)))
    rescue JSON::ParserError
      next
    end.uniq
  end

  def build_verse_history(previous_renga_id, maeku, maeku_type, nm: build_mecab, bui_dict: BuiDictionary.new)
    chain = fetch_verse_chain(previous_renga_id, limit: 9)
    history = chain.each_with_index.map do |r, i|
      offset = chain.size - i
      vtype  = offset.odd? ? maeku_type : (maeku_type == :chouku ? :tanku : :chouku)
      text = r["tsugeku"]
      word = bui_dict.detect_word(text, nm)
      { bui: bui_dict.detect_all(text, nm), season: season_from_text(text, nm: nm), verse_type: vtype,
        word: word, text: text, plant_type: bui_dict.plant_type(word) }
    end
    # chainが非空のとき、末尾要素（previous_renga_id自体＝maekuと同一句）は
    # 既にmapで含まれているため、ここで再度追加すると二重カウントになる（D-41-1）。
    # chainが空（previous_renga_idがblank等でfetch_verse_chainが[]を返す）の
    # ときのみ、maeku自身の情報を補う。
    if chain.empty?
      maeku_word = bui_dict.detect_word(maeku, nm)
      history << { bui: bui_dict.detect_all(maeku, nm), season: season_from_text(maeku, nm: nm), verse_type: maeku_type,
                   word: maeku_word, text: maeku, plant_type: bui_dict.plant_type(maeku_word) }
    end
    history
  end

  # RengaGenerator#build_mecabと同じユーザー辞書（USER_DIC）を再利用する。
  # 定数定義の重複を避けるためRengaGenerator側を参照する。
  def build_mecab
    Natto::MeCab.new(userdic: RengaGenerator::USER_DIC)
  rescue => e
    Rails.logger.warn "ユーザー辞書なし: #{e.message}"
    Natto::MeCab.new
  end

  def season_from_text(text, nm: nil)
    return nil if text.blank?
    key = RengaGenerator::SEASON_WORDS.find do |_, words|
      words.any? { |w| w == "しも" ? shimo_kigo?(text, nm) : text.include?(w) }
    end&.first
    key ? RengaGenerator::SEASON_JP[key] : nil
  end

  # season_from_text Phase0調査（docs/investigation_season_from_text_phase0.md）で確認した
  # 既知バグの修正。「しも」は係助詞と同形のため単純部分一致では「光りしも」のような文でも
  # 霜（季語）と誤検出する。IPA辞書は「しも」を名詞（霜）と解析することがなく常に助詞と
  # 判定するため（事前検証：依頼書§4-1で13文を確認、名詞判定は0件）、MeCabで明示的に
  # 名詞と判定された場合のみ季語として扱う。
  def shimo_kigo?(text, nm)
    return false unless text.include?("しも")

    (nm || build_mecab).parse(text.gsub(/[\s　]+/, "")) do |node|
      next if node.is_eos?
      return true if node.surface == "しも" && node.feature.split(",")[0] == "名詞"
    end
    false
  end
end
