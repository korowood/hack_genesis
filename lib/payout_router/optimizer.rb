# frozen_string_literal: true

module PayoutRouter
  class Optimizer
    GRID = [0.10, 0.20, 0.30].freeze

    def initialize(config:, history_rows: [])
      @config = config
      @history_rows = history_rows
    end

    def recommend(operations:, providers:, limit: 5)
      candidates = GRID.product(GRID, GRID).map do |count_weight, conversion_weight, load_weight|
        weights = normalized_weights(count_weight, conversion_weight, load_weight)
        config = deep_copy(@config)
        config["profiles"]["optimizer_candidate"] = {
          "simulation" => "always_approve",
          "weights" => weights
        }
        run = Router.new(
          providers: providers, config: config, history_rows: @history_rows,
          profile: "optimizer_candidate"
        ).route(operations)
        report = ReportBuilder.new(
          run: run, operations: operations, config: config, history_rows: @history_rows
        ).build
        quality = report.fetch("routing_quality")
        objective = 100.0 -
                    quality.fetch("mean_absolute_target_deviation_pct_points") -
                    quality.fetch("fallback_count") * 10
        {
          "objective" => objective.round(3),
          "weights" => weights,
          "target_deviation" => quality.fetch("mean_absolute_target_deviation_pct_points"),
          "fallback_count" => quality.fetch("fallback_count")
        }
      end

      candidates.sort_by { |candidate| -candidate["objective"] }.first(limit)
    end

    private

    def normalized_weights(count, conversion, load)
      raw = {
        "traffic_count" => count,
        "traffic_volume" => 0.20,
        "priority" => 0.10,
        "conversion" => conversion,
        "amount_band" => 0.05,
        "load" => load,
        "turnover" => 0.05
      }
      total = raw.values.sum
      raw.transform_values { |value| (value / total).round(4) }
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
