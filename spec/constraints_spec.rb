# frozen_string_literal: true

require "spec_helper"

RSpec.describe PayoutRouter::Constraints::Chain do
  subject(:chain) { described_class.new }

  let(:state) { PayoutRouter::StateTracker.new(providers) }

  it "отсекает сумму выше максимума с объяснением" do
    operation = operations.find { |item| item.id == "op_103" }
    vipay = providers.find { |provider| provider.id == "vipay" }
    result = chain.evaluate(operation, vipay, state, config)

    expect(result.allowed?).to be(false)
    expect(result.reason).to eq("amount_exceeds_limit")
    expect(result.details).to include("150000")
  end

  it "учитывает разрешённый список банков" do
    operation = operations.find { |item| item.id == "op_104" }
    payflow = providers.find { |provider| provider.id == "payflow" }
    result = chain.evaluate(operation, payflow, state, config)

    expect(result.reason).to eq("bank_not_in_list")
  end

  it "разрешает пустой список банков как любой банк" do
    operation = operations.find { |item| item.id == "op_108" }
    quickpay = providers.find { |provider| provider.id == "quickpay" }

    expect(chain.evaluate(operation, quickpay, state, config)).to be_allowed
  end

  it "не блокирует специальный fallback с нулевым traffic" do
    operation = operations.first
    fallback = providers.find { |provider| provider.id == "spacepayments" }

    expect(chain.evaluate(operation, fallback, state, config)).to be_allowed
  end

  it "покрывает статус, дневной лимит, маржу и реквизиты" do
    operation = operations.first
    vipay = providers.find { |provider| provider.id == "vipay" }
    cases = {
      "provider_inactive" => { "status" => "maintenance" },
      "daily_limit_exceeded" => { "daily_amount_limit" => 3_200_000 },
      "daily_turnover_max_exceeded" => { "daily_turnover_max" => 3_200_000 },
      "negative_margin" => { "provider_margin_pct" => 2.0 },
      "no_requisites" => { "available_requisites" => 0 }
    }

    cases.each do |reason, attributes|
      original = vipay.data.dup
      vipay.data.merge!(attributes)
      local_state = PayoutRouter::StateTracker.new(providers)
      expect(chain.evaluate(operation, vipay, local_state, config).reason).to eq(reason)
      vipay.data.replace(original)
    end
  end

  it "покрывает оба in-progress лимита" do
    operation = operations.first
    vipay = providers.find { |provider| provider.id == "vipay" }

    vipay.data["in_progress_count_limit"] = vipay["in_progress_count"]
    expect(chain.evaluate(operation, vipay, state, config).reason).to eq("in_progress_count_exceeded")

    vipay.data["in_progress_count_limit"] = 100
    vipay.data["in_progress_amount_limit"] = vipay["in_progress_amount"]
    expect(chain.evaluate(operation, vipay, state, config).reason).to eq("in_progress_amount_exceeded")
  end

  it "проверяет rate limit по скользящему окну" do
    vipay = providers.find { |provider| provider.id == "vipay" }
    vipay.data["requests_per_minute_limit"] = 1
    first = operations.first
    second = first.dup
    second.created_at = first.created_at + 30
    state.begin_attempt(vipay, first)
    state.complete_attempt(vipay, first, "approved")

    result = chain.evaluate(second, vipay, state, config)
    expect(result.reason).to eq("rate_limit_exceeded")
  end
end
