%% Spike fixture: Erlang module emitting telemetry.
-module(demo_erl_telemetry).
-export([tick/1, work/1]).

tick(N) ->
    telemetry:execute([demo_erl, tick], #{count => N}, #{source => erlang}).

work(N) ->
    telemetry:span([demo_erl, work], #{n => N}, fun() -> {N * 2, #{n => N}} end).
