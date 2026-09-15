require "rails_helper"

# 依頼書Bug A: インタラクティブモードで同語・同季の連続違反（例：「水面」→「水面」）が
# 式目チェックを通過してしまう不具合の受入基準（RC-A1〜A3）を、実際のPOST /rengasで確認する。
RSpec.describe "POST /rengas", type: :request do
  it "RC-A1: 同語（水面→水面）を含む前句を入力すると式目違反として拒否される" do
    previous = Renga.create!(maeku: "はるののにかすみたなびく", tsugeku: "水面に映る月影さやかにて", status: "done")

    post rengas_path, params: { renga: { maeku: "水面ゆらめく秋の夕暮れ", previous_renga_id: previous.id } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(flash[:alert]).to include("式目違反")
    expect(flash[:alert]).to include("水面")
  end

  it "RC-A3: 語の重複がない正常な前句は式目チェックを通過し生成へ進む" do
    previous = Renga.create!(maeku: "はるののにかすみたなびく", tsugeku: "水面に映る月影さやかにて", status: "done")

    post rengas_path, params: { renga: { maeku: "山里の霧に響く鳥の声", previous_renga_id: previous.id } }

    expect(response).to redirect_to(Renga.last)
    expect(flash[:alert]).to be_nil
  end
end
