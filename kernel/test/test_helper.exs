# Integration tests (those needing the running Python ML service) are excluded
# by default; run them with `mix test --include integration`.
ExUnit.start(exclude: [:integration])
