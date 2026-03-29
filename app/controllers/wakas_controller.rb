class WakasController < ApplicationController
  def index
    @wakas = Waka.all
  end

  def show
    @waka = Waka.find(params[:id])
  end

  def new
    @waka = Waka.new
  end

  def edit
    @waka = Waka.find(params[:id])
  end

  def create
    @waka = Waka.new(waka_params)
    if @waka.save
      redirect_to @waka, notice: '和歌を登録しました'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    @waka = Waka.find(params[:id])
    if @waka.update(waka_params)
      redirect_to @waka, notice: '和歌を更新しました'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @waka = Waka.find(params[:id])
    @waka.destroy
    redirect_to wakas_path, notice: '和歌を削除しました'
  end

  private

  def waka_params
    params.require(:waka).permit(:upper_phrase, :lower_phrase, :author, :source, :era, :notes)
  end
end
