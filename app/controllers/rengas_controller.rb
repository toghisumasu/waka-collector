# frozen_string_literal: true

require "natto"

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

    # 其の三十八 D-38-1: RengaChecker（LLM式目チェック）からShikimokuChecker
    # （Ruby決定論的チェック）へ置換。bui情報源はBuiDictionary確定値に限定（D-36-1）。
    nm       = build_mecab
    bui_dict = BuiDictionary.new
    candidate = {
      bui:        bui_dict.detect_all(tsugeku, nm),
      season:     season_from_text(tsugeku),
      verse_type: next_verse_type
    }
    history = build_verse_history(previous_renga_id, maeku, maeku_type, nm: nm, bui_dict: bui_dict)

    checker    = ShikimokuChecker.new
    violations = checker.all_violations(history, candidate)
    violations += checker.ichiza_violations(history, candidate)
    violations += checker.chotan_violations(history, candidate)

    style_result = {
      "result"    => violations.empty? ? "ok" : "ng",
      "issues"    => violations.map { |v| ShikimokuChecker.describe(v) },
      "breakdown" => []
    }

    # 其の三十八 D-38-2: ShikimokuCheckerがngの場合はKuValidatorのng分岐と
    # 同じパターンで差し戻す（Renga.create!は実行しない）。
    if style_result["result"] == "ng"
      Rails.logger.warn "[RengasController] ShikimokuChecker ng: tsugeku=#{tsugeku.inspect} issues=#{style_result["issues"].inspect}"
      @renga  = Renga.new(maeku: maeku, previous_renga_id: previous_renga_id)
      @honkas = Waka.limit(5)
      flash.now[:alert] = "式目違反のため再生成が必要です：#{style_result["issues"].join('、')}"
      render :new, status: :unprocessable_entity
      return
    end

    @renga = Renga.create!(
      maeku:              maeku,
      tsugeku:            tsugeku,
      maeku_author:       "ユーザー",
      tsugeku_author:     "メンタムさん",
      generated_by_model: OllamaClient::MODEL,
      style_check_result: style_result,
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
        SELECT id, tsugeku, previous_renga_id, 0 AS depth
        FROM rengas
        WHERE id = ?
        UNION ALL
        SELECT r.id, r.tsugeku, r.previous_renga_id, verse_chain.depth + 1
        FROM rengas r
        INNER JOIN verse_chain ON r.id = verse_chain.previous_renga_id
        #{depth_guard}
      )
      SELECT id, tsugeku, previous_renga_id FROM verse_chain ORDER BY depth DESC
    SQL

    Renga.connection.select_all(sql).to_a
  end

  # 其の三十六 案C: 逆戻り検知に使うtsugeku本文のみ、履歴の深さを制限せず取得。
  def fetch_verse_history(previous_renga_id)
    fetch_verse_chain(previous_renga_id).map { |row| row["tsugeku"] }
  end

  def build_verse_history(previous_renga_id, maeku, maeku_type, nm: build_mecab, bui_dict: BuiDictionary.new)
    chain = fetch_verse_chain(previous_renga_id, limit: 9)
    history = chain.each_with_index.map do |r, i|
      offset = chain.size - i
      vtype  = offset.odd? ? maeku_type : (maeku_type == :chouku ? :tanku : :chouku)
      text   = r["tsugeku"]
      { bui: bui_dict.detect_all(text, nm), season: season_from_text(text), verse_type: vtype }
    end
    history << { bui: bui_dict.detect_all(maeku, nm), season: season_from_text(maeku), verse_type: maeku_type }
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

  def season_from_text(text)
    return nil if text.blank?
    key = RengaGenerator::SEASON_WORDS.find { |_, words| words.any? { |w| text.include?(w) } }&.first
    key ? RengaGenerator::SEASON_JP[key] : nil
  end

  def renga_params
    params.require(:renga).permit(:maeku, :previous_renga_id, honka_ids: [])
  end
end

