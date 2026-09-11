require "rails_helper"

RSpec.describe "PATCH /rengas/:id/manual_tsugeku", type: :request do
  it "生成失敗時にユーザーが有効な付句を入力すると成立として記録される" do
    renga = Renga.create!(maeku: "はるののにかすみたなびく", maeku_author: "ユーザー", status: "failed")

    patch manual_tsugeku_renga_path(renga), params: { tsugeku: "はるののにすみれつみにとこしわれぞ" }

    renga.reload
    expect(response).to redirect_to(renga_path(renga))
    expect(renga.status).to eq("done")
    expect(renga.tsugeku).to eq("はるののにすみれつみにとこしわれぞ")
    expect(renga.tsugeku_author).to eq("連衆")
  end

  it "空の付句は成立させず、生成失敗画面に留まる" do
    renga = Renga.create!(maeku: "はるののにかすみたなびく", maeku_author: "ユーザー", status: "failed")

    patch manual_tsugeku_renga_path(renga), params: { tsugeku: "" }

    renga.reload
    expect(response).to have_http_status(:unprocessable_entity)
    expect(renga.status).to eq("failed")
    expect(renga.tsugeku).to be_nil
  end

  it "生成失敗状態でない連歌には適用できない" do
    renga = Renga.create!(maeku: "はるののにかすみたなびく", maeku_author: "ユーザー", status: "done")

    patch manual_tsugeku_renga_path(renga), params: { tsugeku: "はるののにすみれつみにとこしわれぞ" }

    renga.reload
    expect(response).to redirect_to(renga_path(renga))
    expect(renga.tsugeku).to be_nil
  end
end
