# frozen_string_literal: true

module PayoutRouter
  class HistoryAnalyzer
    PRIOR_STRENGTH = 10.0

    def initialize(rows)
      @rows = rows
      @global_conversion = smoothed_conversion(rows, 0.75, 4.0)
    end

    def provider_metrics(provider_id)
      rows = @rows.select { |row| row["payment_system"] == provider_id }
      return empty_metrics if rows.empty?

      {
        "operations" => rows.size,
        "conversion" => smoothed_conversion(rows, @global_conversion, PRIOR_STRENGTH).round(4),
        "rejection_rate" => ratio(rows, "rejected").round(4),
        "expiration_rate" => ratio(rows, "expired").round(4),
        "avg_latency_sec" => average(rows, "latency_sec").round(2),
        "volume" => rows.sum { |row| row["amount"].to_f }.round(2)
      }
    end

    def conversion_for(provider, bank = nil)
      provider_rows = @rows.select { |row| row["payment_system"] == provider.id }
      bank_rows = provider_rows.select { |row| row["bank"] == bank }
      prior = provider["conversion_24h"]&.to_f || @global_conversion
      rows = bank_rows.size >= 3 ? bank_rows : provider_rows
      return prior if rows.empty?

      smoothed_conversion(rows, prior, PRIOR_STRENGTH)
    end

    def all_metrics(providers)
      providers.to_h { |provider| [provider.id, provider_metrics(provider.id)] }
    end

    private

    def smoothed_conversion(rows, prior, strength)
      approved = rows.count { |row| row["status"] == "approved" }
      (approved + prior * strength) / (rows.size + strength)
    end

    def ratio(rows, status)
      rows.count { |row| row["status"] == status }.to_f / rows.size
    end

    def average(rows, key)
      rows.sum { |row| row[key].to_f } / rows.size
    end

    def empty_metrics
      {
        "operations" => 0,
        "conversion" => nil,
        "rejection_rate" => nil,
        "expiration_rate" => nil,
        "avg_latency_sec" => nil,
        "volume" => 0
      }
    end
  end
end
