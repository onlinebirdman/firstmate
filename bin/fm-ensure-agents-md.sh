#!/usr/bin/env bash
# Ensure a project worktree follows the agent-memory file convention.
#
# Summary
#   AGENTS.md is the real project-intrinsic knowledge file. Each harness memory
#   file below is a real regular file whose canonical content is the two-line
#   @AGENTS.md pointer that the harness inlines at load time: Claude Code reads
#   CLAUDE.md, and CodeBuddy Code reads CODEBUDDY.md. Both are pointers, never
#   symlinks, because a symlink cannot follow a later write into AGENTS.md.
#
# Responsibilities
#   - Create a minimal AGENTS.md skeleton when no memory file exists, promote a
#     real non-canonical pointer file when it is the only memory present (unless
#     it already holds the canonical pointer), convert a correct
#     <pointer> -> AGENTS.md symlink into the pointer file, and refuse to clobber
#     distinct real files or wrong symlinks.
#   - Own the canonical "## Maintaining this file" self-governance wording for
#     project AGENTS.md files, injecting it idempotently into created skeletons,
#     promoted files, and existing AGENTS.md files lacking both the exact heading
#     and the project-owned mark below (exact first line, LF or CRLF):
#     <!-- firstmate:maintained-by-project -->
#     Projects may place this mark at the start of the file and retain equivalent
#     maintenance guidance under their own heading. It declares guidance is
#     present, not permission to remove governance. No prose equivalence is
#     inferred.
#   - Own the canonical pointer content for every harness memory file (the exact
#     two-line @AGENTS.md form per harness label).
#   - Refuse a case-variant real memory file such as a lowercase agents.md, so the
#     pointer's @AGENTS.md import resolves to a real AGENTS.md on a case-sensitive
#     filesystem (issue #389). The real-file pointer also eliminates the old
#     uppercase-literal-target dangling-symlink hazard.
#
# Boundaries (what this file does NOT do)
#   - It is a worktree utility for crewmates, not a supervision script, so it does
#     not call fm-guard.sh and never touches fleet state.
#   - It never deletes or rewrites AGENTS.md content beyond the idempotent
#     maintenance-section injection, and never promotes more than one pointer file.
#
# Usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]
set -eu

usage() {
  echo "usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]" >&2
  cat >&2 <<'EOF'

To retain equivalent project-owned maintenance guidance without adding the
canonical section, use this exact first line of AGENTS.md (LF or CRLF):
<!-- firstmate:maintained-by-project -->
The mark declares retained guidance, not permission to remove governance.
Without the first-line mark or exact canonical heading, the helper adds the section.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac
[ "$#" -le 1 ] || { usage; exit 1; }

DIR=${1:-.}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
DIR=$(cd "$DIR" && pwd -P)
cd "$DIR"

AGENTS=AGENTS.md

# Harness memory files, in promotion precedence order. Claude Code reads
# CLAUDE.md; CodeBuddy Code reads CODEBUDDY.md and supports the same @path import.
POINTERS=(CLAUDE.md CODEBUDDY.md)

pointer_label() {
  case "$1" in
    CLAUDE.md)    printf 'Claude' ;;
    CODEBUDDY.md) printf 'CodeBuddy' ;;
    *)            printf '%s' "$1" ;;
  esac
}

pointer_content() {
  printf '<!-- Points %s at AGENTS.md via import; edit AGENTS.md, not this file. -->\n@AGENTS.md\n' \
    "$(pointer_label "$1")"
}

is_canonical_pointer() {
  local f=$1
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  pointer_content "$f" | cmp -s - "$f"
}

# ptr_state <file> - one of: symlink_ok, symlink_bad, absent, non_regular,
# canonical, real_other.
ptr_state() {
  local f=$1
  if [ -L "$f" ]; then
    if is_correct_agents_symlink "$f"; then printf 'symlink_ok'; else printf 'symlink_bad'; fi
  elif [ ! -e "$f" ]; then
    printf 'absent'
  elif [ ! -f "$f" ]; then
    printf 'non_regular'
  elif is_canonical_pointer "$f"; then
    printf 'canonical'
  else
    printf 'real_other'
  fi
}

conflict() {
  printf 'conflict: %s\n' "$1" >&2
  exit 1
}

write_maintenance_section() {
  cat <<'EOF'
## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
EOF
}

write_maintenance_section_with_eol() {
  local eol=$1 line
  while IFS= read -r line; do
    printf '%s%s' "$line" "$eol"
  done < <(write_maintenance_section)
}

# Idempotently append the canonical self-governance section to AGENTS.md when
# neither its heading nor the first-line project-owned mark is present. Sets
# MAINT_INJECTED=1 when it appends and 0 otherwise, for caller change reporting.
MAINT_INJECTED=0
ensure_maintenance_section() {
  MAINT_INJECTED=0
  if grep -Fqx -e '## Maintaining this file' -e $'## Maintaining this file\r' "$AGENTS" ||
    head -n 1 "$AGENTS" | grep -Fqx -e '<!-- firstmate:maintained-by-project -->' \
      -e $'<!-- firstmate:maintained-by-project -->\r'; then
    return 0
  fi
  local eol=$'\n' sep=''
  if LC_ALL=C grep -q $'\r$' "$AGENTS"; then
    eol=$'\r\n'
  fi
  if [ -s "$AGENTS" ]; then
    if [ -n "$(tail -c 1 "$AGENTS")" ]; then
      sep="${eol}${eol}"
    else
      sep=$eol
    fi
  fi
  {
    printf '%s' "$sep"
    write_maintenance_section_with_eol "$eol"
  } >> "$AGENTS"
  MAINT_INJECTED=1
}

write_skeleton() {
  cat > "$AGENTS" <<'EOF'
# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
EOF
  ensure_maintenance_section
}

# Write a canonical pointer as a regular file. Unlink a symlink first so the write
# cannot follow it and destroy AGENTS.md. Callers classify a distinct real file as
# a conflict before invoking this.
install_pointer() {
  local f=$1 content
  is_canonical_pointer "$f" && return 0
  content=$(pointer_content "$f")
  if [ -L "$f" ]; then
    rm -- "$f"
  elif [ -e "$f" ]; then
    echo "error: internal: refuse to overwrite existing $f" >&2
    exit 1
  fi
  printf '%s\n' "$content" > "$f"
}

# A symlink whose realpath resolves to AGENTS.md. Used to migrate a legacy link
# into the recoverable real-file pointer.
is_correct_agents_symlink() {
  local f=$1 target
  [ -L "$f" ] || return 1
  target=$(readlink "$f")
  case "$target" in
    "$AGENTS"|"./$AGENTS") return 0 ;;
  esac
  [ -e "$AGENTS" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$f" "$AGENTS" <<'PY'
import os
import sys
sys.exit(0 if os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]) else 1)
PY
    return $?
  fi
  return 1
}

# Refuse a case-variant real memory file (issue #389). On a case-insensitive
# filesystem an existing lowercase agents.md satisfies every [ -e AGENTS.md ]
# test below, so the script would emit a pointer whose @AGENTS.md import dangles
# once the tree is checked out on a case-sensitive filesystem. Reading the real
# directory entries catches the mismatch on both filesystem kinds.
for entry in *; do
  if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
    continue
  fi
  if [ "$entry" != "$AGENTS" ]; then
    case "$entry" in
      [Aa][Gg][Ee][Nn][Tt][Ss].[Mm][Dd])
        conflict "memory file is named $entry in $DIR but the convention is AGENTS.md; rename it to AGENTS.md so the @AGENTS.md pointer resolves portably"
        ;;
    esac
  fi
done

if [ -L "$AGENTS" ]; then
  conflict "AGENTS.md is a symlink in $DIR; expected AGENTS.md to be the real file"
fi
if [ -e "$AGENTS" ] && [ ! -f "$AGENTS" ]; then
  conflict "AGENTS.md exists in $DIR but is not a regular file"
fi

# Refuse wrong symlinks and non-regular pointer files before any mutation, so a
# refusal never leaves AGENTS.md or another pointer half-written.
for f in "${POINTERS[@]}"; do
  case "$(ptr_state "$f")" in
    symlink_bad) conflict "$f is a symlink in $DIR but does not point to AGENTS.md" ;;
    non_regular) conflict "$f exists in $DIR but is not a regular file or symlink" ;;
  esac
done

AGENTS_EXISTED=0
PROMOTED=
if [ -e "$AGENTS" ]; then
  AGENTS_EXISTED=1
  for f in "${POINTERS[@]}"; do
    if [ "$(ptr_state "$f")" = real_other ]; then
      conflict "both AGENTS.md and $f are real files in $DIR; reconcile them manually"
    fi
  done
else
  # Promote the first real non-canonical pointer file (highest precedence first)
  # into AGENTS.md rather than writing a fresh skeleton over its content.
  for f in "${POINTERS[@]}"; do
    if [ "$(ptr_state "$f")" = real_other ]; then
      mv "$f" "$AGENTS"
      PROMOTED=$f
      break
    fi
  done
fi

if [ -e "$AGENTS" ]; then
  ensure_maintenance_section
else
  write_skeleton
fi

# Ensure every pointer file is the canonical real-file pointer.
POINTERS_CHANGED=
for f in "${POINTERS[@]}"; do
  case "$(ptr_state "$f")" in
    canonical) : ;;
    absent|symlink_ok)
      install_pointer "$f"
      POINTERS_CHANGED="${POINTERS_CHANGED:+$POINTERS_CHANGED, }$f"
      ;;
  esac
done

if [ -n "$PROMOTED" ]; then
  echo "promoted: moved $PROMOTED to AGENTS.md and wrote ${POINTERS[*]} @AGENTS.md pointers in $DIR"
elif [ "$AGENTS_EXISTED" -eq 0 ]; then
  echo "created: AGENTS.md and wrote ${POINTERS[*]} @AGENTS.md pointers in $DIR"
elif [ -n "$POINTERS_CHANGED" ]; then
  echo "updated: wrote @AGENTS.md pointers for $POINTERS_CHANGED in $DIR"
elif [ "$MAINT_INJECTED" -eq 1 ]; then
  echo "updated: added ## Maintaining this file to AGENTS.md in $DIR"
else
  echo "unchanged: AGENTS.md with ${POINTERS[*]} @AGENTS.md pointers in $DIR"
fi
