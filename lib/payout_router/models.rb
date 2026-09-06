# frozen_string_literal: true

module PayoutRouter
  Operation = Struct.new(
    :id, :created_at, :amount, :bank, :card_brand, :payout_requisite,
    keyword_init: true
  ) do
    def self.from_h(data)
      new(
        id: data.fetch("operation_id"),
        created_at: Time.iso8601(data.fetch("created_at")),
        amount: Float(data.fetch("amount")),
        bank: data.fetch("bank"),
        card_brand: data["card_brand"],
        payout_requisite: data["payout_requisite"]
      )
    rescue KeyError, ArgumentError => e
      raise InputError, "Некорректная операция: #{e.message}"
    end
  end

  Provider = Struct.new(:data, keyword_init: true) do
    def self.from_h(data)
      raise InputError, "У провайдера отсутствует payment_system" unless data["payment_system"]

      new(data: data)
    end

    def id = data["payment_system"]
    def [](key) = data[key.to_s]

    def with_extensions(extension)
      self.class.new(data: data.merge(extension || {}))
    end
  end

  ConstraintResult = Struct.new(:allowed, :reason, :details, keyword_init: true) do
    def allowed? = allowed
  end

  ScoreResult = Struct.new(:total, :components, :explanation, keyword_init: true)

  Attempt = Struct.new(
    :provider, :decision, :reason, :details, :score, :score_breakdown, :result,
    keyword_init: true
  ) do
    def to_h
      {
        "provider" => provider,
        "decision" => decision,
        "reason" => reason,
        "details" => details,
        "score" => score,
        "score_breakdown" => score_breakdown,
        "result" => result
      }.compact
    end
  end

  RoutingDecision = Struct.new(
    :operation_id, :selected_provider, :attempts, :simulated_result, :latency_sec,
    :explanation, :goal_unavailable, keyword_init: true
  ) do
    def to_h
      {
        "operation_id" => operation_id,
        "selected_provider" => selected_provider,
        "attempts" => attempts.map(&:to_h),
        "simulated_result" => simulated_result,
        "latency_sec" => latency_sec,
        "explanation" => explanation,
        "goal_unavailable" => goal_unavailable
      }.compact
    end
  end
end
