# frozen_string_literal: true

module PayoutRouter
  RoutingRun = Struct.new(:decisions, :state, :providers, :profile, keyword_init: true) do
    def to_a = decisions.map(&:to_h)
  end

  class Router
    def initialize(providers:, config:, history_rows: [], profile: "submission", forced_outcomes: {})
      @providers = providers
      @config = config
      @profile = profile
      @fallback_id = config.fetch("fallback_provider", "spacepayments")
      @constraints = Constraints::Chain.new
      @history = HistoryAnalyzer.new(history_rows)
      @scorer = Strategies::CompositeScorer.new(config: config, profile: profile)
      @state = StateTracker.new(providers)
      @simulator = Simulator.new(
        seed: config.fetch("seed", "genesis"),
        mode: @scorer.simulation_mode,
        history: @history,
        forced_outcomes: forced_outcomes
      )
    end

    def route(operations)
      decisions = operations.map { |operation| route_one(operation) }
      RoutingRun.new(
        decisions: decisions, state: @state, providers: @providers, profile: @profile
      )
    end

    private

    def route_one(operation)
      attempts = []
      external = @providers.reject { |provider| provider.id == @fallback_id }
      unavailable_targets = []
      eligible = []

      external.each do |provider|
        result = @constraints.evaluate(operation, provider, @state, @config)
        if result.allowed?
          eligible << provider
        else
          attempts << Attempt.new(
            provider: provider.id, decision: "skipped",
            reason: result.reason, details: result.details
          )
          if provider["traffic_percentage"].to_f.positive?
            unavailable_targets << {
              "provider" => provider.id,
              "target_pct" => provider["traffic_percentage"].to_f,
              "reason" => "target_provider_ineligible",
              "blocking_reason" => result.reason,
              "details" => result.details
            }
          end
        end
      end

      ranked = rank(operation, eligible)
      remaining = ranked.dup
      final_provider = nil
      final_result = nil
      total_latency = 0
      attempted_ids = []
      attempt_number = 0

      while remaining.any? && final_provider.nil?
        remaining = recheck_remaining(operation, remaining, attempts)
        break if remaining.empty?

        item = remaining.shift
        provider = item.fetch(:provider)
        score = item.fetch(:score)
        attempted_ids << provider.id
        attempt_number += 1

        @state.begin_attempt(provider, operation)
        simulation = @simulator.call(operation, provider, attempt_number)
        @state.complete_attempt(provider, operation, simulation[:result])
        total_latency += simulation[:latency_sec]
        attempts << Attempt.new(
          provider: provider.id,
          decision: "selected",
          reason: eligible.one? ? "only_eligible_provider" : "best_composite_score",
          details: score.explanation,
          score: score.total,
          score_breakdown: score.components,
          result: simulation[:result]
        )

        next unless simulation[:result] == "approved"

        final_provider = provider
        final_result = simulation[:result]
      end

      unless final_provider
        fallback = @providers.find { |provider| provider.id == @fallback_id }
        raise InputError, "Fallback-провайдер #{@fallback_id} отсутствует" unless fallback

        result = @constraints.evaluate(operation, fallback, @state, @config)
        raise InputError, "Fallback #{@fallback_id} недоступен: #{result.reason}" unless result.allowed?

        attempt_number += 1
        @state.begin_attempt(fallback, operation)
        simulation = @simulator.call(operation, fallback, attempt_number)
        @state.complete_attempt(fallback, operation, simulation[:result])
        total_latency += simulation[:latency_sec]
        attempts << Attempt.new(
          provider: fallback.id, decision: "selected", reason: "fallback_pool_exhausted",
          details: "Все внешние кандидаты недоступны или завершились отказом",
          result: simulation[:result]
        )
        final_provider = fallback
        final_result = simulation[:result]
      end

      # Traffic/volume shares follow the final selected_provider after fallback,
      # not intermediate rejected attempts.
      @state.record_selection(final_provider, operation)

      append_lower_ranked(attempts, ranked, attempted_ids, final_provider.id)
      RoutingDecision.new(
        operation_id: operation.id,
        selected_provider: final_provider.id,
        attempts: attempts,
        simulated_result: final_result,
        latency_sec: total_latency,
        explanation: decision_explanation(final_provider, attempts, unavailable_targets),
        goal_unavailable: unavailable_targets.empty? ? nil : unavailable_targets
      )
    end

    def recheck_remaining(operation, remaining, attempts)
      remaining.filter_map do |item|
        provider = item.fetch(:provider)
        result = @constraints.evaluate(operation, provider, @state, @config)
        if result.allowed?
          item
        else
          attempts << Attempt.new(
            provider: provider.id,
            decision: "skipped",
            reason: result.reason,
            details: "Повторная hard-проверка перед попыткой: #{result.details}"
          )
          nil
        end
      end
    end

    def rank(operation, eligible)
      eligible.map do |provider|
        score = @scorer.score(
          operation: operation, provider: provider, eligible: eligible,
          state: @state, history: @history
        )
        { provider: provider, score: score }
      end.sort_by do |item|
        provider = item.fetch(:provider)
        [-item.fetch(:score).total, provider["priority"].to_i, provider.id]
      end
    end

    def append_lower_ranked(attempts, ranked, attempted_ids, winner_id)
      already = attempts.map(&:provider)
      ranked.each do |item|
        provider = item.fetch(:provider)
        next if attempted_ids.include?(provider.id) || provider.id == winner_id
        next if already.include?(provider.id)

        score = item.fetch(:score)
        attempts << Attempt.new(
          provider: provider.id, decision: "skipped", reason: "lower_composite_score",
          details: "Итоговый score #{score.total} ниже победителя",
          score: score.total, score_breakdown: score.components
        )
      end
    end

    def decision_explanation(provider, attempts, unavailable_targets)
      retries = attempts.count { |attempt| attempt.decision == "selected" } - 1
      suffix = retries.positive? ? " после #{retries} повторных попыток" : ""
      goals = if unavailable_targets.any?
                "; недоступны целевые: #{unavailable_targets.map { |item| item['provider'] }.uniq.join(', ')}"
              else
                ""
              end
      "Выбран #{provider.id}#{suffix}; hard-фильтры применены до soft-scoring и перед каждым retry#{goals}"
    end
  end
end
