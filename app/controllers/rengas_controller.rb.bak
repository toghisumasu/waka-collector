# frozen_string_literal: true

class RengasController < ApplicationController
  def new
    @renga  = Renga.new
    @honkas = Waka.limit(5)
  end

  def create
    maeku     = renga_params[:maeku]
    confirmed = params[:confirmed] == "true"

    # 句の検証（KuValidator）
    check = KuValidator.new(maeku).validate

    if check[:result] == "ng"
      @renga  = Renga.new(maeku: maeku)
      @honkas = Waka.limit(5)
      flash.now[:alert] = check[:message]
      render :new, status: :unprocessable_entity
      return
    end

    if check[:result] == "warning" && !confirmed
      @renga     = Renga.new(maeku: maeku)
      @honkas    = Waka.limit(5)
      @warning   = check[:message]
      @confirmed = true
      render :new
      return
    end

    honka_ids = Array(renga_params[:honka_ids]).reject(&:blank?).map(&:to_i)
    honkas    = honka_ids.any? ? Waka.where(id: honka_ids) : []
    tsugeku = RengaGenerator.new(maeku, honkas).generate_tsugeku
    result  = RengaChecker.new([maeku, tsugeku]).check

    @renga = Renga.create!(
      maeku:              maeku,
      tsugeku:            tsugeku,
      maeku_author:       "ユーザー",
      tsugeku_author:     "メンタムさん",
      generated_by_model: OllamaClient::MODEL,
      style_check_result: result,
      honka_reference:    honka_ids
    )

    redirect_to @renga, notice: "付け句が生成されました"
  rescue RuntimeError => e
    @renga  = Renga.new(maeku: maeku)
    @honkas = Waka.limit(5)
    flash.now[:alert] = e.message
    render :new, status: :service_unavailable
  end

  def show
    @renga = Renga.find(params[:id])
  end

  private

  def renga_params
    params.require(:renga).permit(:maeku, honka_ids: [])
  end
end
