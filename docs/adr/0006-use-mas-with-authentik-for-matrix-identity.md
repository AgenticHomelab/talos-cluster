# Use MAS with Authentik for Matrix identity

The Matrix Bridge Platform uses Matrix Authentication Service for Matrix-native sessions and delegates human authentication to Authentik. This adds a service and database compared with Synapse's built-in OIDC support, but starts the new deployment on Synapse's stable OIDC-based authentication model and avoids a later migration of users, devices, sessions and upstream identity mappings.
