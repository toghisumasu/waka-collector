require 'rails_helper'

RSpec.describe "Wakas", type: :request do
  describe "GET /index" do
    it "returns http success" do
      get "/wakas/index"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /show" do
    it "returns http success" do
      get "/wakas/show"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /new" do
    it "returns http success" do
      get "/wakas/new"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /edit" do
    it "returns http success" do
      get "/wakas/edit"
      expect(response).to have_http_status(:success)
    end
  end

end
