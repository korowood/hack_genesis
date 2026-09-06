# frozen_string_literal: true

require "sinatra/base"
require_relative "../lib/payout_router"

module PayoutRouter
  class Dashboard < Sinatra::Base
    set :bind, ENV.fetch("BIND", "0.0.0.0")
    set :port, ENV.fetch("PORT", "4567")
    set :server, :puma
    set :views, File.expand_path("views", __dir__)
    set :public_folder, File.expand_path("public", __dir__)
    set :static, true
    set :host_authorization, { permitted_hosts: ["example.org", "localhost", "127.0.0.1"] }

    helpers do
      def h(value)
        Rack::Utils.escape_html(value.to_s)
      end

      def pct(value)
        "#{format('%.1f', value.to_f)}%"
      end

      def bar_width(value)
        [[value.to_f, 0].max, 100].min
      end

      def profile_names
        @config.fetch("profiles").keys
      end
    end

    before do
      @config = Loaders.config(File.join(ROOT, "config", "routing.yml"))
    end

    get "/" do
      @profile = safe_profile(params["profile"] || "submission")
      @run, @report, @operations = scenario(@profile)
      erb :index
    end

    get "/operations/:id" do
      @profile = safe_profile(params["profile"] || "submission")
      @run, @report, @operations = scenario(@profile)
      @decision = @run.decisions.find { |decision| decision.operation_id == params["id"] }
      halt 404, "Операция не найдена" unless @decision
      @operation = @operations.find { |operation| operation.id == params["id"] }
      erb :operation
    end

    get "/compare" do
      @comparisons = profile_names.to_h do |profile|
        run, report, = scenario(profile)
        [profile, { run: run, report: report }]
      end
      @optimizer = Optimizer.new(
        config: @config, history_rows: Loaders.history(history_path)
      ).recommend(
        operations: Loaders.queue(queue_path),
        providers: Loaders.providers(providers_path, @config),
        limit: 3
      )
      erb :compare
    end

    post "/simulate" do
      profile = safe_profile(params["profile"] || "balanced")
      operation_id = params.fetch("operation_id")
      provider_id = params.fetch("provider_id")
      outcome = params.fetch("outcome")
      halt 422, "Недопустимый outcome" unless %w[approved rejected expired].include?(outcome)

      forced = { operation_id => { provider_id => outcome } }
      @profile = profile
      @run, @report, @operations = scenario(profile, forced)
      @notice = "Сценарий: #{provider_id} → #{outcome} для #{operation_id}"
      erb :index
    end

    get "/api/report" do
      content_type :json
      profile = safe_profile(params["profile"] || "submission")
      _run, report, = scenario(profile)
      JSON.pretty_generate(report)
    end

    private

    def safe_profile(value)
      halt 422, "Неизвестный профиль" unless @config.fetch("profiles").key?(value)
      value
    end

    def scenario(profile, forced = {})
      operations = Loaders.queue(queue_path)
      providers = Loaders.providers(providers_path, @config)
      history = Loaders.history(history_path)
      run = Router.new(
        providers: providers, config: @config, history_rows: history,
        profile: profile, forced_outcomes: forced
      ).route(operations)
      report = ReportBuilder.new(
        run: run, operations: operations, config: @config, history_rows: history
      ).build
      [run, report, operations]
    end

    def queue_path = ENV.fetch("QUEUE_PATH", File.join(ROOT, "data", "operations_queue_10.json"))
    def providers_path = ENV.fetch("PROVIDERS_PATH", File.join(ROOT, "data", "providers.json"))
    def history_path = ENV.fetch("HISTORY_PATH", File.join(ROOT, "data", "operations_history.csv"))
  end
end
