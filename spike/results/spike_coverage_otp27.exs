%{
  tracer: %{
    messages: 238,
    status: :stopped,
    otp_release: "27",
    started_at: 1795280952718,
    warnings: [],
    backend: :session,
    pattern_updates: 25,
    finished_at: 1795280959093,
    peak_mailbox: 0,
    skipped_processes: 0,
    invalid_calls: 0
  },
  otp: "27",
  elixir: "1.17.0",
  observer: %{
    status: :stopped,
    started_at: 1795280952704,
    handler_failures: [
      %{
        count: 1,
        kind: :error,
        event: [:demo_app, :cache, :miss],
        handler_id: "demo-app-crasher"
      }
    ],
    dropped_events: 0,
    finished_at: 1795280959115,
    total_events: 825,
    callback_errors: 0,
    ets_memory_bytes: 125144,
    sample_rate: 1.0,
    ets_rows: 447,
    recorded_events: 825
  },
  static_scan_ms: 675,
  static_summary: %{
    events: 185,
    unresolved_patterns: 17,
    patterns: 36,
    spans: 50,
    by_status: %{static_only: 170, referenced_only: 15},
    by_confidence: %{resolved: 97, literal: 72, referenced: 15, configured: 1},
    patterns_by_class: %{dynamic: 1, partial: 35},
    wrapper_templates: 16
  },
  predicted_emittable_names: 170,
  fired_names: 79,
  fired_and_predicted: 66,
  recall_percent: 83.5,
  fired_predicted_by_source: %{
    static_literal: 32,
    static_resolved: 33,
    config_rule: 1
  },
  fired_not_predicted: ["bandit.request.exception", "bandit.request.stop",
   "demo_app.cache.evict", "demo_app.cache.hit", "demo_app.cache.miss",
   "demo_app.dynamic.alpha", "demo_app.dynamic.beta", "demo_app.search.query",
   "thousand_island.connection.async_recv", "thousand_island.connection.ready",
   "thousand_island.connection.recv", "thousand_island.connection.send",
   "thousand_island.connection.stop"],
  fired_not_predicted_but_matching_partial_pattern: ["bandit.request.exception",
   "bandit.request.stop", "demo_app.cache.evict", "demo_app.cache.hit",
   "demo_app.cache.miss", "demo_app.search.query",
   "thousand_island.connection.async_recv", "thousand_island.connection.ready",
   "thousand_island.connection.recv", "thousand_island.connection.send",
   "thousand_island.connection.stop"],
  predicted_but_not_fired: 104
}