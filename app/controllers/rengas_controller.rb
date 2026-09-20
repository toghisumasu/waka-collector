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

    # 成立前句（previous_renga_idあり）は既にrenga_versesへ記録済みのため、
    # 字余り・字足らずの確認画面は出さず生成へ進める。
    if check[:result] == "warning" && !confirmed && previous_renga_id.blank?
      @renga     = Renga.new(maeku: maeku, previous_renga_id: previous_renga_id)
      @honkas    = Waka.limit(5)
      @warning   = check[:message]
      @confirmed = true
      render :new
      return
    end

    # 依頼書2026-09-05 Bug A対応: maeku欄は編集可能なtext_areaだが、これまで
    # createはKuValidator（字数）しか通しておらず、ユーザーが編集したmaeku自体が
    # 式目（句去・七句去物等）違反を含んでいても検出できなかった。生成される
    # 付句候補はRengaGenerationService側で履歴と照合されるが、maeku自身は対象外だった。
    shikimoku_issues = maeku_shikimoku_violations(maeku, maeku_type, previous_renga_id)
    if shikimoku_issues.any?
      @renga  = Renga.new(maeku: maeku, previous_renga_id: previous_renga_id)
      @honkas = Waka.limit(5)
      flash.now[:alert] = "式目違反: #{shikimoku_issues.join('、')}"
      render :new, status: :unprocessable_entity
      return
    end

    honka_ids = Array(renga_params[:honka_ids]).reject(&:blank?).map(&:to_i)

    # 平野連歌会向けVPSデプロイ（方式B'、docs/phase0_async_report.md）:
    # 生成本体（Ollama呼び出しを含む、実測49-256秒）はGenerateRengaJobへ
    # 非同期委譲する。ここではプレースホルダのRengaを即座に作成してshowへ
    # リダイレクトし、以降の進捗・結果はTurbo Streamsで画面に反映される。
    @renga = Renga.create!(
      maeku:             maeku,
      maeku_author:      "ユーザー",
      previous_renga_id: previous_renga_id,
      status:            "pending"
    )

    GenerateRengaJob.perform_later(@renga.id, next_verse_type.to_s, honka_ids)

    redirect_to @renga, notice: "付け句を生成しています……"
  end

  def show
    @renga = Renga.find(params[:id])
  end

  # 依頼書2026-09-06 百韻管理機能: 「この付句を前句として続ける」押下時に
  # 成立句としてrenga_versesへ記録する。rengasは生成試行の全記録（差し戻し・
  # 再試行を含む）のまま変更せず、成立句だけをrenga_versesに切り出す。
  def confirm
    renga = Renga.find(params[:id])

    unless renga.status == "done"
      redirect_to renga, alert: "生成が完了していないため続けられません"
      return
    end

    if (existing = RengaVerse.find_by(renga_id: renga.id))
      redirect_to(existing.verse_no >= RengaVerse::TOTAL_VERSES ? hyakuin_path(existing) : new_renga_path(previous_renga_id: renga.id))
      return
    end

    maeku_mora = KuValidator.new(renga.maeku).count_mora
    maeku_type = KuValidator.nearest_verse_type(maeku_mora)
    # F-3: bui_list記録用。confirm内で1回だけ生成し発句・付け句の両方で共用する。
    nm = shikimoku_check_mecab

    previous_verse = renga.previous_renga_id.present? ? RengaVerse.find_by(renga_id: renga.previous_renga_id) : nil

    if previous_verse.nil?
      if renga.previous_renga_id.present?
        redirect_to renga, alert: "前句がまだ成立していないため続けられません（内部エラー）"
        return
      end

      # 発句（このrengaのmaeku自体）はrenga.previous_renga_idを持たないため
      # 対応するrenga_verse行が存在しない。1句目専用の行を先に作る。
      previous_verse = RengaVerse.create!(
        verse_no:     1,
        maeku:        nil,
        tsugeku:      renga.maeku,
        maeku_type:   nil,
        tsugeku_type: maeku_type.to_s,
        previous_verse_id: nil,
        renga_id:     nil,
        bui_list:     BuiDictionary.new.detect_all(renga.maeku, nm)
      )
    end

    next_verse_no = previous_verse.verse_no + 1
    if next_verse_no > RengaVerse::TOTAL_VERSES
      redirect_to hyakuin_path(previous_verse), alert: "百韻は既に成立しています（挙句まで詠み終えています）"
      return
    end

    tsugeku_type = (maeku_type == :chouku) ? :tanku : :chouku
    verse = RengaVerse.create!(
      verse_no:          next_verse_no,
      maeku:             renga.maeku,
      tsugeku:           renga.tsugeku,
      maeku_type:        maeku_type.to_s,
      tsugeku_type:      tsugeku_type.to_s,
      previous_verse_id: previous_verse.id,
      renga_id:          renga.id,
      bui_list:          BuiDictionary.new.detect_all(renga.tsugeku, nm)
    )

    if verse.verse_no >= RengaVerse::TOTAL_VERSES
      redirect_to hyakuin_path(verse), notice: "百韻が成立しました（挙句まで詠み終えました）"
    else
      redirect_to new_renga_path(previous_renga_id: renga.id)
    end
  end

  # 依頼書D-XX-3: 生成失敗（status: "failed"）時に、ユーザーが自分で付句を
  # 入力して成立させる。KuValidator（字数）・ShikimokuChecker（式目）は
  # 自動生成パイプラインと同じ基準を通す。式目・モーラのロジック自体には
  # 手を入れず、既存のmaeku_shikimoku_violationsと同型の照合を複製する。
  def manual_tsugeku
    renga = Renga.find(params[:id])

    unless renga.status == "failed"
      redirect_to renga, alert: "生成失敗時のみ利用できます"
      return
    end

    tsugeku = params[:tsugeku].to_s

    maeku_mora   = KuValidator.new(renga.maeku).count_mora
    maeku_type   = KuValidator.nearest_verse_type(maeku_mora)
    tsugeku_type = (maeku_type == :chouku) ? :tanku : :chouku

    check = KuValidator.new(tsugeku, type: tsugeku_type).validate
    if check[:result] == "ng"
      @renga                 = renga
      @manual_tsugeku_draft  = tsugeku
      @manual_tsugeku_error  = check[:message]
      render :show, status: :unprocessable_entity
      return
    end

    shikimoku_issues = manual_tsugeku_shikimoku_violations(renga, tsugeku, maeku_type, tsugeku_type)
    if shikimoku_issues.any?
      @renga                = renga
      @manual_tsugeku_draft = tsugeku
      @manual_tsugeku_error = "式目違反: #{shikimoku_issues.join('、')}"
      render :show, status: :unprocessable_entity
      return
    end

    renga.update!(
      tsugeku:            tsugeku,
      tsugeku_author:     "連衆",
      style_check_result: { "result" => "ok", "issues" => [], "breakdown" => [] },
      status:             "done"
    )

    redirect_to renga, notice: "付け句を記録しました"
  end

  private

  def renga_params
    params.require(:renga).permit(:maeku, :previous_renga_id, honka_ids: [])
  end

  # Bug A修正: 自動生成パイプライン（RengaGenerationService/GenerateRengaJob）は
  # 無変更のため、ここで独立した最小限の履歴照合を行う。RengaGenerationService の
  # build_verse_history/fetch_verse_chain と同形の処理だが、意図的に共通化せず
  # 複製している（依頼書のやらないこと：自動生成パイプラインへの変更をしない）。
  def maeku_shikimoku_violations(maeku, maeku_type, previous_renga_id)
    return [] if previous_renga_id.blank?

    nm       = shikimoku_check_mecab
    bui_dict = BuiDictionary.new
    history  = shikimoku_check_verse_chain(previous_renga_id, limit: 9)
                 .map { |row| shikimoku_check_verse_info(row["tsugeku"], nm: nm, bui_dict: bui_dict) }
    candidate = shikimoku_check_verse_info(maeku, nm: nm, bui_dict: bui_dict).merge(verse_type: maeku_type)

    checker    = ShikimokuChecker.new
    violations = checker.all_violations(history, candidate, bui_dict: bui_dict)
    violations += checker.ichiza_violations(history, candidate)
    violations.map { |v| ShikimokuChecker.describe(v) }
  end

  # manual_tsugeku用: renga.maekuに続くユーザー入力tsugekuを候補として、
  # RengaGenerationService#build_verse_historyのchain.empty?時の扱い
  # （前句自体を履歴に補う）に合わせて履歴を組み立てる。
  def manual_tsugeku_shikimoku_violations(renga, tsugeku, maeku_type, tsugeku_type)
    nm       = shikimoku_check_mecab
    bui_dict = BuiDictionary.new

    chain   = shikimoku_check_verse_chain(renga.previous_renga_id, limit: 9)
    history = chain.map { |row| shikimoku_check_verse_info(row["tsugeku"], nm: nm, bui_dict: bui_dict) }
    if chain.empty?
      history << shikimoku_check_verse_info(renga.maeku, nm: nm, bui_dict: bui_dict).merge(verse_type: maeku_type)
    end
    candidate = shikimoku_check_verse_info(tsugeku, nm: nm, bui_dict: bui_dict).merge(verse_type: tsugeku_type)

    checker    = ShikimokuChecker.new
    violations = checker.all_violations(history, candidate, bui_dict: bui_dict)
    violations += checker.ichiza_violations(history, candidate)
    violations.map { |v| ShikimokuChecker.describe(v) }
  end

  def shikimoku_check_verse_info(text, nm:, bui_dict:)
    word = bui_dict.detect_word(text, nm)
    { bui:        bui_dict.detect_all(text, nm),
      season:     shikimoku_check_season(text, nm: nm),
      word:       word,
      text:       text,
      plant_type: bui_dict.plant_type(word) }
  end

  def shikimoku_check_mecab
    Natto::MeCab.new(userdic: RengaGenerator::USER_DIC)
  rescue => e
    Rails.logger.warn "ユーザー辞書なし: #{e.message}"
    Natto::MeCab.new
  end

  def shikimoku_check_verse_chain(previous_renga_id, limit: nil)
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

  # RengaGenerationService#season_from_text と同一ロジック（「しも」誤検出修正済み、
  # season_from_text_mecab_phase0対応）。
  def shikimoku_check_season(text, nm:)
    return nil if text.blank?
    key = RengaGenerator::SEASON_WORDS.find do |_, words|
      words.any? { |w| w == "しも" ? shikimoku_check_shimo_kigo?(text, nm) : text.include?(w) }
    end&.first
    key ? RengaGenerator::SEASON_JP[key] : nil
  end

  def shikimoku_check_shimo_kigo?(text, nm)
    return false unless text.include?("しも")

    nm.parse(text.gsub(/[\s　]+/, "")) do |node|
      next if node.is_eos?
      return true if node.surface == "しも" && node.feature.split(",")[0] == "名詞"
    end
    false
  end
end

