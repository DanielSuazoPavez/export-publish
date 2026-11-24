#!/usr/bin/env bash
# Plain-bash tests for bin/export-publish. A local bare repo plays `origin`;
# each publish runs in a fresh clone, as a CI checkout would.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EP="$SCRIPT_DIR/../bin/export-publish"

unset GITHUB_OUTPUT
export LC_ALL=C

TMP="$(mktemp -d)"
cleanup() {
	if command -v trash-put >/dev/null 2>&1; then
		trash-put "$TMP"
	else
		rm -rf "$TMP"
	fi
}
trap cleanup EXIT

ORIGIN="$TMP/origin.git"
git init -q --bare -b main "$ORIGIN"

FAILS=0
OUT=""
RC=0

# fresh_clone → prints the path of a new clone of $ORIGIN on branch main.
fresh_clone() {
	local dir
	dir="$(mktemp -d "$TMP/target.XXXXXX")"
	git clone -q "$ORIGIN" "$dir" 2>/dev/null
	if ! git -C "$dir" rev-parse -q --verify HEAD >/dev/null; then
		git -C "$dir" symbolic-ref HEAD refs/heads/main
	fi
	printf '%s' "$dir"
}

# run <args...> → sets OUT (stdout+stderr) and RC.
run() {
	RC=0
	OUT="$("$EP" "$@" 2>&1)" || RC=$?
}

# publish <export-dir> <version> → runs publish in a fresh clone.
publish() {
	local target
	target="$(fresh_clone)"
	run publish "$1" "$target" "$2" "test@abc1234"
}

val() { sed -n "s/^$1=//p" <<<"$OUT"; }

origin_files() { git --git-dir="$ORIGIN" ls-tree -r --name-only main; }
origin_ref() { git --git-dir="$ORIGIN" rev-parse -q --verify "$1" || true; }

result() {
	if [[ "$2" -eq 0 ]]; then
		echo "ok $1"
	else
		echo "FAIL $1"
		printf '  %s\n' "$OUT" >&2
		FAILS=$((FAILS + 1))
	fi
}

# --- source fixtures ---------------------------------------------------------
SRC="$TMP/src"
mkdir -p "$SRC/lib/sub" "$SRC/docs"
echo top >"$SRC/README.md"
echo a >"$SRC/lib/a.py"
echo b >"$SRC/lib/sub/b.py"
echo guide >"$SRC/docs/guide.md"
echo secret >"$SRC/private.txt"

spec() {
	local f="$TMP/spec.$RANDOM$RANDOM"
	printf '%s\n' "$@" >"$f"
	printf '%s' "$f"
}

# 1. stage copies a file, a directory, and a rename --------------------------
case_stage_copies() {
	local out="$TMP/stage1" sp
	sp="$(spec '# exported' '' 'README.md' '  lib  ' 'docs/guide.md ->  manual/index.md')"
	run stage "$SRC" "$out" "$sp"
	[[ $RC -eq 0 ]] || return 1
	[[ "$OUT" == "staged 3 entries into $out" ]] || return 1
	local got
	got="$(cd "$out" && find . -type f | sort | tr '\n' ' ')"
	[[ "$got" == "./README.md ./lib/a.py ./lib/sub/b.py ./manual/index.md " ]] || return 1
	[[ "$(cat "$out/manual/index.md")" == guide ]]
}
rc=0; case_stage_copies || rc=1; result "stage copies file, dir and rename" "$rc"

# 2. stage failures -----------------------------------------------------------
expect_stage_fail() {
	local out="$1" sp="$2" needle="$3"
	run stage "$SRC" "$out" "$sp"
	[[ $RC -eq 1 && "$OUT" == *"$needle"* ]]
}
rc=0; expect_stage_fail "$TMP/s2a" "$(spec 'nope.txt')" "nope.txt" || rc=1
[[ ! -e "$TMP/s2a" ]] || rc=1
result "stage fails on missing src" "$rc"
rc=0; expect_stage_fail "$TMP/s2b" "$(spec '../x')" "../x" || rc=1
expect_stage_fail "$TMP/s2b" "$(spec 'README.md -> a/../../x')" "a/../../x" || rc=1
result "stage fails on .. segment" "$rc"
rc=0; expect_stage_fail "$TMP/s2c" "$(spec '/abs')" "/abs" || rc=1
expect_stage_fail "$TMP/s2c" "$(spec 'README.md -> /etc/x')" "/etc/x" || rc=1
result "stage fails on absolute path" "$rc"
rc=0; mkdir -p "$TMP/s2d" && touch "$TMP/s2d/keep"
expect_stage_fail "$TMP/s2d" "$(spec 'README.md')" "not empty" || rc=1
result "stage fails on non-empty out-dir" "$rc"
rc=0; expect_stage_fail "$TMP/s2e" "$(spec '# only' '   # comments' '')" "no entries" || rc=1
result "stage fails on spec with no entries" "$rc"

# --- publish ------------------------------------------------------------------
EXP1="$TMP/exp1"
mkdir -p "$EXP1/lib"
echo one >"$EXP1/README.md"
echo a >"$EXP1/lib/a.py"
echo gone-later >"$EXP1/old.txt"

# 3. first publish
case_first() {
	publish "$EXP1" 1.0.0
	[[ $RC -eq 0 ]] || return 1
	[[ "$(val pushed)" == true && "$(val tag-created)" == true ]] || return 1
	[[ "$(val version)" == 1.0.0 ]] || return 1
	grep -qx 'previous-version=' <<<"$OUT" || return 1
	[[ "$(origin_files | tr '\n' ' ')" == "README.md lib/a.py old.txt " ]] || return 1
	[[ -n "$(origin_ref refs/tags/v1.0.0)" ]] || return 1
	[[ "$(origin_ref refs/tags/v1.0.0)" == "$(origin_ref refs/heads/main)" ]] || return 1
	[[ "$(git --git-dir="$ORIGIN" log -1 --format='%an <%ae> %s' main)" == \
		"github-actions[bot] <github-actions[bot]@users.noreply.github.com> sync: test@abc1234 v1.0.0" ]]
}
rc=0; case_first || rc=1; result "publish first run pushes and tags" "$rc"
V1_COMMIT="$(origin_ref refs/tags/v1.0.0)"

# 4. same version, same tree
case_same() {
	publish "$EXP1" 1.0.0
	[[ $RC -eq 0 && "$(val pushed)" == false && "$(val tag-created)" == false ]] || return 1
	[[ "$(origin_ref refs/heads/main)" == "$V1_COMMIT" ]]
}
rc=0; case_same || rc=1; result "publish same version is a no-op" "$rc"

# 5. tag deleted on origin → re-tag without a new commit
case_retag() {
	git --git-dir="$ORIGIN" tag -d v1.0.0 >/dev/null
	[[ -z "$(origin_ref refs/tags/v1.0.0)" ]] || return 1
	publish "$EXP1" 1.0.0
	[[ $RC -eq 0 && "$(val pushed)" == false && "$(val tag-created)" == true ]] || return 1
	[[ "$(origin_ref refs/tags/v1.0.0)" == "$V1_COMMIT" ]]
}
rc=0; case_retag || rc=1; result "publish re-tags after tag deletion" "$rc"

# 6. next version with a file removed
EXP2="$TMP/exp2"
cp -a "$EXP1" "$EXP2"
mv "$EXP2/old.txt" "$TMP/old.txt.removed"
echo two >"$EXP2/README.md"
case_next() {
	publish "$EXP2" 1.1.0
	[[ $RC -eq 0 && "$(val pushed)" == true && "$(val tag-created)" == true ]] || return 1
	[[ "$(val previous-version)" == 1.0.0 ]] || return 1
	[[ "$(origin_files | tr '\n' ' ')" == "README.md lib/a.py " ]] || return 1
	[[ "$(origin_ref refs/tags/v1.0.0)" == "$V1_COMMIT" ]] || return 1
	[[ "$(origin_ref refs/tags/v1.1.0)" == "$(origin_ref refs/heads/main)" ]] || return 1
	[[ "$V1_COMMIT" != "$(origin_ref refs/heads/main)" ]]
}
rc=0; case_next || rc=1; result "publish next version replaces tree, keeps old tag" "$rc"

# 7. bad versions
case_bad_version() {
	local target v
	target="$(fresh_clone)"
	for v in 1.0 v1.0.0; do
		run publish "$EXP1" "$target" "$v" "test@abc1234"
		[[ $RC -eq 1 && "$OUT" == *"invalid version"* ]] || return 1
	done
}
rc=0; case_bad_version || rc=1; result "publish rejects 1.0 and v1.0.0" "$rc"

# 8. GITHUB_OUTPUT
case_github_output() {
	local gho="$TMP/gh-output"
	: >"$gho"
	GITHUB_OUTPUT="$gho" publish "$EXP2" 1.1.0
	[[ $RC -eq 0 ]] || return 1
	[[ "$(cat "$gho")" == $'version=1.1.0\nprevious-version=1.0.0\npushed=false\ntag-created=false' ]]
}
rc=0; case_github_output || rc=1; result "publish writes four keys to GITHUB_OUTPUT" "$rc"

# 9. usage errors
rc=0; run bogus; [[ $RC -eq 2 ]] || rc=1
run publish a b c; [[ $RC -eq 2 ]] || rc=1
run stage a b; [[ $RC -eq 2 ]] || rc=1
result "unknown subcommand or wrong arity exits 2" "$rc"

if [[ $FAILS -gt 0 ]]; then
	echo "$FAILS failed" >&2
	exit 1
fi
echo "all passed"
