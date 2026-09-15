# frozen_string_literal: true

require "natto"

# 依頼書2026-09-06 百韻管理機能: renga_verses（成立句）を折ごとに一覧表示する。
class HyakuinsController < ApplicationController
  def show
    @tip      = RengaVerse.find(params[:id])
    @verses   = fetch_chain(@tip.id)
    @complete = @verses.size >= RengaVerse::TOTAL_VERSES
  end

  # 依頼書B Item 3: script/log_to_html.rb（旧ドライランログ用縦書きHTML）の
  # 出力品質をrenga_verses（インタラクティブモードの成立句）で再現する。
  #
  # Phase 0で確認済み：renga_versesにはbui/season/forced列がない。
  # season はtsugekuからBuiDictionary経由で動的に再検出する（B層確定値、
  # rengas_controller#shikimoku_check_seasonと同型）。forcedは
  # RengaGenerationService（インタラクティブモードの生成経路）に
  # forced_zatsu相当の再試行機構が存在しないため、常にfalseとする
  # （observe_production_hyakuin.rb側バッチ生成専用の概念であり、
  # 依頼書の「やらないこと」により本スクリプトへの変更は行わない）。
  def vertical
    @tip      = RengaVerse.find(params[:id])
    raw       = fetch_chain(@tip.id)
    @complete = raw.size >= RengaVerse::TOTAL_VERSES

    nm       = vertical_mecab
    bui_dict = BuiDictionary.new
    @verses  = raw.map do |row|
      {
        verse_no: row["verse_no"],
        text:     row["tsugeku"],
        season:   vertical_season_from_text(row["tsugeku"], nm: nm) || "雑",
        chouku:   row["tsugeku_type"] == "chouku",
        forced:   false # Phase 0確認済み: renga_verses由来データにFORCED概念は存在しない
      }
    end

    @fold_groups = RengaVerse::FOLDS.filter_map do |name, range|
      verses_in_fold = @verses.select { |v| range.cover?(v[:verse_no]) }
      next if verses_in_fold.empty?

      [name, range, verses_in_fold]
    end

    @season_counts = @verses.group_by { |v| v[:season] }.transform_values(&:size).sort_by { |_, c| -c }
    @forced_count  = 0
  end

  private

  # rengas側のfetch_verse_chainと同じ再帰CTEパターン（previous_verse_idを
  # 遡って古い順に取得）。renga_versesにグルーピング用の列がないため、
  # tip.idから遡る形でその一巻だけを取り出す。
  def fetch_chain(tip_id)
    sql = RengaVerse.sanitize_sql_array([<<~SQL, tip_id])
      WITH RECURSIVE verse_chain AS (
        SELECT id, verse_no, maeku, tsugeku, tsugeku_type, previous_verse_id, 0 AS depth
        FROM renga_verses
        WHERE id = ?
        UNION ALL
        SELECT r.id, r.verse_no, r.maeku, r.tsugeku, r.tsugeku_type, r.previous_verse_id, verse_chain.depth + 1
        FROM renga_verses r
        INNER JOIN verse_chain ON r.id = verse_chain.previous_verse_id
      )
      SELECT id, verse_no, maeku, tsugeku, tsugeku_type FROM verse_chain ORDER BY depth DESC
    SQL

    RengaVerse.connection.select_all(sql).to_a
  end

  def vertical_mecab
    Natto::MeCab.new(userdic: RengaGenerator::USER_DIC)
  rescue => e
    Rails.logger.warn "ユーザー辞書なし: #{e.message}"
    Natto::MeCab.new
  end

  # RengaGenerationService#season_from_text と同一ロジック（「しも」誤検出修正済み、
  # season_from_text_mecab_phase0対応）。rengas_controller#shikimoku_check_seasonの
  # 複製と同型（意図的に複製・共通化しない、Bug A対応時の方針を踏襲）。
  def vertical_season_from_text(text, nm:)
    return nil if text.blank?
    key = RengaGenerator::SEASON_WORDS.find do |_, words|
      words.any? { |w| w == "しも" ? vertical_shimo_kigo?(text, nm) : text.include?(w) }
    end&.first
    key ? RengaGenerator::SEASON_JP[key] : nil
  end

  def vertical_shimo_kigo?(text, nm)
    return false unless text.include?("しも")

    nm.parse(text.gsub(/[\s　]+/, "")) do |node|
      next if node.is_eos?
      return true if node.surface == "しも" && node.feature.split(",")[0] == "名詞"
    end
    false
  end
end
