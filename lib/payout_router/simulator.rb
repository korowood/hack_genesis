# frozen_string_literal: true

module PayoutRouter
  class Simulator
    def initialize(seed:, mode:, history:, forced_outcomes: {})
      @seed = seed
      @mode = mode
      @history = history
      @forced_outcomes = forced_outcomes
    end

    def call(operation, provider, attempt_number)
      forced = @forced_outcomes.dig(operation.id, provider.id)
      result = forced || simulated_result(operation, provider, attempt_number)
      {
        result: result,
        latency_sec: simulated_latency(operation, provider, attempt_number)
      }
    end

    private

    def simulated_result(operation, provider, attempt_number)
      return "approved" if @mode == "always_approve" || provider.id == "spacepayments"

      conversion = @history.conversion_for(provider, operation.bank)
      draw = deterministic_number(operation.id, provider.id, attempt_number, "result")
      return "approved" if draw < conversion

      expiry_draw = deterministic_number(operation.id, provider.id, attempt_number, "failure")
      expiry_draw < 0.35 ? "expired" : "rejected"
    end

    def simulated_latency(operation, provider, attempt_number)
      baseline = provider["avg_latency_sec"]&.to_f
      baseline ||= @history.provider_metrics(provider.id)["avg_latency_sec"]&.to_f
      baseline = 30.0 unless baseline&.positive?
      jitter = 0.75 + deterministic_number(operation.id, provider.id, attempt_number, "latency") * 0.5
      [(baseline * jitter).round, 1].max
    end

    def deterministic_number(*parts)
      digest = Digest::SHA256.hexdigest(([@seed] + parts).join(":"))
      digest[0, 13].to_i(16).to_f / 0xfffffffffffff
    end
  end
end
