# frozen_string_literal: true

module PayoutRouter
  module Strategies
    Context = Struct.new(:operation, :provider, :eligible, :state, :history, :config, keyword_init: true)

    class Base
      private

      def clamp(value) = [[value.to_f, 0.0].max, 1.0].min
    end

    class TrafficCount < Base
      def call(context)
        target = context.provider["traffic_percentage"].to_f / 100.0
        actual = if context.state.total_selected_count.zero?
                   0.0
                 else
                   context.state.selected_count(context.provider.id).to_f / context.state.total_selected_count
                 end
        clamp(0.5 + target - actual)
      end
    end

    class TrafficVolume < Base
      def call(context)
        target = context.provider["volume_share_pct"].to_f / 100.0
        actual = if context.state.total_selected_volume.zero?
                   0.0
                 else
                   context.state.selected_volume(context.provider.id) / context.state.total_selected_volume
                 end
        clamp(0.5 + target - actual)
      end
    end

    class Priority < Base
      def call(context)
        priorities = context.eligible.map { |provider| provider["priority"].to_i }
        min, max = priorities.minmax
        return 1.0 if min == max

        1.0 - ((context.provider["priority"].to_i - min).to_f / (max - min))
      end
    end

    class Conversion < Base
      def call(context)
        clamp(context.history.conversion_for(context.provider, context.operation.bank))
      end
    end

    class AmountBand < Base
      def call(context)
        band = context.config.fetch("amount_bands", []).find do |item|
          context.operation.amount >= item.fetch("min", 0).to_f &&
            (!item["max"] || context.operation.amount <= item["max"].to_f)
        end
        return 0.5 unless band

        band["preferred"] == context.provider.id ? 1.0 : 0.25
      end
    end

    class Load < Base
      def call(context)
        utilization = context.state.utilization(context.provider)
        rpm_limit = context.provider["requests_per_minute_limit"].to_f
        rpm_utilization = if rpm_limit.positive?
                            context.state.requests_last_minute(
                              context.provider.id, context.operation.created_at
                            ) / rpm_limit
                          else
                            0.0
                          end
        worst = [utilization, rpm_utilization].max
        soft = context.config.dig("risk", "soft_utilization_threshold").to_f
        critical = context.config.dig("risk", "critical_utilization_threshold").to_f
        return clamp(1.0 - worst * 0.5) if soft.zero? || worst <= soft
        return 0.05 if critical.positive? && worst >= critical

        clamp(0.5 * (critical - worst) / (critical - soft))
      end
    end

    class Turnover < Base
      def call(context)
        approved = context.state.daily_approved(context.provider.id)
        minimum = context.provider["daily_turnover_min"].to_f
        maximum = context.provider["daily_turnover_max"].to_f
        score = 0.5

        if minimum.positive? && approved < minimum
          progress = approved / minimum
          score = clamp(1.0 - progress + 0.5)
        end

        if maximum.positive?
          ratio = approved / maximum
          if ratio >= 1.0
            score = [score, 0.05].min
          elsif ratio >= 0.8
            score = [score, clamp(1.0 - ratio)].min
          end
        end

        score
      end
    end

    class CompositeScorer
      STRATEGIES = {
        "traffic_count" => TrafficCount,
        "traffic_volume" => TrafficVolume,
        "priority" => Priority,
        "conversion" => Conversion,
        "amount_band" => AmountBand,
        "load" => Load,
        "turnover" => Turnover
      }.freeze

      def initialize(config:, profile:)
        @config = config
        @profile_name = profile
        @profile = config.fetch("profiles").fetch(profile) do
          raise InputError, "Неизвестный профиль роутинга: #{profile}"
        end
      end

      def score(operation:, provider:, eligible:, state:, history:)
        context = Context.new(
          operation: operation, provider: provider, eligible: eligible,
          state: state, history: history, config: @config
        )
        weights = @profile.fetch("weights")
        components = weights.to_h do |name, weight|
          strategy = STRATEGIES.fetch(name) { raise InputError, "Неизвестная стратегия: #{name}" }
          raw = strategy.new.call(context)
          [name, { "raw" => raw.round(4), "weight" => weight.to_f, "weighted" => (raw * weight.to_f).round(4) }]
        end
        total = components.values.sum { |item| item["weighted"] }
        leaders = components.sort_by { |_name, item| -item["weighted"] }.first(2).map(&:first)

        ScoreResult.new(
          total: total.round(6),
          components: components,
          explanation: "Профиль #{@profile_name}: главные факторы — #{leaders.join(' и ')}"
        )
      end

      def simulation_mode = @profile.fetch("simulation", "always_approve")
    end
  end
end
