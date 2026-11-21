%{
  tracer: %{
    messages: 1769,
    status: :stopped,
    otp_release: "29",
    started_at: 1795290615383,
    warnings: [],
    finished_at: 1795290912998,
    backend: :session,
    peak_mailbox: 78,
    gated_ms: 0,
    pattern_updates: 101,
    gate_closures: 0,
    skipped_processes: 0,
    invalid_calls: 0
  },
  otp: "29",
  elixir: "1.20.1",
  app: "hexpm",
  observer: %{
    status: :stopped,
    total_events: 387167,
    dropped_events: 0,
    callback_errors: 0,
    ets_memory_bytes: 364848,
    ets_rows: 1633
  },
  predicted: 302,
  fired: 123,
  missed: [
    %{
      name: "bandit.request.exception",
      process: "%{initial_call: {Bandit.DelegatingHandler, :init, 1}, registered_name: nil}",
      matches_specific_partial: ["[:bandit, *, :exception]"]
    },
    %{
      name: "bandit.request.stop",
      process: "%{initial_call: {Bandit.DelegatingHandler, :init, 1}, registered_name: nil}",
      matches_specific_partial: ["[:bandit, *, :stop]"]
    },
    %{
      name: "thousand_island.acceptor.einval",
      process: "nil",
      matches_specific_partial: ["[:thousand_island, *, *]"]
    },
    %{
      name: "thousand_island.acceptor.stop",
      process: "nil",
      matches_specific_partial: ["[:thousand_island, *, *]",
       "[:thousand_island, *, :stop]"]
    },
    %{
      name: "thousand_island.connection.async_recv",
      process: "%{initial_call: {Bandit.DelegatingHandler, :init, 1}, registered_name: nil}",
      matches_specific_partial: ["[:thousand_island, *, :async_recv]",
       "[:thousand_island, *, *]"]
    },
    %{
      name: "thousand_island.connection.ready",
      process: "%{initial_call: {Bandit.DelegatingHandler, :init, 1}, registered_name: nil}",
      matches_specific_partial: ["[:thousand_island, *, :ready]",
       "[:thousand_island, *, *]"]
    },
    %{
      name: "thousand_island.connection.recv",
      process: "%{initial_call: {Bandit.DelegatingHandler, :init, 1}, registered_name: nil}",
      matches_specific_partial: ["[:thousand_island, *, :recv]",
       "[:thousand_island, *, *]"]
    },
    %{
      name: "thousand_island.connection.recv_error",
      process: "nil",
      matches_specific_partial: ["[:thousand_island, *, *]",
       "[:thousand_island, *, :recv_error]"]
    },
    %{
      name: "thousand_island.connection.send",
      process: "%{initial_call: {Bandit.DelegatingHandler, :init, 1}, registered_name: nil}",
      matches_specific_partial: ["[:thousand_island, *, *]",
       "[:thousand_island, *, :send]"]
    },
    %{
      name: "thousand_island.connection.stop",
      process: "nil",
      matches_specific_partial: ["[:thousand_island, *, *]",
       "[:thousand_island, *, :stop]"]
    },
    %{
      name: "thousand_island.listener.stop",
      process: "nil",
      matches_specific_partial: ["[:thousand_island, *, *]",
       "[:thousand_island, *, :stop]"]
    }
  ],
  static_scan_ms: 957,
  static_stats: %{
    decoded: 102,
    candidates: 102,
    beams: 2770,
    total_ms: 940,
    indexed: 2770,
    decode_failed: 0,
    analyzed_modules: 116,
    wrapper_rounds: 2,
    wrapper_mfas: 37,
    index_ms: 470,
    analyze_ms: 468
  },
  fired_and_predicted: 112,
  recall_percent: 91.1,
  diagnostics_by_severity: %{info: 413},
  non_info_diagnostics: []
}