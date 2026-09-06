# frozen_string_literal: true

require "spec_helper"
require_relative "../app/app"

RSpec.describe "End-to-end routing" do
  include Rack::Test::Methods

  def app = PayoutRouter::Dashboard

  def build_run(profile = "submission")
    PayoutRouter::Router.new(
      providers: providers, config: config, history_rows: history, profile: profile
    ).route(operations)
  end

  it "строит отчёт с обязательной аналитикой" do
    report = PayoutRouter::ReportBuilder.new(
      run: build_run, operations: operations, config: config, history_rows: history
    ).build

    expect(report).to include(
      "distribution", "volume_distribution", "skip_reasons",
      "projected_daily_utilization", "recommendations",
      "goal_impossibility", "deviation_causes", "recommendation_messages"
    )
    expect(report["total_operations"]).to eq(10)
    expect(report.dig("routing_quality", "explainability_coverage_pct")).to eq(100.0)
    expect(report["goal_impossibility"]["events"]).to be >= 1
    expect(report["recommendation_messages"]).to all(be_a(String))
    expect(report["deviation_causes"]).to be_an(Array)
  end

  it "генерирует воспроизводимый результат" do
    first = JSON.generate(build_run("balanced").to_a)
    second = JSON.generate(build_run("balanced").to_a)

    expect(first).to eq(second)
  end

  it "валидирует контракт решений" do
    expect do
      PayoutRouter::CLI.validate_decisions!(build_run.to_a, operations)
    end.not_to raise_error
  end

  it "запускает bounded optimizer" do
    results = PayoutRouter::Optimizer.new(
      config: config, history_rows: history
    ).recommend(operations: operations, providers: providers, limit: 3)

    expect(results.size).to eq(3)
    expect(results.first["objective"]).to be >= results.last["objective"]
  end

  it "отдаёт dashboard и JSON API" do
    get "/"
    expect(last_response).to be_ok
    expect(last_response.body).to include("Маршрутизация")

    get "/compare"
    expect(last_response).to be_ok
    expect(last_response.body).to include("Лучшие наборы весов")

    get "/api/report"
    expect(last_response).to be_ok
    expect(JSON.parse(last_response.body)["total_operations"]).to eq(10)
  end
end
