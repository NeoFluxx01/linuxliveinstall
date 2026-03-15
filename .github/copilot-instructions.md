---
applyTo: "**"
---

# Copilot Instructions for linuxliveinstall

## Project Context
Bash scripts installing portable Linux (primarily Kali) onto ZFS-encrypted USB SSDs with full UEFI Secure Boot. See CLAUDE.md for comprehensive architecture docs.

## Key Rules
- All scripts use `set -euo pipefail`
- Lib files guard against double-source: `[[ -z "${_LIB_X_LOADED:-}" ]] || return 0`
- Use `info()`, `warn()`, `error()`, `phase()` for output — never raw `echo` in orchestrators
- Every `grep` in a pipeline that may return 0 matches must use `{ grep ... || true; }`
- Preserve unmount ordering in `cleanup_mounts()`: sys → proc → dev → ESP → run
- Keep `zpool create -f` on rpool (prevents stale pool reference failures)
- Loop device handling: `partx --update`, `loop[0-9]+\S*` in vdev regex
- Chroot scripts embed `apt_retry()` inline (can't source host libs from chroot)
- Template placeholders `__DISK__`, `__HOSTID__`, `__PART_ESP__`, `__DISTRO_NAME__` are sed-replaced before chroot execution

## Testing
- Syntax: `bash -n install-kali-zfs.sh lib/*.sh`
- Unit: `bats test/unit/`
- VM: See test/README.md
