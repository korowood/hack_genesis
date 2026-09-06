# Genesis Routing Control Center

Объяснимый stateful-роутер выплат на Ruby. Сначала применяет hard-ограничения, затем ранжирует допустимых провайдеров по комбинации soft-целей, выполняет retry-каскад и формирует аналитический отчёт.

Нейросети и закрытые технологии не используются. Анализ истории основан на прозрачной статистике и Bayesian smoothing.

## Быстрый запуск

На машине с Ruby 3.1+:

```bash
bundle install
bundle exec ruby bin/route
ruby scripts/validate_10.rb routing_decisions.json
bundle exec rspec
bundle exec ruby bin/dashboard
```

Через Docker:

```bash
docker compose build
docker compose run --rm dashboard bundle exec ruby bin/route
docker compose run --rm dashboard ruby scripts/validate_10.rb routing_decisions.json
docker compose run --rm dashboard bundle exec rspec
docker compose up dashboard
```

Dashboard: `http://localhost:4567`.

## Финальная очередь

После получения `operations_queue_test.json`:

```bash
bundle exec ruby bin/route \
  --queue data/operations_queue_test.json \
  --profile submission \
  --output routing_decisions_test.json \
  --report routing_report_test.json
```

Команда атомарно создаёт оба обязательных файла в корне. До записи проверяются покрытие всех `operation_id`, дубликаты и обязательные поля.

## Архитектура

```text
JSON/CSV loaders
      │
      ▼
Hard constraint chain ──► structured skip reason
      │ eligible providers
      ▼
Composite soft scorer ──► score breakdown
      │ ranked cascade
      ▼
Seeded simulator ──reject/expired──┐
      │ approved                   │ retry
      ▼                            │
State tracker ◄────────────────────┘
      │
      ├── routing_decisions.json
      ├── routing_report.json
      └── Sinatra dashboard
```

Основные части:

- `constraints.rb` — независимые hard-фильтры;
- `strategies.rb` — семь нормализованных soft-факторов и формальный weighted sum;
- `state_tracker.rb` — daily/in-progress/RPM/count/volume;
- `router.rb` — ранжирование, retry и fallback;
- `simulator.rb` — детерминированные outcomes и latency;
- `report_builder.rb` — метрики и параметрические рекомендации;
- `optimizer.rb` — безопасный offline what-if grid search;
- `app/` — dashboard над тем же ядром, без отдельной бизнес-логики.

## Hard constraints

Ни одна стратегия не может обойти:

| Проверка | Reason |
|---|---|
| Неактивный провайдер | `provider_inactive` |
| Нулевая доступность трафика | `zero_traffic` |
| Сумма ниже минимума | `amount_below_minimum` |
| Сумма выше максимума | `amount_exceeds_limit` |
| Дневной лимит | `daily_limit_exceeded` |
| Дневной max по обязательствам | `daily_turnover_max_exceeded` |
| In-progress count/amount | `in_progress_count_exceeded`, `in_progress_amount_exceeded` |
| Банк | `bank_not_in_list` |
| Отрицательная маржа | `negative_margin` |
| Нет реквизитов | `no_requisites` |
| RPM | `rate_limit_exceeded` |

`spacepayments` исключён из обычного soft-scoring и используется только после исчерпания внешнего пула. В constraint chain сохранено специальное исключение, совместимое с публичным валидатором. Hard-фильтры пересчитываются перед каждой retry-попыткой.

## Soft scoring

Профили и веса находятся в `config/routing.yml`. Каждый фактор возвращает значение `0..1`:

1. дефицит доли по числу заявок;
2. дефицит доли по объёму;
3. позиция в каскаде;
4. предпочтительный диапазон суммы;
5. сглаженная историческая конверсия;
6. текущая загрузка и RPM с risk penalty;
7. минимум/максимум дневного оборота.

Итог:

```text
score(provider) = Σ normalized_factor × configured_weight
```

При равенстве используется стабильный tie-breaker: `priority`, затем `payment_system`. В `attempts.score_breakdown` сохраняется доказательство выбора.

## Режимы

- `submission` — полностью воспроизводимый, все выбранные попытки одобряются; предназначен для файлов автопроверки.
- `balanced` — баланс долей, конверсии и нагрузки.
- `conversion_first` — сильнее оптимизирует approval rate.
- `resilience` — заранее разгружает каналы около лимитов.

Seed задан в конфигурации. Один вход и профиль всегда дают идентичный JSON.

Доли `traffic_percentage` / `volume_share_pct` в soft-scoring и отчёте считаются по итоговому `selected_provider` после retry/fallback, а не по промежуточным отказам. In-progress снимается при любом закрытии попытки; дневной оборот растёт только на `approved`.

## Демонстрация retry/fallback

```bash
bundle exec ruby bin/demo
```

Для `op_101` три внешних провайдера последовательно получают `rejected/expired/rejected`, после чего выбирается `spacepayments`. Результат записывается в `demo_decisions.json`, аналитика — в `demo_report.json`.

Через dashboard отказ можно инъецировать для любой пары операция/провайдер. Страница операции показывает audit trail, hard-причины, score breakdown и контрфактическое объяснение.

## Аналитика

`routing_report.json` содержит:

- count/volume distribution и отклонения от целей;
- approved/rejected/expired;
- skip reasons;
- daily/in-progress utilization и `daily_turnover_max`;
- исторические conversion/latency/failure metrics;
- retry/fallback, goal impossibility и explainability coverage;
- `deviation_causes` с причинами отклонений;
- рекомендации с текущим/предлагаемым параметром и человекочитаемые `recommendation_messages`.

Раздел «Сравнение стратегий» прогоняет одну очередь через все профили. Bounded optimizer перебирает 27 прозрачных комбинаций весов и только рекомендует варианты — конфигурация автоматически не меняется.
