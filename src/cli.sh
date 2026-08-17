git_hook_pure_main() {
  local command=${1:-help}

  case "$command" in
    install)
      shift
      if [ "$#" -ne 0 ]; then
        git_hook_pure_usage >&2
        return 2
      fi
      git_hook_pure_install
      ;;
    uninstall)
      shift
      if [ "$#" -ne 0 ]; then
        git_hook_pure_usage >&2
        return 2
      fi
      git_hook_pure_uninstall
      ;;
    version|--version)
      if [ "$#" -ne 1 ]; then
        git_hook_pure_usage >&2
        return 2
      fi
      git_hook_pure_version
      ;;
    help|-h|--help)
      if [ "$#" -ne 1 ]; then
        git_hook_pure_usage >&2
        return 2
      fi
      git_hook_pure_usage
      ;;
    *)
      printf '[git-hook-pure] unknown command: %s\n' "$command" >&2
      git_hook_pure_usage >&2
      return 2
      ;;
  esac
}
