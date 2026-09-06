# frozen_string_literal: true

module PayoutRouter
  class StateTracker
    attr_reader :total_selected_count, :total_selected_volume

    def initialize(providers)
      @state = providers.to_h do |provider|
        [
          provider.id,
          {
            daily_approved: provider["daily_approved_amount"].to_f,
            in_progress_count: provider["in_progress_count"].to_i,
            in_progress_amount: provider["in_progress_amount"].to_f,
            selected_count: 0,
            selected_volume: 0.0,
            approved_count: 0,
            requests: []
          }
        ]
      end
      @total_selected_count = 0
      @total_selected_volume = 0.0
    end

    def daily_approved(id) = fetch(id)[:daily_approved]
    def in_progress_count(id) = fetch(id)[:in_progress_count]
    def in_progress_amount(id) = fetch(id)[:in_progress_amount]
    def selected_count(id) = fetch(id)[:selected_count]
    def selected_volume(id) = fetch(id)[:selected_volume]
    def approved_count(id) = fetch(id)[:approved_count]

    # Backward-compatible aliases used by older strategy wording.
    alias routed_count selected_count
    alias routed_volume selected_volume
    def total_routed_count = total_selected_count
    def total_routed_volume = total_selected_volume

    def requests_last_minute(id, time)
      cutoff = time - 60
      fetch(id)[:requests].count { |timestamp| timestamp > cutoff && timestamp <= time }
    end

    def begin_attempt(provider, operation)
      row = fetch(provider.id)
      row[:in_progress_count] += 1
      row[:in_progress_amount] += operation.amount
      row[:requests] << operation.created_at
    end

    def complete_attempt(provider, operation, result)
      row = fetch(provider.id)
      row[:in_progress_count] -= 1
      row[:in_progress_amount] -= operation.amount
      return unless result == "approved"

      row[:daily_approved] += operation.amount
      row[:approved_count] += 1
    end

    # Counts traffic/volume share by final selected_provider after retries/fallback.
    def record_selection(provider, operation)
      row = fetch(provider.id)
      row[:selected_count] += 1
      row[:selected_volume] += operation.amount
      @total_selected_count += 1
      @total_selected_volume += operation.amount
    end

    def utilization(provider)
      ratios = []
      ratios << daily_approved(provider.id) / provider["daily_amount_limit"].to_f if provider["daily_amount_limit"].to_f.positive?
      ratios << in_progress_count(provider.id).to_f / provider["in_progress_count_limit"].to_f if provider["in_progress_count_limit"].to_f.positive?
      ratios << in_progress_amount(provider.id) / provider["in_progress_amount_limit"].to_f if provider["in_progress_amount_limit"].to_f.positive?
      ratios.max || 0.0
    end

    def snapshot
      @state.transform_values do |row|
        row.reject { |key, _value| key == :requests }.transform_values do |value|
          value.is_a?(Float) ? value.round(2) : value
        end
      end
    end

    private

    def fetch(id)
      @state.fetch(id) { raise InputError, "Неизвестный провайдер в состоянии: #{id}" }
    end
  end
end
