# frozen_string_literal: true

require "spec_helper"

RSpec.describe PayoutRouter::Router do
  def route(profile: "submission", forced: {})
    described_class.new(
      providers: providers, config: config, history_rows: history,
      profile: profile, forced_outcomes: forced
    ).route(operations)
  end

  it "совпадает с public golden selections" do
    expected = PayoutRouter::Loaders.json(
      File.join(root, "data", "sample_routing_decisions.json")
    ).to_h { |row| [row["operation_id"], row["selected_provider"]] }
    actual = route.decisions.to_h { |decision| [decision.operation_id, decision.selected_provider] }

    expect(actual).to eq(expected)
  end

  it "проходит четыре детерминированных кейса" do
    required = {
      "op_103" => "quickpay",
      "op_104" => "quickpay",
      "op_107" => "payflow",
      "op_108" => "quickpay"
    }
    actual = route.decisions.to_h { |decision| [decision.operation_id, decision.selected_provider] }

    expect(actual).to include(required)
  end

  it "фиксирует ожидаемые hard skip reasons" do
    decision = route.decisions.find { |item| item.operation_id == "op_103" }
    skips = decision.attempts.select { |attempt| attempt.decision == "skipped" }
      .to_h { |attempt| [attempt.provider, attempt.reason] }

    expect(skips).to include(
      "vipay" => "amount_exceeds_limit",
      "payflow" => "amount_exceeds_limit"
    )
  end

  it "повторяет попытки и уходит на self-provider" do
    forced = {
      "op_101" => {
        "vipay" => "rejected",
        "payflow" => "expired",
        "quickpay" => "rejected"
      }
    }
    run = described_class.new(
      providers: providers, config: config, history_rows: history,
      profile: "balanced", forced_outcomes: forced
    ).route(operations.select { |operation| operation.id == "op_101" })
    decision = run.decisions.first

    expect(decision.selected_provider).to eq("spacepayments")
    expect(decision.attempts.count { |attempt| attempt.decision == "selected" }).to eq(4)
    expect(decision.explanation).to include("повторных попыток")
    expect(run.state.selected_count("vipay")).to eq(0)
    expect(run.state.selected_count("payflow")).to eq(0)
    expect(run.state.selected_count("quickpay")).to eq(0)
    expect(run.state.selected_count("spacepayments")).to eq(1)
    expect(run.state.total_selected_count).to eq(1)
  end

  it "считает traffic share только по финальному selected_provider" do
    forced = { "op_101" => { "vipay" => "rejected" } }
    run = described_class.new(
      providers: providers, config: config, history_rows: history,
      profile: "balanced", forced_outcomes: forced
    ).route(operations.select { |operation| operation.id == "op_101" })
    decision = run.decisions.first
    winner = decision.selected_provider

    expect(winner).not_to eq("vipay")
    expect(run.state.selected_count("vipay")).to eq(0)
    expect(run.state.selected_count(winner)).to eq(1)
    expect(run.state.total_selected_count).to eq(1)
  end

  it "обновляет approved daily state последовательно" do
    run = route
    vipay_total = operations.select do |operation|
      run.decisions.find { |decision| decision.operation_id == operation.id }.selected_provider == "vipay"
    end.sum(&:amount)

    expect(run.state.daily_approved("vipay")).to eq(3_200_000 + vipay_total)
  end

  it "выдаёт полный explainable score breakdown" do
    selected = route.decisions.first.attempts.find { |attempt| attempt.decision == "selected" }

    expect(selected.score_breakdown.keys).to contain_exactly(
      "traffic_count", "traffic_volume", "priority", "conversion",
      "amount_band", "load", "turnover"
    )
    expect(selected.score).to be_between(0, 1)
  end

  it "фиксирует недоступность целевых провайдеров" do
    decision = route.decisions.find { |item| item.operation_id == "op_102" }

    expect(decision.goal_unavailable).to include(
      hash_including(
        "provider" => "vipay",
        "reason" => "target_provider_ineligible",
        "blocking_reason" => "bank_not_in_list"
      )
    )
    expect(decision.explanation).to include("недоступны целевые: vipay")
  end

  it "повторно проверяет hard перед retry" do
    evaluate_counts = Hash.new(0)
    original = PayoutRouter::Constraints::Chain.instance_method(:evaluate)
    allow_any_instance_of(PayoutRouter::Constraints::Chain).to receive(:evaluate) do |instance, operation, provider, state, cfg|
      evaluate_counts[provider.id] += 1
      result = original.bind_call(instance, operation, provider, state, cfg)
      if provider.id == "payflow" && evaluate_counts["payflow"] > 2
        PayoutRouter::ConstraintResult.new(
          allowed: false,
          reason: "daily_limit_exceeded",
          details: "injected recheck fail"
        )
      else
        result
      end
    end

    forced = { "op_101" => { "vipay" => "rejected" } }
    decision = route(profile: "balanced", forced: forced).decisions
      .find { |item| item.operation_id == "op_101" }
    payflow_skip = decision.attempts.find do |attempt|
      attempt.provider == "payflow" && attempt.decision == "skipped"
    end

    expect(payflow_skip.reason).to eq("daily_limit_exceeded")
    expect(payflow_skip.details).to include("Повторная hard-проверка перед попыткой")
    expect(%w[quickpay spacepayments]).to include(decision.selected_provider)
  end
end
