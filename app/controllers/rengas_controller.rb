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

  private

  def renga_params
    params.require(:renga).permit(:maeku, :previous_renga_id, honka_ids: [])
  end
end

