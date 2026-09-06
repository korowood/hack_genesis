FROM ruby:3.3-slim AS builder

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock* ./
RUN bundle install

FROM ruby:3.3-slim

WORKDIR /app

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY . .

EXPOSE 4567

CMD ["bundle", "exec", "ruby", "bin/dashboard"]
