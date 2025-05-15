#!/usr/bin/env bash

main() {
	local max_user_id=100
	local base_url="http://c40:30302/"
	local path_prefix="api/cart/add/anonymous-"
	local path_suffix="/RED/1"
	for ((user_id = 1; user_id <= max_user_id; user_id++)); do
		curl --silent -o /dev/null "${base_url}${path_prefix}${user_id}${path_suffix}"
	done
}

main "$@"
