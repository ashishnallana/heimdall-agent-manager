package contracts

// Keep APP_VERSION in sync with flake.nix appVersion for releases.
APP_VERSION :: #config(HAM_APP_VERSION, "0.3.37")
GIT_COMMIT :: #config(HAM_GIT_COMMIT, "877a8a84")
BUILD_TIMESTAMP :: #config(HAM_BUILD_TIMESTAMP, "2026-10-12T04:43:56Z")
PROTOCOL_VERSION :: 1

ROUTE_HEALTH :: "/health"
ROUTE_REGISTER :: "/register"
ROUTE_RECONNECT :: "/reconnect"
ROUTE_HEARTBEAT :: "/heartbeat"
ROUTE_WS_PREFIX :: "/ws"
ROUTE_AGENT_RPC :: "/agent-rpc"
ROUTE_AGENTS_START :: "/agents/start"
