#!/bin/bash
# diag-kit wrapper — invoke diagnose.sh + report.sh with the right sudo
# Use this from a normal user shell; it adds sudo where needed.

set -e
CMD_PATH=/opt/diag-kit

case "${1:-}" in
  diagnose)
    shift
    sudo "$CMD_PATH/diagnose.sh" "$@"
    ;;
  report)
    shift
    # If --output is not set, default to a sensible place
    args=("$@")
    output_set=0
    for arg in "${args[@]}"; do
      if [ "$arg" = "--output" ] || [ "$arg" = "-o" ]; then
        output_set=1
        break
      fi
    done
    if [ $output_set -eq 0 ]; then
      # Default to /tmp on the Pi (or the diag-kit dir)
      python3 "$CMD_PATH/report.py" "${args[@]}" --output /tmp/diag-report.html
    else
      python3 "$CMD_PATH/report.py" "${args[@]}"
    fi
    ;;
  open-report)
    # Open the most recent /tmp/diag-report.html in chromium
    if [ -f /tmp/diag-report.html ]; then
      chromium /tmp/diag-report.html &
    else
      echo "no /tmp/diag-report.html — run 'diag-kit report' first" >&2
      exit 1
    fi
    ;;
  raw)
    # List the most recent raw artifacts dir
    ls -t -d /tmp/diag-raw-* 2>/dev/null | head -1
    ;;
  -h|--help|help|"")
    cat <<EOF
diag-kit — network diagnostic station wrapper

Usage:
  diag-kit diagnose [options]    Run the diagnostic battery
                                (passes through to diagnose.sh; uses sudo)

  diag-kit report --input FILE   Generate HTML report
                                (default output: /tmp/diag-report.html)

  diag-kit open-report           Open the latest /tmp/diag-report.html in chromium

  diag-kit raw                   Print the path to the most recent raw artifacts dir

EOF
    ;;
  *)
    echo "Unknown subcommand: $1" >&2
    echo "Run 'diag-kit help' for usage" >&2
    exit 1
    ;;
esac