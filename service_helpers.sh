#!/bin/bash

get_port_owner() {
    local port="$1"
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1, $2; exit}' || true
}

kill_port_owner() {
    local port="$1"
    local label="$2"
    local owner=""
    local owner_name=""
    local owner_pid=""

    owner=$(get_port_owner "$port")
    if [[ -z "$owner" ]]; then
        echo "Nothing listening on port $port"
        return 0
    fi

    owner_name=$(echo "$owner" | awk '{print $1}')
    owner_pid=$(echo "$owner" | awk '{print $2}')

    echo "Stopping ${label}: killing ${owner_name} (PID ${owner_pid}) on port ${port}..."
    kill "$owner_pid" 2>/dev/null || true
    sleep 1
    if kill -0 "$owner_pid" 2>/dev/null; then
        kill -9 "$owner_pid" 2>/dev/null || true
    fi

    sleep 1
    if [[ -n "$(get_port_owner "$port")" ]]; then
        echo "❌ Port ${port} is still occupied." >&2
        return 1
    fi

    echo "✓ ${label} stopped, port ${port} is free"
}

wait_for_http_ok() {
    local url="$1"
    local attempts="${2:-12}"
    local interval="${3:-2}"
    local attempt=1

    while (( attempt <= attempts )); do
        if curl -fsS "$url" >/dev/null 2>&1; then
            return 0
        fi
        (( attempt == attempts )) && break
        ((attempt++))
        sleep "$interval"
    done

    return 1
}

print_http_status() {
    local label="$1"
    local port="$2"
    local url="$3"
    local owner=""

    owner=$(get_port_owner "$port")
    if [[ -z "$owner" ]]; then
        echo "✗ ${label} is not running (port ${port} is free)"
        return 1
    fi

    if curl -fsS "$url" >/dev/null 2>&1; then
        echo "✓ ${label} is running on ${url} (${owner})"
        return 0
    fi

    echo "⚠ ${label} has a listener on port ${port}, but ${url} did not respond successfully (${owner})"
    return 1
}
