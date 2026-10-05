#!/usr/bin/env sh
# Запуск ScreenChange из любой директории.
exec python3 "$(dirname "$(readlink -f "$0")")/screenchange.py" "$@"
