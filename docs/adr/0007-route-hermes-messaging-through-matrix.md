# Route Hermes messaging through Matrix

The Matrix Bridge Platform is the canonical messaging hub for Hermes: external
networks connect through dedicated Matrix application-service bridges, and
Hermes consumes Matrix through its adapter. The direct `hermes-signal` workload
was retired after direct encrypted Matrix-to-Hermes messaging was verified. The
planned Signal-to-Matrix-to-Hermes tracer was not accepted, and the operator
explicitly chose not to keep debugging or retain a parallel Signal route.

This supersedes the original cutover gate that required the Signal tracer before
retirement. The narrower accepted outcome is direct Matrix messaging without a
Hermes-owned Signal integration; mautrix-signal remains independently owned by
the Matrix Bridge Platform and is not evidence of a Hermes Signal route.
