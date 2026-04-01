require 'rails_helper'

RSpec.describe Waka, type: :model do
  describe 'バリデーション' do
    it '上の句と下の句があれば有効' do
      waka = build(:waka)
      expect(waka).to be_valid
    end

    it '上の句がなければ無効' do
      waka = build(:waka, upper_phrase: '')
      expect(waka).not_to be_valid
    end

    it '下の句がなければ無効' do
      waka = build(:waka, lower_phrase: '')
      expect(waka).not_to be_valid
    end
  end
end
