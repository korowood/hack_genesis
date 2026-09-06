# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe PayoutRouter::Loaders do
  it "отклоняет невалидный JSON с понятной ошибкой" do
    Tempfile.create(["broken", ".json"]) do |file|
      file.write("{broken")
      file.flush
      expect { described_class.json(file.path) }
        .to raise_error(PayoutRouter::InputError, /Невалидный JSON/)
    end
  end

  it "отклоняет дубли operation_id" do
    row = {
      "operation_id" => "duplicate",
      "created_at" => "2026-07-30T09:00:00+03:00",
      "amount" => 1000,
      "bank" => "sberbank"
    }
    Tempfile.create(["queue", ".json"]) do |file|
      file.write(JSON.generate([row, row]))
      file.flush
      expect { described_class.queue(file.path) }
        .to raise_error(PayoutRouter::InputError, /Дубли operation_id/)
    end
  end

  it "отклоняет операцию без обязательных полей" do
    Tempfile.create(["queue", ".json"]) do |file|
      file.write(JSON.generate([{ "operation_id" => "incomplete" }]))
      file.flush
      expect { described_class.queue(file.path) }
        .to raise_error(PayoutRouter::InputError, /Некорректная операция/)
    end
  end
end
