#!/usr/bin/env bash
# Runs on the source host: heracles-backup sends this script over SSH and reads
# one archive or dump from its standard output. Nothing is written to the host's
# disk. Needs bash, git and a user in the docker group (no sudo).
set -euo pipefail

# Containers to unpause on exit. Global: the EXIT trap runs after functions return.
PAUSED=()
unpause_all() {
	local container
	for container in "${PAUSED[@]}"; do
		docker unpause "$container" >/dev/null || true
	done
}
trap unpause_all EXIT

die() {
	echo "remote: $*" >&2
	exit 1
}

# Plain SQL dump of a container running the official postgres image.
dump_postgres() {
	local container=$1
	# shellcheck disable=SC2016 # expanded inside the container
	docker exec "$container" sh -c \
		'exec pg_dump --username="$POSTGRES_USER" --dbname="${POSTGRES_DB:-$POSTGRES_USER}" --clean --if-exists'
}

# tar of a whole named volume.
archive_volume() {
	local volume=$1 image=$2
	# Checked first: `docker run -v` would silently create a missing volume.
	docker volume inspect "$volume" >/dev/null 2>&1 || die "no such volume: $volume"
	docker run --rm --network none -v "$volume":/src:ro "$image" \
		tar --create --file=- --directory=/src --numeric-owner .
}

# tar of a host path, read by a helper container so root-owned files work.
archive_path() {
	local path=$1 image=$2
	# Checked first: `docker run -v` would create a missing path as an empty directory.
	[[ -e $path ]] || die "no such path: $path"
	docker run --rm --network none -v "$path":/src:ro "$image" \
		tar --create --file=- --directory=/src --numeric-owner .
}

# Prints, NUL-separated and relative to the deploy root, what git cannot give
# back: untracked and ignored files of a repository, or every file of a
# directory that is not a repository.
list_project_files() {
	local root=$1 project=$2 dir top
	dir=$root/$project
	[[ -d $dir ]] || die "no such project directory: $project"
	top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)
	if [[ $top == "$(cd "$dir" && pwd -P)" ]]; then
		# --others without --exclude-standard also lists ignored files.
		git -C "$dir" ls-files -z --others | while IFS= read -r -d '' file; do
			printf '%s\0' "$project/$file"
		done
	else
		(cd "$root" && find "$project" \( -type f -o -type l \) -print0)
	fi
}

# tar of the deployment files that git cannot give back.
# Usage: files ROOT IMAGE [--pause CONTAINER]... [--exclude PATH]... PROJECT...
archive_files() {
	local root image pause=() excludes=() projects=()
	root=$(cd "$1" && pwd -P) || die "no such deploy root: $1"
	image=$2
	shift 2
	while (($#)); do
		case $1 in
		--pause) pause+=("$2") && shift 2 ;;
		--exclude) excludes+=("${2%/}") && shift 2 ;;
		*) projects+=("$1") && shift ;;
		esac
	done
	((${#projects[@]})) || die "no project to archive"

	local list
	list=$(
		for project in "${projects[@]}"; do
			list_project_files "$root" "$project"
		done | while IFS= read -r -d '' file; do
			for exclude in "${excludes[@]}"; do
				[[ $file == "$exclude" || $file == "$exclude"/* ]] && continue 2
			done
			printf '%s\n' "$file"
		done
	)
	[[ -n $list ]] || die "no file to archive under $root"

	# Paused so that SQLite databases and the like are copied in a consistent state.
	for container in "${pause[@]}"; do
		docker pause "$container" >/dev/null || die "cannot pause $container"
		PAUSED+=("$container")
	done

	tr '\n' '\0' <<<"$list" |
		docker run --rm -i --network none -v "$root":/src:ro "$image" \
			tar --create --file=- --directory=/src --numeric-owner --null --files-from=-
}

main() {
	local command=${1:-}
	shift || true
	case $command in
	postgres) dump_postgres "$@" ;;
	volume) archive_volume "$@" ;;
	path) archive_path "$@" ;;
	files) archive_files "$@" ;;
	*) die "unknown command: $command" ;;
	esac
}

# Last line: bash has read the whole script from stdin before anything runs.
main "$@"
