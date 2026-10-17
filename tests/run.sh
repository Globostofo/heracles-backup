#!/usr/bin/env bash
# Integration test on the local Docker: a fake host (ssh replaced by
# tests/fake-ssh) and a real restic repository in a temporary directory.
set -euo pipefail
cd "$(dirname "$0")/.."

image=debian:bookworm-slim
id=heracles-backup-test-$$
tmp=$(mktemp -d)
home=$tmp/home

ok() { echo "ok - $*"; }
fail() {
	echo "FAIL - $*" >&2
	exit 1
}

cleanup() {
	docker rm -f "$id-db" "$id-app" >/dev/null 2>&1 || true
	docker volume rm "$id-vol" >/dev/null 2>&1 || true
	# Root-owned files created through Docker.
	docker run --rm -v "$tmp":/tmp/t "$image" rm -rf /tmp/t/home/etc >/dev/null 2>&1 || true
	rm -rf "$tmp"
}
trap cleanup EXIT

snapshot_count() {
	./heracles-backup restic snapshots --json | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))'
}

echo "# setting up the fake host"
mkdir -p "$home/deploy/app" "$home/deploy/static" "$home/etc/vpn"
(
	cd "$home/deploy/app"
	git init -q
	printf '.env\nbuild/\n' >.gitignore
	echo tracked >compose.yml
	git add .
	git -c user.name=test -c user.email=test@example.com commit -qm init
	echo SECRET=1 >.env
	echo new >untracked.txt
	mkdir build && echo rebuilt >build/out
)
echo KEY=2 >"$home/deploy/static/.env"
echo static >"$home/deploy/static/compose.yml"
docker run --rm -v "$home/etc/vpn":/d "$image" sh -c 'echo ca >/d/ca.key && chmod 600 /d/ca.key'

docker run -d --name "$id-db" -e POSTGRES_PASSWORD=test -e POSTGRES_USER=app -e POSTGRES_DB=appdb postgres:16-alpine >/dev/null
for _ in $(seq 60); do
	docker exec "$id-db" pg_isready -U app -d appdb >/dev/null 2>&1 && break
	sleep 1
done
sleep 2 # the official image restarts once after its first initialisation
for _ in $(seq 30); do
	docker exec "$id-db" psql -U app -d appdb -qc "create table t (v text); insert into t values ('hello-from-db')" 2>/dev/null && break
	sleep 1
done
docker volume create "$id-vol" >/dev/null
docker run --rm -v "$id-vol":/v "$image" sh -c 'echo token >/v/token'
docker run -d --name "$id-app" "$image" sleep infinity >/dev/null

cat >"$tmp/backup.conf" <<EOF
SSH_COMMAND=("$PWD/tests/fake-ssh")
SSH_HOST=test-host
SOURCE_NAME=test
RESTIC_REPOSITORY=$tmp/repo
RESTIC_PASSWORD_FILE=$tmp/secret/password
POSTGRES=($id-db)
VOLUMES=($id-vol)
HOST_PATHS=($home/etc/vpn)
DEPLOY_ROOT=deploy
PROJECTS=(app static)
EXCLUDES=(app/build)
PAUSE=($id-app)
HELPER_IMAGE=$image
KEEP_LAST=2
EOF
mkdir -m 700 "$tmp/run"
export HERACLES_BACKUP_CONFIG=$tmp/backup.conf FAKE_HOME=$home XDG_RUNTIME_DIR=$tmp/run

echo "# init"
./heracles-backup init >/dev/null 2>&1
[[ -s $tmp/secret/password && $(stat -c %a "$tmp/secret/password") == 600 ]] || fail "password file missing or readable by others"
ok "init creates the repository and a private password file"

echo "# run"
./heracles-backup run >"$tmp/run.log" 2>&1 || {
	cat "$tmp/run.log"
	fail "run failed"
}
ok "run succeeds"
[[ $(snapshot_count) == 1 ]] || fail "expected one snapshot"
[[ ! -e $tmp/run/heracles-backup ]] || fail "staging directory left behind"
ok "staging directory removed"
[[ $(docker inspect -f '{{.State.Paused}}' "$id-app") == false ]] || fail "container left paused"
ok "paused container resumed"

echo "# restore"
./heracles-backup restore "$tmp/out" >/dev/null 2>&1
data=$tmp/out$tmp/run/heracles-backup/data
grep -q hello-from-db "$data/postgres/$id-db.sql" || fail "postgres dump"
ok "postgres dump restored"
[[ $(tar -xOf "$data/volumes/$id-vol.tar" ./token) == token ]] || fail "volume archive"
ok "volume archive restored"
path_archive=${home#/}
[[ $(tar -xOf "$data/paths/${path_archive//\//_}_etc_vpn.tar" ./ca.key) == ca ]] || fail "root-owned host path"
ok "root-owned host path restored"
expected=$'app/.env\napp/untracked.txt\nstatic/.env\nstatic/compose.yml'
actual=$(tar -tf "$data/deployment.tar" | LC_ALL=C sort)
[[ $actual == "$expected" ]] || fail "deployment files: got [$actual]"
ok "deployment archive holds only what git lacks, without excluded paths"

echo "# retention"
./heracles-backup run >/dev/null 2>&1
./heracles-backup run >/dev/null 2>&1
[[ $(snapshot_count) == 2 ]] || fail "KEEP_LAST not applied"
ok "old snapshots forgotten"

echo "# failure"
echo "VOLUMES=($id-vol $id-missing)" >>"$tmp/backup.conf"
if ./heracles-backup run >"$tmp/fail.log" 2>&1; then
	fail "run should fail on a missing volume"
fi
grep -q "no such volume: $id-missing" "$tmp/fail.log" || fail "unclear error: $(cat "$tmp/fail.log")"
[[ $(snapshot_count) == 2 ]] || fail "a failed run saved a snapshot"
[[ ! -e $tmp/run/heracles-backup ]] || fail "staging directory left after a failure"
docker volume inspect "$id-missing" >/dev/null 2>&1 && fail "missing volume was created"
ok "a failed run saves nothing and creates nothing on the host"

echo "all tests passed"
