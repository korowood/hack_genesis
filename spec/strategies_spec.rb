# frozen_string_literal: true

require "spec_helper"

RSpec.describe PayoutRouter::Strategies do
  let(:state) { PayoutRouter::StateTracker.new(providers) }
  let(:analyzer) { PayoutRouter::HistoryAnalyzer.new(history) }
  let(:operation) { operations.first }
  let(:eligible) { providers.reject { |provider| provider.id == "spacepayments" } }

  def context(provider)
    PayoutRouter::Strategies::Context.new(
      operation: operation, provider: provider, eligible: eligible,
      state: state, history: analyzer, config: config
    )
  end

  it "все семь стратегий возвращают нормализованные значения" do
    classes = [
      described_class::TrafficCount,
      described_class::TrafficVolume,
      described_class::Priority,
      described_class::Conversion,
      described_class::AmountBand,
      described_class::Load,
      described_class::Turnover
    ]

    classes.each do |strategy|
      expect(strategy.new.call(context(eligible.first))).to be_between(0.0, 1.0)
    end
  end

  it "повышает score провайдера с дефицитом count-share" do
    vipay = providers.find { |provider| provider.id == "vipay" }
    quickpay = providers.find { |provider| provider.id == "quickpay" }
    3.times do
      state.begin_attempt(vipay, operation)
      state.complete_attempt(vipay, operation, "approved")
      state.record_selection(vipay, operation)
    end

    strategy = described_class::TrafficCount.new
    expect(strategy.call(context(quickpay))).to be > strategy.call(context(vipay))
  end

  it "формально объединяет факторы согласно конфигурации" do
    scorer = described_class::CompositeScorer.new(config: config, profile: "submission")
    result = scorer.score(
      operation: operation, provider: eligible.first, eligible: eligible,
      state: state, history: analyzer
    )

    expected = result.components.values.sum { |component| component["weighted"] }.round(6)
    expect(result.total).to eq(expected)
    expect(result.explanation).to include("submission")
  end

  it "понижает score при приближении к daily_turnover_max" do
    vipay = providers.find { |provider| provider.id == "vipay" }
    vipay.data["daily_turnover_max"] = 3_300_000
    strategy = described_class::Turnover.new

    low = strategy.call(context(vipay))
    state.instance_variable_get(:@state)["vipay"][:daily_approved] = 3_250_000
    high = strategy.call(context(vipay))

    expect(high).to be < low
  end
end
