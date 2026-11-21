%{
  tracer: %{
    messages: 230,
    status: :stopped,
    otp_release: "27",
    started_at: 1795286238338,
    warnings: [],
    finished_at: 1795286244422,
    backend: :session,
    peak_mailbox: 16,
    pattern_updates: 46,
    gate_closures: 0,
    gated_ms: 0,
    skipped_processes: 0,
    invalid_calls: 0
  },
  otp: "27",
  elixir: "1.17.0",
  observer: %{
    status: :stopped,
    started_at: 1795286238316,
    handler_failures: [
      %{
        count: 1,
        kind: :error,
        event: [:demo_app, :cache, :miss],
        handler_id: "demo-app-crasher"
      }
    ],
    dropped_events: 0,
    finished_at: 1795286244449,
    total_events: 827,
    callback_errors: 0,
    ets_memory_bytes: 121880,
    sample_rate: 1.0,
    ets_rows: 425,
    recorded_events: 827
  },
  static_scan_ms: 604,
  static_summary: %{
    events: 185,
    unresolved_patterns: 17,
    patterns: 36,
    spans: 50,
    by_confidence: %{resolved: 97, literal: 72, referenced: 15, configured: 1},
    by_status: %{static_only: 170, referenced_only: 15},
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