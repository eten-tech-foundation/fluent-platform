# Bash/Zsh completion for ./fluent.sh
#
# Bash:  add to ~/.bashrc:
#   source /path/to/fluent-platform/completions/fluent.bash
#
# Zsh:   add to ~/.zshrc (bashcompinit bridges bash-style completions):
#   autoload -Uz bashcompinit && bashcompinit
#   source /path/to/fluent-platform/completions/fluent.bash
#
# Keep the word lists below in sync with fluent.sh's dispatchers.

_fluent_complete() {
  local cur prev cword
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  cword=$COMP_CWORD

  local ecosystem="up down restart logs status shell clean fresh build setup check-repos \
    db:migrate db:seed db:init db:psql db:studio repos help"
  local targets="api ai web worker"
  local services="api ai web worker db"

  local api_cmds="up down restart logs shell test lint lint:fix format format:check typecheck run db:migrate db:seed db:generate"
  local ai_cmds="up down restart logs shell test lint lint:fix format format:check typecheck run"
  local web_cmds="up down restart logs shell test lint lint:fix format format:check typecheck precheck preview run"
  local worker_cmds="up down restart logs shell"

  if [ "$cword" -eq 1 ]; then
    COMPREPLY=( $(compgen -W "$ecosystem $targets" -- "$cur") )
    return
  fi

  if [ "$cword" -eq 2 ]; then
    case "${COMP_WORDS[1]}" in
      repos)               COMPREPLY=( $(compgen -W "check sync status" -- "$cur") ) ;;
      api)                 COMPREPLY=( $(compgen -W "$api_cmds" -- "$cur") ) ;;
      ai)                  COMPREPLY=( $(compgen -W "$ai_cmds" -- "$cur") ) ;;
      web)                 COMPREPLY=( $(compgen -W "$web_cmds" -- "$cur") ) ;;
      worker)              COMPREPLY=( $(compgen -W "$worker_cmds" -- "$cur") ) ;;
      db:migrate|db:seed)  COMPREPLY=( $(compgen -W "api ai all" -- "$cur") ) ;;
      up|down|restart|build|clean) COMPREPLY=( $(compgen -W "$targets" -- "$cur") ) ;;
      logs|shell)          COMPREPLY=( $(compgen -W "$services" -- "$cur") ) ;;
    esac
    return
  fi
}

complete -F _fluent_complete fluent.sh ./fluent.sh
