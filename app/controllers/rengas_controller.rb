# frozen_string_literal: true

class RengasController < ApplicationController
  def new
    @renga  = Renga.new
    @honkas = Waka.limit(5)

    if params[:previous_renga_id].present?
      @previous_renga = Renga.find_by(id: params[:previous_renga_id])
      if @previous_renga
        @renga.maeku             = @previous_renga.tsugeku
        @renga.previous_renga_id = @previous_renga.id
      end
    end
  end

  def create
    maeku             = renga_params[:maeku]
    previous_renga_id = renga_params[:previous_renga_id]
    confirmed         = params[:confirmed] == "true"

    maeku_mora      = KuValidator.new(maeku).count_mora
    maeku_type      = KuValidator.nearest_verse_type(maeku_mora)
    next_verse_type = (maeku_type == :chouku) ? :tanku : :chouku

    check = KuValidator.new(maeku, type: maeku_type).validate

    if check[:result] == "ng"
      @renga  = Renga.new(maeku: maeku, previous_renga_id: previous_renga_id)
      @honkas = Waka.limit(5)
      flash.now[:alert] = check[:message]
      render :new, status: :unprocessable_entity
      return
    end

    if check[:result] == "warning" && !confirmed
      @renga     = Renga.new(maeku: maeku, previous_renga_id: previous_renga_id)
      @honkas    = Waka.limit(5)
      @warning   = check[:message]
      @confirmed = true
      render :new
      return
    end

    honka_ids = Array(renga_params[:honka_ids]).reject(&:blank?).map(&:to_i)
    honkas    = honka_ids.any? ? Waka.where(id: honka_ids) : []

    tsugeku = RengaGenerator.new(
      maeku, honkas, next_verse_type,
      constraints: { verse_history: fetch_verse_history(previous_renga_id) }
    ).generate_tsugeku
    result  = RengaChecker.new([maeku, tsugeku]).check

    @renga = Renga.create!(
      maeku:              maeku,
      tsugeku:            tsugeku,
      maeku_author:       "ユーザー",
      tsugeku_author:     "メンタムさん",
      generated_by_model: OllamaClient::MODEL,
      style_check_result: result,
      honka_reference:    honka_ids,
      previous_renga_id:  previous_renga_id
    )

    redirect_to @renga, notice: "付け句が生成されました"
  rescue RuntimeError => e
    @renga  = Renga.new(maeku: maeku, previous_renga_id: previous_renga_id)
    @honkas = Waka.limit(5)
    flash.now[:alert] = e.message
    render :new, status: :service_unavailable
  end

  def show
    @renga = Renga.find(params[:id])
  end

  private

  # 其の三十六 案C: build_verse_history（式目チェーン用、chain.size < 9固定）
  # とは独立した専用最小経路。逆戻り検知に使うtsugeku本文のみを、履歴の深さを
  # 制限せず1クエリ（再帰CTE）で取得する。N+1対策として、previous_renga_idを
  # 1句ずつRenga.find_byで辿る実装を避けている。
  # 戻り値：tsugeku本文の配列（古い句が先頭、直近の句が末尾）
  def fetch_verse_history(previous_renga_id)
    return [] if previous_renga_id.blank?

    sql = Renga.sanitize_sql_array([<<~SQL, previous_renga_id])
      WITH RECURSIVE verse_chain AS (
        SELECT id, tsugeku, previous_renga_id, 0 AS depth
        FROM rengas
        WHERE id = ?
        UNION ALL
        SELECT r.id, r.tsugeku, r.previous_renga_id, verse_chain.depth + 1
        FROM rengas r
        INNER JOIN verse_chain ON r.id = verse_chain.previous_renga_id
      )
      SELECT tsugeku FROM verse_chain ORDER BY depth DESC
    SQL

    Renga.connection.select_values(sql)
  end

  def build_verse_history(previous_renga_id, maeku, maeku_type)
    chain = []
    if previous_renga_id.present?
      renga = Renga.find_by(id: previous_renga_id)
      while renga && chain.size < 9
        chain.unshift(renga)
        renga = renga.previous_renga_id.present? ? Renga.find_by(id: renga.previous_renga_id) : nil
      end
    end
    history = chain.each_with_index.map do |r, i|
      offset = chain.size - i
      vtype  = offset.odd? ? maeku_type : (maeku_type == :chouku ? :tanku : :chouku)
      { bui: [], season: season_from_text(r.tsugeku), verse_type: vtype }
    end
    history << { bui: [], season: season_from_text(maeku), verse_type: maeku_type }
    history
  end

  def season_from_text(text)
    return nil if text.blank?
    key = RengaGenerator::SEASON_WORDS.find { |_, words| words.any? { |w| text.include?(w) } }&.first
    key ? RengaGenerator::SEASON_JP[key] : nil
  end

  def renga_params
    params.require(:renga).permit(:maeku, :previous_renga_id, honka_ids: [])
  end
end

