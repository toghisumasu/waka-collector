require 'rails_helper'

RSpec.describe "Wakas", type: :request do
  describe "GET /wakas" do
    it "一覧ページが表示される" do
      get wakas_path
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /wakas/new" do
    it "新規登録ページが表示される" do
      get new_waka_path
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /wakas/:id" do
    it "詳細ページが表示される" do
      waka = create(:waka)
      get waka_path(waka)
      expect(response).to have_http_status(:success)
    end
  end

  describe "POST /wakas" do
    it "有効なデータで和歌を登録できる" do
      expect {
        post wakas_path, params: { waka: attributes_for(:waka) }
      }.to change(Waka, :count).by(1)
    end

    it "無効なデータでは登録できない" do
      expect {
        post wakas_path, params: { waka: attributes_for(:waka, upper_phrase: '') }
      }.not_to change(Waka, :count)
    end
  end
end
