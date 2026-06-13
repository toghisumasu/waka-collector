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

    tsugeku = RengaGenerator.new(maeku, honkas, next_verse_type).generate_tsugeku
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

  def renga_params
    params.require(:renga).permit(:maeku, :previous_renga_id, honka_ids: [])
  end
end

